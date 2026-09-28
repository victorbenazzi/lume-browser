import Foundation

/// What a row of the address bar's list opens.
enum AutocompleteDestination: Equatable {
    /// The text as typed, resolved as Enter always did: an address, a Lume page or a search.
    case input(String)
    /// An address from history, favorites or an open guia.
    case url(String)
    /// A search for the text, even when it looks like an address.
    case search(String)
    /// An open guia, shown instead of loading its page again.
    case tab(UUID)
    case internalPage(InternalPage)
}

struct AutocompleteMatch: Equatable {
    enum Kind: Equatable {
        /// What was typed, read as an address.
        case typedAddress
        /// What was typed, read as a search, or offered as one below an address.
        case typedSearch
        case history
        case bookmark
        /// An open guia whose page is not in history.
        case tab
        /// A search made before, read back from history.
        case pastSearch
        /// A suggestion from the search engine.
        case suggestion
        case internalPage
    }

    var kind: Kind
    var destination: AutocompleteDestination
    /// The page title, or the text of a search.
    var title: String
    /// The address as shown, without scheme or www, or the engine a typed search goes to.
    var detail: String = ""
    /// What the field shows while the row is selected.
    var fillText: String
    /// The page's address, for its icon.
    var url: String?
    /// An open guia already showing the page.
    var tabID: UUID?
    var relevance: Double = 0

    var isSearch: Bool { kind == .typedSearch || kind == .pastSearch || kind == .suggestion }
    /// Visits of the page can be removed from history, as Chrome's Shift+Delete does.
    var isRemovable: Bool { kind == .history && tabID == nil }
}

struct AutocompleteResult {
    var matches: [AutocompleteMatch] = []
    /// Appended to the typed text and selected, so the next keystroke replaces it. Empty when nothing completes.
    var inlineCompletion = ""
    /// Whether the search engine's suggestions have a place in the list.
    var wantsSuggestions = false
}

/// Folding and byte search shared by the index. Text is compared as lowercase UTF-8 without accents,
/// so a keystroke only runs `memmem` over bytes prepared when history changed.
enum AutocompleteText {
    static func fold(_ text: String) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.utf8.count)
        // Addresses are almost always ASCII, which skips Foundation.
        for byte in text.utf8 {
            guard byte < 0x80 else {
                return Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
            }
            bytes.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }
        return bytes
    }

    /// `https://www.github.com/anthropics/` reads `github.com/anthropics`.
    static func displayURL(_ url: String) -> String {
        var text = Substring(url)
        if text.hasPrefix("https://") { text = text.dropFirst(8) } else if text.hasPrefix("http://") { text = text.dropFirst(7) }
        if text.hasPrefix("www.") { text = text.dropFirst(4) }
        if text.hasSuffix("/") { text = text.dropLast() }
        return String(text)
    }

    /// Typed text as it would start a displayed address: without a web scheme or www.
    static func addressPrefix(_ text: String) -> Substring {
        var value = Substring(text)
        for prefix in ["https://", "http://", "www."] where value.lowercased().hasPrefix(prefix) { value = value.dropFirst(prefix.count) }
        return value
    }

    static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, start >= 0, haystack.count - start >= needle.count else { return nil }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { wanted in
                guard let base = hay.baseAddress, let found = memmem(base + start, hay.count - start, wanted.baseAddress, wanted.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
        }
    }

    /// Anything but an ASCII letter or digit starts a new word. Bytes of other scripts count as letters.
    static func isBoundary(_ byte: UInt8) -> Bool {
        byte < 0x80 && !(97...122).contains(byte) && !(65...90).contains(byte) && !(48...57).contains(byte)
    }
}

/// The search engine's results address, so searches made before read back as searches instead of pages.
struct SearchTemplate {
    let host: String
    let path: String
    let parameter: String
    private let prefixes: [[UInt8]]

    init?(_ searchURL: String) {
        let marker = "LUMEQUERY"
        guard let components = URLComponents(string: searchURL.replacingOccurrences(of: "{query}", with: marker)),
              let host = components.host?.lowercased(), !host.isEmpty,
              let item = components.queryItems?.first(where: { $0.value == marker }) else { return nil }
        self.host = host
        path = components.path.isEmpty ? "/" : components.path
        parameter = item.name
        prefixes = [Array(("https://" + host).utf8), Array(("http://" + host).utf8)]
    }

