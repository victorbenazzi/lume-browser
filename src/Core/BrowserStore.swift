import Foundation
import AppKit

/// App state is mutated on the main thread. The engine owns its native web views.
final class BrowserStore {
    /// The order is the sidebar order, apart from pinned tabs coming first.
    private(set) var tabs: [Tab] = []
    private(set) var activeTabID: UUID?
    private(set) var settings = BrowserSettings()
    private(set) var persistenceError: String?
    private(set) var persistenceRecoveryMessage: String?
    private(set) var history: [HistoryEntry] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var bookmarkFolders: [BookmarkFolder] = []
    private(set) var downloads: [BrowserDownload] = []
    private(set) var findMatchCount: Int = 0
    private(set) var findActiveMatch: Int = 0
    /// The tab whose page asked for fullscreen, such as a video player. Only the active tab can hold it.
    private(set) var fullscreenTabID: UUID?

    var onChange: (() -> Void)?

    private let engine: BrowserEngine
    private let navigation = NavigationController()
    private let sessions: SessionManager
    private let settingsStore: SettingsStore
    private let libraryStore: LibraryStore
    private let favicons: FaviconStore
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
    /// Tabs whose DevTools is open. Chromium closes it with the page, so it is never saved.
    private var devToolsTabIDs: Set<UUID> = []
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
    /// The active tab when the engine shows it. Page tools do nothing on Lume pages.
    private var activeWebTab: Tab? { activeTab.flatMap { $0.internalPage == nil ? $0 : nil } }
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }
    var isCurrentPageBookmarked: Bool { currentPageBookmark != nil }
    var currentPageBookmark: Bookmark? { activeTab.flatMap { tab in bookmarks.first { $0.url == tab.url } } }
    var zoomPercentage: Int { Int((pow(1.2, activeTab?.zoomLevel ?? 0) * 100).rounded()) }
    var pendingNavigationURL: String? { activeTabID.flatMap { runtime[$0]?.navigation?.requestedURL } }
    var visibleTabs: [Tab] { tabs.filter(\.pinned) + tabs.filter { !$0.pinned } }
    /// Whether the page on screen has its DevTools open beside it.
    var showsDevTools: Bool { activeWebTab.map { devToolsTabIDs.contains($0.id) } ?? false }

    init(engine: BrowserEngine, dataDirectory: URL? = nil) {
        self.engine = engine
        let directory = dataDirectory ?? SessionManager.defaultDirectory
        sessions = SessionManager(directory: directory)
        settingsStore = SettingsStore(directory: directory)
        libraryStore = LibraryStore(directory: directory)
        favicons = FaviconStore(directory: directory)
        do { settings = try settingsStore.load() }
        catch { persistenceError = error.localizedDescription }
        do {
            if let session = try sessions.restore() { restore(session) }
        } catch { persistenceError = error.localizedDescription }
        do {
            let library = try libraryStore.load()
            history = Array(library.history.filter { isWebURL($0.url) }.sorted { $0.visitedAt > $1.visitedAt }.prefix(Self.historyLimit))
            var folderIDs = Set<UUID>()
            bookmarkFolders = library.folders.filter { folderIDs.insert($0.id).inserted }.map { saved in
                var folder = saved
                if !BookmarkFolder.symbols.contains(folder.icon) { folder.icon = BookmarkFolder.symbols[0] }
                return folder
            }
            var bookmarkURLs = Set<String>()
            bookmarks = library.bookmarks.filter { isWebURL($0.url) && bookmarkURLs.insert($0.url).inserted }.map { saved in
                var bookmark = saved
                if let folderID = bookmark.folderID, !folderIDs.contains(folderID) { bookmark.folderID = nil }
                return bookmark
            }
            downloads = Array(library.downloads.prefix(Self.downloadLimit)).map { saved in
                var download = saved
                if download.state == .inProgress { download.state = .failed; libraryDirty = true }
                return download
            }
        } catch { persistenceError = error.localizedDescription }
        persistenceRecoveryMessage = [persistenceError, sessions.recoveryMessage, settingsStore.recoveryMessage, libraryStore.recoveryMessage]
            .compactMap { $0 }.joined(separator: " ")
        if persistenceRecoveryMessage?.isEmpty == true { persistenceRecoveryMessage = nil }
        engine.onEvent = { [weak self] event in
            if Thread.isMainThread { self?.receive(event) }
            else { DispatchQueue.main.async { [weak self] in self?.receive(event) } }
        }
        resources.onEvaluate = { [weak self] pressure in self?.evaluateResources(pressure) }
        engine.setPermissionPolicy(self)
        if let id = activeTabID { selectTab(id) }
        else { newTab() }
    }

    func contentView(for id: UUID) -> NSView {
        if let view = runtime[id]?.view { return view }
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].internalPage == nil else { return NSView() }
        let view = engine.makeView(for: tabs[index])
        runtime[id, default: TabRuntime()].view = view
        tabs[index].page.memoryState = id == activeTabID ? .active : .warm
        return view
    }

    func newTab(url: String = "about:blank") {
        let destination: String
        if let page = InternalPage(url: url) { destination = page.rawValue }
        else {
            do { destination = try navigation.normalize(url, searchURL: settings.searchURL) }
            catch { reportNavigationError(error); return }
        }
        let tab = Tab(url: destination, title: title(for: destination))
        tabs.append(tab)
        selectTab(tab.id)
    }

    /// Opens a link beside the tab it came from and starts loading it without leaving the current page.
    func openInBackground(_ url: String, from openerID: UUID? = nil) {
        guard let destination = try? navigation.normalize(url, searchURL: settings.searchURL),
              destination != "about:blank" else { return }
        let tab = Tab(url: destination, title: title(for: destination))
        insert(tab, after: openerID ?? activeTabID)
        _ = contentView(for: tab.id)
        changed(persistImmediately: true)
    }

    /// Searches for the text in a new tab beside its page, even when the text looks like an address.
    func searchInNewTab(_ text: String, from openerID: UUID? = nil) {
        guard let destination = try? navigation.search(String(text.prefix(1_000)), searchURL: settings.searchURL) else { return }
        let tab = Tab(url: destination, title: title(for: destination))
        insert(tab, after: openerID ?? activeTabID)
        selectTab(tab.id)
    }

    /// Leaves the page's fullscreen, as Esc or leaving the window's full screen does.
    func exitFullscreen() {
        guard let id = fullscreenTabID else { return }
        fullscreenTabID = nil
        engine.exitFullscreen(tabID: id)
        onChange?()
    }

    // MARK: Site permissions

    /// Remembered decisions, grouped by site.
    var sitePermissions: [SitePermissionDecision] {
        settings.sitePermissions.sorted { ($0.origin, $0.permission.rawValue) < ($1.origin, $1.permission.rawValue) }
    }

    func rememberPermission(_ decision: SitePermissionDecision) {
        guard decision.permission.isValid, let origin = NavigationController.origin(of: decision.origin) else { return }
        var clean = decision
        clean.origin = origin
        settings.sitePermissions.removeAll { $0.answers(decision.permission, for: origin) }
        settings.sitePermissions.append(clean)
        changed(persistImmediately: true)
    }

    func forgetPermission(origin: String, permission: SitePermission) {
        settings.sitePermissions.removeAll { $0.answers(permission, for: origin) }
        changed(persistImmediately: true)
    }

    func forgetAllPermissions() {
        settings.sitePermissions.removeAll()
        changed(persistImmediately: true)
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
        if let fullscreen = fullscreenTabID, fullscreen != id {
            fullscreenTabID = nil
            engine.exitFullscreen(tabID: fullscreen)
        }
        if let oldIndex = tabs.firstIndex(where: { $0.id == activeTabID }), tabs[oldIndex].id != id,
           tabs[oldIndex].page.memoryState == .active { tabs[oldIndex].page.memoryState = .warm }
        activeTabID = id
        tabs[index].lastActivatedAt = Date()
        // A Lume page has no engine page, so it stays out of the memory policy.
        if tabs[index].internalPage == nil {
            tabs[index].page.memoryState = .active
            _ = contentView(for: id)
            engine.activate(tabID: id)
            engine.setMuted(tabID: id, muted: tabs[index].muted)
            engine.setZoom(tabID: id, level: tabs[index].zoomLevel)
        }
        changed(persistImmediately: true)
    }

    /// Switches to the tab already showing the page, or opens one for it.
    func openInternalPage(_ page: InternalPage) {
        if let tab = visibleTabs.first(where: { $0.internalPage == page }) { selectTab(tab.id) }
        else { newTab(url: page.rawValue) }
    }

    func navigate(_ input: String) {
        if let page = InternalPage(url: input) { openInternalPage(page); return }
        let destination: String
        do { destination = try navigation.normalize(input, searchURL: settings.searchURL) }
        catch { reportNavigationError(error); return }
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { newTab(url: destination); return }
        if tabs[index].internalPage != nil {
            // Leaving a Lume page turns the tab into a site with its own engine page.
            tabs[index].url = destination
            tabs[index].title = title(for: destination)
            tabs[index].page = PageState()
            selectTab(tabs[index].id)
            return
        }
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
    func reload() { if let tab = activeWebTab { beginNavigation(tab.id); engine.reload(tabID: tab.id) } }
    func stop() { if let id = activeWebTab?.id { engine.stop(tabID: id) } }

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

    func toggleSidebar() { settings.sidebarVisible.toggle(); changed() }

    func cycleTheme() {
        switch settings.theme {
        case .system: setTheme(.light)
        case .light: setTheme(.dark)
        case .dark: setTheme(.system)
        }
    }

    func setTheme(_ mode: ThemeMode) { settings.theme = mode; changed(persistImmediately: true) }
    func setTranslucency(_ level: Translucency) { settings.translucency = level; changed(persistImmediately: true) }
    func setFavoritesLayout(_ layout: FavoritesLayout) { settings.favoritesLayout = layout; changed(persistImmediately: true) }
    func toggleFavoritesCollapsed() { settings.favoritesCollapsed.toggle(); changed(persistImmediately: true) }
    func updateMemoryPolicy(_ policy: MemoryPolicy) { settings.memoryPolicy = policy.validated; changed(persistImmediately: true) }

    /// Callers must explain that reloading can lose unsaved form and page state.
    func discardInactiveTabs() { evaluateResources(.normal, manual: true) }
    func toggleDevTools() {
        guard let id = activeWebTab?.id else { return }
        if devToolsTabIDs.contains(id) { engine.closeDevTools(tabID: id) }
        else { engine.showDevTools(tabID: id) }
    }
    func devToolsView(for id: UUID) -> NSView? { devToolsTabIDs.contains(id) ? engine.devToolsView(tabID: id) : nil }
    func setDevToolsWidth(_ width: Double) { settings.devToolsWidth = width; changed() }

    func searchHistory(_ query: String) -> [HistoryEntry] {
        history.filter { matches(query, text: "\($0.title) \($0.url)") }
    }

    /// The library lists favorites newest first, whatever their order in the sidebar.
    func searchBookmarks(_ query: String) -> [Bookmark] {
        bookmarks.filter { matches(query, text: "\($0.title) \($0.url)") }.sorted { $0.createdAt > $1.createdAt }
    }

    func toggleBookmark() {
        if let bookmark = currentPageBookmark { removeBookmark(bookmark.id) }
        else { bookmarkCurrentPage() }
    }

    /// The current page's favorite, created at the end of the top level when the page has none yet.
    @discardableResult
    func bookmarkCurrentPage() -> UUID? {
        if let bookmark = currentPageBookmark { return bookmark.id }
        guard let tab = activeTab, isWebURL(tab.url) else { return nil }
        let bookmark = Bookmark(url: tab.url, title: tab.title)
        bookmarks.append(bookmark)
        if let image = tab.page.faviconImage { favicons.save(image, for: tab.url) }
        libraryChanged()
        return bookmark.id
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        favicons.prune(keeping: bookmarks.map(\.url))
        libraryChanged()
    }

    /// The array order is the sidebar order, folder by folder.
    func bookmarks(inFolder folderID: UUID?) -> [Bookmark] {
        bookmarks.filter { $0.folderID == folderID }
    }

    /// Switches to a tab already showing the bookmark, or opens it in a new one.
    func openBookmark(_ id: UUID) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        if let tab = visibleTabs.first(where: { $0.url == bookmark.url }) { selectTab(tab.id) }
        else { newTab(url: bookmark.url) }
    }

    func renameBookmark(_ id: UUID, title: String) {
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id }), bookmarks[index].title != clean else { return }
        bookmarks[index].title = clean
        libraryChanged()
    }

    /// `position` counts the destination's favorites without the one being moved. Without it, the favorite
    /// goes to the end of a new folder and stays put in its own.
    func moveBookmark(_ id: UUID, toFolder folderID: UUID?, at position: Int? = nil) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }),
              folderID == nil || bookmarkFolders.contains(where: { $0.id == folderID }),
              position != nil || bookmarks[index].folderID != folderID else { return }
        var bookmark = bookmarks.remove(at: index)
        bookmark.folderID = folderID
        let siblings = bookmarks.indices.filter { bookmarks[$0].folderID == folderID }
        let target = min(max(0, position ?? siblings.count), siblings.count)
        bookmarks.insert(bookmark, at: target < siblings.count ? siblings[target] : siblings.last.map { $0 + 1 } ?? bookmarks.endIndex)
        libraryChanged()
    }

    /// `position` counts the folders without the one being moved.
    func moveBookmarkFolder(_ id: UUID, to position: Int) {
        guard let index = bookmarkFolders.firstIndex(where: { $0.id == id }) else { return }
        let folder = bookmarkFolders.remove(at: index)
        bookmarkFolders.insert(folder, at: min(max(0, position), bookmarkFolders.count))
        libraryChanged()
    }

    @discardableResult
    func newBookmarkFolder(name: String, icon: String) -> UUID? {
        guard let clean = folderName(name) else { return nil }
        let folder = BookmarkFolder(name: clean, icon: BookmarkFolder.symbols.contains(icon) ? icon : BookmarkFolder.symbols[0])
        bookmarkFolders.append(folder)
        libraryChanged()
        return folder.id
    }

    func updateBookmarkFolder(_ id: UUID, name: String, icon: String) {
        guard let clean = folderName(name), let index = bookmarkFolders.firstIndex(where: { $0.id == id }) else { return }
        bookmarkFolders[index].name = clean
        if BookmarkFolder.symbols.contains(icon) { bookmarkFolders[index].icon = icon }
        libraryChanged()
    }

    /// The folder's bookmarks move to the top level instead of being deleted.
    func removeBookmarkFolder(_ id: UUID) {
        bookmarkFolders.removeAll { $0.id == id }
        for index in bookmarks.indices where bookmarks[index].folderID == id { bookmarks[index].folderID = nil }
        libraryChanged()
    }

    /// The live page icon when the tab has one, else the icon saved for a bookmarked host.
    func favicon(for tab: Tab) -> NSImage? { tab.page.faviconImage ?? favicons.image(for: tab.url) }
    func favicon(for bookmark: Bookmark) -> NSImage? { favicons.image(for: bookmark.url) }

    func clearHistory() {
        history.removeAll()
        libraryDirty = true
        do {
            try libraryStore.save(library, purgePrevious: true)
            libraryDirty = false
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
        onChange?()
    }

    func reopenClosedTab() {
        guard var closed = closedTabs.popLast() else { return }
        if tabs.contains(where: { $0.id == closed.tab.id }) { closed.tab.id = UUID() }
        closed.tab = restoredTab(closed.tab)
        tabs.insert(closed.tab, at: max(0, min(closed.position, tabs.count)))
        selectTab(closed.tab.id)
    }

    func findInPage(_ text: String, forward: Bool = true, findNext: Bool = false) {
        guard let id = activeWebTab?.id else { return }
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
    func printPage() { if let id = activeWebTab?.id { engine.printPage(tabID: id) } }
    func cancelDownload(_ id: String) {
        guard downloads.contains(where: { $0.id == id && $0.state == .inProgress }) else { return }
        engine.cancelDownload(id: id)
    }

    private func setZoomPercentage(_ percent: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeWebTab?.id }) else { return }
        tabs[index].zoomLevel = log(Double(percent) / 100) / log(1.2)
        engine.setZoom(tabID: tabs[index].id, level: tabs[index].zoomLevel)
        changed(persistImmediately: true)
    }

    func saveSession() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try sessions.save(BrowserSession(tabs: tabs, activeTabID: activeTabID, closedTabs: closedTabs))
            try settingsStore.save(settings)
            if libraryDirty {
                try libraryStore.save(library)
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

    private func restore(_ session: BrowserSession) {
        var tabIDs = Set<UUID>()
        tabs = session.tabs.filter { tabIDs.insert($0.id).inserted }.map(restoredTab)
        closedTabs = Array(session.closedTabs.filter { !tabIDs.contains($0.tab.id) }.suffix(Self.closedTabLimit))
        activeTabID = tabs.contains(where: { $0.id == session.activeTabID }) ? session.activeTabID : visibleTabs.first?.id
    }

    /// Validates a persisted or closed tab and starts it without an engine page.
    private func restoredTab(_ saved: Tab) -> Tab {
        var tab = saved
        tab.url = InternalPage(url: tab.url)?.rawValue ?? (try? navigation.normalize(tab.url, searchURL: settings.searchURL)) ?? "about:blank"
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
        case .popup(let url): openPopup(url)
        case .popupCreated(let id, let url): adoptPopup(id, url: url)
        case .title(let id, let value): didChangeTitle(id, value)
        case .url(let id, let value): didCommit(id, url: value)
        case .loading(let id, let loading, let back, let forward):
            didChangeLoading(id, loading: loading, canGoBack: back, canGoForward: forward)
        case .failure(let id, let message), .rendererTerminated(let id, let message):
            didFail(id, message: message)
        case .favicon(let id, let value):
            updateTab(id) {
                if $0.page.favicon != value { $0.page.faviconImage = nil }
                $0.page.favicon = value
            }
            changed()
        case .faviconImage(let id, let url, let image):
            // A download for an icon the page has since replaced is stale.
            guard let tab = tabs.first(where: { $0.id == id }), tab.page.favicon == url else { return }
            updateTab(id) { $0.page.faviconImage = image }
            if let image, bookmarks.contains(where: { FaviconStore.key(for: $0.url) == FaviconStore.key(for: tab.url) }) {
                favicons.save(image, for: tab.url)
            }
            changed()
        case .audio(let id, let playing):
            updateTab(id) { $0.page.audible = playing }
            changed()
        case .findResult(let id, let count, let active, _):
            didFind(id, count: count, active: active)
        case .fullscreen(let id, let entering):
            didChangeFullscreen(id, entering: entering)
        case .openInBackground(let id, let url):
            openInBackground(url, from: id)
        case .searchSelection(let id, let text):
            searchInNewTab(text, from: id)
        case .permissionDecided(let decision):
            rememberPermission(decision)
        case .devTools(let id, let open):
            guard tabs.contains(where: { $0.id == id }) else { return }
            if open { devToolsTabIDs.insert(id) } else { devToolsTabIDs.remove(id) }
            onChange?()
        }
    }

    /// A link the page asked to open in a new tab. A file the page generated keeps its blob address.
    private func openPopup(_ url: String) {
        guard NavigationController.isWebBlob(url) else { newTab(url: url); return }
        let tab = Tab(url: url, title: title(for: url))
        insert(tab, after: activeTabID)
        selectTab(tab.id)
    }

    private func didChangeFullscreen(_ id: UUID, entering: Bool) {
        if entering {
            // A page in a background tab cannot take over the window.
            guard id == activeTabID else { engine.exitFullscreen(tabID: id); return }
            fullscreenTabID = id
        } else if fullscreenTabID == id {
            fullscreenTabID = nil
        } else { return }
        onChange?()
    }

    private func insert(_ tab: Tab, after openerID: UUID?) {
        if let openerID, let index = tabs.firstIndex(where: { $0.id == openerID }) { tabs.insert(tab, at: index + 1) }
        else { tabs.append(tab) }
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
        // A page opening a file it generated, such as a PDF, hands the new tab a blob address.
        let blob = NavigationController.isWebBlob(url) ? url : nil
        guard let destination = blob ?? (try? navigation.normalize(url, searchURL: settings.searchURL)) else {
            engine.close(tabID: id)
            return
        }
        tabs.append(Tab(id: id, url: destination, title: title(for: destination)))
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
        if fullscreenTabID == id { fullscreenTabID = nil }
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
        guard let position = tabs.firstIndex(where: { $0.id == id }) else { return }
        closedTabs.append(ClosedTab(tab: tabs[position], position: position))
        closedTabs = Array(closedTabs.suffix(Self.closedTabLimit))
        let removedIndex = visibleTabs.firstIndex { $0.id == id } ?? 0
        if findTabID == id { stopFinding() }
        if fullscreenTabID == id { fullscreenTabID = nil }
        runtime[id] = nil
        devToolsTabIDs.remove(id)
        tabs.remove(at: position)
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
        devToolsTabIDs.remove(id)
        if fullscreenTabID == id { fullscreenTabID = nil }
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

    private var library: BrowserLibrary {
        BrowserLibrary(history: history, bookmarks: bookmarks, folders: bookmarkFolders, downloads: downloads)
    }

    private func libraryChanged() {
        libraryDirty = true
        changed(persistImmediately: true)
    }

    private func folderName(_ name: String) -> String? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return clean.isEmpty ? nil : clean
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
        if url == "about:blank" { return "Nova guia" }
        if let page = InternalPage(url: url) { return page.title }
        if NavigationController.isWebBlob(url) { return URL(string: String(url.dropFirst(5)))?.host ?? url }
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
}

extension BrowserStore: SitePermissionPolicy {
    func permissionDecision(origin: String, permission: SitePermission) -> Bool? {
        guard let origin = NavigationController.origin(of: origin) else { return nil }
        return settings.sitePermissions.last { $0.answers(permission, for: origin) }?.allowed
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
