import Foundation
import AppKit

private final class FakeEngine: BrowserEngine {
    var onEvent: ((BrowserEvent) -> Void)?
    let capabilities = EngineCapabilities()
    var created: [UUID] = []
    var activated: [UUID] = []
    var requestedClose: [UUID] = []
    var navigated: [(UUID, String)] = []
    var muteChanges: [(UUID, Bool)] = []
    var didShutdown = false
    var findRequests: [(UUID, String, Bool, Bool)] = []
    var stoppedFinds: [UUID] = []
    var zoomChanges: [(UUID, Double)] = []
    var printed: [UUID] = []
    var cancelledDownloads: [String] = []
    var exitedFullscreen: [UUID] = []
    weak var permissionPolicy: SitePermissionPolicy?
    func makeView(for tab: Tab) -> NSView { created.append(tab.id); return NSView() }
    func activate(tabID: UUID) { activated.append(tabID) }
    func navigate(tabID: UUID, url: String) { navigated.append((tabID, url)) }
    func goBack(tabID: UUID) {}
    func goForward(tabID: UUID) {}
    func reload(tabID: UUID) {}
    func stop(tabID: UUID) {}
    func setMuted(tabID: UUID, muted: Bool) { muteChanges.append((tabID, muted)) }
    func close(tabID: UUID) { requestedClose.append(tabID) }
    var devToolsRequests: [UUID] = []
    var closedDevTools: [UUID] = []
    func showDevTools(tabID: UUID) { devToolsRequests.append(tabID) }
    func closeDevTools(tabID: UUID) { closedDevTools.append(tabID) }
    func devToolsView(tabID: UUID) -> NSView? { NSView() }
    func find(tabID: UUID, text: String, forward: Bool, findNext: Bool) { findRequests.append((tabID, text, forward, findNext)) }
    func stopFinding(tabID: UUID) { stoppedFinds.append(tabID) }
    func setZoom(tabID: UUID, level: Double) { zoomChanges.append((tabID, level)) }
    func printPage(tabID: UUID) { printed.append(tabID) }
    func cancelDownload(id: String) { cancelledDownloads.append(id) }
    func exitFullscreen(tabID: UUID) { exitedFullscreen.append(tabID) }
    func setPermissionPolicy(_ policy: SitePermissionPolicy) { permissionPolicy = policy }
    func shutdown() { didShutdown = true }
}

@main
struct CoreTests {
    private static var checks = 0

    static func main() throws {
        try testNavigation()
        testLifecycle()
        try testRestoreAndTabOrder()
        try testAsynchronousDiscard()
        try testCloseCancellationAndEvents()
        try testQuitCancellation()
        try testHistoryAndBookmarks()
        try testBookmarkFolders()
        try testBookmarkOrder()
        try testReopenAndAbruptExit()
        try testRecoveryAndMigration()
        try testPageToolsDownloadsAndPopups()
        try testCancelledNavigationKeepsCommittedURL()
        try testInternalPages()
        try testContextMenuActionsAndFullscreen()
        testDevTools()
        try testSitePermissions()
        testFavicons()
        print("PASS: \(checks) core checks")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String,
                               file: StaticString = #file, line: UInt = #line) rethrows {
        checks += 1
        if try condition() == false { fatalError("FAIL: \(message)", file: file, line: line) }
    }

    private static func testNavigation() throws {
        let navigation = NavigationController()
        expect(tryResult { try navigation.normalize(" github.com ") } == "https://github.com", "Domain gets HTTPS")
        try expect(try navigation.normalize("localhost:4321/docs") == "http://localhost:4321/docs", "Local dev port uses HTTP")
        try expect(try navigation.normalize("localhost?test=1") == "http://localhost?test=1", "Local query uses HTTP")
        try expect(try navigation.normalize("127.0.0.1:8080") == "http://127.0.0.1:8080", "Loopback gets HTTP")
        try expect(try navigation.normalize("[::1]:8080") == "http://[::1]:8080", "IPv6 loopback gets HTTP")
        try expect(try navigation.normalize("https://example.com/a?b=c#d") == "https://example.com/a?b=c#d", "Valid URL is preserved")
        let search = try navigation.normalize("ação & café")
        expect(URLComponents(string: search)?.queryItems?.first?.value == "ação & café", "Search query safely round-trips UTF-8")
        for input in ["javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "chrome://settings", "https://user:pass@example.com", "https://", "http:example.com"] {
            expect((try? navigation.normalize(input)) == nil, "Unsafe or malformed input rejected: \(input)")
        }
        try expect(try navigation.normalize("") == "about:blank", "Empty address resolves to blank page")
        expect(!navigation.isSafeSearchURL("http://example.com/?q={query}"), "Search templates require HTTPS")
        expect(!navigation.isSafeSearchURL("https://{query}.example.com/?q=test"), "Search placeholder cannot enter authority")
        expect(!navigation.isSafeSearchURL("https://example.com/{query}?q=test"), "Search placeholder must be query value")
        expect(navigation.isSafeSearchURL("https://example.com/search?q={query}&src=lume"), "Safe search template accepted")
        try expect(try navigation.normalize("find this", searchURL: "javascript:{query}").hasPrefix("https://duckduckgo.com/"), "Invalid search template falls back safely")
    }

