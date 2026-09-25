import AppKit

/// The popover for one favorite: its name and where it lives. Changes apply as it closes, unless the favorite was deleted.
final class BookmarkEditorController: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    private let store: BrowserStore
    private let bookmarkID: UUID
    private let isNew: Bool
    private let palette: LumePalette
    private let iconBox = LumeView()
    private let favicon = NSImageView()
    private let heading = lumeLabel("", size: 13, weight: .semibold)
    private let host = lumeLabel("", size: 11)
    private let nameBox = LumeView()
    private let nameField = EditorField()
    private let folderBox = LumeView()
    private let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderChevron = NSImageView()
    private let newFolderField = EditorField()
    private lazy var cancelFolderButton = QuietButton(symbol: "xmark", title: "Cancelar nova pasta") { [weak self] in self?.creatingFolder = false }
    private lazy var deleteButton = NSButton(title: "Apagar", target: self, action: #selector(deleteBookmark))
    private lazy var doneButton = NSButton(title: "Concluído", target: self, action: #selector(done))
    private var destination: UUID?
    private var creatingFolder = false { didSet { showFolderMode() } }
    private var finished = false
    weak var popover: NSPopover?
    var onClose: (() -> Void)?

    private static let width: CGFloat = 300
    private static let height: CGFloat = 182
    private enum Choice: Int { case topLevel = 1, folder, newFolder }

    init(store: BrowserStore, bookmarkID: UUID, isNew: Bool, palette: LumePalette) {
        self.store = store
        self.bookmarkID = bookmarkID
        self.isNew = isNew
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = LumeView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        view = root
        let bookmark = store.bookmarks.first { $0.id == bookmarkID }
        let address = bookmark?.url ?? ""
        let siteName = URL(string: address)?.host ?? address

        iconBox.frame = NSRect(x: 16, y: 16, width: 30, height: 30)
        style(iconBox, focused: false)
        iconBox.layer?.borderWidth = 0
        favicon.frame = NSRect(x: 7, y: 7, width: 16, height: 16)
        if let image = bookmark.flatMap(store.favicon(for:)) { favicon.image = image }
        else {
            favicon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            favicon.contentTintColor = palette.textMuted
        }
        iconBox.addSubview(favicon)

        heading.stringValue = isNew ? "Favorito adicionado" : "Editar favorito"
        heading.textColor = palette.textPrimary
        heading.frame = NSRect(x: 56, y: 14, width: Self.width - 72, height: 18)
        host.stringValue = siteName
        host.toolTip = address
        host.textColor = palette.textMuted
        host.frame = NSRect(x: 56, y: 32, width: Self.width - 72, height: 15)

        nameBox.frame = NSRect(x: 16, y: 60, width: Self.width - 32, height: 30)
        configure(nameField, in: nameBox, placeholder: "Nome", label: "Nome do favorito")
        nameField.stringValue = bookmark.map { $0.title.isEmpty ? siteName : $0.title } ?? ""

        folderBox.frame = NSRect(x: 16, y: 98, width: Self.width - 32, height: 30)
        style(folderBox, focused: false)
        folderChevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        folderChevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        folderChevron.contentTintColor = palette.textMuted
        folderChevron.frame = NSRect(x: folderBox.bounds.width - 24, y: 9, width: 12, height: 12)
        folderBox.addSubview(folderChevron)
        // Borderless over the whole box, so the chevron drawn below it also opens the menu.
        folderPopup.isBordered = false
        folderPopup.font = .systemFont(ofSize: 13)
        (folderPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        folderPopup.frame = NSRect(x: 3, y: 3, width: folderBox.bounds.width - 6, height: 24)
        folderPopup.target = self
        folderPopup.action = #selector(folderChanged)
        folderPopup.setAccessibilityLabel("Pasta do favorito")
        folderBox.addSubview(folderPopup)
        configure(newFolderField, in: folderBox, placeholder: "Nome da nova pasta", label: "Nome da nova pasta")
        newFolderField.frame.size.width -= 26
        cancelFolderButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        cancelFolderButton.contentTintColor = palette.textMuted
        cancelFolderButton.hoverColor = palette.isDark ? .white.withAlphaComponent(0.1) : .black.withAlphaComponent(0.06)
        cancelFolderButton.frame = NSRect(x: folderBox.bounds.width - 28, y: 5, width: 20, height: 20)
        folderBox.addSubview(cancelFolderButton)
        destination = bookmark?.folderID
        buildDestinations()
        showFolderMode()

        for button in [deleteButton, doneButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13)
        }
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: Self.width - 110, y: Self.height - 42, width: 100, height: 32)
        deleteButton.frame = NSRect(x: doneButton.frame.minX - 98, y: Self.height - 42, width: 90, height: 32)
        deleteButton.toolTip = "Remover dos favoritos"

        for subview in [iconBox, heading, host, nameBox, folderBox, deleteButton, doneButton] { root.addSubview(subview) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func configure(_ field: EditorField, in box: LumeView, placeholder: String, label: String) {
        style(box, focused: false)
        field.onFocus = { [weak self, weak box] in if let box { self?.style(box, focused: true) } }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = palette.textPrimary
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(label)
        field.delegate = self
        field.frame = NSRect(x: 8, y: 6, width: box.bounds.width - 16, height: 18)
        box.addSubview(field)
    }

    /// The same field as the address bar: a quiet fill, and the accent outline while typing.
    private func style(_ box: LumeView, focused: Bool) {
        box.cornerRadius = LumeMetrics.fieldRadius
        box.fillColor = palette.isDark ? .white.withAlphaComponent(0.06) : .black.withAlphaComponent(0.035)
        box.wantsLayer = true
        box.layer?.cornerRadius = LumeMetrics.fieldRadius
        box.layer?.borderWidth = focused ? 1.5 : 1
        box.layer?.borderColor = (focused ? palette.accent.withAlphaComponent(0.65) : palette.separator).cgColor
    }

    // MARK: Folder

    private func buildDestinations() {
        folderPopup.removeAllItems()
        guard let menu = folderPopup.menu else { return }
        menu.addItem(choice("Barra de favoritos", symbol: "star", tag: .topLevel, folder: nil))
        if !store.bookmarkFolders.isEmpty { menu.addItem(.separator()) }
        for folder in store.bookmarkFolders { menu.addItem(choice(folder.name, symbol: folder.icon, tag: .folder, folder: folder.id)) }
        menu.addItem(.separator())
        menu.addItem(choice("Nova pasta…", symbol: "folder.badge.plus", tag: .newFolder, folder: nil))
        selectDestination()
    }

    private func choice(_ title: String, symbol: String, tag: Choice, folder: UUID?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag.rawValue
        item.representedObject = folder
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        return item
    }

    private func selectDestination() {
        let item = folderPopup.itemArray.first { item in
            switch Choice(rawValue: item.tag) {
            case .topLevel: return destination == nil
            case .folder: return (item.representedObject as? UUID) == destination
            default: return false
            }
        }
        if let item { folderPopup.select(item) }
    }

    @objc private func folderChanged() {
        guard let item = folderPopup.selectedItem else { return }
        if item.tag == Choice.newFolder.rawValue {
            selectDestination()
            creatingFolder = true
            return
        }
        destination = item.representedObject as? UUID
    }

    private func showFolderMode() {
        folderPopup.isHidden = creatingFolder
        folderChevron.isHidden = creatingFolder
        newFolderField.isHidden = !creatingFolder
        cancelFolderButton.isHidden = !creatingFolder
        if creatingFolder {
            newFolderField.stringValue = ""
            view.window?.makeFirstResponder(newFolderField)
        } else if view.window?.firstResponder === newFolderField.currentEditor() {
            view.window?.makeFirstResponder(nameField)
        }
    }

    // MARK: Actions

    @objc private func done() { popover?.performClose(nil) }

    @objc private func deleteBookmark() {
        finished = true
        store.removeBookmark(bookmarkID)
        popover?.performClose(nil)
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        guard store.bookmarks.contains(where: { $0.id == bookmarkID }) else { return }
        store.renameBookmark(bookmarkID, title: nameField.stringValue)
        if creatingFolder, let folder = store.newBookmarkFolder(name: newFolderField.stringValue, icon: BookmarkFolder.symbols[0]) {
            destination = folder
        }
        store.moveBookmark(bookmarkID, toFolder: destination)
    }

    func popoverWillClose(_ notification: Notification) { commit() }
    func popoverDidClose(_ notification: Notification) { onClose?() }

    // MARK: Text fields

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === nameField { style(nameBox, focused: false) }
        if notification.object as? NSTextField === newFolderField { style(folderBox, focused: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if control === newFolderField { creatingFolder = false }
            else { done() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            done()
            return true
        default:
            return false
        }
    }
}

/// Reports focus as it arrives. Editing notifications only start with the first keystroke.
private final class EditorField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
