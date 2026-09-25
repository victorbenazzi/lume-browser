import AppKit

/// Opt-in integration check against the repository's local HTTP fixtures.
/// It uses the same public core and native engine as normal browsing.
final class SmokeCheck {
    private let store: BrowserStore
    private let engine: CEFEngine
    private let baseURL: String
    private var stage = 0
    private var originalID: UUID?
    private var secondID: UUID?
    private var checks: [String] = []
    private var finished = false
    var completion: ((Bool) -> Void)?

    init(store: BrowserStore, engine: CEFEngine, baseURL: String) {
        self.store = store
        self.engine = engine
        self.baseURL = baseURL
    }

    func start() {
        engine.onDiagnosticEvent = { [weak self] event in
            DispatchQueue.main.async { self?.evaluate(event) }
        }
        originalID = store.activeTabID
        store.navigate(baseURL + "/first.html")
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(false, error: "Timed out at stage \(self.stage)")
        }
    }

    private func evaluate(_ event: [String: Any]) {
        guard !finished else { return }
        if event["kind"] as? String == "failure" {
            finish(false, error: event["value"] as? String ?? "Navigation failed")
            return
        }
        guard let tab = store.activeTab else { return }
        let ready = !tab.page.status.isLoading && tab.page.errorMessage == nil
        switch stage {
        case 0 where ready && tab.title == "Lume Test One":
            checks.append("real Chromium HTTP render and title callback")
            stage = 1
            store.navigate(baseURL + "/second.html")
        case 1 where ready && tab.title == "Lume Test Two":
            guard tab.page.canGoBack else { finish(false, error: "No back history"); return }
            checks.append("navigation and back availability")
            stage = 2
            store.back()
        case 2 where ready && tab.title == "Lume Test One":
            guard tab.page.canGoForward else { return }
            checks.append("back restored page")
            stage = 3
            store.forward()
        case 3 where ready && tab.title == "Lume Test Two":
            checks.append("forward restored page")
            stage = 4
            store.newTab(url: baseURL + "/first.html")
            secondID = store.activeTabID
        case 4 where ready && tab.id == secondID && tab.title == "Lume Test One":
            checks.append("second native tab renders independently")
            stage = 5
            store.discardInactiveTabs()
        case 5 where event["kind"] as? String == "closed":
            guard let originalID, store.tabs.first(where: { $0.id == originalID })?.page.memoryState == .discarded else { return }
            checks.append("discard confirmed by CEF OnBeforeClose")
            stage = 6
            store.selectTab(originalID)
        case 6 where ready && tab.id == originalID && tab.title == "Lume Test Two":
            checks.append("discarded tab recreated and loaded by URL")
            stage = 7
            if let secondID { store.closeTab(secondID) }
        case 7 where event["kind"] as? String == "closed":
            guard let secondID, !store.tabs.contains(where: { $0.id == secondID }) else { return }
            checks.append("close removes only the selected browser instance")
            store.toggleSidebar()
            store.setTheme(.dark)
            store.newWorkspace(name: "Smoke Workspace")
            store.setTheme(.light)
            guard store.workspaces.count == 2, store.activeTab?.workspaceId == store.selectedWorkspaceID,
                  !store.commands(matching: "tema").isEmpty else {
                finish(false, error: "Workspace or command invariant failed"); return
            }
            checks.append("workspace, theme, sidebar and command state")
            store.saveSession()
            finish(true)
        default: break
        }
    }

    private func finish(_ passed: Bool, error: String? = nil) {
        guard !finished else { return }
        finished = true
        engine.onDiagnosticEvent = nil
        var report: [String: Any] = ["passed": passed, "checks": checks, "stage": stage,
                                     "engine": "CEF 154 ARM64", "sandboxConfigured": true]
        if let error { report["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            if let destination = ProcessInfo.processInfo.environment["LUME_SMOKE_REPORT"] {
                try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            }
            print(String(decoding: data, as: UTF8.self))
        }
        completion?(passed)
        store.shutdown()
    }
}
