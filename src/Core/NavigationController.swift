import Foundation

enum NavigationError: LocalizedError {
    case disallowedScheme(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .disallowedScheme(let scheme): return "O protocolo \(scheme) não é permitido."
        case .invalidURL: return "Digite um endereço válido ou uma busca."
        }
    }
}

struct NavigationController {
    static let defaultSearchURL = "https://duckduckgo.com/?q={query}"

    func normalize(_ input: String, searchURL: String = defaultSearchURL) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "about:blank" { return "about:blank" }

        if let scheme = explicitScheme(value), !isHostWithPort(value) {
            guard scheme == "http" || scheme == "https" else {
                throw NavigationError.disallowedScheme(scheme)
            }
            return try validatedWebURL(value)
        }

        if !value.contains(where: { $0.isWhitespace }) && looksLikeHost(value) {
            let host = value.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? value
            let isLocal = host == "localhost" || host.hasPrefix("localhost:") ||
                host.hasPrefix("127.") || host.hasPrefix("[::1]") || host.hasSuffix(".localhost")
            return try validatedWebURL((isLocal ? "http://" : "https://") + value)
        }

        return try search(value, searchURL: searchURL)
    }

    /// Always a search, even for text that looks like an address, as when searching a selection.
    func search(_ text: String, searchURL: String = defaultSearchURL) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw NavigationError.invalidURL }
        let template = isSafeSearchURL(searchURL) ? searchURL : Self.defaultSearchURL
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NavigationError.invalidURL
        }
        return try validatedWebURL(template.replacingOccurrences(of: "{query}", with: encoded))
    }

    /// `scheme://host[:port]` for an HTTP or HTTPS address, with the default port left out. Nil for anything else.
    static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// A `blob:` address minted by an HTTP or HTTPS page, as pages use for files they generate.
    static func isWebBlob(_ url: String) -> Bool {
        guard url.lowercased().hasPrefix("blob:") else { return false }
        return origin(of: String(url.dropFirst(5))) != nil
    }

    func isSafeSearchURL(_ template: String) -> Bool {
        let marker = "LUME_SEARCH_QUERY_MARKER"
        guard template.components(separatedBy: "{query}").count == 2,
              let components = URLComponents(string: template.replacingOccurrences(of: "{query}", with: marker)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !host.contains(marker), !components.path.contains(marker),
              components.fragment?.contains(marker) != true,
              components.queryItems?.contains(where: { $0.value?.contains(marker) == true }) == true
        else { return false }
        return true
    }

    private func validatedWebURL(_ value: String) throws -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              components.user == nil, components.password == nil,
              let result = components.url?.absoluteString else { throw NavigationError.invalidURL }
        return result
    }

    private func explicitScheme(_ input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let prefix = String(input[..<colon])
        guard prefix.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil else { return nil }
        return prefix.lowercased()
    }

    private func isHostWithPort(_ value: String) -> Bool {
        value.range(of: "^(localhost|[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+):[0-9]+(?:[/?#]|$)", options: .regularExpression) != nil
    }

    private func looksLikeHost(_ value: String) -> Bool {
        let authority = value.components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? value
        return authority == "localhost" || authority.hasPrefix("localhost:") ||
            authority.contains(".") || authority.hasPrefix("[")
    }
}
