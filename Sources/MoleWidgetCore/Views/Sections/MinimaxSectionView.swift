import SwiftUI

/// Widget section: two usage bars (5h + weekly) each followed by their own
/// "Xh Ym 后重置" countdown.
///
/// `snapshot` 和 `error` 是分开的两份状态:拉取失败时用量数字和倒计时继续显示
/// (数据来自上一次成功),下面加一行错误提示。这样断网几秒不会让整块区域闪掉。
public struct MinimaxSectionView: View, Equatable {
    let snapshot: MinimaxSnapshot?
    let error: MinimaxErrorKind?

    public init(snapshot: MinimaxSnapshot?, error: MinimaxErrorKind? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    public var body: some View {
        SectionView(icon: "◈", title: "MiniMax") {
            if let snapshot, !snapshot.isEmpty {
                if let fiveHour = snapshot.fiveHour {
                    MetricRow(
                        label: "5h",
                        fraction: fiveHour.usedFraction,
                        value: "\(fiveHour.usedPercent)%"
                    )
                    if let countdown = MinimaxMapper.countdown(for: fiveHour) {
                        TextRow(label: "", value: countdown)
                            .opacity(0.85)
                    }
                }
                if let weekly = snapshot.weekly {
                    MetricRow(
                        label: "周",
                        fraction: weekly.usedFraction,
                        value: "\(weekly.usedPercent)%"
                    )
                    if let countdown = MinimaxMapper.countdown(for: weekly) {
                        TextRow(label: "", value: countdown)
                            .opacity(0.85)
                    }
                }
                // 已经有数据时,失败只作为附加的一行提示
                if let error {
                    errorRow(error)
                }
            } else if let error {
                // 一次都没成功过:错误信息就是全部内容,不再重复显示"未配置"
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .help(error.message)
            } else if snapshot == nil {
                Text("未配置").foregroundStyle(Theme.dim)
            } else {
                Text("等待数据…").foregroundStyle(Theme.dim)
            }
        }
    }

    @ViewBuilder
    private func errorRow(_ error: MinimaxErrorKind) -> some View {
        HStack(spacing: 8) {
            Text(error.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.danger)
                .frame(width: 56, alignment: .leading)
            Text(error.message)
                .font(.caption2)
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(error.message)
    }
}
