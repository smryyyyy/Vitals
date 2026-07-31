import SwiftUI

/// Modal settings window for the MiniMax credentials. Persists to the
/// macOS Keychain on save and offers a "测试连接" button that exercises
/// the same auth path the background poller uses.
public struct MinimaxSettingsView: View {
    @Bindable var manager: MinimaxManager

    @State private var token: String = ""
    @State private var session: String = ""
    @State private var groupId: String = ""

    @AppStorage(WidgetSettings.minimaxRefreshIntervalKey)
    private var refreshMinutes: Double = WidgetSettings.defaultMinimaxRefreshInterval

    @State private var testResult: String?
    @State private var testIsError: Bool = false
    @State private var isTesting: Bool = false

    public init(manager: MinimaxManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MiniMax 用量")
                .font(.headline)
            Text("从 platform.minimaxi.com 的 DevTools 里复制以下三个值。")
                .foregroundStyle(.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "_token (JWT)", text: $token)
                field(label: "HERTZ-SESSION", text: $session)
                field(label: "minimax_group_id_v2", text: $groupId)
            }

            HStack {
                Button("测试连接") { testConnection() }
                    .disabled(isTesting || !canSave)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                Spacer()
            }

            Divider()

            HStack {
                Text("刷新间隔")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $refreshMinutes) {
                    ForEach(WidgetSettings.minimaxRefreshIntervalOptions, id: \.self) { mins in
                        Text(formatMinutes(mins)).tag(mins)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: refreshMinutes) { _, newValue in
                    manager.restart()
                }
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(testIsError ? .red : .green)
            }

            if let snapshot = manager.snapshot, let err = snapshot.error {
                Text("当前状态: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if manager.snapshot != nil {
                Text("当前状态: 已配置，正在拉取…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 460, height: 340)
        .onAppear { loadFromKeychain() }
    }

    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
            && !session.trimmingCharacters(in: .whitespaces).isEmpty
            && !groupId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private func field(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// "1" → "1 分钟", "5" → "5 分钟" — keeps the picker labels in Chinese.
    private func formatMinutes(_ value: Double) -> String {
        // 整数显示成 "5 分钟",小数显示成 "0.5 分钟"
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value)) 分钟"
        }
        return String(format: "%.1f 分钟", value)
    }

    private func loadFromKeychain() {
        guard let creds = MinimaxKeychain.load() else { return }
        token = creds.token
        session = creds.session
        groupId = creds.groupId
    }

    private func save() {
        let creds = MinimaxCredentials(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            session: session.trimmingCharacters(in: .whitespacesAndNewlines),
            groupId: groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try MinimaxKeychain.save(creds)
            testResult = "已保存到 Keychain"
            testIsError = false
            manager.refresh()
        } catch {
            testResult = "保存失败: \(error.localizedDescription)"
            testIsError = true
        }
    }

    private func testConnection() {
        let creds = MinimaxCredentials(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            session: session.trimmingCharacters(in: .whitespacesAndNewlines),
            groupId: groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isTesting = true
        testResult = nil
        Task {
            do {
                _ = try await MinimaxClient(credentials: creds).fetchUsage()
                testResult = "连接成功"
                testIsError = false
            } catch {
                testResult = "连接失败: \(error.localizedDescription)"
                testIsError = true
            }
            isTesting = false
        }
    }
}
