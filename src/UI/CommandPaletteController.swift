import AppKit

private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CommandPaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: BrowserStore
    private let panel: CommandPanel
    private let root = LumeView()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let divider = LumeView()
    private let footer = lumeLabel("↑ ↓ selecionar     ↵ executar     esc fechar", size: 11)
    private let emptyLabel = lumeLabel("Nenhum comando encontrado", size: 13)
    private var results: [Command] = []
    private var palette = LumePalette.light
    private weak var parentWindow: NSWindow?

    init(store: BrowserStore) {
        self.store = store
        panel = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 392), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        root.cornerRadius = LumeMetrics.panelRadius
        root.wantsLayer = true
        root.layer?.cornerRadius = LumeMetrics.panelRadius
        root.layer?.masksToBounds = true
        panel.contentView = root
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = "Pesquisar abas ou executar comando"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Pesquisar abas ou executar comando")
        root.addSubview(field)
        root.addSubview(divider)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(executeSelection)
        table.setAccessibilityLabel("Comandos disponíveis")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        root.addSubview(scroll)
        root.addSubview(footer)
        root.addSubview(emptyLabel)
        root.onLayout = { [weak self] in self?.layout() }
    }

    func show(relativeTo window: NSWindow) {
        if panel.isVisible { dismiss(); return }
        parentWindow = window
        panel.appearance = window.appearance
        palette = .current(for: window.effectiveAppearance)
        root.fillColor = palette.elevated
        field.textColor = palette.textPrimary
        field.insertionPointColorIfAvailable(palette.accent)
        divider.fillColor = palette.separator
        footer.textColor = palette.textMuted
        emptyLabel.textColor = palette.textSecondary
        table.backgroundColor = palette.elevated
        field.stringValue = ""
        reloadResults()
        let width = min(560, window.frame.width - 48)
        panel.setFrame(NSRect(x: window.frame.midX - width / 2,
                              y: window.frame.maxY - 106 - panelHeight,
                              width: width, height: panelHeight), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        parentWindow?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { dismiss() }
    }

    private func layout() {
        let width = root.bounds.width
        field.frame = NSRect(x: 20, y: 19, width: width - 40, height: 25)
        divider.frame = NSRect(x: 0, y: 62, width: width, height: 1)
        scroll.frame = NSRect(x: 8, y: 71, width: width - 16, height: root.bounds.height - 104)
        table.tableColumns.first?.width = width - 16
        footer.frame = NSRect(x: 20, y: root.bounds.height - 25, width: width - 40, height: 16)
        emptyLabel.frame = NSRect(x: 20, y: 99, width: width - 40, height: 22)
    }

    private var panelHeight: CGFloat { 104 + CGFloat(min(6, max(1, results.count))) * 50 }

    private func reloadResults() {
        results = store.commands(matching: field.stringValue)
        table.reloadData()
        if let parentWindow {
            var frame = panel.frame
            frame.size.height = panelHeight
            frame.origin.y = parentWindow.frame.maxY - 106 - panelHeight
            panel.setFrame(frame, display: true)
        }
        emptyLabel.isHidden = !results.isEmpty
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { reloadResults() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            executeSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); return true
        default: return false
        }
    }

    private func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + offset, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func executeSelection() {
        let index = table.selectedRow
        guard results.indices.contains(index) else { return }
        let command = results[index]
        dismiss()
        command.execute()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for row in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LumeView)?.fillColor = row == table.selectedRow ? palette.selection : .clear
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = results[row]
        let view = LumeView()
        view.cornerRadius = 6
        view.fillColor = row == table.selectedRow ? palette.selection : .clear
        let title = lumeLabel(command.title, size: 13, weight: .medium)
        title.textColor = palette.textPrimary
        let subtitle = lumeLabel(command.subtitle, size: 11)
        subtitle.textColor = palette.textSecondary
        let shortcut = lumeLabel(command.shortcut ?? "", size: 11)
        shortcut.alignment = .right
        shortcut.textColor = palette.textMuted
        view.addSubview(title)
        view.addSubview(subtitle)
        view.addSubview(shortcut)
        view.onLayout = { [weak view, weak title, weak subtitle, weak shortcut] in
            guard let view else { return }
            title?.frame = NSRect(x: 12, y: 7, width: max(0, view.bounds.width - 102), height: 18)
            subtitle?.frame = NSRect(x: 12, y: 26, width: max(0, view.bounds.width - 36), height: 15)
            shortcut?.frame = NSRect(x: view.bounds.width - 84, y: 8, width: 70, height: 18)
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(command.title + ". " + command.subtitle)
        return view
    }
}

private extension NSTextField {
    func insertionPointColorIfAvailable(_ color: NSColor) {
        (currentEditor() as? NSTextView)?.insertionPointColor = color
    }
}
