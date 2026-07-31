import SwiftUI

/// Widget section: two usage bars (5h + weekly) each followed by their own
/// "Xh Ym 后重置" countdown. When the snapshot is missing or the API
/// reported an error, the rows collapse into a single placeholder row.
public struct MinimaxSectionView: View, Equatable {
    let snapshot: MinimaxSnapshot?

    public init(snapshot: MinimaxSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        SectionView(icon: "◈", title: "MiniMax") {
            if let snapshot {
                if snapshot.isError {
                    TextRow(
                        label: "状态",
                        value: snapshot.error ?? "拉取失败"
                    )
                } else if snapshot.isEmpty {
                    Text("等待数据…").foregroundStyle(Theme.dim)
                } else {
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
                }
            } else {
                Text("未配置").foregroundStyle(Theme.dim)
            }
        }
    }
}
