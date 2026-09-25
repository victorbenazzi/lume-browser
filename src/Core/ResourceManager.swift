import Foundation

enum ResourcePressure: String { case normal, warning, critical }

struct TabLifecycleManager {
    func isDiscardable(_ tab: Tab, activeTabID: UUID?, policy: MemoryPolicy) -> Bool {
        tab.id != activeTabID && !tab.page.audible && !tab.page.status.isLoading &&
            !(tab.pinned && policy.keepPinnedTabsAlive) &&
            (tab.page.memoryState == .warm || tab.page.memoryState == .frozen)
    }

    func discardCandidates(tabs: [Tab], activeTabID: UUID?, policy: MemoryPolicy,
                           now: Date = Date(), pressure: ResourcePressure = .normal,
                           manual: Bool = false) -> [UUID] {
        guard manual || policy.automaticDiscardEnabled else { return [] }
        let candidates = tabs.filter { isDiscardable($0, activeTabID: activeTabID, policy: policy) }
            .sorted { $0.lastActivatedAt < $1.lastActivatedAt }
        if manual || pressure == .critical { return candidates.map(\.id) }
        let excess = max(0, tabs.filter { $0.page.memoryState == .warm }.count - policy.warmTabLimit)
        return candidates.enumerated().compactMap { index, tab in
            let expired = now.timeIntervalSince(tab.lastActivatedAt) >= Double(policy.discardAfterMinutes * 60)
            return expired || index < excess || pressure == .warning ? tab.id : nil
        }
    }
}

/// Observes pressure and cadence. No RAM or CPU estimate is inferred from tab count.
final class ResourceManager {
    var onEvaluate: ((ResourcePressure) -> Void)?
    private(set) var pressure: ResourcePressure = .normal
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?

    init() { start() }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.onEvaluate?(self.pressure)
        }
        timer.resume()
        self.timer = timer
        let pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressureSource.setEventHandler { [weak self] in
            guard let self = self, let data = self.pressureSource?.data else { return }
            self.pressure = data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
            self.onEvaluate?(self.pressure)
        }
        pressureSource.resume()
        self.pressureSource = pressureSource
    }

    func stop() {
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    deinit { stop() }
}
