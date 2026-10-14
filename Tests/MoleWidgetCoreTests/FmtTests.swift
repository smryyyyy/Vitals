import Testing
@testable import MoleWidgetCore

@Suite struct FmtTests {
    // All unit maths here is decimal (1 k = 1000, 1 M = 1e6, 1 G = 1e9) so the
    // "MB/s" / "GB" labels are literally true. Expected strings below are the
    // decimal readings of the same byte counts the binary-era tests used.

    @Test func gigabytes() {
        #expect(Fmt.gigabytes(17_179_869_184) == "17.2 GB")  // 17.18 GB decimal (was 16.0 GiB-binary)
        #expect(Fmt.gigabytes(10_630_044_058) == "10.6 GB")
        #expect(Fmt.gigabytes(1_000_000_000) == "1.0 GB")
        #expect(Fmt.gigabytes(0) == "0.0 GB")
    }

    @Test func memoryCompact() {
        #expect(Fmt.memoryCompact(1_610_612_736) == "1.6G")
        #expect(Fmt.memoryCompact(1_000_000_000) == "1.0G")   // exactly 1 GB
        #expect(Fmt.memoryCompact(999_999_999) == "1000M")     // just under 1 GB rounds into MB
        #expect(Fmt.memoryCompact(831_472_640) == "831M")
        #expect(Fmt.memoryCompact(5_242_880) == "5M")
        #expect(Fmt.memoryCompact(0) == "0M")
    }

    @Test func percent() {
        #expect(Fmt.percent(0.119) == "11.9%")
        #expect(Fmt.percent(1.0) == "100.0%")
        #expect(Fmt.percent(0) == "0.0%")
    }

    @Test func rate() {
        #expect(Fmt.rate(524_288) == "0.5 MB/s")
        #expect(Fmt.rate(0) == "0.0 MB/s")
        #expect(Fmt.rate(157_286_400) == "157 MB/s") // >= 100 MB/s — no fractional part
        #expect(Fmt.rate(-1_048_576) == "0.0 MB/s")  // negative delta → 0
        #expect(Fmt.rate(99_999_999) == "100 MB/s")   // 99.999 MB/s — no format flicker
        #expect(Fmt.rate(47_185_920) == "47.2 MB/s")  // mid range
        #expect(Fmt.rate(1_000_000) == "1.0 MB/s")    // exactly 1 MB/s
    }

    @Test func rateCompact() {
        #expect(Fmt.rateCompact(524_288) == "0.5M")
        #expect(Fmt.rateCompact(0) == "0.0M")
        #expect(Fmt.rateCompact(157_286_400) == "157M")
        #expect(Fmt.rateCompact(-1_048_576) == "0.0M")
    }

    @Test func usedFreePair() {
        // ≥ 10 GB — no fractional part (mo style: "176G")
        #expect(Fmt.usedFreePair(used: 175_973_534_106, free: 318_372_188_979) == "176G 已用 · 318G 空闲")
        // < 10 GB — one decimal digit
        #expect(Fmt.usedFreePair(used: 5_368_709_120, free: 17_179_869_184) == "5.4G 已用 · 17G 空闲")
        #expect(Fmt.usedFreePair(used: 0, free: 0) == "0.0G 已用 · 0.0G 空闲")
    }

    @Test func readWritePair() {
        #expect(Fmt.readWritePair(read: 104_858, write: 524_288) == "R 0.1 · W 0.5 MB/s")
        #expect(Fmt.readWritePair(read: 0, write: 0) == "R 0.0 · W 0.0 MB/s")
        #expect(Fmt.readWritePair(read: -1, write: 157_286_400) == "R 0.0 · W 157 MB/s")
    }

    /// The bug this suite exists for: dividing by 1024 while labelling the result
    /// "MB"/"GB" overstated every figure by 4.9% and disagreed with the decimal
    /// capacities the drive itself reports.
    @Test func unitsAreDecimalNotBinary() {
        // 1 MiB is 4.86% more than 1 MB; a decimal formatter must show 1.0, not 1.05.
        #expect(Fmt.rate(1_048_576) == "1.0 MB/s")
        // 1 GiB reads as 1.07 GB, never as "1.0 GB".
        #expect(Fmt.gigabytes(1_073_741_824) == "1.1 GB")
    }
}
