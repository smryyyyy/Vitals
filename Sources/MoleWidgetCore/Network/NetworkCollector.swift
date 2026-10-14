import Foundation
import SystemConfiguration
import Darwin

/// Collects live network I/O counters and primary interface info from the OS.
///
/// `@unchecked Sendable`: the wrap-compensation cache is mutable, but every access
/// goes through `cacheLock`, and `info()` touches no shared state. Safe to hand to
/// the metrics collection queue.
public final class NetworkCollector: @unchecked Sendable {
    /// Serialises the wrap-compensation cache below. `ioCounters()` may be called
    /// from the metrics collection queue while `info()` runs on another, and the
    /// SMC/network caches are plain Swift state — no actor, so lock it explicitly.
    private let cacheLock = NSLock()
    /// Last raw 32-bit reading per interface name, used to turn a wrapping
    /// counter into a monotonic one.
    private var lastRaw: [String: (in: UInt32, out: UInt32)] = [:]
    private var accumulatedIn: UInt64 = 0
    private var accumulatedOut: UInt64 = 0
    private var seeded = false

    public init() {}

    /// Returns monotonic byte counters summed across all non-loopback interfaces,
    /// or nil if `getifaddrs` fails.
    ///
    /// ## Why this is not a plain sum of the raw fields
    ///
    /// The counters reachable through `getifaddrs` (`if_data.ifi_ibytes` /
    /// `ifi_obytes`) are `u_int32_t` — they wrap every 4.29 GB. Summing them
    /// produced a sawtooth total, which `NetIO.rates` correctly read as a counter
    /// reset, so the frame right after each wrap reported 0 bytes/s. At 100 MB/s
    /// that is every ~43 seconds.
    ///
    /// ## Why the 64-bit `if_data64` path is not used
    ///
    /// `if_data64` is only reachable through `RTM_IFINFO2` routing messages, not
    /// through `ifa_data`. Both ways of asking for it are denied to this app:
    ///
    /// - `socket(AF_ROUTE)` + `write(RTM_IFINFO2)` → `EPERM` for an unprivileged
    ///   process (measured, including from the shell).
    /// - `sysctl(CTL_NET, PF_ROUTE, …, NET_RT_IFLIST2)` → `EISDIR`. macOS denies the
    ///   numeric `sysctl()` MIB to ad-hoc-signed binaries, and this app ships
    ///   ad-hoc signed (`codesign --force --sign -`, see Makefile). Only
    ///   `sysctlbyname` is permitted, and there is no name-based handle for
    ///   interface counters. (`/usr/sbin/sysctl` still works because it is a
    ///   platform binary, which is why this is easy to misdiagnose.)
    ///
    /// Re-check both before replacing this with `if_data64`: the moment either
    /// path becomes available the wrap compensation below can be deleted.
    ///
    /// ## Remaining limitation
    ///
    /// The compensation assumes at most one wrap per interface per sample. A
    /// single interface would have to move > 4.29 GB between two samples for that
    /// to bite — above 2.1 GB/s at the 2 s fast tick, i.e. beyond 10 GbE wired
    /// but within reach of 100 GbE on a server build. `netstat` and the app agree
    /// everywhere below that rate.
    public func ioCounters() -> NetIOCounters? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let base = ifap else { return nil }
        defer { freeifaddrs(base) }

        var current: [String: (in: UInt32, out: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = base
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }

            // Skip loopback interfaces.
            guard (ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            // AF_LINK addresses carry the interface data struct (if_data) in ifa_data.
            guard ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }

            guard let dataPtr = ifa.pointee.ifa_data else { continue }
            let ifData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            current[String(cString: ifa.pointee.ifa_name)] = (ifData.ifi_ibytes, ifData.ifi_obytes)
        }

        return advance(to: current)
    }

    /// Folds this sample's raw 32-bit readings into the monotonic total.
    ///
    /// Keying by interface name (rather than summing first) is what makes the
    /// total survive an interface appearing or disappearing: a newcomer only
    /// establishes a baseline and contributes no delta, so the total never drops
    /// and `NetIO.rates` never mistakes a hot-plug for a counter reset.
    ///
    /// - Note: internal rather than private so tests can drive the accumulator
    ///   through a synthetic 32-bit wrap, which cannot be forced on a real Mac.
    func advance(to current: [String: (in: UInt32, out: UInt32)]) -> NetIOCounters {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        var totalIn = accumulatedIn
        var totalOut = accumulatedOut

        if seeded {
            for (name, value) in current {
                guard let previous = lastRaw[name] else { continue }
                totalIn &+= Self.wrapDelta(value.in, previous.in)
                totalOut &+= Self.wrapDelta(value.out, previous.out)
            }
        } else {
            // First sample: seed with the raw sum so the very first reading is a
            // plausible "since boot" figure instead of 0.
            for value in current.values {
                totalIn &+= UInt64(value.in)
                totalOut &+= UInt64(value.out)
            }
            seeded = true
        }

        lastRaw = current
        accumulatedIn = totalIn
        accumulatedOut = totalOut
        return NetIOCounters(bytesIn: totalIn, bytesOut: totalOut)
    }

    /// Wrapping period of the `if_data` traffic counters.
    static let counterWrap: UInt64 = 1 << 32

    /// Traffic moved since the previous sample of one 32-bit counter, adding one
    /// wrap period when the raw value went backwards.
    static func wrapDelta(_ current: UInt32, _ previous: UInt32) -> UInt64 {
        if current >= previous { return UInt64(current - previous) }
        return UInt64(current) + counterWrap - UInt64(previous)
    }

    /// Returns the primary network interface name and its IPv4 address,
    /// or nil when the machine is offline or the dynamic store is unavailable.
    public func info() -> NetworkInfo? {
        guard let store = SCDynamicStoreCreate(nil, "mole-widget" as CFString, nil, nil) else {
            return nil
        }

        guard
            let raw = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
            let dict = raw as? [String: Any],
            let iface = dict["PrimaryInterface"] as? String
        else {
            return nil
        }

        let ip = ipv4Address(for: iface)
        return NetworkInfo(interfaceName: iface, localIP: ip)
    }

    // MARK: - Private helpers

    /// Finds the IPv4 address of the named interface via a second getifaddrs pass.
    private func ipv4Address(for name: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let base = ifap else { return nil }
        defer { freeifaddrs(base) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = base
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }

            guard
                String(cString: ifa.pointee.ifa_name) == name,
                ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                let addrPtr = ifa.pointee.ifa_addr
            else { continue }

            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
                var addr = sinPtr.pointee.sin_addr
                guard let cstr = inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) else {
                    return nil
                }
                return String(cString: cstr)
            }
        }
        return nil
    }
}