    private static func testLifecycle() {
        let now = Date()
        var active = Tab()
        active.page.memoryState = .active
        var old = Tab()
        old.page.memoryState = .warm
        old.lastActivatedAt = now.addingTimeInterval(-3600)
        var pinned = old; pinned.id = UUID(); pinned.pinned = true
        var audible = old; audible.id = UUID(); audible.page.audible = true
        var loading = old; loading.id = UUID(); loading.page.status = .loading
        var discarded = old; discarded.id = UUID(); discarded.page.memoryState = .discarded
        let tabs = [active, old, pinned, audible, loading, discarded]
        let lifecycle = TabLifecycleManager()
        let policy = MemoryPolicy()
        expect(lifecycle.discardCandidates(tabs: tabs, activeTabID: active.id, policy: policy, now: now).isEmpty,
               "Automatic discard is opt-in")
        expect(lifecycle.discardCandidates(tabs: tabs, activeTabID: active.id, policy: policy, now: now, manual: true) == [old.id],
               "Manual discard protects active, pinned, audible, loading and already discarded tabs")
        var automatic = policy
        automatic.automaticDiscardEnabled = true
        expect(lifecycle.discardCandidates(tabs: tabs, activeTabID: active.id, policy: automatic, now: now) == [old.id],
               "Expired warm tab is eligible after opt-in")
        automatic.keepPinnedTabsAlive = false
        expect(Set(lifecycle.discardCandidates(tabs: tabs, activeTabID: active.id, policy: automatic, now: now)) == Set([old.id, pinned.id]),
               "Pinned-tab exception requires policy change")
        let invalid = MemoryPolicy(warmTabLimit: -1, freezeAfterMinutes: 0, discardAfterMinutes: -3)
        expect(invalid.validated.warmTabLimit == 1 && invalid.validated.discardAfterMinutes == 1, "Invalid limits normalized")
        expect(!EngineCapabilities().supportsFreezing, "No false claim of page freezing")
    }

    private static func testRestoreAndTabOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let first = BrowserStore(engine: engine, dataDirectory: directory)
        expect(engine.created.count == 1, "First run materializes one blank tab")
        first.navigate("example.com")
        engine.onEvent?(.url(first.activeTabID!, "https://example.com"))
        first.newTab(url: "https://example.org")
        first.togglePin(first.activeTabID!)
        first.newTab()
        first.navigate("localhost:4321")
        engine.onEvent?(.url(first.activeTabID!, "http://localhost:4321"))
        first.setTheme(.dark)
        first.toggleSidebar()
        first.setTranslucency(.high)
        let activeID = first.activeTabID!
        first.saveSession()
        expect(first.visibleTabs.map(\.url) == ["https://example.org", "https://example.com", "http://localhost:4321"],
               "All tabs share one list with pinned tabs first")
        let raw = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        _ = try JSONDecoder().decode(BrowserSession.self, from: raw)
        expect(first.persistenceError == nil, "Session writes valid JSON atomically")
        let savedTabs = (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
        let persistedKeys: Set<String> = ["id", "url", "title", "createdAt", "lastActivatedAt", "pinned", "muted", "zoomLevel"]
        expect(!savedTabs.isEmpty && savedTabs.allSatisfy { Set($0.keys).isSubset(of: persistedKeys) },
               "Live page state is never written to the session")
        first.shutdown()
        expect(engine.didShutdown, "Shutdown reaches engine after saving")

        let restoreEngine = FakeEngine()
        let restored = BrowserStore(engine: restoreEngine, dataDirectory: directory)
        defer { restored.shutdown() }
        expect(restored.tabs.count == 3, "Session restores every tab")
        expect(restored.activeTabID == activeID, "Session restores the selected tab")
        expect(restoreEngine.created == [activeID], "Restore only materializes the active tab")
        expect(restored.tabs.filter { $0.page.memoryState == .discarded }.count == 2, "Inactive restored tabs remain discarded")
        expect(restored.settings.theme == .dark && !restored.settings.sidebarVisible && restored.settings.translucency == .high,
               "Appearance preferences persist")
        expect(restored.visibleTabs.first?.pinned == true, "Pinned tabs sort first")
        restored.selectTab(restored.visibleTabs[0].id)
        expect(restoreEngine.created.count == 2, "Selecting a restored tab lazily materializes it")
        expect(restored.tabs.filter { $0.page.memoryState == .active }.count == 1, "Exactly one tab is active")
    }

