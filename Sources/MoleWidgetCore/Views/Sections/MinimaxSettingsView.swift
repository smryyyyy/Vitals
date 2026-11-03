import SwiftUI

/// Modal settings window for the MiniMax credentials. Persists to the
/// macOS Keychain on save and offers a "测试连接" button that exercises
/// the same auth path the background poller uses.
public struct MinimaxSettingsView: View {
    @Bindable var manager: MinimaxManager

    @State private var token: String = ""
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
            Text("从 platform.minimaxi.com 的 DevTools 里复制以下两个值。")
                .foregroundStyle(.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "_token (JWT)", text: $token)
                field(label: "minimax_group_id_v2", text: $groupId)
            }

            HStack {
                Button("测试连接") { testConnection() }
                    .disabled(isTesting || !canSave)
                // 自动续期每天 04:00 才跑,用户没法主动确认它是否工作 ——
                // 这个按钮让用户随时强制走一遍完整链路。
                Button("立即续期") { renewNow() }
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

            if let error = manager.lastError {
                Text("当前状态: \(error.message)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if manager.snapshot != nil {
                Text("当前状态: 已配置，正在拉取…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Token 有效期与续期状态 —— 常驻显示。用户得看得到「还剩多久」,
            // 否则只能靠「没过期」反推自动续期是否在跑。
            tokenStatusView
            renewalScheduleView
            // 续期失败必须有自己的出口:用量还能正常拉,界面一片正常,
            // 但 token 一直没换新 —— 只靠"用量正常"根本发现不了。
            if let renewalError = manager.lastRenewalError {
                Text("自动续期失败: \(renewalError.errorDescription ?? "未知原因")")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let renewalAt = manager.lastRenewalAt {
                Text("最近续期: \(renewalAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 460, height: 430)
        .onAppear { loadFromKeychain() }
    }

    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty
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

    /// Token 剩余有效期。读不出来时给一句中性提示,不装作"一切正常"。
    @ViewBuilder
    private var tokenStatusView: some View {
        if let expiry = manager.tokenExpiry {
            let days = expiry.timeIntervalSinceNow / 86_400
            if days > 0 {
                Text("Token 剩余 \(Int(days.rounded())) 天(\(expiry.formatted(date: .abbreviated, time: .omitted)) 到期)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Token 已过期,请重新抓取")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } else {
            Text("Token 有效期未知(保存后自动显示)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 自动续期时刻:每天几点跑、下一次是什么时候。
    ///
    /// 三种状态分开说,不能混:
    ///  - 待补续:今天到点了但还没续(发生在下一次拉取时,没有固定时刻)
    ///  - 有明确的下次时刻:今天还没到点,或今天已续过等明天
    @ViewBuilder
    private var renewalScheduleView: some View {
        let hour = WidgetSettings.minimaxDailyRenewalHour
        if manager.isRenewalOverdue {
            // 显示一个已经过去的时刻(比如"下次 今天 04:00")会误导人 ——
            // 那个时刻要么不会续(今天已续过),要么已经过去了。
            Text("自动续期: 每天 \(hour) 点(今天待补续,下次拉取时自动执行)")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let next = manager.nextRenewalDate {
            Text("自动续期: 每天 \(hour) 点(下次 \(next.formatted(date: .abbreviated, time: .shortened)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("自动续期: 每天 \(hour) 点")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 「1」 → 「1 分钟」,「5」 → 「5 分钟」 — keeps the picker labels in Chinese.
    private func formatMinutes(_ value: Double) -> String {
        // 整数显示成 "5 分钟",小数显示成 "0.5 分钟"
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value)) 分钟"
        }
        return String(format: "%.1f 分钟", value)
    }

    private func loadFromKeychain() {
        // 只有真的读到才回填。锁屏时 Keychain 返回"读不出来",
        // 这时候把框清空等于让用户以为配置丢了。
        if case .found(let creds) = MinimaxKeychain.load() {
            token = creds.token
            groupId = creds.groupId
        }
    }

    private func save() {
        let creds = MinimaxCredentials(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
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
            groupId: groupId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isTesting = true
        testResult = nil
        Task {
            do {
                _ = try await MinimaxClient(credentials: creds).fetchUsage()
                testResult = "连接成功"
                testIsError = false
            } catch let error as MinimaxError {
                // 和浮窗共用同一套分类文案,两边说法不会打架
                testResult = "连接失败: \(error.kind.message)"
                testIsError = true
            } catch {
                testResult = "连接失败: \(error.localizedDescription)"
                testIsError = true
            }
            isTesting = false
        }
    }

    /// 手动续期:强制走一遍「换 token → 写回 Keychain → 刷新用量」。
    private func renewNow() {
        isTesting = true
        testResult = nil
        Task {
            if let failure = await manager.renewNow() {
                testResult = "续期失败: \(failure)"
                testIsError = true
            } else {
                testResult = "续期成功,新 token 已写回 Keychain"
                testIsError = false
            }
            isTesting = false
        }
    }
}
