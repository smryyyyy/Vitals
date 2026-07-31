import SwiftUI

public struct CPUSectionView: View, Equatable {
    let snapshot: CPUSnapshot?
    let history: [Double]
    let temperature: Double?

    public init(snapshot: CPUSnapshot?, history: [Double], temperature: Double?) {
        self.snapshot = snapshot
        self.history = history
        self.temperature = temperature
    }

    public var body: some View {
        SectionView(icon: "◉", title: "CPU") {
            if let s = snapshot {
                MetricRow(label: "总计", fraction: s.totalUsage, value: Fmt.percent(s.totalUsage))
                if let temperature {
                    MetricRow(
                        label: "温度",
                        fraction: min(temperature / 100, 1.0),
                        value: String(format: "%.0f°C", temperature)
                    )
                }
                ForEach(s.topCores, id: \.index) { core in
                    MetricRow(
                        label: "核心 \(core.index + 1)",
                        fraction: core.usage,
                        value: Fmt.percent(core.usage)
                    )
                }
                if s.loadAverage.count >= 3 {
                    // ", N cores" did not fit in the column and was truncated — removed
                    TextRow(
                        label: "负载",
                        value: String(
                            format: "%.2f / %.2f / %.2f",
                            s.loadAverage[0], s.loadAverage[1], s.loadAverage[2]
                        )
                    )
                }
                HStack(spacing: 8) {
                    Text("趋势")
                        .foregroundStyle(Theme.text)
                        .frame(width: 56, alignment: .leading)
                    SparklineView(values: history, color: Theme.accent)
                }
            } else {
                Text("暂无数据").foregroundStyle(Theme.dim)
            }
        }
    }
}

public struct MemorySectionView: View, Equatable {
    let snapshot: MemorySnapshot?

    public init(snapshot: MemorySnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        SectionView(icon: "▥", title: "内存") {
            if let s = snapshot {
                MetricRow(label: "已用", fraction: s.usedFraction, value: Fmt.percent(s.usedFraction))
                MetricRow(
                    label: "空闲",
                    fraction: s.freeFraction,
                    value: Fmt.percent(s.freeFraction),
                    barColor: Theme.accent // high free memory is good — always green
                )
                TextRow(label: "总计", value: "\(Fmt.gigabytes(s.used)) / \(Fmt.gigabytes(s.total))")
                TextRow(label: "缓存", value: Fmt.gigabytes(s.cached))
                TextRow(label: "可用", value: Fmt.gigabytes(s.available))
            } else {
                Text("暂无数据").foregroundStyle(Theme.dim)
            }
        }
    }
}

public struct DiskSectionView: View, Equatable {
    let usage: DiskUsageSnapshot?
    let io: DiskIORates?

    public init(usage: DiskUsageSnapshot?, io: DiskIORates?) {
        self.usage = usage
        self.io = io
    }

    public var body: some View {
        SectionView(icon: "▦", title: "磁盘") {
            if usage == nil && io == nil {
                Text("暂无数据").foregroundStyle(Theme.dim)
            } else {
                if let u = usage {
                    MetricRow(label: "占用", fraction: u.usedFraction, value: Fmt.percent(u.usedFraction))
                    TextRow(label: "总计", value: "\(Fmt.gigabytes(u.total)) · \(u.fileSystem)")
                    TextRow(label: "空间", value: Fmt.usedFreePair(used: u.used, free: u.free))
                }
                if let io {
                    TextRow(label: "速度", value: Fmt.readWritePair(read: io.read, write: io.write))
                }
            }
        }
    }
}

public struct NetworkSectionView: View, Equatable {
    let rates: NetIORates?
    let info: NetworkInfo?
    let downloadHistory: [Double]
    let uploadHistory: [Double]

    public init(rates: NetIORates?, info: NetworkInfo?, downloadHistory: [Double] = [], uploadHistory: [Double] = []) {
        self.rates = rates
        self.info = info
        self.downloadHistory = downloadHistory
        self.uploadHistory = uploadHistory
    }

    public var body: some View {
        SectionView(icon: "⇅", title: "网络") {
            if rates == nil && info == nil {
                Text("暂无数据").foregroundStyle(Theme.dim)
            } else {
                if let r = rates {
                    SparkRow(label: "下载", values: downloadHistory, value: Fmt.rate(r.download), color: Theme.accent)
                    SparkRow(label: "上传", values: uploadHistory, value: Fmt.rate(r.upload), color: Theme.header)
                }
                if let i = info {
                    TextRow(label: "接口", value: ifaceString(i))
                }
            }
        }
    }

    private func ifaceString(_ i: NetworkInfo) -> String {
        if let ip = i.localIP { return "\(i.interfaceName) · \(ip)" }
        return i.interfaceName
    }
}

public struct PowerSectionView: View, Equatable {
    let snapshot: PowerSnapshot?

    public init(snapshot: PowerSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        SectionView(icon: "◪", title: "电源") {
            if let s = snapshot {
                MetricRow(
                    label: "电量",
                    fraction: s.levelFraction,
                    value: Fmt.percent(s.levelFraction),
                    barColor: levelColor(s.levelFraction)
                )
                if let health = s.healthFraction {
                    MetricRow(
                        label: "健康度",
                        fraction: health,
                        value: Fmt.percent(health),
                        barColor: Theme.accent
                    )
                }
                TextRow(label: "状态", value: statusLine(s))
                if let detail = detailLine(s) {
                    TextRow(label: "电池", value: detail)
                }
            } else {
                Text("暂无数据").foregroundStyle(Theme.dim)
            }
        }
    }

    private func levelColor(_ level: Double) -> Color {
        switch level {
        case ..<0.2: Theme.danger
        case ..<0.5: Theme.warning
        default: Theme.accent
        }
    }

    private func statusLine(_ s: PowerSnapshot) -> String {
        let state = s.isCharging ? "充电中" : "未充电"
        guard let minutes = s.timeRemainingMinutes else { return state }
        return "\(state) · \(BatteryMath.formatMinutes(minutes))"
    }

    private func detailLine(_ s: PowerSnapshot) -> String? {
        var parts: [String] = []
        if let cycles = s.cycleCount { parts.append("\(cycles) 次循环") }
        if let t = s.temperatureCelsius { parts.append(String(format: "%.1f°C", t)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct ProcessesSectionView: View, Equatable {
    let processes: [ProcessUsage]

    public init(processes: [ProcessUsage]) {
        self.processes = processes
    }

    private let cpuColumnWidth: CGFloat = 44
    private let memColumnWidth: CGFloat = 52

    public var body: some View {
        SectionView(icon: "≡", title: "进程") {
            if processes.isEmpty {
                Text("暂无数据").foregroundStyle(Theme.dim)
            } else {
                // Column headers so the two independent metrics are labeled.
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Text("CPU")
                        .frame(width: cpuColumnWidth, alignment: .trailing)
                    Text("内存")
                        .frame(width: memColumnWidth, alignment: .trailing)
                }
                .foregroundStyle(Theme.dim)

                ForEach(processes.prefix(3), id: \.pid) { p in
                    // Process names vary wildly in length; give the name the
                    // flexible space and let SwiftUI truncate with "…" —
                    // a single line always, so the row height never jumps.
                    HStack(spacing: 8) {
                        Text(p.name)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(String(format: "%.0f%%", p.cpuFraction * 100))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                            .frame(width: cpuColumnWidth, alignment: .trailing)
                        Text(Fmt.memoryCompact(p.memoryBytes))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                            .frame(width: memColumnWidth, alignment: .trailing)
                    }
                }
            }
        }
    }

}
