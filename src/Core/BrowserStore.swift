import Foundation
import AppKit

/// App state is mutated on the main thread. The engine owns its native web views.
final class BrowserStore {
    private(set) var tabs: [Tab] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var activeTabID: UUID?
    private(set) var selectedWorkspaceID: UUID?
    private(set) var settings = BrowserSettings()
    private(set) var persistenceError: String?
    private(set) var persistenceRecoveryMessage: String?
    private(set) var history: [HistoryEntry] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var downloads: [BrowserDownload] = []
    private(set) var findMatchCount: Int = 0
    private(set) var findActiveMatch: Int = 0

    var onChange: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onFocusAddress: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowBookmarks: (() -> Void)?
    var onShowDownloads: (() -> Void)?
    var onShowFind: (() -> Void)?
    let commandRegistry = CommandRegistry()

    private let engine: BrowserEngine
    private let navigation = NavigationController()
    private let sessions: SessionManager
    private let settingsStore: SettingsStore
    private let libraryStore: LibraryStore
    private let resources = ResourceManager()
    private let lifecycle = TabLifecycleManager()
    private enum CloseIntent { case remove, discard, quit }
    private struct PendingNavigation {
        let requestedURL: String?
        /// Restored when beforeunload cancels the navigation.
        let previousStatus: PageStatus
    }
    /// Store bookkeeping for a tab with an engine page. Discarding or removing
    /// the tab drops the whole entry.
    private struct TabRuntime {
        var view: NSView?
        var closeIntent: CloseIntent?
        var navigation: PendingNavigation?
        var visitPending = false
        var lastVisitID: UUID?
    }
    private var runtime: [UUID: TabRuntime] = [:]
    private var pendingSave: DispatchWorkItem?
    private var shuttingDown = false
    private var closedTabs: [ClosedTab] = []
    private var libraryDirty = false
    private var findTabID: UUID?
    private var findText = ""
    private let zoomSteps = [25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500]

