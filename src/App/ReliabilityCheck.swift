import AppKit

/// Runs only against synthetic loopback fixtures in a dedicated test profile.
final class ReliabilityCheck {
    private let store: BrowserStore
    private let engine: CEFEngine
    private let baseURL: String
    private let phase: String
    private var stage = 0
    private var finished = false
    private var checks: [String] = []
    private var timer: Timer?
    var completion: ((Bool) -> Void)?

    init(store: BrowserStore, engine: CEFEngine, baseURL: String, phase: String) {
        self.store = store
        self.engine = engine
        self.baseURL = baseURL
        self.phase = phase
    }

    func start() {
        engine.onDiagnosticEvent = { [weak self] event in
            DispatchQueue.main.async { self?.evaluate(event) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.evaluate([:]) }
        switch phase {
        case "seed": store.navigate(baseURL + "/session/set")
        case "restore":
            guard store.activeTab?.url == baseURL + "/workbench.html", store.isCurrentPageBookmarked,
                  !store.searchHistory("Workbench").isEmpty else {
                finish(false, error: "Session, bookmark or history failed to restore")
                return
            }
            checks.append("tabs, bookmark and searchable history survived restart")
            stage = -1
        case "abrupt-seed":
            store.newTab()
            store.togglePin(store.activeTabID!)
            store.navigate(baseURL + "/workbench.html#crash-recovery")
        case "abrupt-restore":
            guard store.activeTab?.pinned == true,
                  store.activeTab?.url == baseURL + "/workbench.html#crash-recovery" else {
                finish(false, error: "Active tab or its pin lost after forced termination")
                return
            }
            checks.append("active tab and pin recovered after SIGKILL")
        default: finish(false, error: "Unknown test phase")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 65) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(false, error: "Timed out in \(self.phase), stage \(self.stage), title \(self.store.activeTab?.title ?? "nil")")
        }
    }

    private func evaluate(_ event: [String: Any]) {
        guard !finished, let tab = store.activeTab else { return }
        let ready = !tab.page.status.isLoading && tab.page.errorMessage == nil
        if phase == "seed" {
            if stage == 0, ready, tab.title == "Session Seed Ready" {
                checks.append("synthetic session cookie and localStorage written by Chromium")
                stage = 1
                store.navigate(baseURL + "/workbench.html")
            } else if stage == 1, ready, tab.title == "Lume Workbench" {
                if !store.isCurrentPageBookmarked { store.toggleBookmark() }
                stage = 2
                engine.runFixtureScript(tabID: tab.id, script: "localStorage.setItem('lume-base-dpr',devicePixelRatio);document.title='Zoom Seed Ready'")
            } else if stage == 2, tab.title == "Zoom Seed Ready" {
                store.zoomIn()
                checks.append("bookmark and browsing session saved")
                store.saveSession()
                finish(true)
            }
            return
        }
        if phase == "abrupt-seed", stage == 0, ready, tab.title == "Lume Workbench" {
            stage = 1
            store.saveSession()
            if let path = ProcessInfo.processInfo.environment["LUME_TEST_READY"] {
                try? Data("ready".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            return
        }
        if phase == "abrupt-restore", ready, tab.title == "Lume Workbench" {
            checks.append("recovered tab rendered after forced termination")
            finish(true)
            return
        }
        guard phase == "restore" else { return }
        switch stage {
        case -1 where ready && tab.title == "Lume Workbench":
            guard store.zoomPercentage == 110 else { finish(false, error: "Saved zoom lost in core"); return }
            stage = -2
            engine.runFixtureScript(tabID: tab.id, script: "document.title=Math.abs(devicePixelRatio/Number(localStorage.getItem('lume-base-dpr'))-1.1)<0.02?'Restored Zoom PASS':'Restored Zoom FAIL'")
        case -2 where tab.title == "Restored Zoom PASS":
            checks.append("saved zoom applied to the asynchronously recreated Chromium browser")
            store.resetZoom()
            stage = 0
            store.navigate(baseURL + "/session/check")
        case -2 where tab.title == "Restored Zoom FAIL": finish(false, error: tab.title)
        case 0 where ready && tab.title == "Session PASS":
            checks.append("HttpOnly session cookie and localStorage survived full app restart")
            stage = 1
            store.navigate(baseURL + "/workbench.html")
        case 0 where tab.title.hasSuffix("FAIL"):
            finish(false, error: tab.title)
        case 1 where ready && tab.title == "Lume Workbench":
            stage = 2
            store.findInPage("LUME-FIND-MARKER")
        case 2 where event["kind"] as? String == "findResult" && store.findMatchCount == 3:
            checks.append("native Chromium find reports all three matches")
            store.stopFinding()
            stage = 3
            store.zoomIn()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.engine.runFixtureScript(tabID: tab.id, script: "document.title=Math.abs(devicePixelRatio-window.__initialDPR)>0.01?'Zoom PASS':'Zoom FAIL'")
            }
        case 3 where tab.title == "Zoom PASS":
            checks.append("zoom changes the actual Chromium rendering scale")
            store.resetZoom()
            stage = 4
            store.navigate(baseURL + "/network/fail")
        case 3 where tab.title == "Zoom FAIL": finish(false, error: tab.title)
        case 4 where event["kind"] as? String == "failure":
            checks.append("interrupted network produces a recoverable page error")
            stage = 5
            store.navigate(baseURL + "/workbench.html")
        case 5 where ready && tab.title == "Lume Workbench":
            checks.append("navigation recovers after network failure")
            stage = 6
            engine.crashRendererForTesting(tabID: tab.id)
        case 6 where event["kind"] as? String == "rendererTerminated":
            checks.append("renderer crash reaches the native recoverable error state")
            stage = 7
            store.reload()
        case 7 where ready && tab.title == "Lume Workbench":
            checks.append("reload restores the URL after a renderer crash")
            stage = 8
            engine.runFixtureScript(tabID: tab.id, script: "window.testLocalMedia()")
        case 8 where tab.title == "WebRTC PASS":
            checks.append("synthetic video frames transmitted and played through local WebRTC peers")
            stage = 9
            store.newTab(url: baseURL + "/second.html")
        case 8 where tab.title.hasPrefix("WebRTC FAIL"): finish(false, error: tab.title)
        case 9 where ready && tab.title == "Lume Test Two":
            stage = 10
            store.closeTab(tab.id)
        case 10 where store.canReopenClosedTab && tab.title == "WebRTC PASS":
            stage = 11
            store.reopenClosedTab()
        case 11 where ready && tab.title == "Lume Test Two":
            checks.append("closed native tab reopens and renders the previous URL")
            finish(true)
        default: break
        }
    }

    private func finish(_ passed: Bool, error: String? = nil) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        engine.onDiagnosticEvent = nil
        var report: [String: Any] = ["passed": passed, "phase": phase, "stage": stage, "checks": checks]
        if let error { report["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let path = ProcessInfo.processInfo.environment["LUME_SMOKE_REPORT"] {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        }
        completion?(passed)
        store.shutdown()
    }
}
