import Foundation

/// Suggestions from the default search engine while a search is typed, as Chrome and Safari offer them.
/// Only engines with a known suggestion address are asked, requests carry no cookies and nothing is cached on disk.
/// Callbacks run on the main thread.
final class SearchSuggestions {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A late answer is no longer worth showing.
        configuration.timeoutIntervalForRequest = 1.5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    private var pending: DispatchWorkItem?
    private var lastSent = Date.distantPast
    private var lastWarmUp = Date.distantPast
    /// Answers by request, so going back over the same letters shows them at once.
    private var cache: [URL: [String]] = [:]
    /// Requests are numbered so a slow answer never replaces a newer one.
    private var sent = 0
    private var delivered = 0

    /// Chrome keeps about 100 ms between requests. The first keystroke still goes at once.
    static let interval: TimeInterval = 0.08

    /// The engine's suggestion address for the query, or nil when Lume knows none for the engine.
    /// The Mac's language and region pick suggestions in Portuguese for a Mac set up in Brazil.
    static func endpoint(searchURL: String, query: String, locale: Locale = .current) -> URL? {
        guard let host = URLComponents(string: searchURL.replacingOccurrences(of: "{query}", with: "q"))?.host?.lowercased() else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let language = locale.language.languageCode?.identifier.lowercased().filter(\.isLetter) ?? ""
        let region = locale.region?.identifier.lowercased().filter(\.isLetter) ?? ""
        let address: String
        if matches("duckduckgo.com") {
            // DuckDuckGo names regions first, and the United Kingdom as uk.
            let market = language.isEmpty || region.isEmpty ? "" : "&kl=\(region == "gb" ? "uk" : region)-\(language)"
            address = "https://duckduckgo.com/ac/?q=\(encoded)&type=list" + market
        } else if host.split(separator: ".").contains("google") {
            // Without ie and oe the answer comes in Latin-1 and garbles accents.
            let hl = language.isEmpty ? "en" : region.isEmpty ? language : "\(language)-\(region.uppercased())"
            address = "https://suggestqueries.google.com/complete/search?client=firefox&ie=UTF-8&oe=UTF-8&hl=\(hl)&q=\(encoded)"
        } else if matches("bing.com") {
            address = "https://www.bing.com/osjson.aspx?query=\(encoded)"
        } else if host == "search.brave.com" {
            address = "https://search.brave.com/api/suggest?q=\(encoded)"
        } else if matches("ecosia.org") {
            address = "https://ac.ecosia.org/autocomplete?q=\(encoded)&type=list"
        } else {
            return nil
        }
        return URL(string: address)
    }

    /// OpenSearch suggestions: `["query", ["one", "two"], ...]`.
    static func parse(_ data: Data) -> [String]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 2,
              let items = array[1] as? [String] else { return nil }
        return Array(items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(10))
    }

    func cached(_ query: String, searchURL: String) -> [String]? {
        Self.endpoint(searchURL: searchURL, query: query).flatMap { cache[$0] }
    }

    /// Asks for the query's suggestions, keeping the interval between requests. `completion` receives the query it answers.
    func request(_ query: String, searchURL: String, completion: @escaping (String, [String]) -> Void) {
        pending?.cancel()
        guard let url = Self.endpoint(searchURL: searchURL, query: query) else { return }
        let send = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastSent = Date()
            self.sent += 1
            let number = self.sent
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            self.session.dataTask(with: request) { [weak self] data, response, _ in
                guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let items = Self.parse(data) else { return }
                if self.cache.count > 200 { self.cache.removeAll() }
                self.cache[url] = items
                guard number > self.delivered else { return }
                self.delivered = number
                completion(query, items)
            }.resume()
        }
        pending = send
        let wait = Self.interval - Date().timeIntervalSince(lastSent)
        if wait > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: send) } else { send.perform() }
    }

    /// Drops a request still waiting for its turn, as when the text becomes an address.
    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// Opens the connection as the field gains focus, so the first suggestion does not wait for TLS.
    /// The request is empty: nothing typed leaves the Mac before a keystroke.
    func warmUp(searchURL: String) {
        guard Date().timeIntervalSince(lastWarmUp) > 60, let url = Self.endpoint(searchURL: searchURL, query: "") else { return }
        lastWarmUp = Date()
        session.dataTask(with: url).resume()
    }
}
