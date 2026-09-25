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
    var faviconImage: NSImage?
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
    var title: String = "Nova guia"
    var createdAt: Date = Date()
    var lastActivatedAt: Date = Date()
    var pinned: Bool = false
    var muted: Bool = false
    var zoomLevel: Double = 0
    var page = PageState()
}

/// Lume's own pages. They open in a tab like a site, but AppKit draws them and the engine never loads them.
enum InternalPage: String, CaseIterable {
    case settings = "lume://ajustes"
    case library = "lume://biblioteca"

    init?(url: String) { self.init(rawValue: url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }

    var title: String {
        switch self {
        case .settings: return "Ajustes"
        case .library: return "Biblioteca"
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        case .library: return "books.vertical"
        }
    }
}

extension Tab {
    var internalPage: InternalPage? { InternalPage(url: url) }
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
    /// Nil keeps the bookmark at the top level of the favorites.
    var folderID: UUID?
}

struct BookmarkFolder: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var icon: String = BookmarkFolder.symbols[0]
    var createdAt: Date = Date()

    /// SF Symbols offered for folders. Anything else read from disk falls back to the first.
    static let symbols = ["folder", "star", "heart", "bookmark", "briefcase", "house", "book", "graduationcap",
                          "newspaper", "cart", "creditcard", "chevron.left.forwardslash.chevron.right", "terminal",
                          "paintpalette", "photo", "music.note", "film", "gamecontroller", "airplane", "map",
                          "fork.knife", "leaf", "flame", "bolt", "sparkles", "person.2", "bubble.left", "envelope",
                          "calendar", "chart.bar", "wrench.and.screwdriver", "globe"]
}

enum FavoritesLayout: String, Codable, CaseIterable {
    case list, icons
}

/// How much of the desktop shows through the app chrome. Page content is always opaque.
enum Translucency: String, Codable, CaseIterable {
    case high, medium, off
}

struct ClosedTab: Codable {
    var tab: Tab
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

/// A capability a site asks for. External apps are one permission per URL scheme, such as `external:zoommtg`.
struct SitePermission: RawRepresentable, Codable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let camera = SitePermission(rawValue: "camera")
    static let microphone = SitePermission(rawValue: "microphone")
    static let location = SitePermission(rawValue: "location")
    static let clipboard = SitePermission(rawValue: "clipboard")
    static let multipleDownloads = SitePermission(rawValue: "multipleDownloads")
    static func externalApp(_ scheme: String) -> SitePermission { SitePermission(rawValue: "external:" + scheme.lowercased()) }

    static let known: [SitePermission] = [.camera, .microphone, .location, .clipboard, .multipleDownloads]

    var externalScheme: String? {
        guard rawValue.hasPrefix("external:") else { return nil }
        let scheme = String(rawValue.dropFirst("external:".count))
        return scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) == nil ? nil : scheme
    }

    /// Anything else read from disk is dropped rather than granted under a name nobody recognizes.
    var isValid: Bool { Self.known.contains(self) || externalScheme != nil }

    var title: String {
        switch self {
        case .camera: return "Câmera"
        case .microphone: return "Microfone"
        case .location: return "Localização"
        case .clipboard: return "Área de transferência"
        case .multipleDownloads: return "Vários downloads"
        default: return externalScheme.map { "Abrir links \($0)" } ?? rawValue
        }
    }
}

/// A decision the user asked Lume to remember, for one origin such as `https://meet.example.com`.
struct SitePermissionDecision: Codable, Equatable {
    var origin: String
    var permission: SitePermission
    var allowed: Bool
    var decidedAt: Date = Date()

    /// `origin` must already be normalized, as `NavigationController.origin(of:)` returns it.
    func answers(_ permission: SitePermission, for origin: String) -> Bool {
        self.origin == origin && self.permission == permission
    }
}

struct BrowserSettings: Codable {
    var theme: ThemeMode = .system
    var sidebarVisible: Bool = true
    var translucency: Translucency = .medium
    var favoritesLayout: FavoritesLayout = .icons
    /// The sidebar shows only the favorites heading.
    var favoritesCollapsed: Bool = false
    var memoryPolicy: MemoryPolicy = MemoryPolicy()
    var searchURL: String = "https://duckduckgo.com/?q={query}"
    var sitePermissions: [SitePermissionDecision] = []
    /// The DevTools panel beside the page keeps the width it was last dragged to.
    var devToolsWidth: Double = 440
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
    /// The icon downloaded from a favicon URL, or nil when the download failed.
    case faviconImage(UUID, String, NSImage?)
    case audio(UUID, Bool)
    case download(BrowserDownload)
    case findResult(UUID, Int, Int, Bool)
    case popupCreated(UUID, String)
    case rendererTerminated(UUID, String)
    /// The page entered or left fullscreen, as a video player does.
    case fullscreen(UUID, Bool)
    /// A context menu command that opens a link without leaving the page.
    case openInBackground(UUID, String)
    case searchSelection(UUID, String)
    case permissionDecided(SitePermissionDecision)
    /// The tab's DevTools opened in the panel beside the page, or closed.
    case devTools(UUID, Bool)
}

/// Remembered answers the engine reads before prompting. Nil means ask.
protocol SitePermissionPolicy: AnyObject {
    func permissionDecision(origin: String, permission: SitePermission) -> Bool?
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
    /// Opens the tab's DevTools, or focuses it when already open. It reports `.devTools` once it can be shown.
    func showDevTools(tabID: UUID)
    func closeDevTools(tabID: UUID)
    /// The view the tab's DevTools draws into, for the panel beside the page.
    func devToolsView(tabID: UUID) -> NSView?
    func find(tabID: UUID, text: String, forward: Bool, findNext: Bool)
    func stopFinding(tabID: UUID)
    func setZoom(tabID: UUID, level: Double)
    func printPage(tabID: UUID)
    func cancelDownload(id: String)
    func exitFullscreen(tabID: UUID)
    /// The engine asks before each prompt. It must hold the policy weakly.
    func setPermissionPolicy(_ policy: SitePermissionPolicy)
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
// Page fields and the workspace membership written by earlier versions are ignored.
extension Tab {
    private enum CodingKeys: String, CodingKey {
        case id, url, title, createdAt, lastActivatedAt, pinned, muted, zoomLevel
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(String.self, forKey: .url)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Nova guia"
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
    private enum CodingKeys: String, CodingKey { case theme, sidebarVisible, translucency = "translucencyLevel", favoritesLayout, favoritesCollapsed, memoryPolicy, searchURL, sitePermissions, devToolsWidth }
    private enum LegacyKeys: String, CodingKey { case translucency }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        sidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        // Earlier versions only switched the glass on or off, which the medium level keeps.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .translucency)
        translucency = try values.decodeIfPresent(Translucency.self, forKey: .translucency) ?? legacy.map { $0 ? .medium : .off } ?? .medium
        favoritesLayout = try values.decodeIfPresent(FavoritesLayout.self, forKey: .favoritesLayout) ?? .icons
        favoritesCollapsed = try values.decodeIfPresent(Bool.self, forKey: .favoritesCollapsed) ?? false
        memoryPolicy = try values.decodeIfPresent(MemoryPolicy.self, forKey: .memoryPolicy) ?? MemoryPolicy()
        searchURL = try values.decodeIfPresent(String.self, forKey: .searchURL) ?? NavigationController.defaultSearchURL
        sitePermissions = try values.decodeIfPresent([SitePermissionDecision].self, forKey: .sitePermissions) ?? []
        devToolsWidth = try values.decodeIfPresent(Double.self, forKey: .devToolsWidth) ?? 440
    }
}
