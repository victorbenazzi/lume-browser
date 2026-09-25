import AppKit

/// Site icons of bookmarked hosts, kept on disk so favorites show them before their pages open again.
/// It is a cache: a failed read or write only means the fallback symbol is shown.
final class FaviconStore {
    private let directory: URL
    private var images: [String: NSImage] = [:]
    private var missing = Set<String>()

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("favicons", isDirectory: true)
    }

    func image(for url: String) -> NSImage? {
        guard let key = Self.key(for: url) else { return nil }
        if let image = images[key] { return image }
        if missing.contains(key) { return nil }
        guard let image = NSImage(contentsOf: file(for: key)) else { missing.insert(key); return nil }
        images[key] = image
        return image
    }

    func save(_ image: NSImage, for url: String) {
        guard let key = Self.key(for: url), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        images[key] = image
        missing.remove(key)
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? png.write(to: file(for: key), options: .atomic)) != nil {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: key).path)
        }
    }

    /// Deletes the icons of hosts that are no longer bookmarked.
    func prune(keeping urls: [String]) {
        let kept = Set(urls.compactMap(Self.key(for:)))
        images = images.filter { kept.contains($0.key) }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && !kept.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// One icon per host. The key is also the file name, so only safe characters remain.
    static func key(for url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    private func file(for key: String) -> URL { directory.appendingPathComponent(key + ".png") }
}
