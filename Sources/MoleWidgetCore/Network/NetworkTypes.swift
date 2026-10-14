import Foundation

/// Monotonic I/O byte totals summed across all non-loopback interfaces.
///
/// Monotonic rather than "since system boot": the underlying `if_data` counters
/// are 32-bit and wrap, so `NetworkCollector` keeps a wrap-compensated running
/// total instead of reporting the raw sum. Only the difference between two
/// readings is meaningful — the absolute value starts wherever the collector did.
public struct NetIOCounters: Equatable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Current download/upload rates in bytes per second.
public struct NetIORates: Equatable {
    public let download: Double
    public let upload: Double

    public init(download: Double, upload: Double) {
        self.download = download
        self.upload = upload
    }
}

/// Primary network interface name and its IPv4 address.
public struct NetworkInfo: Equatable {
    public let interfaceName: String
    public let localIP: String?

    public init(interfaceName: String, localIP: String?) {
        self.interfaceName = interfaceName
        self.localIP = localIP
    }
}
