import AppKit

/// History, favorites and downloads, drawn on the page card of their own tab. Favorites are arranged here too:
/// folders with their bookmarks in sidebar order, reordered and moved by dragging.
final class LibraryPage: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Section: Int { case history, bookmarks, downloads }

    private struct Item {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let progress: Double?
        let indeterminate: Bool
        let primaryLabel: String?
        let primarySymbol: String?
        let primaryAction: (() -> Void)?
        let secondaryLabel: String?
        let secondarySymbol: String?
        let secondaryAction: (() -> Void)?
        var indent: CGFloat = 0
        /// Shown instead of the symbol, as is.
        var image: NSImage?
        var favorite: FavoriteKind?
        /// The folder holding a bookmark, as in the sidebar.
        var folderID: UUID?
        /// Index among the folders, or among the bookmarks sharing the folder.
        var position = 0

        var structure: ItemStructure {
            ItemStructure(id: id, symbol: symbol, indent: indent, hasProgress: progress != nil || indeterminate,
                          primaryLabel: primaryLabel, primarySymbol: primarySymbol,
                          secondaryLabel: secondaryLabel, secondarySymbol: secondarySymbol)
        }
    }

    private struct ItemStructure: Equatable {
        let id: String
        let symbol: String
        let indent: CGFloat
        let hasProgress: Bool
        let primaryLabel: String?
        let primarySymbol: String?
        let secondaryLabel: String?
        let secondarySymbol: String?
    }

    private final class ItemRow: LumeView {
        private let icon = NSImageView()
        private let titleLabel = lumeLabel("", size: 13, weight: .medium)
        private let subtitleLabel = lumeLabel("", size: 11)
        private var primaryButton: QuietButton?
        private var secondaryButton: QuietButton?
        private var progressIndicator: NSProgressIndicator?
        private let indent: CGFloat
        private var buttons: [QuietButton] { [primaryButton, secondaryButton].compactMap { $0 } }

        init(item: Item, palette: LumePalette, selected: Bool) {
            indent = item.indent
            super.init(frame: .zero)
            cornerRadius = 6
            addSubview(icon)
            addSubview(titleLabel)
            addSubview(subtitleLabel)
            if let symbol = item.primarySymbol, let label = item.primaryLabel, let action = item.primaryAction {
                let button = QuietButton(symbol: symbol, title: label, action: action)
                primaryButton = button
                addSubview(button)
            }
            if let symbol = item.secondarySymbol, let label = item.secondaryLabel, let action = item.secondaryAction {
                let button = QuietButton(symbol: symbol, title: label, action: action)
                secondaryButton = button
                addSubview(button)
            }
            if item.structure.hasProgress {
                let indicator = NSProgressIndicator()
                indicator.style = .bar
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = 1
                indicator.controlSize = .small
                progressIndicator = indicator
                addSubview(indicator)
            }
            update(item: item, palette: palette, selected: selected)
        }

        required init?(coder: NSCoder) { nil }

        func update(item: Item, palette: LumePalette, selected: Bool) {
            fillColor = selected ? palette.selection : .clear
            if titleLabel.stringValue != item.title {
                titleLabel.stringValue = item.title
                titleLabel.toolTip = item.title
            }
            if subtitleLabel.stringValue != item.subtitle {
                subtitleLabel.stringValue = item.subtitle
                subtitleLabel.toolTip = item.subtitle
            }
            titleLabel.textColor = palette.textPrimary
            subtitleLabel.textColor = palette.textSecondary
            icon.image = item.image ?? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            icon.contentTintColor = item.image == nil ? palette.textMuted : nil
            primaryButton?.actionHandler = item.primaryAction
            secondaryButton?.actionHandler = item.secondaryAction
            for button in buttons {
                button.contentTintColor = palette.textSecondary
                button.hoverColor = palette.isTranslucent ? palette.separator : palette.elevated
            }
            if let indicator = progressIndicator {
                if indicator.isIndeterminate != item.indeterminate {
                    indicator.isIndeterminate = item.indeterminate
                    if item.indeterminate { indicator.startAnimation(nil) }
                    else { indicator.stopAnimation(nil) }
                }
                indicator.doubleValue = item.progress ?? 0
            }
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 12 + indent, y: 17, width: 17, height: 17)
            let leading = 42 + indent
            let trailing = CGFloat(max(1, buttons.count)) * 32 + 16
            titleLabel.frame = NSRect(x: leading, y: 11, width: max(0, bounds.width - leading - trailing), height: 20)
            subtitleLabel.frame = NSRect(x: leading, y: 34, width: max(0, bounds.width - leading - trailing), height: 17)
            progressIndicator?.frame = NSRect(x: leading, y: 59, width: max(0, bounds.width - leading - trailing), height: 4)
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(x: bounds.width - 42 - CGFloat(index) * 32, y: 16, width: 28, height: 28)
            }
        }
    }

    let view = LumeView()
    private let store: BrowserStore
    /// A column of limited width, centered on wide pages.
    private let content = LumeView()
    private let heading = lumeLabel("Biblioteca", size: 24, weight: .medium)
    private let sections = NSSegmentedControl(labels: ["Histórico", "Favoritos", "Downloads"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let summary = lumeLabel("", size: 11)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let clearButton = NSButton(title: "Limpar histórico…", target: nil, action: nil)
    private let newFolderButton = NSButton(title: "Nova pasta…", target: nil, action: nil)
    private let contextMenu = NSMenu()
    private let emptyTitle = lumeLabel("", size: 18, weight: .medium)
    private let emptyDescription = NSTextField(wrappingLabelWithString: "")
    private let footer = lumeLabel("", size: 11)
    private var section: Section = .history
    private var items: [Item] = []
    private var renderedSection: Section?
    private var palette = LumePalette.light
    private var lastDarkAppearance: Bool?
    var onOpenURL: ((String) -> Void)?
    /// Asks the owner for the favorite editor, pointing at a rectangle of a view.
    var onEditBookmark: ((UUID, NSRect, NSView) -> Void)?
    /// Favorites are dragged while they show in sidebar order, not while a search filters them.
    private var arranging: Bool {
        section == .bookmarks && search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let columnWidth: CGFloat = 760
    private static let topInset: CGFloat = 24

    init(store: BrowserStore) {
        self.store = store
        super.init()
        view.addSubview(content)
        let views: [NSView] = [heading, sections, search, summary, scroll, clearButton, newFolderButton, emptyTitle, emptyDescription, footer]
        views.forEach { content.addSubview($0) }
        sections.target = self
        sections.action = #selector(changeSection)
        sections.selectedSegment = 0
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        newFolderButton.bezelStyle = .rounded
        newFolderButton.target = self
        newFolderButton.action = #selector(newFolder)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Itens da biblioteca")
        table.registerForDraggedTypes([.lumeFavorite])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        contextMenu.delegate = self
        table.menu = contextMenu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        emptyDescription.font = .systemFont(ofSize: 13)
        view.onLayout = { [weak self] in self?.layout() }
    }

    /// Switches to a section with an empty search.
    func select(_ section: Section) {
        self.section = section
        sections.selectedSegment = section.rawValue
        search.stringValue = ""
        refresh()
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }

    func apply(_ palette: LumePalette) {
        let changed = lastDarkAppearance != palette.isDark
        lastDarkAppearance = palette.isDark
        self.palette = palette
        view.fillColor = palette.elevated
        table.backgroundColor = palette.elevated
        heading.textColor = palette.textPrimary
        summary.textColor = palette.textSecondary
        emptyTitle.textColor = palette.textPrimary
        emptyDescription.textColor = palette.textSecondary
        footer.textColor = palette.textMuted
        search.textColor = palette.textPrimary
        if changed { updateVisibleRows() }
    }

    func refresh() {
        let previousStructures = items.map(\.structure)
        let selectedID = items.indices.contains(table.selectedRow) ? items[table.selectedRow].id : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = DateFormatter()
        date.locale = Locale(identifier: "pt_BR")
        date.dateStyle = .medium
        date.timeStyle = .short
        switch section {
        case .history:
            search.placeholderString = "Buscar no histórico"
            items = store.searchHistory(query).map { entry in
                Item(id: entry.id.uuidString, title: entry.title.isEmpty ? entry.url : entry.title,
                     subtitle: "\(displayURL(entry.url)) · \(date.string(from: entry.visitedAt))", symbol: "clock",
                     progress: nil, indeterminate: false,
                     primaryLabel: "Abrir página", primarySymbol: "arrow.up.right", primaryAction: { [weak self] in self?.openURL(entry.url) },
                     secondaryLabel: nil, secondarySymbol: nil, secondaryAction: nil)
            }
            summary.stringValue = "\(items.count) \(items.count == 1 ? "página" : "páginas")"
            emptyTitle.stringValue = query.isEmpty ? "Seu histórico aparece aqui" : "Nenhuma página encontrada"
            emptyDescription.stringValue = query.isEmpty ? "Volte aos sites que você visitou neste Mac." : "Tente buscar pelo título ou pelo endereço do site."
            footer.stringValue = "O histórico é armazenado neste Mac."
        case .bookmarks:
            search.placeholderString = "Buscar favoritos"
            if query.isEmpty {
                items = bookmarkTree()
                let bookmarks = store.bookmarks.count, folders = store.bookmarkFolders.count
                summary.stringValue = "\(bookmarks) \(bookmarks == 1 ? "favorito" : "favoritos")"
                    + (folders == 0 ? "" : " · \(folders) \(folders == 1 ? "pasta" : "pastas")")
            } else {
                items = store.searchBookmarks(query).map { bookmarkItem($0, position: 0, indent: 0, showingFolder: true) }
                summary.stringValue = "\(items.count) \(items.count == 1 ? "favorito" : "favoritos")"
            }
            emptyTitle.stringValue = query.isEmpty ? "Guarde as páginas que quer revisitar" : "Nenhum favorito encontrado"
            emptyDescription.stringValue = query.isEmpty ? "Use a estrela na barra de endereço ou ⌘D para favoritar a página atual." : "Tente outro título ou endereço."
            footer.stringValue = query.isEmpty ? "Arraste para reordenar ou mover para uma pasta. Clique com o botão direito para mais opções."
                : "Abra um favorito pelo botão à direita ou com dois cliques."
        case .downloads:
            search.placeholderString = "Buscar downloads"
            let downloads = store.downloads.filter { query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
            items = downloads.map { downloadItem($0) }
            let active = downloads.filter { $0.state == .inProgress }.count
            summary.stringValue = active > 0 ? "\(active) em andamento · \(items.count) \(items.count == 1 ? "arquivo" : "arquivos")" : "\(items.count) \(items.count == 1 ? "arquivo" : "arquivos")"
            emptyTitle.stringValue = query.isEmpty ? "Nenhum download por enquanto" : "Nenhum arquivo encontrado"
            emptyDescription.stringValue = query.isEmpty ? "Os arquivos que você baixar aparecem aqui, com seu progresso e local de destino." : "Tente buscar por outro nome de arquivo."
            footer.stringValue = "Abrir arquivos e mostrar no Finder ficam disponíveis após a conclusão."
        }
        search.setAccessibilityLabel(search.placeholderString)
        clearButton.isHidden = section != .history
        clearButton.isEnabled = !store.history.isEmpty
        newFolderButton.isHidden = section != .bookmarks
        let structureChanged = renderedSection != section || previousStructures != items.map(\.structure)
        if structureChanged {
            renderedSection = section
            table.rowHeight = section == .downloads ? 76 : 64
            table.reloadData()
            if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        } else {
            updateVisibleRows()
        }
        emptyTitle.isHidden = !items.isEmpty
        emptyDescription.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        layout()
    }

    /// Folders with their bookmarks, then the top level: the sidebar order.
    private func bookmarkTree() -> [Item] {
        var tree: [Item] = []
        for (position, folder) in store.bookmarkFolders.enumerated() {
            let contents = store.bookmarks(inFolder: folder.id)
            tree.append(Item(id: folder.id.uuidString, title: folder.name,
                             subtitle: contents.isEmpty ? "Pasta vazia" : "\(contents.count) \(contents.count == 1 ? "favorito" : "favoritos")",
                             symbol: folder.icon, progress: nil, indeterminate: false,
                             primaryLabel: "Editar pasta", primarySymbol: "pencil", primaryAction: { [weak self] in self?.editFolder(folder) },
                             secondaryLabel: "Apagar pasta", secondarySymbol: "xmark", secondaryAction: { [weak self] in self?.store.removeBookmarkFolder(folder.id) },
                             favorite: .folder(folder.id), position: position))
            tree += contents.enumerated().map { bookmarkItem($1, position: $0, indent: 26, showingFolder: false) }
        }
        return tree + store.bookmarks(inFolder: nil).enumerated().map { bookmarkItem($1, position: $0, indent: 0, showingFolder: false) }
    }

    private func bookmarkItem(_ bookmark: Bookmark, position: Int, indent: CGFloat, showingFolder: Bool) -> Item {
        let folder = showingFolder ? store.bookmarkFolders.first { $0.id == bookmark.folderID } : nil
        return Item(id: bookmark.id.uuidString, title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                    subtitle: displayURL(bookmark.url) + (folder.map { " · \($0.name)" } ?? ""), symbol: "globe",
                    progress: nil, indeterminate: false,
                    primaryLabel: "Abrir favorito", primarySymbol: "arrow.up.right", primaryAction: { [weak self] in self?.openURL(bookmark.url) },
                    secondaryLabel: "Remover favorito", secondarySymbol: "xmark", secondaryAction: { [weak self] in self?.store.removeBookmark(bookmark.id) },
                    indent: indent, image: store.favicon(for: bookmark), favorite: .bookmark(bookmark.id), folderID: bookmark.folderID, position: position)
    }

    private func downloadItem(_ download: BrowserDownload) -> Item {
        let received = ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file)
        let title = download.filename.isEmpty ? "Preparando download" : download.filename
        switch download.state {
        case .inProgress:
            return Item(id: download.id, title: title,
                        subtitle: download.totalBytes > 0 ? "\(received) de \(total)" : "\(received) recebidos",
                        symbol: "arrow.down", progress: download.totalBytes > 0 ? min(1, Double(download.receivedBytes) / Double(download.totalBytes)) : nil,
                        indeterminate: download.totalBytes <= 0,
                        primaryLabel: "Cancelar download", primarySymbol: "xmark", primaryAction: { [weak self] in self?.store.cancelDownload(download.id) },
                        secondaryLabel: nil, secondarySymbol: nil, secondaryAction: nil)
        case .complete:
            return Item(id: download.id, title: title, subtitle: "Concluído · \(received)", symbol: "doc",
                        progress: nil, indeterminate: false,
                        primaryLabel: "Abrir arquivo", primarySymbol: "arrow.up.right", primaryAction: { [weak self] in self?.openDownload(download, reveal: false) },
                        secondaryLabel: "Mostrar no Finder", secondarySymbol: "folder", secondaryAction: { [weak self] in self?.openDownload(download, reveal: true) })
        case .cancelled, .failed:
            return Item(id: download.id, title: title,
                        subtitle: download.state == .cancelled ? "Cancelado" : "Não foi possível concluir o download", symbol: download.state == .cancelled ? "xmark.circle" : "exclamationmark.circle",
                        progress: nil, indeterminate: false,
                        primaryLabel: nil, primarySymbol: nil, primaryAction: nil,
                        secondaryLabel: nil, secondarySymbol: nil, secondaryAction: nil)
        }
    }

    private func displayURL(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host else { return value }
        return host + (url.path == "/" ? "" : url.path)
    }

    private func openURL(_ url: String) { onOpenURL?(url) }

    private func openDownload(_ download: BrowserDownload, reveal: Bool) {
        guard download.state == .complete, !download.path.isEmpty else { return }
        let url = URL(fileURLWithPath: download.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Arquivo não encontrado"
            alert.informativeText = "O arquivo pode ter sido movido ou removido do local onde foi salvo."
            alert.addButton(withTitle: "OK")
            if let window = view.window { alert.beginSheetModal(for: window) }
            return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url) }
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            openSelected()
            return true
        }
        if selector == #selector(NSResponder.moveDown(_:)), !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: max(0, min(table.selectedRow + 1, items.count - 1))), byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
            return true
        }
        if selector == #selector(NSResponder.moveUp(_:)), !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: max(0, table.selectedRow - 1)), byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), !search.stringValue.isEmpty {
            search.stringValue = ""
            refresh()
            return true
        }
        return false
    }

    @objc private func changeSection() {
        section = Section(rawValue: sections.selectedSegment) ?? .history
        search.stringValue = ""
        refresh()
        focusSearch()
    }

    @objc private func openSelected() {
        let index = table.selectedRow >= 0 ? table.selectedRow : 0
        guard items.indices.contains(index) else { return }
        if section != .downloads { items[index].primaryAction?() }
    }

    @objc private func newFolder() { editFolder(nil) }

    private func editFolder(_ folder: BookmarkFolder?, moving bookmarkID: UUID? = nil) {
        guard let window = view.window else { return }
        FavoriteActions.editFolder(folder, store: store, in: window, moving: bookmarkID)
    }

    /// The favorite editor points at the row's title.
    private func editBookmark(_ id: UUID) {
        guard let row = items.firstIndex(where: { $0.favorite == .bookmark(id) }) else { return }
        let rect = table.rect(ofRow: row)
        let leading = 42 + items[row].indent
        onEditBookmark?(id, NSRect(x: rect.minX + leading, y: rect.minY + 8, width: min(240, max(0, rect.width - leading)), height: rect.height - 16), table)
    }

    @objc private func clearHistory() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Limpar histórico de navegação?"
        alert.informativeText = "Os registros de páginas visitadas neste Mac serão removidos. Seus favoritos e arquivos baixados serão mantidos."
        alert.addButton(withTitle: "Limpar histórico")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.store.clearHistory() }
        }
    }

    private func layout() {
        let columnWidth = min(Self.columnWidth, view.bounds.width)
        content.frame = NSRect(x: ((view.bounds.width - columnWidth) / 2).rounded(), y: Self.topInset,
                               width: columnWidth, height: max(0, view.bounds.height - Self.topInset))
        let width = content.bounds.width
        let height = content.bounds.height
        heading.frame = NSRect(x: 24, y: 23, width: 200, height: 34)
        sections.frame = NSRect(x: width - 330, y: 27, width: 306, height: 28)
        search.frame = NSRect(x: 24, y: 79, width: width - 48, height: 28)
        summary.frame = NSRect(x: 26, y: 128, width: width - 220, height: 18)
        clearButton.frame = NSRect(x: width - 174, y: 119, width: 154, height: 30)
        newFolderButton.frame = NSRect(x: width - 140, y: 119, width: 120, height: 30)
        scroll.frame = NSRect(x: 16, y: 162, width: width - 32, height: max(0, height - 203))
        table.tableColumns.first?.width = width - 32
        let emptyY = max(190, height * 0.44)
        emptyTitle.frame = NSRect(x: 32, y: emptyY, width: width - 64, height: 28)
        emptyDescription.frame = NSRect(x: 32, y: emptyY + 39, width: width - 100, height: 58)
        footer.frame = NSRect(x: 26, y: height - 27, width: width - 52, height: 18)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? LumeView)?.fillColor = index == table.selectedRow ? palette.selection : .clear
        }
    }
    private func updateVisibleRows() {
        for index in items.indices {
            guard let row = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ItemRow else { continue }
            row.update(item: items[index], palette: palette, selected: index == table.selectedRow)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        ItemRow(item: items[row], palette: palette, selected: row == table.selectedRow)
    }

    // MARK: Arranging favorites

    /// Where a drop lands, and the row the table marks for it.
    private enum Destination {
        case into(UUID)
        case bookmark(folder: UUID?, index: Int)
        case folder(index: Int)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard arranging, items.indices.contains(row), let favorite = items[row].favorite else { return nil }
        return favorite.pasteboardItem(in: store)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let drop = drop(info, row: row, operation: operation) else { return [] }
        tableView.setDropRow(drop.row, dropOperation: drop.operation)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let kind = FavoriteKind(pasteboard: info.draggingPasteboard, in: store),
              let drop = drop(info, row: row, operation: dropOperation) else { return false }
        switch (kind, drop.destination) {
        case (.bookmark(let id), .into(let folder)): store.moveBookmark(id, toFolder: folder)
        case (.bookmark(let id), .bookmark(let folder, let index)): FavoriteActions.placeBookmark(id, inFolder: folder, at: index, store: store)
        case (.folder(let id), .folder(let index)): FavoriteActions.placeFolder(id, at: index, store: store)
        default: return false
        }
        return true
    }

    /// Bookmarks go into a folder over its row and between rows elsewhere. Folders move as a block with their bookmarks.
    private func drop(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation)
        -> (row: Int, operation: NSTableView.DropOperation, destination: Destination)? {
        guard arranging, let kind = FavoriteKind(pasteboard: info.draggingPasteboard, in: store) else { return nil }
        var gap = min(max(0, row), items.count)
        if operation == .on, items.indices.contains(row) {
            if case .bookmark(let id) = kind, case .folder(let folder)? = items[row].favorite {
                let alreadyThere = store.bookmarks.first { $0.id == id }?.folderID == folder
                return alreadyThere ? nil : (row, .on, .into(folder))
            }
            // Over another row, the half under the pointer picks the side.
            if table.convert(info.draggingLocation, from: nil).y > table.rect(ofRow: row).midY { gap = row + 1 }
        }
        switch kind {
        case .bookmark:
            // A gap belongs to the bookmark under it. Over a folder row it ends the folder above, and at the end it is the top level.
            if gap < items.count, case .bookmark? = items[gap].favorite {
                return (gap, .above, .bookmark(folder: items[gap].folderID, index: items[gap].position))
            }
            guard gap > 0 else { return nil }
            if gap == items.count { return (gap, .above, .bookmark(folder: nil, index: store.bookmarks(inFolder: nil).count)) }
            let above = items[gap - 1]
            switch above.favorite {
            case .folder(let folder)?: return (gap, .above, .bookmark(folder: folder, index: 0))
            case .bookmark?: return (gap, .above, .bookmark(folder: above.folderID, index: above.position + 1))
            case nil: return nil
            }
        case .folder:
            // Folders come before the top level, and a line never splits a folder from its bookmarks.
            let foldersEnd = items.firstIndex { if case .bookmark? = $0.favorite { return $0.folderID == nil }; return false } ?? items.count
            gap = min(gap, foldersEnd)
            while gap < foldersEnd, items[gap].folderID != nil { gap += 1 }
            var index = store.bookmarkFolders.count
            if gap < foldersEnd, case .folder? = items[gap].favorite { index = items[gap].position }
            return (gap, .above, .folder(index: index))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard section == .bookmarks else { return }
        let row = table.clickedRow
        guard items.indices.contains(row), let favorite = items[row].favorite else {
            menu.addItem(menuItem("Nova pasta…") { [weak self] in self?.editFolder(nil) })
            return
        }
        switch favorite {
        case .bookmark(let id):
            guard let bookmark = store.bookmarks.first(where: { $0.id == id }) else { return }
            menu.addItem(menuItem("Abrir") { [weak self] in self?.openURL(bookmark.url) })
            menu.addItem(menuItem("Renomear…") { [weak self] in self?.editBookmark(id) })
            menu.addItem(FavoriteActions.moveMenuItem(for: bookmark, store: store) { [weak self] in self?.editFolder(nil, moving: id) })
            menu.addItem(.separator())
            menu.addItem(menuItem("Apagar favorito") { [weak self] in self?.store.removeBookmark(id) })
        case .folder(let id):
            guard let folder = store.bookmarkFolders.first(where: { $0.id == id }) else { return }
            menu.addItem(menuItem("Editar pasta…") { [weak self] in self?.editFolder(folder) })
            menu.addItem(menuItem("Nova pasta…") { [weak self] in self?.editFolder(nil) })
            menu.addItem(.separator())
            menu.addItem(menuItem("Apagar pasta") { [weak self] in self?.store.removeBookmarkFolder(id) })
        }
    }
}