    static let historyLimit = 5_000
    static let closedTabLimit = 25
    static let downloadLimit = 100

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    var currentWorkspace: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }
    var isCurrentPageBookmarked: Bool { activeTab.map { tab in bookmarks.contains { $0.url == tab.url } } ?? false }
    var zoomPercentage: Int { Int((pow(1.2, activeTab?.zoomLevel ?? 0) * 100).rounded()) }
    var pendingNavigationURL: String? { activeTabID.flatMap { runtime[$0]?.navigation?.requestedURL } }
    var visibleTabs: [Tab] {
        guard let workspace = currentWorkspace else { return [] }
        let ordered = workspace.tabs.compactMap { id in tabs.first { $0.id == id } }
        return ordered.filter(\.pinned) + ordered.filter { !$0.pinned }
    }

    init(engine: BrowserEngine, dataDirectory: URL? = nil) {
        self.engine = engine
        let directory = dataDirectory ?? SessionManager.defaultDirectory
        sessions = SessionManager(directory: directory)
        settingsStore = SettingsStore(directory: directory)
        libraryStore = LibraryStore(directory: directory)
        do { settings = try settingsStore.load() }
        catch { persistenceError = error.localizedDescription }
        do {
            if let session = try sessions.restore() { restore(session) }
        } catch { persistenceError = error.localizedDescription }
        do {
            let library = try libraryStore.load()
            history = Array(library.history.filter { isWebURL($0.url) }.sorted { $0.visitedAt > $1.visitedAt }.prefix(Self.historyLimit))
            var bookmarkURLs = Set<String>()
            bookmarks = library.bookmarks.filter { isWebURL($0.url) && bookmarkURLs.insert($0.url).inserted }
            downloads = Array(library.downloads.prefix(Self.downloadLimit)).map { saved in
                var download = saved
                if download.state == .inProgress { download.state = .failed; libraryDirty = true }
                return download
            }
        } catch { persistenceError = error.localizedDescription }
        persistenceRecoveryMessage = [persistenceError, sessions.recoveryMessage, settingsStore.recoveryMessage, libraryStore.recoveryMessage]
            .compactMap { $0 }.joined(separator: " ")
        if persistenceRecoveryMessage?.isEmpty == true { persistenceRecoveryMessage = nil }
        if workspaces.isEmpty { workspaces = [Workspace(name: "Pessoal")] }
        if selectedWorkspaceID == nil { selectedWorkspaceID = workspaces.first?.id }
        engine.onEvent = { [weak self] event in
            if Thread.isMainThread { self?.receive(event) }
            else { DispatchQueue.main.async { [weak self] in self?.receive(event) } }
        }
        resources.onEvaluate = { [weak self] pressure in self?.evaluateResources(pressure) }
        registerCommands()
        if let id = activeTabID { selectTab(id) }
        else { newTab() }
    }

    func contentView(for id: UUID) -> NSView {
        if let view = runtime[id]?.view { return view }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return NSView() }
        let view = engine.makeView(for: tabs[index])
        runtime[id, default: TabRuntime()].view = view
        tabs[index].page.memoryState = id == activeTabID ? .active : .warm
        return view
    }

    func newTab(url: String = "about:blank") {
        guard let workspaceID = selectedWorkspaceID else { return }
        let destination: String
        do { destination = try navigation.normalize(url, searchURL: settings.searchURL) }
        catch { reportNavigationError(error); return }
        let tab = Tab(url: destination, title: title(for: destination), workspaceId: workspaceID)
        tabs.append(tab)
        if let index = workspaces.firstIndex(where: { $0.id == workspaceID }) { workspaces[index].tabs.append(tab.id) }
        selectTab(tab.id)
    }

    func closeTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }), runtime[id]?.closeIntent == nil else { return }
        guard runtime[id]?.view != nil else { removeTab(id); return }
        runtime[id]?.closeIntent = .remove
        engine.close(tabID: id)
    }

    func selectTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if activeTabID != id { stopFinding() }
        if let oldIndex = tabs.firstIndex(where: { $0.id == activeTabID }), tabs[oldIndex].id != id,
           tabs[oldIndex].page.memoryState == .active { tabs[oldIndex].page.memoryState = .warm }
        activeTabID = id
        selectedWorkspaceID = tabs[index].workspaceId
        tabs[index].lastActivatedAt = Date()
        tabs[index].page.memoryState = .active
        _ = contentView(for: id)
        engine.activate(tabID: id)
        engine.setMuted(tabID: id, muted: tabs[index].muted)
        engine.setZoom(tabID: id, level: tabs[index].zoomLevel)
        changed(persistImmediately: true)
    }

    func navigate(_ input: String) {
        let destination: String
        do { destination = try navigation.normalize(input, searchURL: settings.searchURL) }
        catch { reportNavigationError(error); return }
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { newTab(url: destination); return }
        beginNavigation(tabs[index].id, requestedURL: destination)
        stopFinding()
        engine.navigate(tabID: tabs[index].id, url: destination)
        changed(persistImmediately: true)
    }

    func back() {
        if let tab = activeTab, tab.page.canGoBack { beginNavigation(tab.id); engine.goBack(tabID: tab.id) }
    }
    func forward() {
        if let tab = activeTab, tab.page.canGoForward { beginNavigation(tab.id); engine.goForward(tabID: tab.id) }
    }
    func reload() { if let id = activeTabID { beginNavigation(id); engine.reload(tabID: id) } }
    func stop() { if let id = activeTabID { engine.stop(tabID: id) } }

    func toggleMute(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].muted.toggle()
        engine.setMuted(tabID: id, muted: tabs[index].muted)
        changed()
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].pinned.toggle()
        changed()
    }

    func newWorkspace(name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty else { return }
        let workspace = Workspace(name: clean)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        newTab()
    }

    func switchWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        if let tab = tabs.filter({ $0.workspaceId == id }).max(by: { $0.lastActivatedAt < $1.lastActivatedAt }) {
            selectTab(tab.id)
        } else { newTab() }
    }

    func toggleSidebar() { settings.sidebarVisible.toggle(); changed() }

    func cycleTheme() {
        switch settings.theme {
        case .system: setTheme(.light)
        case .light: setTheme(.dark)
        case .dark: setTheme(.system)
        }
    }

    func setTheme(_ mode: ThemeMode) { settings.theme = mode; changed(persistImmediately: true) }
    func updateMemoryPolicy(_ policy: MemoryPolicy) { settings.memoryPolicy = policy.validated; changed(persistImmediately: true) }

    /// Callers must explain that reloading can lose unsaved form and page state.
    func discardInactiveTabs() { evaluateResources(.normal, manual: true) }
    func showDevTools() { if let id = activeTabID { engine.showDevTools(tabID: id) } }

    func searchHistory(_ query: String) -> [HistoryEntry] {
        history.filter { matches(query, text: "\($0.title) \($0.url)") }
    }

    func searchBookmarks(_ query: String) -> [Bookmark] {
        bookmarks.filter { matches(query, text: "\($0.title) \($0.url)") }
    }

    func toggleBookmark() {
        guard let tab = activeTab, isWebURL(tab.url) else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == tab.url }) { bookmarks.remove(at: index) }
        else { bookmarks.insert(Bookmark(url: tab.url, title: tab.title), at: 0) }
        libraryDirty = true
        changed(persistImmediately: true)
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        libraryDirty = true
        changed(persistImmediately: true)
    }

    func clearHistory() {
        history.removeAll()
        libraryDirty = true
        do {
            try libraryStore.save(BrowserLibrary(history: history, bookmarks: bookmarks, downloads: downloads), purgePrevious: true)
            libraryDirty = false
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
        onChange?()
    }

    func reopenClosedTab() {
        guard var closed = closedTabs.popLast() else { return }
        if !workspaces.contains(where: { $0.id == closed.workspace.id }) {
            closed.workspace.tabs = []
            workspaces.append(closed.workspace)
        }
        if tabs.contains(where: { $0.id == closed.tab.id }) { closed.tab.id = UUID() }
        closed.tab = restoredTab(closed.tab)
        closed.tab.workspaceId = closed.workspace.id
        tabs.append(closed.tab)
        if let index = workspaces.firstIndex(where: { $0.id == closed.workspace.id }) {
            workspaces[index].tabs.insert(closed.tab.id, at: max(0, min(closed.position, workspaces[index].tabs.count)))
        }
        selectTab(closed.tab.id)
    }

    func findInPage(_ text: String, forward: Bool = true, findNext: Bool = false) {
        guard let id = activeTabID else { return }
        guard !text.isEmpty else { stopFinding(); return }
        let continuing = findNext && findTabID == id && findText == text
        if !continuing { findMatchCount = 0; findActiveMatch = 0 }
        findText = text
        findTabID = id
        engine.find(tabID: id, text: text, forward: forward, findNext: continuing)
        onChange?()
    }

    func stopFinding() {
        if let id = findTabID { engine.stopFinding(tabID: id) }
        findTabID = nil
        findText = ""
        findMatchCount = 0
        findActiveMatch = 0
        onChange?()
    }

    func zoomIn() { setZoomPercentage(zoomSteps.first { $0 > zoomPercentage } ?? zoomSteps.last!) }
    func zoomOut() { setZoomPercentage(zoomSteps.last { $0 < zoomPercentage } ?? zoomSteps.first!) }
    func resetZoom() { setZoomPercentage(100) }
    func printPage() { if let id = activeTabID { engine.printPage(tabID: id) } }
    func cancelDownload(_ id: String) {
        guard downloads.contains(where: { $0.id == id && $0.state == .inProgress }) else { return }
        engine.cancelDownload(id: id)
    }

    private func setZoomPercentage(_ percent: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[index].zoomLevel = log(Double(percent) / 100) / log(1.2)
        engine.setZoom(tabID: tabs[index].id, level: tabs[index].zoomLevel)
        changed(persistImmediately: true)
    }

    func saveSession() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try sessions.save(BrowserSession(tabs: tabs, workspaces: workspaces,
                                             activeTabID: activeTabID, selectedWorkspaceID: selectedWorkspaceID,
                                             closedTabs: closedTabs))
            try settingsStore.save(settings)
            if libraryDirty {
                try libraryStore.save(BrowserLibrary(history: history, bookmarks: bookmarks, downloads: downloads))
                libraryDirty = false
            }
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        // Quitting supersedes pending close or discard requests. A page that
        // refuses to unload cancels the whole quit.
        for (id, entry) in runtime where entry.view != nil { runtime[id]?.closeIntent = .quit }
        resources.stop()
        saveSession()
        engine.shutdown()
    }

    func commands(matching query: String) -> [Command] {
        var result = commandRegistry.matching(query)
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for tab in tabs where matches(clean, text: "Alternar aba Buscar abas Switch tab Search tabs \(tab.title) \(tab.url)") {
            result.append(Command(id: "tab.\(tab.id)", title: "Ir para \(tab.title)", subtitle: tab.url,
                                  keywords: ["tab", "search"]) { [weak self] in self?.selectTab(tab.id) })
        }
        for workspace in workspaces where matches(clean, text: "Alternar espaço de trabalho Switch workspace \(workspace.name)") {
            result.append(Command(id: "workspace.\(workspace.id)", title: "Ir para \(workspace.name)",
                                  subtitle: "Espaço de trabalho", keywords: ["workspace"]) { [weak self] in
                self?.switchWorkspace(workspace.id)
            })
        }
        if !clean.isEmpty, let destination = try? navigation.normalize(clean, searchURL: settings.searchURL) {
            result.append(Command(id: "navigation.open", title: "Abrir \(clean)", subtitle: destination,
                                  keywords: ["open", "search"]) { [weak self] in self?.navigate(clean) })
        }
        return result
    }

    private func restore(_ session: BrowserSession) {
        var workspaceIDs = Set<UUID>()
        workspaces = session.workspaces.filter { workspaceIDs.insert($0.id).inserted }
        if workspaces.isEmpty { workspaces = [Workspace(name: "Pessoal")] }
        let fallback = workspaces[0].id
        var tabIDs = Set<UUID>()
        tabs = session.tabs.filter { tabIDs.insert($0.id).inserted }.map { saved in
            var tab = restoredTab(saved)
            if !workspaces.contains(where: { $0.id == tab.workspaceId }) { tab.workspaceId = fallback }
            return tab
        }
        closedTabs = Array(session.closedTabs.filter { !tabIDs.contains($0.tab.id) }.suffix(Self.closedTabLimit))
        for index in workspaces.indices {
            let belonging = tabs.filter { $0.workspaceId == workspaces[index].id }.map(\.id)
            var seen = Set<UUID>()
            workspaces[index].tabs = (workspaces[index].tabs + belonging).filter { belonging.contains($0) && seen.insert($0).inserted }
        }
        selectedWorkspaceID = workspaces.contains(where: { $0.id == session.selectedWorkspaceID }) ? session.selectedWorkspaceID : fallback
        activeTabID = tabs.contains(where: { $0.id == session.activeTabID }) ? session.activeTabID :
            tabs.first(where: { $0.workspaceId == selectedWorkspaceID })?.id
        if let active = activeTab { selectedWorkspaceID = active.workspaceId }
    }

    /// Validates a persisted or closed tab and starts it without an engine page.
    private func restoredTab(_ saved: Tab) -> Tab {
        var tab = saved
        tab.url = (try? navigation.normalize(tab.url, searchURL: settings.searchURL)) ?? "about:blank"
        tab.zoomLevel = tab.zoomLevel.isFinite ? max(log(0.25) / log(1.2), min(log(5) / log(1.2), tab.zoomLevel)) : 0
        tab.page = PageState()
        return tab
    }

    private func receive(_ event: BrowserEvent) {
        // While quitting, only closures, their cancellation and download results matter.
        if shuttingDown, !event.mattersDuringQuit { return }
        switch event {
        case .closed(let id): didClose(id)
        case .closeCancelled(let id): didCancelClose(id)
        case .download(let download): record(download)
        case .popup(let url): newTab(url: url)
        case .popupCreated(let id, let url): adoptPopup(id, url: url)
        case .title(let id, let value): didChangeTitle(id, value)
        case .url(let id, let value): didCommit(id, url: value)
        case .loading(let id, let loading, let back, let forward):
            didChangeLoading(id, loading: loading, canGoBack: back, canGoForward: forward)
        case .failure(let id, let message), .rendererTerminated(let id, let message):
            didFail(id, message: message)
        case .favicon(let id, let value):
            updateTab(id) { $0.page.favicon = value }
            changed()
        case .audio(let id, let playing):
            updateTab(id) { $0.page.audible = playing }
            changed()
        case .findResult(let id, let count, let active, _):
            didFind(id, count: count, active: active)
        }
    }

    /// During quit every engine closure belongs to the quit, whatever was requested before.
    private func closeIntent(for id: UUID) -> CloseIntent? {
        shuttingDown ? .quit : runtime[id]?.closeIntent
    }

    private func didClose(_ id: UUID) {
        switch closeIntent(for: id) ?? .remove {
        case .remove:
            // Without a request this is the page closing itself, as with window.close.
            removeTab(id)
        case .discard, .quit:
            markDiscarded(id)
            guard !shuttingDown else { return }
            if id == activeTabID { selectTab(id) } else { changed() }
        }
    }

    private func didCancelClose(_ id: UUID) {
        let intent = closeIntent(for: id)
        runtime[id]?.closeIntent = nil
        if intent == .quit {
            // The page refused to unload, so the whole quit is abandoned. Tabs
            // already closed during the attempt stay discarded.
            shuttingDown = false
            resources.start()
            selectTab(id)
            return
        }
        // Without a close request, beforeunload refused a navigation.
        if intent == nil { cancelPendingNavigation(id) }
        changed(persistImmediately: true)
    }

    private func record(_ download: BrowserDownload) {
        if let index = downloads.firstIndex(where: { $0.id == download.id }) { downloads[index] = download }
        else { downloads.insert(download, at: 0) }
        if downloads.count > Self.downloadLimit,
           let index = downloads.lastIndex(where: { $0.state != .inProgress }) { downloads.remove(at: index) }
        libraryDirty = true
        changed(persistImmediately: shuttingDown || download.state != .inProgress)
    }

    private func adoptPopup(_ id: UUID, url: String) {
        guard !tabs.contains(where: { $0.id == id }) else { return }
        guard let workspaceID = selectedWorkspaceID,
              let destination = try? navigation.normalize(url, searchURL: settings.searchURL) else {
            engine.close(tabID: id)
            return
        }
        tabs.append(Tab(id: id, url: destination, title: title(for: destination), workspaceId: workspaceID))
        if let index = workspaces.firstIndex(where: { $0.id == workspaceID }) { workspaces[index].tabs.append(id) }
        selectTab(id)
    }

    private func didChangeTitle(_ id: UUID, _ value: String) {
        updateTab(id) { $0.title = value.isEmpty ? title(for: $0.url) : value }
        if let tab = tabs.first(where: { $0.id == id }), let entryID = runtime[id]?.lastVisitID,
           let index = history.firstIndex(where: { $0.id == entryID && $0.url == tab.url }) {
            history[index].title = tab.title
            libraryDirty = true
        }
        changed()
    }

    private func didCommit(_ id: UUID, url: String) {
        let previous = tabs.first { $0.id == id }
        let wasRequested = runtime[id]?.navigation != nil
        updateTab(id) { $0.url = url }
        runtime[id]?.navigation = nil
        if previous?.url != url {
            runtime[id]?.visitPending = true
            // An unrequested change on a finished page (fragment, pushState)
            // brings no loading events, so it is a visit on its own.
            if !wasRequested && previous?.page.status == .ready { recordVisit(id) }
        }
        changed(persistImmediately: true)
    }

    private func didChangeLoading(_ id: UUID, loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        updateTab(id) {
            $0.page.canGoBack = canGoBack
            $0.page.canGoForward = canGoForward
            if loading { $0.page.startLoading() }
            else if $0.page.status.failure == nil { $0.page.status = .ready }
        }
        if loading {
            runtime[id]?.visitPending = true
        } else {
            // A requested destination is not a committed document. In
            // particular, cancelled beforeunload must not create a visit.
            let requested = runtime[id]?.navigation?.requestedURL
            if requested == nil || requested == tabs.first(where: { $0.id == id })?.url {
                runtime[id]?.navigation = nil
                recordVisit(id)
            }
        }
        changed()
    }

    private func didFail(_ id: UUID, message: String) {
        runtime[id]?.visitPending = false
        runtime[id]?.navigation = nil
        updateTab(id) {
            $0.page.status = .failed(message)
            $0.page.inputError = nil
            $0.page.audible = false
        }
        changed()
    }

    private func didFind(_ id: UUID, count: Int, active: Int) {
        guard id == activeTabID && id == findTabID && !findText.isEmpty else { return }
        // Negative values mean the engine left that number unchanged.
        if count >= 0 { findMatchCount = count }
        if active >= 0 { findActiveMatch = active }
        onChange?()
    }

    private func evaluateResources(_ pressure: ResourcePressure, manual: Bool = false) {
        let candidates = lifecycle.discardCandidates(tabs: tabs, activeTabID: activeTabID,
                                                     policy: settings.memoryPolicy, pressure: pressure, manual: manual)
        for id in candidates where runtime[id]?.closeIntent == nil {
            runtime[id, default: TabRuntime()].closeIntent = .discard
            engine.close(tabID: id)
        }
    }

    private func removeTab(_ id: UUID) {
        guard let removed = tabs.first(where: { $0.id == id }) else { return }
        if let workspace = workspaces.first(where: { $0.id == removed.workspaceId }) {
            closedTabs.append(ClosedTab(tab: removed, workspace: workspace, position: workspace.tabs.firstIndex(of: id) ?? 0))
            closedTabs = Array(closedTabs.suffix(Self.closedTabLimit))
        }
        let removedIndex = visibleTabs.firstIndex { $0.id == id } ?? 0
        if findTabID == id { stopFinding() }
        runtime[id] = nil
        tabs.removeAll { $0.id == id }
        for index in workspaces.indices { workspaces[index].tabs.removeAll { $0 == id } }
        if activeTabID == id {
            activeTabID = nil
            if !visibleTabs.isEmpty { selectTab(visibleTabs[min(removedIndex, visibleTabs.count - 1)].id) }
            else { newTab() }
        } else { changed(persistImmediately: true) }
    }

    private func updateTab(_ id: UUID, _ update: (inout Tab) -> Void) {
        if let index = tabs.firstIndex(where: { $0.id == id }) { update(&tabs[index]) }
    }

    private func markDiscarded(_ id: UUID) {
        runtime[id] = nil
        updateTab(id) { $0.page = PageState() }
    }

    private func beginNavigation(_ id: UUID, requestedURL: String? = nil) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // Consecutive requests keep the first snapshot, so cancelling returns
        // to the committed page rather than to an abandoned attempt.
        let previous = runtime[id]?.navigation?.previousStatus ?? tab.page.status
        runtime[id, default: TabRuntime()].navigation = PendingNavigation(requestedURL: requestedURL, previousStatus: previous)
        // CEF can coalesce loading=true across consecutive navigations. Clear
        // the previous attempt's error before dispatch.
        updateTab(id) { $0.page.startLoading() }
    }

    private func cancelPendingNavigation(_ id: UUID) {
        guard let pending = runtime[id]?.navigation else { return }
        runtime[id]?.navigation = nil
        runtime[id]?.visitPending = false
        updateTab(id) { $0.page.status = pending.previousStatus }
    }

    private func reportNavigationError(_ error: Error) {
        if let id = activeTabID { updateTab(id) { $0.page.inputError = error.localizedDescription } }
        onChange?()
    }

    private func changed(persistImmediately: Bool = false) {
        onChange?()
        pendingSave?.cancel()
        if persistImmediately { saveSession(); return }
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func title(for url: String) -> String {
        if url == "about:blank" { return "Nova aba" }
        return URL(string: url)?.host ?? url
    }

    private func isWebURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        return components.scheme == "https" || components.scheme == "http"
    }

    private func recordVisit(_ id: UUID) {
        guard runtime[id]?.visitPending == true else { return }
        runtime[id]?.visitPending = false
        guard let tab = tabs.first(where: { $0.id == id }), tab.page.status == .ready, isWebURL(tab.url) else { return }
        let entry = HistoryEntry(url: tab.url, title: tab.title)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        runtime[id]?.lastVisitID = entry.id
        libraryDirty = true
        saveSession()
    }

    private func matches(_ query: String, text: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func registerCommands() {
        commandRegistry.register(Command(id: "navigation.focus", title: "Abrir endereço", subtitle: "Digite um endereço ou faça uma busca",
                                         keywords: ["endereço", "navegar", "buscar", "address", "navigate", "search"], shortcut: "⌘L") { [weak self] in self?.onFocusAddress?() })
        commandRegistry.register(Command(id: "tab.new", title: "Nova aba", keywords: ["criar", "create"], shortcut: "⌘T") { [weak self] in self?.newTab(); self?.onFocusAddress?() })
        commandRegistry.register(Command(id: "tab.close", title: "Fechar aba", shortcut: "⌘W") { [weak self] in
            if let id = self?.activeTabID { self?.closeTab(id) }
        })
        commandRegistry.register(Command(id: "workspace.new", title: "Novo espaço de trabalho", keywords: ["criar", "organizar", "create", "organize"]) { [weak self] in self?.onCreateWorkspace?() })
        commandRegistry.register(Command(id: "sidebar.toggle", title: "Mostrar ou ocultar barra lateral", shortcut: "⌘⇧S") { [weak self] in self?.toggleSidebar() })
        commandRegistry.register(Command(id: "theme.toggle", title: "Alternar tema", subtitle: "Sistema, claro e escuro", keywords: ["aparência", "claro", "escuro", "appearance", "light", "dark"]) { [weak self] in self?.cycleTheme() })
        commandRegistry.register(Command(id: "settings.open", title: "Abrir ajustes", keywords: ["preferências", "memória", "desempenho", "preferences", "memory", "performance"], shortcut: "⌘,") { [weak self] in self?.onShowSettings?() })
        commandRegistry.register(Command(id: "developer.tools", title: "Abrir ferramentas de desenvolvimento", keywords: ["devtools", "inspect", "console"], shortcut: "⌥⌘I") { [weak self] in self?.showDevTools() })
        commandRegistry.register(Command(id: "tab.reopen", title: "Reabrir aba fechada", keywords: ["restaurar", "reopen"], shortcut: "⌘⇧T") { [weak self] in self?.reopenClosedTab() })
        commandRegistry.register(Command(id: "history.show", title: "Mostrar histórico", keywords: ["visitas", "history"], shortcut: "⌘Y") { [weak self] in self?.onShowHistory?() })
        commandRegistry.register(Command(id: "bookmarks.show", title: "Mostrar favoritos", keywords: ["bookmarks"], shortcut: "⌘⇧B") { [weak self] in self?.onShowBookmarks?() })
        commandRegistry.register(Command(id: "bookmark.toggle", title: "Adicionar ou remover favorito", keywords: ["salvar", "bookmark"], shortcut: "⌘D") { [weak self] in self?.toggleBookmark() })
        commandRegistry.register(Command(id: "downloads.show", title: "Mostrar downloads", keywords: ["arquivos", "transferências"], shortcut: "⌘⇧J") { [weak self] in self?.onShowDownloads?() })
        commandRegistry.register(Command(id: "page.find", title: "Buscar nesta página", keywords: ["encontrar", "find"], shortcut: "⌘F") { [weak self] in self?.onShowFind?() })
        commandRegistry.register(Command(id: "page.zoomIn", title: "Ampliar página", keywords: ["zoom"], shortcut: "⌘+") { [weak self] in self?.zoomIn() })
        commandRegistry.register(Command(id: "page.zoomOut", title: "Reduzir página", keywords: ["zoom"], shortcut: "⌘−") { [weak self] in self?.zoomOut() })
        commandRegistry.register(Command(id: "page.zoomReset", title: "Restaurar zoom", subtitle: "100%", shortcut: "⌘0") { [weak self] in self?.resetZoom() })
        commandRegistry.register(Command(id: "page.print", title: "Imprimir página", shortcut: "⌘P") { [weak self] in self?.printPage() })
    }
}

private extension BrowserEvent {
    var mattersDuringQuit: Bool {
        switch self {
        case .closed, .closeCancelled, .download: return true
        default: return false
        }
    }
}
