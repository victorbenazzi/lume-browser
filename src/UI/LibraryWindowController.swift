import AppKit

final class LibraryWindowController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
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

        var structure: ItemStructure {
            ItemStructure(id: id, symbol: symbol, hasProgress: progress != nil || indeterminate,
                          primaryLabel: primaryLabel, primarySymbol: primarySymbol,
                          secondaryLabel: secondaryLabel, secondarySymbol: secondarySymbol)
        }
    }

    private struct ItemStructure: Equatable {
        let id: String
        let symbol: String
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
        private var buttons: [QuietButton] { [primaryButton, secondaryButton].compactMap { $0 } }

        init(item: Item, palette: LumePalette, selected: Bool) {
            super.init(frame: .zero)
            cornerRadius = 6
            icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
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
            icon.contentTintColor = palette.textMuted
            primaryButton?.actionHandler = item.primaryAction
            secondaryButton?.actionHandler = item.secondaryAction
            for button in buttons {
                button.contentTintColor = palette.textSecondary
                button.hoverColor = palette.elevated
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
            icon.frame = NSRect(x: 12, y: 17, width: 17, height: 17)
            let trailing = CGFloat(max(1, buttons.count)) * 32 + 16
            titleLabel.frame = NSRect(x: 42, y: 11, width: max(0, bounds.width - 42 - trailing), height: 20)
            subtitleLabel.frame = NSRect(x: 42, y: 34, width: max(0, bounds.width - 42 - trailing), height: 17)
            progressIndicator?.frame = NSRect(x: 42, y: 59, width: max(0, bounds.width - 42 - trailing), height: 4)
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(x: bounds.width - 42 - CGFloat(index) * 32, y: 16, width: 28, height: 28)
            }
        }
    }

    private let store: BrowserStore
    private let root = LumeView()
    private let heading = lumeLabel("Biblioteca", size: 24, weight: .medium)
    private let sections = NSSegmentedControl(labels: ["Histórico", "Favoritos", "Downloads"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let summary = lumeLabel("", size: 11)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let clearButton = NSButton(title: "Limpar histórico…", target: nil, action: nil)
    private let emptyTitle = lumeLabel("", size: 18, weight: .medium)
    private let emptyDescription = NSTextField(wrappingLabelWithString: "")
    private let footer = lumeLabel("", size: 11)
    private var section: Section = .history
    private var items: [Item] = []
    private var renderedSection: Section?
    private var palette = LumePalette.light
    private var lastDarkAppearance: Bool?
    var onOpenURL: ((String) -> Void)?

    init(store: BrowserStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 570), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Biblioteca do Lume"
        window.minSize = NSSize(width: 600, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = root
        let views: [NSView] = [heading, sections, search, summary, scroll, clearButton, emptyTitle, emptyDescription, footer]
        views.forEach { root.addSubview($0) }
        sections.target = self
        sections.action = #selector(changeSection)
        sections.selectedSegment = 0
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
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
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        emptyDescription.font = .systemFont(ofSize: 13)
        root.onLayout = { [weak self] in self?.layout() }
        root.onAppearanceChange = { [weak self] in self?.applyTheme(appearance: self?.window?.appearance) }
        applyTheme(appearance: nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(section: Section, appearance: NSAppearance?) {
        self.section = section
        sections.selectedSegment = section.rawValue
        search.stringValue = ""
        applyTheme(appearance: appearance)
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    func applyTheme(appearance: NSAppearance?) {
        if window?.appearance !== appearance { window?.appearance = appearance }
        guard let window else { return }
        let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let changed = lastDarkAppearance != isDark
        lastDarkAppearance = isDark
        palette = .current(for: window.effectiveAppearance)
        root.fillColor = palette.background
        window.backgroundColor = palette.background
        table.backgroundColor = palette.background
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
            items = store.searchBookmarks(query).map { bookmark in
                Item(id: bookmark.id.uuidString, title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                     subtitle: displayURL(bookmark.url), symbol: "bookmark",
                     progress: nil, indeterminate: false,
                     primaryLabel: "Abrir favorito", primarySymbol: "arrow.up.right", primaryAction: { [weak self] in self?.openURL(bookmark.url) },
                     secondaryLabel: "Remover favorito", secondarySymbol: "xmark", secondaryAction: { [weak self] in self?.store.removeBookmark(bookmark.id) })
            }
            summary.stringValue = "\(items.count) \(items.count == 1 ? "favorito" : "favoritos")"
            emptyTitle.stringValue = query.isEmpty ? "Guarde as páginas que quer revisitar" : "Nenhum favorito encontrado"
            emptyDescription.stringValue = query.isEmpty ? "Use a estrela na barra de endereço ou ⌘D para favoritar a página atual." : "Tente outro título ou endereço."
            footer.stringValue = "Abra um favorito pelo botão à direita ou com dois cliques."
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
            if let window { alert.beginSheetModal(for: window) }
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
        if selector == #selector(NSResponder.cancelOperation(_:)) { window?.performClose(nil); return true }
        return false
    }

    @objc private func changeSection() {
        section = Section(rawValue: sections.selectedSegment) ?? .history
        search.stringValue = ""
        refresh()
        window?.makeFirstResponder(search)
    }

    @objc private func openSelected() {
        let index = table.selectedRow >= 0 ? table.selectedRow : 0
        guard items.indices.contains(index) else { return }
        if section != .downloads { items[index].primaryAction?() }
    }

    @objc private func clearHistory() {
        guard let window else { return }
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
        let width = root.bounds.width
        let height = root.bounds.height
        heading.frame = NSRect(x: 24, y: 23, width: 200, height: 34)
        sections.frame = NSRect(x: width - 330, y: 27, width: 306, height: 28)
        search.frame = NSRect(x: 24, y: 79, width: width - 48, height: 28)
        summary.frame = NSRect(x: 26, y: 128, width: width - 220, height: 18)
        clearButton.frame = NSRect(x: width - 174, y: 119, width: 154, height: 30)
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
}
