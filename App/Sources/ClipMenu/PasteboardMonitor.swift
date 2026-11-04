import AppKit

// Clipboard watcher (legacy ClipsController polling, ClipsController.m:587-649,
// 815-833).
//
// Design per performance guardrails (design-invariants.md — Clipboard polling):
// the pasteboard has no change notification, so poll
// `NSPasteboard.general.changeCount` on a coalesced timer. This monitor is an
// `actor`, so its loop — including the changeCount read AND the payload
// snapshot — runs OFF the main actor; copying a multi-MB image/PDF never stalls
// the UI (design-invariants.md — Clipboard polling). NSPasteboard is obtained
// and used entirely on this actor's executor (see PasteboardReader).
//
// On a changeCount change it reads a snapshot and hands it to the ClipStore
// actor to persist. Default interval 0.75s with a 1.0s cap mirrors the legacy
// timeInterval / MAX_TIME_INTERVAL. Per-app exclusion
// (ClipsController.m:606-608) is applied inside PasteboardReader.snapshot()
// (returns nil for excluded front apps).

actor PasteboardMonitor {
    private var lastChangeCount: Int = 0
    private var pollTask: Task<Void, Never>?
    private var clipStore: ClipStore?

    /// Polling interval bounds: clamped to the legacy maximum of 1.0s, and to a
    /// 0.25s floor so the slider's 0 value can't turn the poll into a busy loop.
    static let maxInterval: Duration = .seconds(1)
    static let minInterval: Duration = .milliseconds(250)
    static let defaultInterval: Duration = .milliseconds(750)

    /// The poll interval to use given the stored `timeInterval` preference (in
    /// seconds), or nil when unset. Clamped to [minInterval, maxInterval]; nil
    /// → defaultInterval. Pure, so it is unit-testable.
    static func effectiveInterval(fromSeconds seconds: Double?) -> Duration {
        guard let seconds else { return defaultInterval }
        let requested = Duration.seconds(seconds)
        return min(max(requested, minInterval), maxInterval)
    }

    /// Wake-up tolerance for the poll timer: a quarter of the interval. Letting the
    /// OS defer each wake up to this much lets it coalesce our recurring wake with
    /// other timers, cutting the number of distinct wake events (and so the energy
    /// cost) of an always-on agent — without changing the nominal cadence. Capture
    /// latency stays bounded by interval + tolerance (≤ ~0.94s at the default).
    /// Pure, so it is unit-testable.
    static func pollTolerance(for interval: Duration) -> Duration {
        interval / 4
    }

    func start(clipStore: ClipStore, interval: Duration? = nil) async {
        guard pollTask == nil else { return }
        self.clipStore = clipStore
        let effective = interval ?? Self.effectiveInterval(
            fromSeconds: UserDefaults.standard.object(forKey: PreferenceKeys.timeInterval) as? Double)

        lastChangeCount = NSPasteboard.general.changeCount

        let tolerance = Self.pollTolerance(for: effective)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: effective, tolerance: tolerance)
                await self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Read and persist off the main actor (ClipsController.m:610-643). Per-app
        // exclusion — and the nspasteboard.org privacy markers — are applied in
        // snapshot() against the CURRENT frontmost app, i.e. the app the copy was
        // made in. We deliberately do NOT also skip based on the previously
        // frontmost app: that "copy-then-switch" guard dropped legitimate copies
        // made in a non-excluded app whenever an excluded app happened to be
        // frontmost at the prior tick (a clipboard manager silently losing clips
        // is worse than the narrow race it closed).
        guard let snapshot = PasteboardReader.snapshot() else { return }
        // snapshot() checks the front app and the privacy markers before it reads
        // the payload. If another app copied in between (1Password writing a
        // concealed password, say), the payload belongs to that newer copy, so
        // drop this one; the next poll sees the new changeCount and reads it whole.
        guard NSPasteboard.general.changeCount == current else { return }
        await clipStore?.capture(snapshot)
    }
}
