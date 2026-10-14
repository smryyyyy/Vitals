import Foundation

/// Value formatters matching the style of `mo status` output.
///
/// Units are decimal (1 k = 1000, 1 M = 1 000 000, 1 G = 1 000 000 000) so the
/// "MB/s" and "GB" labels are literally true. They used to divide by 1024 while
/// still calling the result MB/GB, which overstated every rate by 4.9% — and,
/// worse, disagreed with the disk numbers printed right next to them: a
/// "500 GB" drive reports its capacity in decimal, so the used/free split
/// rendered with binary divisors did not add up to the total on the box.
public enum Fmt {
    /// 17_179_869_184 → "17.2 GB"
    public static func gigabytes(_ bytes: UInt64) -> String {
        gigabytesNumber(bytes) + " GB"
    }

    /// Disk usage in mo style: "494G used · 297G free"
    public static func usedFreePair(used: UInt64, free: UInt64) -> String {
        "\(gigabytesCompact(used)) 已用 · \(gigabytesCompact(free)) 空闲"
    }

    /// Adaptive compact memory footprint: "1.6G" at or above 1 GB, "848M"
    /// below. Avoids showing small processes as a misleading "0.0G".
    public static func memoryCompact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", Double(bytes) / 1_000_000.0)
    }

    /// 0.119 → "11.9%"
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// Bytes/s → "0.5 MB/s"; above ~100 MB/s — no fractional part.
    /// Negative values (counter reset, sample race) are clamped to 0.
    public static func rate(_ bytesPerSecond: Double) -> String {
        rateNumber(bytesPerSecond) + " MB/s"
    }

    /// Compact throughput for the tight menu bar column: "0.5M", "150M" (MB/s).
    public static func rateCompact(_ bytesPerSecond: Double) -> String {
        rateNumber(bytesPerSecond) + "M"
    }

    /// Disk read/write speeds: "R 0.1 · W 0.5 MB/s"
    public static func readWritePair(read: Double, write: Double) -> String {
        "R \(rateNumber(read)) · W \(rateNumber(write)) MB/s"
    }

    /// Compact CNY for the menu bar: "1.2k" / "523" / "0.5".
    /// ≥ 1 000 000 → "1.2M", ≥ 1 000 → "1.2k", ≥ 100 → "523", else "0.5".
    public static func cnyCompact(_ amount: Double) -> String {
        let a = Swift.abs(amount)
        if a >= 1_000_000 {
            return String(format: "%.1fM", amount / 1_000_000)
        }
        if a >= 1_000 {
            return String(format: "%.1fk", amount / 1_000)
        }
        if a >= 100 {
            return String(format: "%.0f", amount)
        }
        return String(format: "%.1f", amount)
    }

    private static func gigabytesNumber(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000.0)
    }

    /// "494G" (≥ 10 GB — no fractional part), "5.4G" (< 10 GB)
    private static func gigabytesCompact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 10 { return String(format: "%.0fG", gb) }
        return String(format: "%.1fG", gb)
    }

    private static func rateNumber(_ bytesPerSecond: Double) -> String {
        let mbPerSecond = max(0, bytesPerSecond) / 1_000_000.0
        if mbPerSecond >= 99.95 { return String(format: "%.0f", mbPerSecond.rounded()) }
        return String(format: "%.1f", mbPerSecond)
    }
}
