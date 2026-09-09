import SwiftUI

/// Widget section: "¥ 工资" header + state-driven body.
/// Reads the latest `SalarySnapshot` (recomputed every second) and
/// `SalarySettings` for context like `dailySalary` on a day off.
public struct SalarySectionView: View, Equatable {
    let snapshot: SalarySnapshot
    let settings: SalarySettings

    public init(snapshot: SalarySnapshot, settings: SalarySettings) {
        self.snapshot = snapshot
        self.settings = settings
    }

    public var body: some View {
        SectionView(icon: "¥", title: "工资") {
            switch snapshot.state {
            case .unconfigured:
                Text("未配置,点菜单栏 → 工资设置…")
                    .foregroundStyle(Theme.dim)

            case .dayOff:
                dayOffBody

            case .beforeWork:
                beforeWorkBody

            case .working, .onLunch:
                activeBody

            case .afterWork:
                doneBody
            }
        }
    }

    // MARK: - 行内 KPI(两列布局专用,label 宽 68 放得下"下班倒计时")

    /// 与公共 `TextRow` 类似,但 label 宽 68,能放下 5 字中文标签(如"下班倒计时")。
    /// 仅在本视图内使用,避免改公共组件影响其它 section。
    @ViewBuilder
    private func kpiRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// 两列 KPI 容器。`spacing: 16` 给两列之间留呼吸空间;`alignment: .top`
    /// 让两列顶端对齐,即使一行 KPI 数量不同也不会上下错位。
    @ViewBuilder
    private func kpiColumns<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) { left() }
            VStack(alignment: .leading, spacing: 4) { right() }
        }
    }

    // MARK: - 上班中 / 午休中(7 行 KPI,两列各 3,加顶部大数字+进度条)

    @ViewBuilder
    private var activeBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SalaryEngine.formatCNY(snapshot.todayEarned))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            BarView(fraction: snapshot.progress, color: Theme.accent).equatable()
            kpiColumns(
                left: {
                    let stateText = snapshot.state == .onLunch ? "午休中" : "上班中"
                    kpiRow("状态", stateText)
                    kpiRow("时薪", String(format: "¥%.2f", snapshot.hourlyRate))
                    if snapshot.state == .onLunch, let t = snapshot.timeToLunchEnd {
                        kpiRow("午休剩", SalaryEngine.formatCountdown(t))
                    } else if let t = snapshot.timeToOffDuty {
                        kpiRow("下班倒计时", SalaryEngine.formatCountdown(t))
                    }
                },
                right: {
                    kpiRow("本月", SalaryEngine.formatCNY(snapshot.monthEarned))
                    if snapshot.yearEarned > 0 {
                        kpiRow("本年", SalaryEngine.formatCNY(snapshot.yearEarned))
                    }
                    if settings.hireDate != nil, snapshot.totalEarned > 0 {
                        kpiRow("在职累计", SalaryEngine.formatCNY(snapshot.totalEarned))
                    }
                }
            )
        }
    }

    // MARK: - 已下班(5 行 KPI,左 3 右 2,加顶部大数字+进度条)

    @ViewBuilder
    private var doneBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SalaryEngine.formatCNY(snapshot.todayEarned))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            BarView(fraction: 1.0, color: Theme.accent).equatable()
            kpiColumns(
                left: {
                    kpiRow("状态", "已下班")
                    kpiRow("时薪", String(format: "¥%.2f", snapshot.hourlyRate))
                    kpiRow("本月", SalaryEngine.formatCNY(snapshot.monthEarned))
                },
                right: {
                    if snapshot.yearEarned > 0 {
                        kpiRow("本年", SalaryEngine.formatCNY(snapshot.yearEarned))
                    }
                    if settings.hireDate != nil, snapshot.totalEarned > 0 {
                        kpiRow("在职累计", SalaryEngine.formatCNY(snapshot.totalEarned))
                    }
                }
            )
        }
    }

    // MARK: - 休息日(最多 5 行,左 3 右 ≤2)

    @ViewBuilder
    private var dayOffBody: some View {
        if settings.isConfigured {
            kpiColumns(
                left: {
                    kpiRow("今日", "休息日")
                    kpiRow("日薪", SalaryEngine.formatCNY(snapshot.todayDaily))
                    kpiRow("本月", SalaryEngine.formatCNY(snapshot.monthEarned))
                },
                right: {
                    if snapshot.yearEarned > 0 {
                        kpiRow("本年", SalaryEngine.formatCNY(snapshot.yearEarned))
                    }
                    if settings.hireDate != nil, snapshot.totalEarned > 0 {
                        kpiRow("在职累计", SalaryEngine.formatCNY(snapshot.totalEarned))
                    }
                }
            )
        } else {
            kpiRow("今日", "休息日")
        }
    }

    // MARK: - 距上班(最多 4 行,左 2 右 ≤2)

    @ViewBuilder
    private var beforeWorkBody: some View {
        kpiColumns(
            left: {
                if let t = snapshot.timeToWorkStart {
                    kpiRow("距上班", SalaryEngine.formatCountdown(t))
                }
                kpiRow("日薪", SalaryEngine.formatCNY(snapshot.todayDaily))
            },
            right: {
                if snapshot.monthEarned > 0 {
                    kpiRow("本月", SalaryEngine.formatCNY(snapshot.monthEarned))
                }
                if snapshot.yearEarned > 0 {
                    kpiRow("本年", SalaryEngine.formatCNY(snapshot.yearEarned))
                }
            }
        )
    }
}
