import AppKit

/// Main-thread adapter. No Chromium types escape into the browser core.
final class CEFEngine: BrowserEngine {
    var onEvent: ((BrowserEvent) -> Void)?
    var onDiagnosticEvent: (([String: Any]) -> Void)?
    let capabilities = EngineCapabilities(supportsFreezing: false)
    private let bridge = LBCEFEngine()

    func setDialogWindow(_ window: NSWindow?) { bridge.dialogWindow = window }

    init() {
        bridge.eventHandler = { [weak self] event in
            guard let self else { return }
            self.onDiagnosticEvent?(event)
            guard let kind = event["kind"] as? String,
                  let textID = event["id"] as? String,
                  let id = UUID(uuidString: textID) else { return }
            let value = event["value"] as? String ?? ""
            switch kind {
            case "title": self.onEvent?(.title(id, value))
            case "url": self.onEvent?(.url(id, value))
            case "favicon": self.onEvent?(.favicon(id, value))
            case "loading": self.onEvent?(.loading(id, event["loading"] as? Bool ?? false,
                                                  event["back"] as? Bool ?? false,
                                                  event["forward"] as? Bool ?? false))
            case "failure": self.onEvent?(.failure(id, value))
            case "closed": self.onEvent?(.closed(id))
            case "closeCancelled": self.onEvent?(.closeCancelled(id))
            case "popup": self.onEvent?(.popup(value))
            case "popupCreated": self.onEvent?(.popupCreated(id, value))
            case "rendererTerminated": self.onEvent?(.rendererTerminated(id, value))
            case "findResult": self.onEvent?(.findResult(id, event["count"] as? Int ?? 0,
                                                          event["active"] as? Int ?? 0,
                                                          event["final"] as? Bool ?? false))
            case "download":
                guard let downloadID = event["downloadID"] as? String,
                      let stateText = event["state"] as? String,
                      let state = DownloadState(rawValue: stateText) else { return }
                self.onEvent?(.download(BrowserDownload(id: downloadID, tabID: id,
                    url: event["url"] as? String ?? "", filename: event["filename"] as? String ?? "",
                    path: event["path"] as? String ?? "", receivedBytes: (event["received"] as? NSNumber)?.int64Value ?? 0,
                    totalBytes: (event["total"] as? NSNumber)?.int64Value ?? 0, state: state)))
            default: break
            }
        }
    }

    func makeView(for tab: Tab) -> NSView { bridge.createTab(tab.id.uuidString, url: tab.url) }
    func activate(tabID: UUID) { bridge.activateTab(tabID.uuidString) }
    func navigate(tabID: UUID, url: String) { bridge.navigateTab(tabID.uuidString, url: url) }
    func goBack(tabID: UUID) { bridge.goBack(tabID.uuidString) }
    func goForward(tabID: UUID) { bridge.goForward(tabID.uuidString) }
    func reload(tabID: UUID) { bridge.reload(tabID.uuidString) }
    func stop(tabID: UUID) { bridge.stop(tabID.uuidString) }
    func setMuted(tabID: UUID, muted: Bool) { bridge.muteTab(tabID.uuidString, muted: muted) }
    func close(tabID: UUID) { bridge.closeTab(tabID.uuidString) }
    func showDevTools(tabID: UUID) { bridge.showDevTools(tabID.uuidString) }
    func find(tabID: UUID, text: String, forward: Bool, findNext: Bool) {
        bridge.find(tabID.uuidString, text: text, forward: forward, findNext: findNext)
    }
    func stopFinding(tabID: UUID) { bridge.stopFinding(tabID.uuidString) }
    func setZoom(tabID: UUID, level: Double) { bridge.setZoom(tabID.uuidString, level: level) }
    func printPage(tabID: UUID) { bridge.printPage(tabID.uuidString) }
    func cancelDownload(id: String) { bridge.cancelDownload(id) }
    func runFixtureScript(tabID: UUID, script: String) { bridge.runFixtureScript(tabID.uuidString, script: script) }
    func crashRendererForTesting(tabID: UUID) { bridge.crashRenderer(forTesting: tabID.uuidString) }
    func shutdown() { bridge.shutdown() }
}
