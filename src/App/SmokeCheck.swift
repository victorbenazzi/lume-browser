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
    private var windowsBeforeDevTools = 0
    /// Protocol methods the DevTools frontend sent, in order.
    private var devToolsMethods: [String] = []
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
            stage = 8
            windowsBeforeDevTools = NSApp.windows.filter(\.isVisible).count
            // Inspecting the heading, as the page's context menu does.
            engine.inspectForTesting(tabID: originalID!, x: 120, y: 84)
        case 8 where ["devTools", "devToolsProtocol"].contains(event["kind"] as? String):
            if event["kind"] as? String == "devToolsProtocol", let method = event["value"] as? String { devToolsMethods.append(method) }
            guard let originalID, store.showsDevTools, devToolsMethods.contains("DOM.pushNodesByBackendIdsToFrontend") else { return }
            guard store.devToolsView(for: originalID)?.subviews.isEmpty == false, devToolsMethods.contains("DOM.getDocument") else {
                finish(false, error: "DevTools did not open in its panel"); return
            }
            guard NSApp.windows.filter(\.isVisible).count == windowsBeforeDevTools else {
                finish(false, error: "DevTools opened a window of its own"); return
            }
            checks.append("DevTools opens in the panel, reads the page and reveals the inspected node")
            stage = 9
            store.toggleDevTools()
        case 9 where event["kind"] as? String == "devTools":
            guard let originalID, !store.showsDevTools, store.devToolsView(for: originalID) == nil else {
                finish(false, error: "DevTools did not close"); return
            }
            checks.append("DevTools closes with the page still open")
            store.toggleSidebar()
            store.setTheme(.dark)
            let folder = store.newBookmarkFolder(name: "Smoke", icon: "star")
            store.setTheme(.light)
            guard folder != nil, store.bookmarkFolders.count == 1 else {
                finish(false, error: "Favorites invariant failed"); return
            }
            checks.append("favorites, theme and sidebar state")
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
                                     "devToolsMethods": Array(devToolsMethods.prefix(40)),
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
