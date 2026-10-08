# Swift Testing in Command Line Tools (without full Xcode) ships as a separate
# framework; the SwiftPM test runner needs a global -F flag, otherwise
# canImport(Testing) == false and tests silently do not run.
FRAMEWORKS = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTFLAGS = -Xswiftc -F -Xswiftc $(FRAMEWORKS)

APP_NAME = Vitals
DIST = dist/$(APP_NAME).app

# Cursor themes live outside the bundle on purpose.
#
# The .ani files were downloaded from the web, so macOS 26 tags them with
# `com.apple.provenance`. That attribute cannot be stripped (xattr -d,
# `cp -X`, `ditto --norsrc` and rewriting the file all fail) and codesign
# refuses any bundle containing a file that carries it. Keeping the themes
# in Application Support sidesteps signing entirely and lets the user swap
# themes without reinstalling.
CURSOR_SUPPORT = $(HOME)/Library/Application Support/$(APP_NAME)/Cursors

.PHONY: run test app cursors install clean scrub-xattrs

run:
	swift run MoleWidget

# make test            — run all tests
# make test FILTER=Fmt — run only suites/tests matching FILTER
test:
	swift test $(TESTFLAGS) $(if $(FILTER),--filter $(FILTER))

# Copies the bundled .ani themes to Application Support.
cursors:
	@mkdir -p "$(CURSOR_SUPPORT)"
	@cp Resources/Cursors/*.ani "$(CURSOR_SUPPORT)/"
	@echo "Installed $$(ls "$(CURSOR_SUPPORT)"/*.ani | wc -l | tr -d ' ') cursor files to $(CURSOR_SUPPORT)"

app:
	swift build -c release
	# This tree sits under directories macOS 26 has stamped with
	# `com.apple.provenance` (the build directory and the downloaded .ani assets
	# alike). codesign refuses any bundle containing such a file, and the
	# attribute is inherited by whatever `cp` creates — intermittently, which
	# makes this look like a flaky build. Strip it from every source before
	# copying and from the assembled bundle before signing, so it never depends
	# on whether the attribute happened to propagate.
	xattr -cr .build/release
	xattr -cr Resources
	rm -rf "$(DIST)"
	mkdir -p "$(DIST)/Contents/MacOS"
	cp .build/release/MoleWidget "$(DIST)/Contents/MacOS/MoleWidget"
	cp Resources/Info.plist "$(DIST)/Contents/Info.plist"
	mkdir -p "$(DIST)/Contents/Resources"
	cp Resources/AppIcon.icns "$(DIST)/Contents/Resources/AppIcon.icns"
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$(DIST)/Contents/MacOS/MoleWidget"
	$(MAKE) scrub-xattrs "$(DIST)"
	codesign --force --sign - "$(DIST)"
	$(MAKE) cursors
	@echo "Done: $(DIST)"

# Removes the extended attributes codesign refuses.
#
# `xattr -cr` is not enough: this tree lives under directories macOS 26 has
# stamped with `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P`
# (the build directory and the downloaded .ani assets alike), and those two —
# not `com.apple.provenance`, which codesign tolerates — abort the signing step.
# They also reappear on whatever `cp` creates, so they must be stripped from the
# source *and* from the assembled bundle, and `xattr -cr` cannot remove them.
scrub-xattrs:
	@for t in $(TARGETS) "$(DIST)"; do \
		[ -e "$$t" ] || continue; \
		find "$$t" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true; \
		find "$$t" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true; \
		find "$$t" -exec xattr -cr {} \; 2>/dev/null || true; \
		xattr -d com.apple.FinderInfo "$$t" 2>/dev/null || true; \
		xattr -d 'com.apple.fileprovider.fpfs#P' "$$t" 2>/dev/null || true; \
	done
	@true

# app + copy into /Applications
install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R "$(DIST)" /Applications/
	$(MAKE) scrub-xattrs TARGETS=/Applications/$(APP_NAME).app
	codesign --force --sign - /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf .build dist
