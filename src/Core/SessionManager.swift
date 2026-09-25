import Foundation
import Darwin

/// The tab list order is the sidebar order.
struct BrowserSession: Codable {
    var version: Int = 3
    var tabs: [Tab]
    var activeTabID: UUID?
    var closedTabs: [ClosedTab] = []

    private enum CodingKeys: String, CodingKey { case version, tabs, activeTabID, closedTabs }
    /// Versions 1 and 2 grouped tabs in workspaces, each with its own tab order.
    private enum LegacyKeys: String, CodingKey { case workspaces }
    private struct LegacyWorkspace: Decodable { var tabs: [UUID]? }
}

extension BrowserSession {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tabs = try values.decode([Tab].self, forKey: .tabs)
        activeTabID = try values.decodeIfPresent(UUID.self, forKey: .activeTabID)
        closedTabs = try values.decodeIfPresent([ClosedTab].self, forKey: .closedTabs) ?? []
        // Tabs from former workspaces join a single list, workspace after workspace.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let workspaces = try legacy.decodeIfPresent([LegacyWorkspace].self, forKey: .workspaces) {
            let order = Dictionary(workspaces.flatMap { $0.tabs ?? [] }.enumerated().map { ($1, $0) }) { first, _ in first }
            tabs = tabs.enumerated()
                .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
                .map(\.element)
        }
    }
}

/// Bookmarks are in sidebar order. Version 1 kept them newest first.
struct BrowserLibrary: Codable {
    var version: Int = 2
    var history: [HistoryEntry] = []
    var bookmarks: [Bookmark] = []
    var folders: [BookmarkFolder] = []
    var downloads: [BrowserDownload] = []
}

extension BrowserLibrary {
    private enum CodingKeys: String, CodingKey { case version, history, bookmarks, folders, downloads }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        history = try values.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        bookmarks = try values.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        if version == 1 { bookmarks.reverse() }
        folders = try values.decodeIfPresent([BookmarkFolder].self, forKey: .folders) ?? []
        downloads = try values.decodeIfPresent([BrowserDownload].self, forKey: .downloads) ?? []
    }
}

enum PersistenceError: LocalizedError {
    case unsupportedVersion(Int)
    case unreadableFile(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "A versão \(version) dos dados não é compatível. O arquivo original foi preservado."
        case .unreadableFile(let filename): return "Não foi possível recuperar \(filename). O arquivo danificado foi preservado."
        }
    }
}

/// Atomic replacement keeps a validated previous copy. Corrupt input is never used as a backup.
final class LocalJSONFile<Value: Codable> {
    let url: URL
    var backupURL: URL { url.deletingPathExtension().appendingPathExtension("backup.json") }
    private(set) var recoveryMessage: String?
    private let validate: (Value) throws -> Void

    init(url: URL, validate: @escaping (Value) throws -> Void = { _ in }) {
        self.url = url
        self.validate = validate
    }

    func read() throws -> Value? {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            do { return try decode(data) }
            catch PersistenceError.unsupportedVersion(let version) { throw PersistenceError.unsupportedVersion(version) }
            catch { try quarantine(url) }
        } else if !manager.fileExists(atPath: backupURL.path) { return nil }

