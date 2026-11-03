# Swift Testing in Command Line Tools (without full Xcode) ships as a separate
# framework; the SwiftPM test runner needs a global -F flag, otherwise
# canImport(Testing) == false and tests silently do not run.
FRAMEWORKS = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTFLAGS = -Xswiftc -F -Xswiftc $(FRAMEWORKS)

APP_NAME = Vitals
DIST_DIR = dist
DIST = $(DIST_DIR)/$(APP_NAME).app

# 组装暂存目录:必须在 /tmp(/private/tmp),**不能**放项目目录里。
#
# 项目目录在 iCloud/FileProvider 管理下,新建的目录会被后台异步打上
# `com.apple.fileprovider.fpfs#P` + `com.apple.FinderInfo` —— codesign 直接拒签
# (`resource fork, Finder information, or similar detritus not allowed`)。
# 间歇性失败的原因就在「异步」二字:清理跑完之后 fileprovider 才动手把属性
# 打回来,于是同一个 Makefile 时好时坏。/tmp 不受 FileProvider 管理,干净。
STAGE_ROOT = /tmp/$(APP_NAME)-stage
STAGE = $(STAGE_ROOT)/$(APP_NAME).app

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
	# 组装在 /tmp 做 —— 见上面 STAGE 的注释:项目目录里组装会被 FileProvider
	# 异步打上 FinderInfo/fpfs#P,codesign 间歇性拒签。
	rm -rf "$(STAGE_ROOT)" "$(DIST)"
	mkdir -p "$(STAGE)/Contents/MacOS"
	cp .build/release/MoleWidget "$(STAGE)/Contents/MacOS/MoleWidget"
	cp Resources/Info.plist "$(STAGE)/Contents/Info.plist"
	mkdir -p "$(STAGE)/Contents/Resources"
	cp Resources/AppIcon.icns "$(STAGE)/Contents/Resources/AppIcon.icns"
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$(STAGE)/Contents/MacOS/MoleWidget"
	$(MAKE) scrub-xattrs TARGETS="$(STAGE)"
	codesign --force --sign - "$(STAGE)"
	# `cp -R` 不会创建缺失的父目录:dist/ 是 gitignore 的,全新克隆时根本不存在,
	# 少了这一行 `make app` 会直接失败(No such file or directory)。
	mkdir -p "$(DIST_DIR)"
	cp -R "$(STAGE)" "$(DIST)"
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
#
# `find -depth`(后序遍历)是关键:默认的前序遍历会在改写目录元数据后让 find 的
# fd 指向已被替换的 inode,**顶层目录**的 FinderInfo 会漏删,随后 codesign 报
# `resource fork, Finder information, or similar detritus not allowed`
# —— 而这个错不指认具体文件,极难定位。后序遍历让每个目录都在其子项处理完之后
# 才被改写,漏删就不会发生。
scrub-xattrs:
	@for t in $(TARGETS) "$(DIST)"; do \
		[ -e "$$t" ] || continue; \
		find "$$t" -depth 2>/dev/null | while read -r p; do \
			for a in com.apple.FinderInfo com.apple.ResourceFork com.apple.quarantine; do \
				xattr -d "$$a" "$$p" 2>/dev/null || true; \
			done; \
			xattr -d 'com.apple.fileprovider.fpfs#P' "$$p" 2>/dev/null || true; \
		done; \
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
