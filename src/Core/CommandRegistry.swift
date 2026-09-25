import Foundation

struct Command: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let keywords: [String]
    let shortcut: String?
    let execute: () -> Void

    init(id: String, title: String, subtitle: String = "", keywords: [String] = [],
         shortcut: String? = nil, execute: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.shortcut = shortcut
        self.execute = execute
    }
}

final class CommandRegistry {
    private var entries: [Command] = []

    func register(_ command: Command) {
        entries.removeAll { $0.id == command.id }
        entries.append(command)
    }

    func unregister(id: String) { entries.removeAll { $0.id == id } }

    func matching(_ query: String) -> [Command] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
        return entries.filter { command in
            let text = ([command.title, command.subtitle] + command.keywords).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy { text.contains($0) }
        }
    }
}
