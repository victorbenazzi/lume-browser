import Foundation
import AppKit

enum TabMemoryState: String, Codable, CaseIterable {
    case active, warm, frozen, discarded
}

enum PageStatus: Equatable {
    /// No document loaded by the current engine instance: new, restored or discarded.
    case idle
    case loading
    case ready
    case failed(String)

    var isLoading: Bool { self == .loading }
    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Live state of a tab's engine page. It is never persisted: restoring or
/// discarding a tab starts again from these defaults.
struct PageState: Equatable {
    var status: PageStatus = .idle
    var memoryState: TabMemoryState = .discarded
    var canGoBack = false
    var canGoForward = false
    var audible = false
    var favicon: String?
    /// Address input rejected before reaching the engine. It is not a page failure.
    var inputError: String?

    var errorMessage: String? { inputError ?? status.failure }

    mutating func startLoading() {
        status = .loading
        inputError = nil
    }
}

/// The fields above `page` are what the user organizes and what the session persists.
struct Tab: Identifiable, Codable {
    var id: UUID = UUID()
    var url: String = "about:blank"
    var title: String = "Nova aba"
    var createdAt: Date = Date()
    var lastActivatedAt: Date = Date()
    var workspaceId: UUID
    var pinned: Bool = false
    var muted: Bool = false
    var zoomLevel: Double = 0
    var page = PageState()
}

struct HistoryEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var visitedAt: Date = Date()
}

struct Bookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var createdAt: Date = Date()
}

struct ClosedTab: Codable {
    var tab: Tab
    var workspace: Workspace
    var position: Int
    var closedAt: Date = Date()
}

enum DownloadState: String, Codable {
    case inProgress, complete, cancelled, failed
}

struct BrowserDownload: Identifiable, Codable {
    var id: String
    var tabID: UUID
    var url: String
    var filename: String
    var path: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: DownloadState
}

struct Workspace: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "square.stack"
    var tabs: [UUID] = []
    var createdAt: Date = Date()
}

enum ThemeMode: String, Codable, CaseIterable {
    case system, light, dark
}

struct MemoryPolicy: Codable, Equatable {
    var warmTabLimit: Int = 5
    var freezeAfterMinutes: Int = 10
    var discardAfterMinutes: Int = 30
    var keepPinnedTabsAlive: Bool = true
    // Reloading can lose transient page state. Automatic discard requires opt-in.
    var automaticDiscardEnabled: Bool = false

    var validated: MemoryPolicy {
        var result = self
        result.warmTabLimit = max(1, min(100, warmTabLimit))
        result.freezeAfterMinutes = max(1, min(1440, freezeAfterMinutes))
        result.discardAfterMinutes = max(1, min(10080, discardAfterMinutes))
        return result
    }
}

struct BrowserSettings: Codable {
    var theme: ThemeMode = .system
    var sidebarVisible: Bool = true
    var memoryPolicy: MemoryPolicy = MemoryPolicy()
    var searchURL: String = "https://duckduckgo.com/?q={query}"
}

struct EngineCapabilities {
    var supportsFreezing: Bool = false
}

enum BrowserEvent {
    case title(UUID, String)
    case url(UUID, String)
    case loading(UUID, Bool, Bool, Bool)
    case failure(UUID, String)
    case closed(UUID)
    case closeCancelled(UUID)
    case popup(String)
    case favicon(UUID, String)
    case audio(UUID, Bool)
    case download(BrowserDownload)
    case findResult(UUID, Int, Int, Bool)
    case popupCreated(UUID, String)
    case rendererTerminated(UUID, String)
}

protocol BrowserEngine: AnyObject {
    var onEvent: ((BrowserEvent) -> Void)? { get set }
    var capabilities: EngineCapabilities { get }
    func makeView(for tab: Tab) -> NSView
    func activate(tabID: UUID)
    func navigate(tabID: UUID, url: String)
    func goBack(tabID: UUID)
    func goForward(tabID: UUID)
    func reload(tabID: UUID)
    func stop(tabID: UUID)
    func setMuted(tabID: UUID, muted: Bool)
    func close(tabID: UUID)
    func showDevTools(tabID: UUID)
    func find(tabID: UUID, text: String, forward: Bool, findNext: Bool)
    func stopFinding(tabID: UUID)
    func setZoom(tabID: UUID, level: Double)
    func printPage(tabID: UUID)
    func cancelDownload(id: String)
    func shutdown()
}

/// An extension point only. No provider, API key or outbound AI request exists.
protocol AIProvider {
    var identifier: String { get }
    var displayName: String { get }
    func respond(to request: AIRequest, completion: @escaping (Result<String, Error>) -> Void)
}

struct AIRequest {
    var instruction: String
    var userSelectedContext: String
}

// New persisted fields have defaults so profiles from the first milestone remain readable.
// Page fields written by earlier versions are ignored.
extension Tab {
    private enum CodingKeys: String, CodingKey {
        case id, url, title, createdAt, lastActivatedAt, workspaceId, pinned, muted, zoomLevel
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        workspaceId = try values.decode(UUID.self, forKey: .workspaceId)
        url = try values.decode(String.self, forKey: .url)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Nova aba"
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastActivatedAt = try values.decodeIfPresent(Date.self, forKey: .lastActivatedAt) ?? createdAt
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        zoomLevel = try values.decodeIfPresent(Double.self, forKey: .zoomLevel) ?? 0
    }
}

extension MemoryPolicy {
    private enum CodingKeys: String, CodingKey {
        case warmTabLimit, freezeAfterMinutes, discardAfterMinutes, keepPinnedTabsAlive, automaticDiscardEnabled
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        warmTabLimit = try values.decodeIfPresent(Int.self, forKey: .warmTabLimit) ?? 5
        freezeAfterMinutes = try values.decodeIfPresent(Int.self, forKey: .freezeAfterMinutes) ?? 10
        discardAfterMinutes = try values.decodeIfPresent(Int.self, forKey: .discardAfterMinutes) ?? 30
        keepPinnedTabsAlive = try values.decodeIfPresent(Bool.self, forKey: .keepPinnedTabsAlive) ?? true
        automaticDiscardEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticDiscardEnabled) ?? false
    }
}

extension BrowserSettings {
    private enum CodingKeys: String, CodingKey { case theme, sidebarVisible, memoryPolicy, searchURL }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        sidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        memoryPolicy = try values.decodeIfPresent(MemoryPolicy.self, forKey: .memoryPolicy) ?? MemoryPolicy()
        searchURL = try values.decodeIfPresent(String.self, forKey: .searchURL) ?? NavigationController.defaultSearchURL
    }
}