        if manager.fileExists(atPath: backupURL.path) {
            let data = try Data(contentsOf: backupURL)
            let restored: Value
            do {
                restored = try decode(data)
            } catch PersistenceError.unsupportedVersion(let version) { throw PersistenceError.unsupportedVersion(version) }
            catch {
                try quarantine(backupURL)
                throw PersistenceError.unreadableFile(url.lastPathComponent)
            }
            try atomicWrite(data, to: url)
            recoveryMessage = "\(url.lastPathComponent) foi recuperado da cópia anterior."
            return restored
        }
        throw PersistenceError.unreadableFile(url.lastPathComponent)
    }

    func write(_ value: Value, retainPrevious: Bool = true) throws {
        try validate(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            if previous == data {
                if !retainPrevious || !manager.fileExists(atPath: backupURL.path) { try atomicWrite(data, to: backupURL) }
                return
            }
            do {
                _ = try decode(previous)
                if retainPrevious { try atomicWrite(previous, to: backupURL) }
            } catch PersistenceError.unsupportedVersion(let version) { throw PersistenceError.unsupportedVersion(version) }
            catch is DecodingError { try quarantine(url) }
        }
        try atomicWrite(data, to: url)
        // A first successful save also has a recoverable copy. Privacy deletion
        // replaces both copies so an older history cannot reappear on recovery.
        if !retainPrevious || !manager.fileExists(atPath: backupURL.path) { try atomicWrite(data, to: backupURL) }
    }

    private func decode(_ data: Data) throws -> Value {
        let value = try JSONDecoder().decode(Value.self, from: data)
        try validate(value)
        return value
    }

    func removeRecoveryArchives() throws {
        let directory = url.deletingLastPathComponent()
        let prefixes = [url.deletingPathExtension().lastPathComponent + ".corrupt-",
                        backupURL.deletingPathExtension().lastPathComponent + ".corrupt-"]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) && file.pathExtension == "json" {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func quarantine(_ damaged: URL) throws {
        let stamp = String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString.prefix(8)
        let preserved = damaged.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try FileManager.default.moveItem(at: damaged, to: preserved)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        // Ask the OS to flush completed state transitions, including after rename.
        let descriptor = open(destination.path, O_RDONLY)
        if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 { _ = fsync(directoryDescriptor); close(directoryDescriptor) }
    }
}

final class SessionManager {
    let directory: URL
    private let file: LocalJSONFile<BrowserSession>
    var recoveryMessage: String? { file.recoveryMessage }

    init(directory: URL) {
        self.directory = directory
        file = LocalJSONFile(url: directory.appendingPathComponent("session.json")) { session in
            guard (1...3).contains(session.version) else { throw PersistenceError.unsupportedVersion(session.version) }
        }
    }

    func restore() throws -> BrowserSession? { try file.read() }
    func save(_ session: BrowserSession) throws { try file.write(session) }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lume", isDirectory: true)
    }
}

final class SettingsStore {
    private let file: LocalJSONFile<BrowserSettings>
    var recoveryMessage: String? { file.recoveryMessage }
    init(directory: URL) { file = LocalJSONFile(url: directory.appendingPathComponent("settings.json")) }

    func load() throws -> BrowserSettings {
        var settings = try file.read() ?? BrowserSettings()
        settings.memoryPolicy = settings.memoryPolicy.validated
        if !NavigationController().isSafeSearchURL(settings.searchURL) { settings.searchURL = NavigationController.defaultSearchURL }
        // One decision per origin and permission, the latest winning. Unknown or malformed entries are dropped.
        var seen = Set<String>()
        settings.sitePermissions = settings.sitePermissions.reversed().compactMap { saved -> SitePermissionDecision? in
            guard saved.permission.isValid, let origin = NavigationController.origin(of: saved.origin),
                  seen.insert(origin + " " + saved.permission.rawValue).inserted else { return nil }
            var decision = saved
            decision.origin = origin
            return decision
        }.reversed()
        return settings
    }

    func save(_ settings: BrowserSettings) throws { try file.write(settings) }
}

final class LibraryStore {
    private let file: LocalJSONFile<BrowserLibrary>
    var recoveryMessage: String? { file.recoveryMessage }
    init(directory: URL) {
        file = LocalJSONFile(url: directory.appendingPathComponent("library.json")) { library in
            guard (1...2).contains(library.version) else { throw PersistenceError.unsupportedVersion(library.version) }
        }
    }
    func load() throws -> BrowserLibrary { try file.read() ?? BrowserLibrary() }
    func save(_ library: BrowserLibrary, purgePrevious: Bool = false) throws {
        try file.write(library, retainPrevious: !purgePrevious)
        if purgePrevious { try file.removeRecoveryArchives() }
    }
}