    /// The text searched on a results page of this engine, or nil for any other address.
    func query(in url: String) -> String? {
        // Most history is other sites. A prefix test spares parsing them.
        guard prefixes.contains(where: { url.utf8.starts(with: $0) }),
              let components = URLComponents(string: url), components.host?.lowercased() == host,
              (components.path.isEmpty ? "/" : components.path) == path,
              let raw = components.percentEncodedQueryItems?.first(where: { $0.name == parameter })?.value,
              let text = raw.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The engine's name, as the typed search row says where it goes.
    var name: String {
        let known = ["duckduckgo": "DuckDuckGo", "google": "Google", "bing": "Bing", "brave": "Brave",
                     "ecosia": "Ecosia", "startpage": "Startpage", "kagi": "Kagi", "yahoo": "Yahoo"]
        let labels = host.split(separator: ".").map(String.init)
        if let name = labels.lazy.compactMap({ known[$0] }).first { return name }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// History read once per change into one entry per address, with visits weighed by how recent and how deliberate
/// they were. Each keystroke then only compares prepared bytes, which keeps typing instant with thousands of visits.
final class AutocompleteIndex {
    struct Page {
        let url: String
        var title: String
        /// The address as shown, folded, and the length of its host in bytes.
        let key: [UInt8]
        let hostLength: Int
        var titleKey: [UInt8] = []
        var visits = 0
        var typed = 0
        var frecency = 0.0
        var bookmarked = false
        /// Completing inside the field needs a sign the address is wanted: typed before, visited again or saved.
        var canInline: Bool { typed > 0 || visits > 1 || bookmarked }
    }

    struct Host {
        let key: [UInt8]
        /// The page that stands for the host: its root when visited, else the most frequent page.
        var page: Int
        var hasRoot = false
        var frecency = 0.0
        var visits = 0
        var canInline = false
    }

    struct PastSearch {
        let text: String
        let key: [UInt8]
        var frecency = 0.0
    }

    private(set) var pages: [Page] = []
    private(set) var hosts: [Host] = []
    private(set) var searches: [PastSearch] = []
    private(set) var builtAt = Date.distantPast
    private var pageByURL: [String: Int] = [:]
    private var template: SearchTemplate?

    static let maxMatches = 8

    // MARK: Building

    /// `history` is newest first, as the store keeps it.
    func rebuild(history: [HistoryEntry], bookmarks: [Bookmark], searchURL: String, now: Date = Date()) {
        // Pages of the previous build keep their folded text, so a rebuild after a visit only folds what is new.
        let previous = pages
        let previousByURL = pageByURL
        func newPage(_ url: String, title: String) -> Page {
            if let old = previousByURL[url].map({ previous[$0] }) {
                return Page(url: url, title: title, key: old.key, hostLength: old.hostLength, titleKey: old.title == title ? old.titleKey : [])
            }
            let key = AutocompleteText.fold(AutocompleteText.displayURL(url))
            return Page(url: url, title: title, key: key, hostLength: key.firstIndex { $0 == 47 || $0 == 63 || $0 == 35 } ?? key.count)
        }
        template = SearchTemplate(searchURL)
        var pages: [Page] = []
        var byURL: [String: Int] = [:]
        // Firefox's frecency: the ten latest visits sampled, each worth more when recent and twice as much when typed.
        var points: [Double] = []
        var samples: [Int] = []
        var searchByKey: [[UInt8]: Int] = [:]
        var searches: [PastSearch] = []
        var searchSamples: [Int] = []
        for entry in history {
            let weight = Self.weight(age: now.timeIntervalSince(entry.visitedAt)) * (entry.typed == true ? 2 : 1)
            if let text = template?.query(in: entry.url) {
                let key = AutocompleteText.fold(text)
                let index = searchByKey[key] ?? {
                    searches.append(PastSearch(text: text, key: key))
                    searchSamples.append(0)
                    searchByKey[key] = searches.count - 1
                    return searches.count - 1
                }()
                if searchSamples[index] < 10 { searches[index].frecency += weight; searchSamples[index] += 1 }
                continue
            }
            let index: Int
            if let known = byURL[entry.url] {
                index = known
            } else {
                pages.append(newPage(entry.url, title: entry.title))
                points.append(0)
                samples.append(0)
                index = pages.count - 1
                byURL[entry.url] = index
            }
            if pages[index].title.isEmpty && !entry.title.isEmpty {
                pages[index].title = entry.title
                pages[index].titleKey = []
            }
            pages[index].visits += 1
            if entry.typed == true { pages[index].typed += 1 }
            if samples[index] < 10 { points[index] += weight; samples[index] += 1 }
        }
        for index in pages.indices {
            pages[index].frecency = Double(pages[index].visits) * points[index] / Double(max(1, samples[index]))
        }
        // A favorite is worth a recent visit even when never opened, and more once visited.
        for bookmark in bookmarks {
            let index = byURL[bookmark.url] ?? {
                pages.append(newPage(bookmark.url, title: bookmark.title))
                byURL[bookmark.url] = pages.count - 1
                return pages.count - 1
            }()
            pages[index].bookmarked = true
            pages[index].frecency = max(100, pages[index].frecency) * 1.4
            // The favorite's own name shows, and the page's title still finds it.
            let pageTitle = pages[index].title
            guard !bookmark.title.isEmpty, pageTitle != bookmark.title else { continue }
            pages[index].title = bookmark.title
            pages[index].titleKey = AutocompleteText.fold(pageTitle.isEmpty ? bookmark.title : bookmark.title + " " + pageTitle)
        }
        for index in pages.indices where pages[index].titleKey.isEmpty { pages[index].titleKey = AutocompleteText.fold(pages[index].title) }

        var hosts: [Host] = []
        var hostByKey: [ArraySlice<UInt8>: Int] = [:]
        for (index, page) in pages.enumerated() {
            let key = page.key[..<page.hostLength]
            let isRoot = page.hostLength == page.key.count
            if let known = hostByKey[key] {
                hosts[known].frecency += page.frecency
                hosts[known].visits += page.visits
                hosts[known].canInline = hosts[known].canInline || page.canInline
                if isRoot || (!hosts[known].hasRoot && page.frecency > pages[hosts[known].page].frecency) { hosts[known].page = index }
                hosts[known].hasRoot = hosts[known].hasRoot || isRoot
            } else {
                hostByKey[key] = hosts.count
                hosts.append(Host(key: Array(key), page: index, hasRoot: isRoot, frecency: page.frecency, visits: page.visits, canInline: page.canInline))
            }
        }
        // Two visits across a host's pages are enough to complete its name.
        for index in hosts.indices where hosts[index].visits > 1 { hosts[index].canInline = true }

        self.pages = pages
        self.hosts = hosts
        self.searches = searches
        pageByURL = byURL
        builtAt = now
    }

    /// Points for one visit by age, as in Firefox: the last four days count most.
    static func weight(age: TimeInterval) -> Double {
        let days = age / 86_400
        switch days {
        case ..<4: return 100
        case ..<14: return 70
        case ..<31: return 50
        case ..<90: return 30
        default: return 10
        }
    }

    // MARK: Matching

    /// How well one typed word matches a page, from 0 (it does not) to 1 (the address starts with it).
    /// As in Chrome, words match where a word starts, and the host counts more than the path, the path more than the query.
    /// Only the host also matches inside a word, as "tube" finds youtube.com. A single letter only matches a host's start,
    /// so "v" does not bring every page with a `?v=` or a title word in v.
    static func score(_ term: [UInt8], key: [UInt8], hostLength: Int, title: [UInt8]) -> Double {
        var best = 0.0
        let query = key[hostLength...].firstIndex { $0 == 63 || $0 == 35 } ?? key.count
        var position = AutocompleteText.firstIndex(of: term, in: key)
        while let found = position, best < 0.85 {
            if found == 0 { return 1 }
            let previous = key[found - 1]
            if found < hostLength {
                if previous == 46 { best = max(best, 0.85) } // after a dot: mail.google.com
                else if term.count >= 3 { best = max(best, 0.3) }
            } else if term.count >= 2 && AutocompleteText.isBoundary(previous) {
                if found < query { best = max(best, 0.55); break }
                if term.count >= 3 { best = max(best, 0.35) }
            }
            position = AutocompleteText.firstIndex(of: term, in: key, from: found + 1)
        }
        guard best < 0.75, term.count >= 2 else { return best }
        position = AutocompleteText.firstIndex(of: term, in: title)
        while let found = position {
            if found == 0 || AutocompleteText.isBoundary(title[found - 1]) { return 0.75 }
            position = AutocompleteText.firstIndex(of: term, in: title, from: found + 1)
        }
        return best
    }

    /// Words of Lume's own pages, so "histórico" or "ajustes" finds them.
    private static let internalWords: [InternalPage: String] = [
        .settings: "ajustes configuracoes preferencias settings",
        .library: "biblioteca historico favoritos downloads library"
    ]

    /// Rows for the text, best first, capped at eight. Remote suggestions are placed last, so they never move rows already read.
    /// `expectsSuggestions` keeps room for the search engine's suggestions below the pages.
    func complete(_ text: String, allowInline: Bool, openTabs: [Tab], suggestions: [String] = [], expectsSuggestions: Bool = false,
                  navigation: NavigationController = NavigationController()) -> AutocompleteResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AutocompleteResult() }
        let isAddress = navigation.isAddress(trimmed)
        let singleWord = !trimmed.contains(where: \.isWhitespace)
        var seenTerms = Set<[UInt8]>()
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map { AutocompleteText.fold(String($0)) }.filter { !$0.isEmpty && seenTerms.insert($0).inserted }
        let prefix = AutocompleteText.fold(String(AutocompleteText.addressPrefix(trimmed)))
        let wholeKey = AutocompleteText.fold(trimmed)

        func relevance(_ quality: Double, _ frecency: Double, _ length: Int) -> Double {
            quality * log2(2 + frecency) - Double(length) * 0.0005
        }
        func quality(key: [UInt8], hostLength: Int, title: [UInt8]) -> Double? {
            if singleWord, !prefix.isEmpty, key.starts(with: prefix) { return 1.2 }
            var total = 0.0
            for term in terms {
                let score = Self.score(term, key: key, hostLength: hostLength, title: title)
                guard score > 0 else { return nil }
                total += score
            }
            return total / Double(terms.count)
        }

        // Pages from history and favorites.
        var scored: [(page: Int, relevance: Double)] = []
        for (index, page) in pages.enumerated() {
            guard let quality = quality(key: page.key, hostLength: page.hostLength, title: page.titleKey) else { continue }
            scored.append((index, relevance(quality, page.frecency, page.key.count)))
        }
        scored.sort { $0.relevance > $1.relevance }

        // Open guias: they switch instead of loading the page twice.
        var tabForURL: [String: UUID] = [:]
        var tabMatches: [AutocompleteMatch] = []
        for tab in openTabs where tab.url != "about:blank" && tab.internalPage == nil {
            if pageByURL[tab.url] != nil { tabForURL[tab.url] = tabForURL[tab.url] ?? tab.id; continue }
            let display = AutocompleteText.displayURL(tab.url)
            let key = AutocompleteText.fold(display)
            let hostLength = key.firstIndex { $0 == 47 || $0 == 63 || $0 == 35 } ?? key.count
            guard let quality = quality(key: key, hostLength: hostLength, title: AutocompleteText.fold(tab.title)) else { continue }
            tabMatches.append(AutocompleteMatch(kind: .tab, destination: .tab(tab.id), title: tab.title.isEmpty ? display : tab.title,
                                                detail: display, fillText: display, url: tab.url, tabID: tab.id,
                                                relevance: relevance(quality, 150, key.count)))
        }

        // The default row: the address being completed inside the field, or what was typed.
        var result = AutocompleteResult()
        var inline: AutocompleteMatch?
        let asciiTail = trimmed == text && trimmed.utf8.allSatisfy { $0 < 0x80 }
        if allowInline && singleWord && asciiTail && !prefix.isEmpty {
            if !prefix.contains(47), let host = hosts.filter({ $0.canInline && $0.key.starts(with: prefix) }).max(by: { $0.frecency < $1.frecency }) {
                let page = pages[host.page]
                let name = String(decoding: host.key, as: UTF8.self)
                let url = host.hasRoot ? page.url : (NavigationController.origin(of: page.url).map { $0 + "/" } ?? page.url)
                inline = AutocompleteMatch(kind: page.bookmarked && host.hasRoot ? .bookmark : .history, destination: .url(url),
                                           title: host.hasRoot && !page.title.isEmpty ? page.title : name, detail: name, fillText: name, url: url)
                result.inlineCompletion = String(decoding: host.key[prefix.count...], as: UTF8.self)
            } else if let index = scored.lazy.map(\.page).first(where: { self.pages[$0].canInline && self.pages[$0].key.starts(with: prefix) }) {
                let page = pages[index]
                let display = AutocompleteText.displayURL(page.url)
                inline = AutocompleteMatch(kind: page.bookmarked ? .bookmark : .history, destination: .url(page.url),
                                           title: page.title.isEmpty ? display : page.title, detail: display, fillText: display, url: page.url)
                result.inlineCompletion = String(decoding: page.key[prefix.count...], as: UTF8.self)
            }
        }
        let engine = template?.name ?? "buscador"
        if let inline {
            result.matches.append(inline)
        } else if let page = InternalPage(url: trimmed) {
            result.matches.append(AutocompleteMatch(kind: .internalPage, destination: .internalPage(page), title: page.title,
                                                    detail: page.rawValue, fillText: page.rawValue))
        } else if isAddress {
            let url = try? navigation.normalize(trimmed)
            let display = url.map(AutocompleteText.displayURL) ?? trimmed
            result.matches.append(AutocompleteMatch(kind: .typedAddress, destination: .input(trimmed), title: display, fillText: trimmed, url: url))
        } else {
            result.matches.append(AutocompleteMatch(kind: .typedSearch, destination: .input(trimmed), title: trimmed,
                                                    detail: "Pesquisar no \(engine)", fillText: trimmed))
        }
        // An address can still be meant as a search, as Chrome offers right below it.
        if result.matches[0].kind != .typedSearch && !trimmed.contains("://") {
            result.matches.append(AutocompleteMatch(kind: .typedSearch, destination: .search(trimmed), title: trimmed,
                                                    detail: "Pesquisar no \(engine)", fillText: trimmed))
        }

        // History, favorites, open guias and Lume's pages, by relevance.
        var candidates: [AutocompleteMatch] = []
        for (index, relevance) in scored.prefix(Self.maxMatches * 2) {
            let page = pages[index]
            let display = AutocompleteText.displayURL(page.url)
            let tabID = tabForURL[page.url]
            candidates.append(AutocompleteMatch(kind: page.bookmarked ? .bookmark : .history, destination: tabID.map { .tab($0) } ?? .url(page.url),
                                                title: page.title.isEmpty ? display : page.title, detail: display, fillText: display,
                                                url: page.url, tabID: tabID, relevance: relevance))
        }
        candidates += tabMatches
        if terms.allSatisfy({ $0.count >= 3 }) || trimmed.lowercased().hasPrefix("lume:") {
            for page in InternalPage.allCases {
                let key = AutocompleteText.fold(page.rawValue)
                let words = AutocompleteText.fold(page.title + " " + (Self.internalWords[page] ?? ""))
                let matched = key.starts(with: wholeKey) ? 1 : quality(key: key, hostLength: key.count, title: words)
                guard let matched else { continue }
                let tab = openTabs.first { $0.internalPage == page }
                candidates.append(AutocompleteMatch(kind: .internalPage, destination: tab.map { .tab($0.id) } ?? .internalPage(page),
                                                    title: page.title, detail: page.rawValue, fillText: page.rawValue,
                                                    tabID: tab?.id, relevance: relevance(matched, 20, key.count)))
            }
        }
        candidates.sort { $0.relevance > $1.relevance }

        // One row per page as the reader sees it: http and https, www, a trailing slash or a fragment do not make another page.
        func sameness(_ url: String) -> String {
            let display = AutocompleteText.displayURL(url)
            return display.firstIndex(of: "#").map { String(display[..<$0]) } ?? display
        }
        var shown = Set(result.matches.compactMap { $0.url.map(sameness) ?? ($0.kind == .internalPage ? $0.detail : nil) })
        let pageLimit = !isAddress && expectsSuggestions ? 4 : Self.maxMatches - result.matches.count
        var pageRows: [AutocompleteMatch] = []
        for match in candidates where pageRows.count < pageLimit {
            if let url = match.url, !shown.insert(sameness(url)).inserted { continue }
            if match.kind == .internalPage, !shown.insert(match.detail).inserted { continue }
            pageRows.append(match)
        }
        result.matches += pageRows

        // Searches: made before first, then the engine's suggestions, which arrive while typing.
        guard !isAddress else { return result }
        result.wantsSuggestions = true
        var searchedKeys: Set<[UInt8]> = [wholeKey]
        var pastRows: [AutocompleteMatch] = []
        let past = searches.compactMap { search -> (PastSearch, Double)? in
            guard search.key != wholeKey else { return nil }
            if search.key.starts(with: wholeKey) { return (search, relevance(1, search.frecency, 0)) }
            guard let quality = quality(key: [], hostLength: 0, title: search.key) else { return nil }
            return (search, relevance(quality, search.frecency, 0))
        }.sorted { $0.1 > $1.1 }
        for (search, _) in past.prefix(2) {
            searchedKeys.insert(search.key)
            pastRows.append(AutocompleteMatch(kind: .pastSearch, destination: .search(search.text), title: search.text, fillText: search.text))
        }
        result.matches += pastRows
        for suggestion in suggestions where result.matches.count < Self.maxMatches {
            let key = AutocompleteText.fold(suggestion)
            // Engines sometimes answer with addresses. Those belong to the rows above.
            guard !key.isEmpty, AutocompleteText.firstIndex(of: Array("://".utf8), in: key) == nil,
                  searchedKeys.insert(key).inserted else { continue }
            result.matches.append(AutocompleteMatch(kind: .suggestion, destination: .search(suggestion), title: suggestion, fillText: suggestion))
        }
        return result
    }
}