    private static func testAsynchronousDiscard() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        let firstID = store.activeTabID!
        store.newTab(url: "example.com")
        let secondID = store.activeTabID!
        store.discardInactiveTabs()
        expect(engine.requestedClose == [firstID], "Discard requests only inactive tab closure")
        expect(store.tabs.first { $0.id == firstID }?.page.memoryState == .warm, "Discard waits for engine close confirmation")
        engine.onEvent?(.closed(firstID))
        expect(store.tabs.first { $0.id == firstID }?.page.memoryState == .discarded, "Confirmed close marks discarded")
        expect(store.tabs.count == 2, "Discard preserves session metadata")
        store.selectTab(firstID)
        expect(engine.created.filter { $0 == firstID }.count == 2, "Discarded tab recreates only when selected")
        store.discardInactiveTabs()
        expect(engine.requestedClose.last == secondID, "Another inactive tab can be discarded")
        store.selectTab(secondID)
        engine.onEvent?(.closed(secondID))
        expect(store.activeTabID == secondID && store.activeTab?.page.memoryState == .active, "Reselecting a closing tab recreates it after close")
        expect(engine.created.filter { $0 == secondID }.count == 2, "Pending discard race recreates once")
    }

    private static func testCloseCancellationAndEvents() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        let firstID = store.activeTabID!
        store.newTab(url: "https://example.com")
        store.closeTab(firstID)
        expect(store.tabs.count == 2, "Close retains model until beforeunload resolves")
        engine.onEvent?(.closeCancelled(firstID))
        store.closeTab(firstID)
        expect(engine.requestedClose == [firstID, firstID], "Cancelled close can be requested again")
        engine.onEvent?(.closed(firstID))
        expect(store.tabs.count == 1, "Confirmed user close removes tab entity")
        let id = store.activeTabID!
        engine.onEvent?(.loading(id, true, true, false))
        engine.onEvent?(.title(id, "Example page"))
        engine.onEvent?(.url(id, "https://example.com/page"))
        engine.onEvent?(.audio(id, true))
        expect(store.activeTab?.title == "Example page" && store.activeTab?.page.canGoBack == true && store.activeTab?.page.audible == true,
               "Engine events update tab state")
        engine.onEvent?(.failure(id, "Network offline"))
        engine.onEvent?(.loading(id, false, true, false))
        expect(store.activeTab?.page.status == .failed("Network offline"), "Loading completion preserves navigation failure")
        let navigations = engine.navigated.count
        store.navigate("javascript:alert(1)")
        expect(engine.navigated.count == navigations, "Blocked protocol never reaches engine")
        expect(store.activeTab?.page.inputError != nil && store.activeTab?.page.status == .failed("Network offline"),
               "A rejected address is reported apart from the page status")
        engine.onEvent?(.loading(id, true, true, false))
        engine.onEvent?(.loading(id, false, true, false))
        expect(store.activeTab?.page.status == .ready && store.activeTab?.page.errorMessage == nil,
               "A new load clears the rejected address and completes as ready")
        store.navigate("javascript:alert(2)")
        engine.onEvent?(.loading(id, false, true, false))
        expect(store.activeTab?.page.status == .ready && store.activeTab?.page.inputError != nil,
               "A rejected address never turns a loaded page into a failure")
        store.closeTab(id)
        engine.onEvent?(.closed(id))
        expect(store.tabs.count == 1 && store.activeTab?.url == "about:blank", "Closing final tab provides a new blank tab")
    }

    private static func testBookmarkFolders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        store.navigate("https://a.test")
        engine.onEvent?(.url(store.activeTabID!, "https://a.test"))
        store.toggleBookmark()
        store.newTab(url: "https://b.test")
        store.toggleBookmark()
        let first = store.bookmarks.first { $0.url == "https://a.test" }!.id
        expect(store.bookmarks(inFolder: nil).map(\.url) == ["https://a.test", "https://b.test"], "Favorites keep the order they were added in")
        expect(store.newBookmarkFolder(name: "   ", icon: "star") == nil, "A folder needs a name")
        let folder = store.newBookmarkFolder(name: "  Trabalho  ", icon: "not.a.symbol")!
        expect(store.bookmarkFolders.first?.name == "Trabalho" && store.bookmarkFolders.first?.icon == "folder",
               "Folder names are trimmed and unknown icons fall back")
        store.moveBookmark(first, toFolder: folder)
        store.updateBookmarkFolder(folder, name: "Projetos", icon: "briefcase")
        store.renameBookmark(first, title: "  Site A  ")
        expect(store.bookmarks(inFolder: folder).map(\.title) == ["Site A"] && store.bookmarks(inFolder: nil).count == 1,
               "Bookmarks move into folders")
        store.openBookmark(first)
        expect(store.activeTab?.url == "https://a.test" && store.tabs.count == 2, "Opening a favorite switches to its open tab")
        store.shutdown()

        let restored = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(restored.bookmarkFolders.map(\.icon) == ["briefcase"] && restored.bookmarks(inFolder: folder).count == 1,
               "Folders and their icons persist")
        restored.removeBookmarkFolder(folder)
        expect(restored.bookmarkFolders.isEmpty && restored.bookmarks(inFolder: nil).count == 2,
               "Deleting a folder keeps its bookmarks at the top level")
        restored.openBookmark(restored.bookmarks[0].id)
        expect(restored.activeTab?.url == restored.bookmarks[0].url, "Opening a favorite without a tab opens a new one")
        restored.shutdown()
    }

    private static func testBookmarkOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        for host in ["a", "b", "c"] {
            store.newTab(url: "https://\(host).test")
            expect(store.bookmarkCurrentPage() != nil, "A web page can be bookmarked")
        }
        let first = store.bookmarkCurrentPage()
        expect(first == store.bookmarks.last?.id && store.bookmarks.count == 3, "Bookmarking a saved page returns its favorite")
        func order(_ folder: UUID? = nil) -> [String] { store.bookmarks(inFolder: folder).map { URL(string: $0.url)!.host! } }
        let id = { (host: String) in store.bookmarks.first { $0.url == "https://\(host).test" }!.id }
        store.moveBookmark(id("c"), toFolder: nil, at: 0)
        expect(order() == ["c.test", "a.test", "b.test"], "A favorite moves to the front")
        store.moveBookmark(id("c"), toFolder: nil, at: 2)
        expect(order() == ["a.test", "b.test", "c.test"], "A favorite moves to the end")
        let folder = store.newBookmarkFolder(name: "Leitura", icon: "book")!
        store.moveBookmark(id("b"), toFolder: folder)
        store.moveBookmark(id("a"), toFolder: folder, at: 0)
        expect(order(folder) == ["a.test", "b.test"] && order() == ["c.test"], "Favorites drop into a folder at a position")
        store.moveBookmark(id("b"), toFolder: nil, at: 0)
        expect(order() == ["b.test", "c.test"] && order(folder) == ["a.test"], "A favorite leaves its folder")
        let second = store.newBookmarkFolder(name: "Ferramentas", icon: "terminal")!
        store.moveBookmarkFolder(second, to: 0)
        expect(store.bookmarkFolders.map(\.id) == [second, folder], "Folders reorder")
        expect(store.searchBookmarks("").map { URL(string: $0.url)!.host! } == ["c.test", "b.test", "a.test"],
               "The library still lists favorites newest first")
        store.shutdown()
        let restored = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(restored.bookmarks(inFolder: nil).map(\.url) == ["https://b.test", "https://c.test"]
               && restored.bookmarkFolders.map(\.id) == [second, folder], "The favorites order persists")
        restored.shutdown()

        // Version 1 stored favorites newest first and showed them in reverse.
        let url = directory.appendingPathComponent("library.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        legacy["version"] = 1
        legacy["folders"] = []
        legacy["bookmarks"] = ["https://new.test", "https://old.test"].map { ["id": UUID().uuidString, "url": $0, "title": $0, "createdAt": 0] }
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let migrated = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(migrated.bookmarks(inFolder: nil).map(\.url) == ["https://old.test", "https://new.test"],
               "Favorites saved by version 1 keep their sidebar order")
        migrated.moveBookmark(migrated.bookmarks[0].id, toFolder: nil, at: 1)
        migrated.shutdown()
        let saved = try LibraryStore(directory: directory).load()
        expect(saved.version == 2 && saved.bookmarks.map(\.url) == ["https://new.test", "https://old.test"],
               "The next save writes the current version in sidebar order")
    }

    private static func testInternalPages() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        let createdBefore = engine.created.count
        store.openInternalPage(.settings)
        let settingsID = store.activeTabID!
        expect(store.activeTab?.url == "lume://ajustes" && store.activeTab?.title == "Ajustes" && engine.created.count == createdBefore,
               "Settings open in a tab without an engine page")
        store.openInternalPage(.library)
        store.openInternalPage(.settings)
        expect(store.activeTabID == settingsID && store.tabs.count == 3, "An open Lume page is reused")
        let requests = engine.navigated.count
        store.reload()
        store.zoomIn()
        store.findInPage("texto")
        expect(engine.navigated.count == requests && store.zoomPercentage == 100 && engine.findRequests.isEmpty
               && store.activeTab?.page.status == .idle, "Page tools leave Lume pages alone")
        store.navigate("lume://biblioteca")
        expect(store.activeTab?.internalPage == .library && store.tabs.count == 3, "Typing a Lume address opens its page")
        store.discardInactiveTabs()
        expect(!engine.requestedClose.contains(settingsID), "Lume pages are never discarded")
        store.selectTab(settingsID)
        store.navigate("example.com")
        expect(store.activeTab?.url == "https://example.com" && engine.created.last == settingsID,
               "Navigating from a Lume page loads the site in the same tab")
        store.openInternalPage(.library)
        let libraryID = store.activeTabID!
        store.shutdown()
        let restored = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(restored.activeTabID == libraryID && restored.activeTab?.internalPage == .library, "Lume pages survive a restart")
        restored.closeTab(libraryID)
        expect(!restored.tabs.contains { $0.id == libraryID }, "A Lume page closes without the engine")
        restored.shutdown()
    }

    private static func testFavicons() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        let id = store.activeTabID!
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        engine.onEvent?(.favicon(id, "https://a.test/favicon.ico"))
        engine.onEvent?(.faviconImage(id, "https://a.test/old.ico", icon))
        expect(store.activeTab?.page.faviconImage == nil, "A stale favicon download is ignored")
        engine.onEvent?(.faviconImage(id, "https://a.test/favicon.ico", icon))
        expect(store.activeTab?.page.faviconImage === icon, "The current favicon download reaches the tab")
        engine.onEvent?(.favicon(id, "https://a.test/favicon.ico"))
        expect(store.activeTab?.page.faviconImage === icon, "Repeating the same favicon keeps its icon")
        engine.onEvent?(.favicon(id, "https://b.test/favicon.ico"))
        expect(store.activeTab?.page.faviconImage == nil, "A new favicon shows the fallback until it downloads")
        engine.onEvent?(.faviconImage(id, "https://b.test/favicon.ico", nil))
        expect(store.activeTab?.page.faviconImage == nil, "A failed download keeps the fallback")

        let drawn = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        engine.onEvent?(.url(id, "https://c.test/page"))
        store.toggleBookmark()
        engine.onEvent?(.favicon(id, "https://c.test/icon.png"))
        engine.onEvent?(.faviconImage(id, "https://c.test/icon.png", drawn))
        store.shutdown()
        let reopened = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        defer { reopened.shutdown() }
        expect(reopened.favicon(for: reopened.bookmarks[0]) != nil, "Bookmarked hosts keep their icon across launches")
        reopened.removeBookmark(reopened.bookmarks[0].id)
        expect(FaviconStore(directory: directory).image(for: "https://c.test") == nil, "Removing the bookmark deletes its icon")
    }

    private static func testHistoryAndBookmarks() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        let id = store.activeTabID!
        store.navigate("https://example.com/cafe")
        engine.onEvent?(.loading(id, true, false, false))
        engine.onEvent?(.url(id, "https://example.com/cafe"))
        engine.onEvent?(.title(id, "Café e ação"))
        engine.onEvent?(.loading(id, false, false, false))
        engine.onEvent?(.loading(id, false, false, false))
        expect(store.history.count == 1, "Repeated loading completion records one visit")
        expect(store.searchHistory("cafe acao").count == 1, "History search ignores accents and searches multiple terms")
        expect(tryResult { try LibraryStore(directory: directory).load().history.count } == 1, "Completed navigation persists without waiting for shutdown")
        engine.onEvent?(.title(id, "Título final"))
        expect(store.history.first?.title == "Título final", "Late title updates the matching visit")
        store.toggleBookmark()
        expect(store.isCurrentPageBookmarked && store.bookmarks.count == 1, "Current page can be bookmarked")
        expect(store.searchBookmarks("titulo final").count == 1, "Bookmark search finds the saved title")
        let restored = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(restored.history.count == 1 && restored.bookmarks.count == 1, "History and bookmarks survive profile reopening")
        restored.shutdown()
        store.navigate("https://example.com/failure")
        engine.onEvent?(.loading(id, true, false, false))
        engine.onEvent?(.failure(id, "Rede indisponível"))
        engine.onEvent?(.loading(id, false, false, false))
        expect(store.history.count == 1, "Failed navigation is not recorded as a successful visit")
        store.clearHistory()
        expect(store.history.isEmpty && store.bookmarks.count == 1, "Clear history preserves bookmarks")
        let backup = try JSONDecoder().decode(BrowserLibrary.self, from: Data(contentsOf: directory.appendingPathComponent("library.backup.json")))
        expect(backup.history.isEmpty && backup.bookmarks.count == 1, "History deletion also clears the recovery copy")
        store.removeBookmark(store.bookmarks[0].id)
        expect(tryResult { try LibraryStore(directory: directory).load().bookmarks.isEmpty } == true, "Bookmark removal is persisted immediately")
    }

    private static func testReopenAndAbruptExit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        let firstID = store.activeTabID!
        store.newTab(url: "example.com")
        let closedID = store.activeTabID!
        store.newTab(url: "example.org")
        store.closeTab(closedID)
        expect(!store.canReopenClosedTab, "Requested closure is not yet eligible for reopening")
        engine.onEvent?(.closeCancelled(closedID))
        expect(!store.canReopenClosedTab && store.tabs.contains { $0.id == closedID }, "Cancelled beforeunload keeps the tab and does not create reopen history")
        store.closeTab(closedID)
        engine.onEvent?(.closed(closedID))
        expect(store.canReopenClosedTab, "Confirmed closure becomes reopenable")
        store.reopenClosedTab()
        expect(store.activeTabID == closedID, "Reopening selects the tab")
        expect(store.tabs.map(\.id).prefix(2) == [firstID, closedID], "Reopening preserves original position")
        expect(!store.canReopenClosedTab, "Reopened entry is consumed once")
        store.closeTab(closedID)
        engine.onEvent?(.closed(closedID))
        let snapshot = try SessionManager(directory: directory).restore()!
        expect(!snapshot.tabs.contains { $0.id == closedID } && snapshot.closedTabs.last?.tab.id == closedID,
               "Abrupt exit after confirmed closure preserves both session and reopen stack")
        let restoreEngine = FakeEngine()
        let restored = BrowserStore(engine: restoreEngine, dataDirectory: directory)
        expect(restored.canReopenClosedTab, "Closed tabs persist across app launches")
        restored.reopenClosedTab()
        expect(restored.activeTabID == closedID && restored.activeTab?.url == "https://example.com", "Persisted closed tab reopens with its URL")
        restored.shutdown()

        var limited = snapshot
        limited.closedTabs = (0..<40).map { offset in ClosedTab(tab: Tab(url: "https://example.com/\(offset)"), position: 0) }
        try SessionManager(directory: directory).save(limited)
        let bounded = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        bounded.saveSession()
        expect(tryResult { try SessionManager(directory: directory).restore()?.closedTabs.count } == BrowserStore.closedTabLimit,
               "Restored closed-tab history obeys the limit")
        bounded.shutdown()
    }

    private static func testRecoveryAndMigration() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = Tab(url: "https://example.com")
        let manager = SessionManager(directory: directory)
        var first = BrowserSession(tabs: [tab], activeTabID: tab.id)
        try manager.save(first)
        first.tabs[0].url = "https://example.org"
        try manager.save(first)
        let primary = directory.appendingPathComponent("session.json")
        try Data("{broken".utf8).write(to: primary)
        let recoveredManager = SessionManager(directory: directory)
        let recovered = try recoveredManager.restore()!
        expect(recovered.tabs[0].url == "https://example.com", "Corrupted session recovers the validated previous snapshot")
        expect(recoveredManager.recoveryMessage != nil, "Recovery is reported to the UI")
        let preserved = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("session.corrupt-") }
        expect(preserved.count == 1, "Corrupted original is preserved separately")
        expect(tryResult { try SessionManager(directory: directory).restore()?.tabs.count } == 1, "Recovered primary is readable on the next launch")

        let encoded = try JSONEncoder().encode(first)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy["version"] = 1
        legacy.removeValue(forKey: "closedTabs")
        var legacyTabs = legacy["tabs"] as! [[String: Any]]
        legacyTabs[0].removeValue(forKey: "zoomLevel")
        legacyTabs[0].merge(["loading": true, "status": "failed", "error": "Stale", "memoryState": "active"]) { $1 }
        legacy["tabs"] = legacyTabs
        try JSONSerialization.data(withJSONObject: legacy).write(to: primary)
        let migrated = try SessionManager(directory: directory).restore()!
        expect(migrated.version == 1 && migrated.closedTabs.isEmpty && migrated.tabs[0].zoomLevel == 0,
               "First-milestone profiles load with defaults for new fields")
        expect(migrated.tabs[0].page == PageState(), "Page state saved by earlier versions is ignored")

        let tabIDs = (0..<3).map { _ in UUID() }
        var grouped = legacy
        grouped["version"] = 2
        grouped["tabs"] = tabIDs.map { ["id": $0.uuidString, "url": "https://example.com/\($0)", "workspaceId": UUID().uuidString] }
        grouped["workspaces"] = [["id": UUID().uuidString, "name": "Trabalho", "tabs": [tabIDs[2].uuidString]],
                                 ["id": UUID().uuidString, "name": "Pessoal", "tabs": [tabIDs[0].uuidString, tabIDs[1].uuidString]]]
        try JSONSerialization.data(withJSONObject: grouped).write(to: primary)
        let merged = try SessionManager(directory: directory).restore()!
        expect(merged.tabs.map(\.id) == [tabIDs[2], tabIDs[0], tabIDs[1]], "Workspace tabs merge into one list in workspace order")

        let oldSettings = Data("{\"theme\":\"dark\",\"memoryPolicy\":{\"warmTabLimit\":3}}".utf8)
        try oldSettings.write(to: directory.appendingPathComponent("settings.json"))
        let settings = try SettingsStore(directory: directory).load()
        expect(settings.theme == .dark && settings.memoryPolicy.warmTabLimit == 3 && !settings.memoryPolicy.automaticDiscardEnabled
               && settings.translucency == .medium && settings.favoritesLayout == .icons && !settings.favoritesCollapsed,
               "Missing preference fields use safe defaults")
        for (saved, level) in [("true", Translucency.medium), ("false", .off)] {
            try Data("{\"translucency\":\(saved)}".utf8).write(to: directory.appendingPathComponent("settings.json"))
            let loaded = try SettingsStore(directory: directory).load()
            expect(loaded.translucency == level,
                   "The earlier glass switch becomes a transparency level")
        }

        legacy["version"] = 999
        let future = try JSONSerialization.data(withJSONObject: legacy)
        try future.write(to: primary)
        expect((try? SessionManager(directory: directory).restore()) == nil, "Unsupported future schema is refused")
        expect((try? manager.save(first)) == nil && (try? Data(contentsOf: primary)) == future,
               "Unsupported future profile cannot be overwritten by autosave")
    }

    private static func testPageToolsDownloadsAndPopups() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        let firstID = store.activeTabID!
        store.findInPage("texto")
        expect(engine.findRequests.last?.1 == "texto" && engine.findRequests.last?.3 == false, "Find starts a new engine search")
        engine.onEvent?(.findResult(firstID, 4, 1, true))
        expect(store.findMatchCount == 4 && store.findActiveMatch == 1, "Find exposes match counts")
        store.findInPage("texto", forward: false, findNext: true)
        expect(engine.findRequests.last?.2 == false && engine.findRequests.last?.3 == true, "Find can move to a previous match")
        engine.onEvent?(.findResult(firstID, -1, 4, true))
        expect(store.findMatchCount == 4 && store.findActiveMatch == 4, "Incremental find result preserves an unchanged match count")
        store.newTab(url: "example.com")
        engine.onEvent?(.findResult(firstID, 99, 99, true))
        expect(store.findMatchCount == 0 && engine.stoppedFinds.contains(firstID), "Tab switching cancels old find state and ignores late results")
        store.zoomIn()
        expect(store.zoomPercentage == 110, "Zoom uses meaningful percentage steps")
        store.zoomOut()
        expect(store.zoomPercentage == 100, "Zoom out restores prior step")
        store.zoomIn()
        let zoomTab = store.activeTabID!
        store.selectTab(firstID)
        expect(store.zoomPercentage == 100, "Zoom state is tracked per tab")
        store.selectTab(zoomTab)
        expect(store.zoomPercentage == 110, "Selecting a tab reapplies its zoom")
        store.resetZoom()
        store.printPage()
        expect(store.zoomPercentage == 100 && engine.printed.last == zoomTab, "Reset and print target the selected tab")
        engine.onEvent?(.rendererTerminated(zoomTab, "Página interrompida"))
        expect(store.activeTab?.page.status == .failed("Página interrompida") && store.tabs.contains { $0.id == zoomTab }, "Renderer termination preserves a reloadable tab")

        let popupID = UUID()
        engine.onEvent?(.popupCreated(popupID, "https://example.org/popup"))
        expect(store.activeTabID == popupID && engine.created.last == popupID, "Native popup is adopted with its engine-assigned ID")
        engine.onEvent?(.closed(popupID))
        expect(!store.tabs.contains { $0.id == popupID } && store.canReopenClosedTab, "window.close removes the popup and makes it reopenable")

        var download = BrowserDownload(id: "download-1", tabID: zoomTab, url: "https://example.com/file.txt", filename: "file.txt",
                                       path: "/tmp/file.txt", receivedBytes: 4, totalBytes: 10, state: .inProgress)
        engine.onEvent?(.download(download))
        store.cancelDownload(download.id)
        expect(engine.cancelledDownloads == [download.id] && store.downloads[0].state == .inProgress,
               "Download cancellation waits for engine confirmation")
        store.shutdown()
        download.state = .cancelled
        engine.onEvent?(.download(download))
        expect(tryResult { try LibraryStore(directory: directory).load().downloads.first?.state } == .cancelled,
               "Download cancellation during shutdown is immediately persisted")
        var library = try LibraryStore(directory: directory).load()
        library.downloads[0].state = .inProgress
        try LibraryStore(directory: directory).save(library)
        let restored = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(restored.downloads.first?.state == .failed, "Abruptly interrupted downloads are not falsely resumed")
        restored.shutdown()
    }

    private static func testCancelledNavigationKeepsCommittedURL() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        let id = store.activeTabID!
        engine.onEvent?(.url(id, "https://example.com/form"))
        engine.onEvent?(.title(id, "Formulário preenchido"))
        engine.onEvent?(.loading(id, false, true, false))
        let visits = store.history.count
        store.navigate("https://example.org/destination")
        expect(store.activeTab?.url == "https://example.com/form" && store.pendingNavigationURL == "https://example.org/destination",
               "Requested destination is separate from the committed address")
        let beforeCancel = try SessionManager(directory: directory).restore()!
        expect(beforeCancel.tabs.first?.url == "https://example.com/form", "An abrupt exit before navigation commits restores the original document")
        engine.onEvent?(.loading(id, true, true, false))
        engine.onEvent?(.closeCancelled(id))
        expect(store.activeTab?.url == "https://example.com/form" && store.activeTab?.page.status == .ready,
               "Beforeunload cancellation restores prior document and loading state")
        expect(store.pendingNavigationURL == nil && store.history.count == visits, "Cancelled destination is neither pending nor recorded as a visit")
        let afterCancel = try SessionManager(directory: directory).restore()!
        expect(afterCancel.tabs.first?.url == "https://example.com/form",
               "Cancellation persists the committed document, never the requested destination")

        store.navigate("https://example.org/accepted")
        engine.onEvent?(.loading(id, true, true, false))
        engine.onEvent?(.url(id, "https://example.org/accepted"))
        expect(store.activeTab?.url == "https://example.org/accepted" && store.pendingNavigationURL == nil,
               "Only an engine address event confirms the destination")
        expect(tryResult { try SessionManager(directory: directory).restore()?.tabs.first?.url } == "https://example.org/accepted",
               "Confirmed address is persisted immediately")
        engine.onEvent?(.loading(id, false, true, false))
        expect(store.history.first?.url == "https://example.org/accepted", "Accepted destination is recorded after loading completes")
        engine.onEvent?(.failure(id, "Erro anterior"))
        store.reload()
        engine.onEvent?(.loading(id, true, true, false))
        engine.onEvent?(.closeCancelled(id))
        expect(store.activeTab?.page.status == .failed("Erro anterior"),
               "Cancelling reload restores the previous error and status")
        store.navigate("https://example.org/recovered")
        expect(store.activeTab?.page.status == .loading && store.activeTab?.url == "https://example.org/accepted",
               "Retry clears the previous error without changing the committed address")
        engine.onEvent?(.url(id, "https://example.org/recovered"))
        engine.onEvent?(.loading(id, false, true, false))
        expect(store.activeTab?.page.status == .ready,
               "Navigation recovers from failure even when CEF coalesces loading=true")
        expect(store.history.first?.url == "https://example.org/recovered", "Recovered navigation is recorded as a successful visit")
    }

    private static func testQuitCancellation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        let firstID = store.activeTabID!
        store.newTab(url: "example.com")
        let secondID = store.activeTabID!
        store.newTab(url: "example.org")
        let thirdID = store.activeTabID!
        store.closeTab(thirdID)
        store.shutdown()
        engine.onEvent?(.closed(firstID))
        expect(store.tabs.count == 3, "Quitting keeps session entities after engine closures")
        expect(store.tabs.first { $0.id == firstID }?.page.memoryState == .discarded, "Quitting releases closed views")
        engine.onEvent?(.closeCancelled(secondID))
        expect(store.activeTabID == secondID, "Cancelling quit focuses the page that refused closure")
        engine.onEvent?(.title(secondID, "Retained unsaved form"))
        expect(store.activeTab?.title == "Retained unsaved form", "Engine events resume after quit cancellation")
        engine.onEvent?(.closed(thirdID))
        expect(store.tabs.first { $0.id == thirdID }?.page.memoryState == .discarded,
               "Late quit closures remain restorable, even when a user close was pending")
        store.selectTab(firstID)
        expect(engine.created.filter { $0 == firstID }.count == 2, "View closed during cancelled quit is recreated on selection")
        store.saveSession()
        let saved = try SessionManager(directory: directory).restore()
        expect(saved?.tabs.count == 3 && saved?.activeTabID == firstID, "Persistence remains usable after cancelled quit")
        engine.didShutdown = false
        store.shutdown()
        expect(engine.didShutdown, "Quit can be attempted again after cancellation")
    }

    private static func testContextMenuActionsAndFullscreen() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        store.newTab(url: "example.com")
        let pageID = store.activeTabID!
        store.newTab(url: "example.net")
        store.selectTab(pageID)

        engine.onEvent?(.openInBackground(pageID, "https://example.org/artigo"))
        let order = store.tabs.map(\.url)
        expect(store.activeTabID == pageID, "A link opened from the menu leaves the current tab in front")
        expect(order.firstIndex(of: "https://example.org/artigo") == order.firstIndex(of: "https://example.com")! + 1,
               "A background link opens beside the tab it came from")
        let backgroundID = store.tabs.first { $0.url == "https://example.org/artigo" }!.id
        expect(engine.created.contains(backgroundID) && store.tabs.first { $0.id == backgroundID }?.page.memoryState == .warm,
               "A background link starts loading at once")
        let count = store.tabs.count
        engine.onEvent?(.openInBackground(pageID, "javascript:alert(1)"))
        expect(store.tabs.count == count, "Only web links open from the menu")

        engine.onEvent?(.searchSelection(pageID, "  apple.com  "))
        expect(store.activeTab?.url.hasPrefix("https://duckduckgo.com/?q=apple.com") == true,
               "Searching a selection that looks like an address still searches")
        store.selectTab(pageID)

        let blobID = UUID()
        engine.onEvent?(.popupCreated(blobID, "blob:https://example.com/5e0c"))
        expect(store.activeTab?.url == "blob:https://example.com/5e0c" && store.activeTab?.title == "example.com",
               "A generated file opened by a page keeps its blob address")
        let foreignBlob = UUID()
        engine.onEvent?(.popupCreated(foreignBlob, "blob:null/5e0c"))
        expect(!store.tabs.contains { $0.id == foreignBlob } && engine.requestedClose.contains(foreignBlob),
               "A blob address without a web origin is refused")
        expect(NavigationController.isWebBlob("blob:http://localhost:3000/x") && !NavigationController.isWebBlob("blob:file:///x"),
               "Only blobs minted by web pages count")
        engine.onEvent?(.popup("blob:https://example.com/9a1f"))
        expect(store.activeTab?.url == "blob:https://example.com/9a1f", "A blob link opened with Command-click gets its own tab")

        store.selectTab(pageID)
        engine.onEvent?(.fullscreen(pageID, true))
        expect(store.fullscreenTabID == pageID, "The active page can enter fullscreen")
        engine.onEvent?(.fullscreen(backgroundID, true))
        expect(store.fullscreenTabID == pageID && engine.exitedFullscreen.last == backgroundID,
               "A background page is sent back out of fullscreen")
        store.selectTab(backgroundID)
        expect(store.fullscreenTabID == nil && engine.exitedFullscreen.last == pageID, "Switching tabs ends the page's fullscreen")
        engine.onEvent?(.fullscreen(backgroundID, true))
        store.exitFullscreen()
        expect(store.fullscreenTabID == nil && engine.exitedFullscreen.last == backgroundID, "Esc ends the page's fullscreen through the engine")
        engine.onEvent?(.fullscreen(backgroundID, true))
        engine.onEvent?(.fullscreen(backgroundID, false))
        expect(store.fullscreenTabID == nil, "The page can leave fullscreen on its own")
        engine.onEvent?(.fullscreen(backgroundID, true))
        store.closeTab(backgroundID)
        engine.onEvent?(.closed(backgroundID))
        expect(store.fullscreenTabID == nil, "Closing the tab clears its fullscreen")
        store.shutdown()
    }

    private static func testDevTools() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let store = BrowserStore(engine: engine, dataDirectory: directory)
        defer { store.shutdown() }
        store.navigate("example.com")
        let pageID = store.activeTabID!
        store.toggleDevTools()
        expect(engine.devToolsRequests == [pageID] && !store.showsDevTools, "DevTools shows only once the engine reports it open")
        engine.onEvent?(.devTools(pageID, true))
        expect(store.showsDevTools && store.devToolsView(for: pageID) != nil, "Open DevTools has a view for the panel")
        store.newTab(url: "example.net")
        expect(!store.showsDevTools, "Another tab shows no DevTools of its own")
        store.selectTab(pageID)
        store.toggleDevTools()
        expect(engine.closedDevTools == [pageID], "Toggling again closes DevTools")
        engine.onEvent?(.devTools(pageID, false))
        expect(!store.showsDevTools && store.devToolsView(for: pageID) == nil, "Closed DevTools leaves the panel")
        engine.onEvent?(.devTools(pageID, true))
        store.closeTab(pageID)
        engine.onEvent?(.closed(pageID))
        engine.onEvent?(.devTools(pageID, false))
        expect(store.devToolsView(for: pageID) == nil, "A closed tab takes its DevTools with it")
        store.setDevToolsWidth(512)
        store.saveSession()
        let reopened = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        defer { reopened.shutdown() }
        expect(reopened.settings.devToolsWidth == 512, "The panel keeps its width across launches")
    }

    private static func testSitePermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        var store: BrowserStore? = BrowserStore(engine: engine, dataDirectory: directory)
        expect(engine.permissionPolicy === store, "The store answers the engine's permission questions")
        expect(store!.permissionDecision(origin: "https://meet.example.com", permission: .camera) == nil, "Nothing is remembered at first")

        engine.onEvent?(.permissionDecided(SitePermissionDecision(origin: "https://Meet.Example.com:443/", permission: .camera, allowed: true)))
        engine.onEvent?(.permissionDecided(SitePermissionDecision(origin: "https://meet.example.com", permission: .microphone, allowed: false)))
        engine.onEvent?(.permissionDecided(SitePermissionDecision(origin: "https://meet.example.com", permission: .externalApp("ZoomMTG"), allowed: true)))
        expect(store!.permissionDecision(origin: "https://meet.example.com/sala?x=1", permission: .camera) == true,
               "A remembered answer applies to the whole origin")
        expect(store!.permissionDecision(origin: "http://meet.example.com", permission: .camera) == nil,
               "HTTP and HTTPS are different sites")
        expect(store!.permissionDecision(origin: "https://meet.example.com", permission: .microphone) == false, "Refusals are remembered too")
        expect(store!.permissionDecision(origin: "https://meet.example.com", permission: SitePermission(rawValue: "external:zoommtg")) == true,
               "External app permissions are kept per scheme")
        engine.onEvent?(.permissionDecided(SitePermissionDecision(origin: "https://meet.example.com", permission: .camera, allowed: false)))
        expect(store!.permissionDecision(origin: "https://meet.example.com", permission: .camera) == false && store!.sitePermissions.count == 3,
               "A new answer replaces the old one")
        engine.onEvent?(.permissionDecided(SitePermissionDecision(origin: "file:///etc", permission: .camera, allowed: true)))
        engine.onEvent?(.permissionDecided(SitePermissionDecision(origin: "https://example.com", permission: SitePermission(rawValue: "notifications"), allowed: true)))
        expect(store!.sitePermissions.count == 3, "Non-web origins and unknown permissions are not stored")
        store!.shutdown()
        store = nil

        store = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(store!.permissionDecision(origin: "https://meet.example.com", permission: .microphone) == false && store!.sitePermissions.count == 3,
               "Remembered answers survive a restart")
        store!.forgetPermission(origin: "https://meet.example.com", permission: .microphone)
        expect(store!.permissionDecision(origin: "https://meet.example.com", permission: .microphone) == nil, "Forgetting an answer makes the site ask again")
        store!.forgetAllPermissions()
        expect(store!.sitePermissions.isEmpty, "All answers can be forgotten at once")
        store!.shutdown()

        let settingsURL = directory.appendingPathComponent("settings.json")
        let tampered = #"{"sitePermissions":[{"origin":"https://a.example","permission":"camera","allowed":true,"decidedAt":0},{"origin":"https://a.example","permission":"camera","allowed":false,"decidedAt":1},{"origin":"javascript:x","permission":"camera","allowed":true,"decidedAt":0},{"origin":"https://b.example","permission":"external:../x","allowed":true,"decidedAt":0}]}"#
        try Data(tampered.utf8).write(to: settingsURL)
        let reloaded = BrowserStore(engine: FakeEngine(), dataDirectory: directory)
        expect(reloaded.sitePermissions.count == 1 && reloaded.permissionDecision(origin: "https://a.example", permission: .camera) == false,
               "Loading keeps the latest valid answer per site and drops malformed entries")
        reloaded.shutdown()
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumeCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func tryResult<T>(_ action: () throws -> T) -> T? { try? action() }
}
