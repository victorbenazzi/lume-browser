import AppKit

extension NSPasteboard.PasteboardType {
    /// A favorite dragged in the sidebar or in the library, as "bookmark:<id>" or "folder:<id>".
    static let lumeFavorite = NSPasteboard.PasteboardType("app.lume.browser.favorite")
}

/// A folder or a bookmark, as the sidebar and the library drag it.
enum FavoriteKind: Equatable {
    case bookmark(UUID), folder(UUID)

    var pasteboardValue: String {
        switch self {
        case .bookmark(let id): return "bookmark:" + id.uuidString
        case .folder(let id): return "folder:" + id.uuidString
        }
    }

    init?(pasteboardValue: String) {
        let parts = pasteboardValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "bookmark": self = .bookmark(id)
        case "folder": self = .folder(id)
        default: return nil
        }
    }

    /// The favorite on a drag pasteboard, while it still exists.
    init?(pasteboard: NSPasteboard, in store: BrowserStore) {
        guard let kind = pasteboard.string(forType: .lumeFavorite).flatMap(FavoriteKind.init(pasteboardValue:)) else { return nil }
        switch kind {
        case .bookmark(let id): guard store.bookmarks.contains(where: { $0.id == id }) else { return nil }
        case .folder(let id): guard store.bookmarkFolders.contains(where: { $0.id == id }) else { return nil }
        }
        self = kind
    }

    /// Outside Lume a bookmark is its address, for other apps.
    func pasteboardItem(in store: BrowserStore) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(pasteboardValue, forType: .lumeFavorite)
        if case .bookmark(let id) = self, let url = store.bookmarks.first(where: { $0.id == id })?.url {
            item.setString(url, forType: .URL)
            item.setString(url, forType: .string)
        }
        return item
    }
}

/// Folder dialogs, menus and drops shared by the sidebar favorites and the library.
enum FavoriteActions {
    /// `index` counts the folder's favorites as shown, the dragged one included.
    static func placeBookmark(_ id: UUID, inFolder folder: UUID?, at index: Int, store: BrowserStore) {
        var index = index
        if let current = store.bookmarks(inFolder: folder).firstIndex(where: { $0.id == id }), current < index { index -= 1 }
        store.moveBookmark(id, toFolder: folder, at: index)
    }

    /// `index` counts the folders as shown, the dragged one included.
    static func placeFolder(_ id: UUID, at index: Int, store: BrowserStore) {
        var index = index
        if let current = store.bookmarkFolders.firstIndex(where: { $0.id == id }), current < index { index -= 1 }
        store.moveBookmarkFolder(id, to: index)
    }

    /// "Mover para": the top level, each folder, and a new folder.
    static func moveMenuItem(for bookmark: Bookmark, store: BrowserStore, newFolder: @escaping () -> Void) -> NSMenuItem {
        let move = NSMenuItem(title: "Mover para", action: nil, keyEquivalent: "")
        let destinations = NSMenu()
        let topLevel = menuItem("Barra de favoritos", image: NSImage(systemSymbolName: "star", accessibilityDescription: nil)) {
            store.moveBookmark(bookmark.id, toFolder: nil)
        }
        topLevel.state = bookmark.folderID == nil ? .on : .off
        destinations.addItem(topLevel)
        if !store.bookmarkFolders.isEmpty { destinations.addItem(.separator()) }
        for folder in store.bookmarkFolders {
            let item = menuItem(folder.name, image: NSImage(systemSymbolName: folder.icon, accessibilityDescription: nil)) {
                store.moveBookmark(bookmark.id, toFolder: folder.id)
            }
            item.state = bookmark.folderID == folder.id ? .on : .off
            destinations.addItem(item)
        }
        destinations.addItem(.separator())
        destinations.addItem(menuItem("Nova pasta…", newFolder))
        move.submenu = destinations
        return move
    }

    /// Creates a folder, or edits one, with a name and an icon. A new folder can receive a bookmark right away.
    static func editFolder(_ folder: BookmarkFolder?, store: BrowserStore, in window: NSWindow, moving bookmarkID: UUID? = nil,
                           onCreate: ((UUID) -> Void)? = nil) {
        let editor = FolderEditor(name: folder?.name ?? "", icon: folder?.icon ?? BookmarkFolder.symbols[0])
        let alert = NSAlert()
        alert.messageText = folder == nil ? "Nova pasta" : "Editar pasta"
        alert.informativeText = "Dê um nome e escolha um ícone."
        alert.addButton(withTitle: folder == nil ? "Criar pasta" : "Salvar")
        alert.addButton(withTitle: "Cancelar")
        alert.accessoryView = editor
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = editor.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let folder {
                store.updateBookmarkFolder(folder.id, name: name.isEmpty ? folder.name : name, icon: editor.icon)
            } else if let id = store.newBookmarkFolder(name: name.isEmpty ? "Nova pasta" : name, icon: editor.icon) {
                onCreate?(id)
                if let bookmarkID { store.moveBookmark(bookmarkID, toFolder: id) }
            }
        }
        alert.window.initialFirstResponder = editor.nameField
        alert.window.makeFirstResponder(editor.nameField)
    }
}

/// Name field over a grid of the folder symbols. It sits in a system alert, so it uses system colors.
private final class FolderEditor: NSView {
    let nameField = NSTextField()
    private(set) var icon: String
    private var choices: [(symbol: String, button: QuietButton)] = []
    private static let columns = 8
    private static let cell: CGFloat = 32
    private static let gap: CGFloat = 4

    override var isFlipped: Bool { true }

    init(name: String, icon: String) {
        self.icon = icon
        let lines = (BookmarkFolder.symbols.count + Self.columns - 1) / Self.columns
        let width = CGFloat(Self.columns) * Self.cell + CGFloat(Self.columns - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38 + CGFloat(lines) * (Self.cell + Self.gap) - Self.gap))
        nameField.stringValue = name
        nameField.placeholderString = "Nome da pasta"
        nameField.setAccessibilityLabel("Nome da pasta")
        nameField.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        addSubview(nameField)
        for (index, symbol) in BookmarkFolder.symbols.enumerated() {
            let button = QuietButton(symbol: symbol, title: symbol) { [weak self] in self?.select(symbol) }
            button.toolTip = nil
            button.setAccessibilityLabel("Ícone \(index + 1)")
            button.cornerRadius = 7
            button.hoverColor = .quaternaryLabelColor
            let column = CGFloat(index % Self.columns), line = CGFloat(index / Self.columns)
            button.frame = NSRect(x: column * (Self.cell + Self.gap), y: 38 + line * (Self.cell + Self.gap), width: Self.cell, height: Self.cell)
            addSubview(button)
            choices.append((symbol, button))
        }
        select(icon)
    }

    required init?(coder: NSCoder) { nil }

    private func select(_ symbol: String) {
        icon = symbol
        for choice in choices {
            let chosen = choice.symbol == symbol
            choice.button.restingColor = chosen ? NSColor.controlAccentColor.withAlphaComponent(0.2) : .clear
            choice.button.contentTintColor = chosen ? .controlAccentColor : .secondaryLabelColor
            choice.button.setAccessibilityValue(chosen ? "Selecionado" : "")
        }
    }
}

private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

func menuItem(_ title: String, image: NSImage? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = action
    // The target is weak, so the item keeps its action alive.
    item.representedObject = action
    item.image = image
    return item
}
