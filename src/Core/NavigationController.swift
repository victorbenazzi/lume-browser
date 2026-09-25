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

        let template = isSafeSearchURL(searchURL) ? searchURL : Self.defaultSearchURL
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NavigationError.invalidURL
        }
        return try validatedWebURL(template.replacingOccurrences(of: "{query}", with: encoded))
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
