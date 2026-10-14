/// Pure math: memory snapshot computed from raw page counters.
///
/// These deliberately do **not** reproduce Activity Monitor's split. AM's "App
/// Memory" counts the anonymous pages sitting in *inactive* as well as *active*,
/// and `vm_statistics64` cannot tell those apart — it reports page *age*, not
/// page *type*, and the only counters for inactive split it further are
/// `inactive_file` / `inactive_purgeable`, which together do not account for all
/// of inactive (the anonymous remainder is not separately exported). Matching AM
/// would therefore mean inventing a split, and it would break the
/// `used + free == total` invariant that the UI's colouring and thresholds rest
/// on. So the definitions below are stated exactly rather than approximated:
///
///   used   = active + wired + compressed
///            Anonymous + file-backed pages the kernel counts as in use. Below
///            AM's "Memory Used" by whatever anonymous pages are parked in
///            inactive; see the note above.
///   free   = total − used
///            The complement of used, in `mo status` style. **Not** the kernel's
///            free_count — most of it is inactive and file cache, which AM shows
///            under "Cached Files".
///   cached = max(external, purgeable)
///            Reclaimable file-backed pages. purgeable is a *subset* of external,
///            so the old `purgeable + external` double-counted every purgeable
///            page and inflated `available` by that amount.
///   avail  = free_count + cached
///            Actually reclaimable without swapping. Still excludes
///            `speculative`, which is reclaimable too — a deliberate omission, not
///            an oversight: adding it changes a user-visible number without any
///            local way to validate the result.
public enum MemoryUsage {
    public static func compute(stats: VMStats, pageSize: UInt64, total: UInt64) -> MemorySnapshot {
        let used = (stats.active &+ stats.wired &+ stats.compressed) &* pageSize
        let cached = Swift.max(stats.external, stats.purgeable) &* pageSize
        let free = total > used ? total - used : 0
        let available = stats.free &* pageSize &+ cached
        return MemorySnapshot(total: total, used: used, free: free, cached: cached, available: available)
    }
}
