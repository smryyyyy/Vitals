import SwiftUI

/// Settings window for the salary module. Edits a local copy of
/// `SalarySettings` and only commits back to the manager on "保存".
/// "取消" discards; "恢复默认" resets to the factory default first.
public struct SalarySettingsView: View {
    @Bindable var manager: SalaryManager

    /// 取消时调用的回调(用于关窗)。默认 nil,保持向后兼容。
    private let onCancel: (() -> Void)?

    // 编辑期间本地状态 — 保存时才落回 manager
    @State private var monthlyNetSalaryText: String = ""
    @State private var clockInDate: Date = SalarySettingsView.dateFromMinute(9 * 60)
    @State private var clockOutDate: Date = SalarySettingsView.dateFromMinute(18 * 60)
    @State private var lunchStartDate: Date = SalarySettingsView.dateFromMinute(12 * 60)
    @State private var lunchEndDate: Date = SalarySettingsView.dateFromMinute(13 * 60)
    @State private var includeLunch: Bool = true
    @State private var hasHireDate: Bool = false
    @State private var hireDate: Date = Date()
    /// 顶部展示的"当前月工作日"以哪个日期为准(打开窗口时为 Date())
    @State private var workdaysReferenceDate: Date = Date()

    public init(manager: SalaryManager, onCancel: (() -> Void)? = nil) {
        self.manager = manager
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("工资设置")
                .font(.headline)
            Text("按月配置薪资,实时计算今日已赚、累计本月、累计在职。")
                .foregroundStyle(.secondary)
                .font(.caption)

            Form {
                Section("基本") {
                    numberField(
                        label: "月薪(税后)",
                        text: $monthlyNetSalaryText,
                        unit: "元"
                    )
                    HStack {
                        Text("月工作天数")
                        Spacer()
                        Text("\(currentMonthWorkdays) 天")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text("按中国法定节假日 + 调休自动计算,2027 年数据未更新")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("时间") {
                    timeField(label: "上班", date: $clockInDate)
                    timeField(label: "下班", date: $clockOutDate)
                    timeField(label: "午休开始", date: $lunchStartDate)
                    timeField(label: "午休结束", date: $lunchEndDate)
                    Toggle("午休计入收入", isOn: $includeLunch)
                        .help("开启:午休时间按工作时计算;关闭:午休时间不算工资")
                }

                Section("在职累计 (可选)") {
                    Toggle("设置入职日期", isOn: $hasHireDate)
                    if hasHireDate {
                        DatePicker(
                            "入职日期",
                            selection: $hireDate,
                            displayedComponents: [.date]
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 360)

            HStack {
                Button("恢复默认") { resetToDefault() }
                Spacer()
                Button("取消") {
                    loadFromManager()
                    onCancel?()
                }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .onAppear {
            workdaysReferenceDate = Date()
            loadFromManager()
        }
    }

    private var currentMonthWorkdays: Int {
        let cal = ChineseWorkdayCalendar.calendar
        let y = cal.component(.year, from: workdaysReferenceDate)
        let m = cal.component(.month, from: workdaysReferenceDate)
        return ChineseWorkdayCalendar.monthWorkdays(year: y, month: m)
    }

    private var canSave: Bool {
        Double(monthlyNetSalaryText.trimmingCharacters(in: .whitespaces)) ?? 0 > 0
    }

    @ViewBuilder
    private func numberField(
        label: String,
        text: Binding<String>,
        unit: String,
        placeholder: String = ""
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func timeField(label: String, date: Binding<Date>) -> some View {
        HStack {
            Text(label)
            Spacer()
            DatePicker(
                "",
                selection: date,
                displayedComponents: [.hourAndMinute]
            )
            .labelsHidden()
            .fixedSize()
        }
    }

    private func loadFromManager() {
        let s = manager.settings
        monthlyNetSalaryText = formatPlain(s.monthlyNetSalary)
        clockInDate = Self.dateFromMinute(s.clockInMinute)
        clockOutDate = Self.dateFromMinute(s.clockOutMinute)
        lunchStartDate = Self.dateFromMinute(s.lunchStartMinute)
        lunchEndDate = Self.dateFromMinute(s.lunchEndMinute)
        includeLunch = s.includeLunchInEarnings
        if let h = s.hireDate {
            hasHireDate = true
            hireDate = h
        } else {
            hasHireDate = false
            hireDate = Date()
        }
    }

    private func resetToDefault() {
        let d = SalarySettings()
        monthlyNetSalaryText = formatPlain(d.monthlyNetSalary)
        clockInDate = Self.dateFromMinute(d.clockInMinute)
        clockOutDate = Self.dateFromMinute(d.clockOutMinute)
        lunchStartDate = Self.dateFromMinute(d.lunchStartMinute)
        lunchEndDate = Self.dateFromMinute(d.lunchEndMinute)
        includeLunch = d.includeLunchInEarnings
        hasHireDate = false
        hireDate = Date()
        workdaysReferenceDate = Date()
    }

    private func save() {
        let salary = Double(monthlyNetSalaryText.trimmingCharacters(in: .whitespaces)) ?? 0
        let new = SalarySettings(
            monthlyNetSalary: salary,
            clockInMinute: Self.minuteFromDate(clockInDate),
            clockOutMinute: Self.minuteFromDate(clockOutDate),
            lunchStartMinute: Self.minuteFromDate(lunchStartDate),
            lunchEndMinute: Self.minuteFromDate(lunchEndDate),
            includeLunchInEarnings: includeLunch,
            hireDate: hasHireDate ? Calendar.current.startOfDay(for: hireDate) : nil
        )
        manager.updateSettings(new)
    }

    // MARK: - 分钟数 ↔ Date

    private static func dateFromMinute(_ minute: Int) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return cal.date(byAdding: .minute, value: minute, to: start) ?? start
    }

    private static func minuteFromDate(_ date: Date) -> Int {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return h * 60 + m
    }

    /// 10000 → "10000"; 21.75 → "21.75"; 0 → "0".
    /// Strips trailing zeros so the field reads cleanly.
    private func formatPlain(_ d: Double) -> String {
        if d.rounded() == d {
            return String(Int(d))
        }
        return String(format: "%g", d)
    }
}
