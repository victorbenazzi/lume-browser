import AppKit

final class FindBar: LumeView, NSSearchFieldDelegate {
    private let store: BrowserStore
    private let search = NSSearchField()
    private let countLabel = lumeLabel("", size: 11)
    private let previousButton: QuietButton
    private let nextButton: QuietButton
    private let closeButton: QuietButton
    var onClose: (() -> Void)?
    var query: String { search.stringValue }

    init(store: BrowserStore) {
        self.store = store
        previousButton = QuietButton(symbol: "chevron.up", title: "Resultado anterior (⇧⌘G)", action: {})
        nextButton = QuietButton(symbol: "chevron.down", title: "Próximo resultado (⌘G)", action: {})
        closeButton = QuietButton(symbol: "xmark", title: "Fechar busca (Esc)", action: {})
        super.init(frame: .zero)
        search.font = .systemFont(ofSize: 13)
        search.placeholderString = "Buscar nesta página"
        search.setAccessibilityLabel("Buscar nesta página")
        search.delegate = self
        for view in [search, countLabel, previousButton, nextButton, closeButton] { addSubview(view) }
        previousButton.actionHandler = { [weak self] in self?.findNext(forward: false) }
        nextButton.actionHandler = { [weak self] in self?.findNext(forward: true) }
        closeButton.actionHandler = { [weak self] in self?.onClose?() }
    }

    required init?(coder: NSCoder) { nil }

    func focus() { window?.makeFirstResponder(search); search.selectText(nil) }

    func refresh(palette: LumePalette) {
        fillColor = palette.surface
        search.textColor = palette.textPrimary
        countLabel.textColor = palette.textSecondary
        if query.isEmpty { countLabel.stringValue = "" }
        else if store.findMatchCount == 0 { countLabel.stringValue = "Nenhum resultado" }
        else if store.findActiveMatch == 0 {
            countLabel.stringValue = "\(store.findMatchCount) \(store.findMatchCount == 1 ? "resultado" : "resultados")"
        } else { countLabel.stringValue = "\(store.findActiveMatch) de \(store.findMatchCount)" }
        countLabel.setAccessibilityLabel(query.isEmpty ? "" : "Busca: \(countLabel.stringValue)")
        for button in [previousButton, nextButton, closeButton] {
            button.contentTintColor = palette.textSecondary
            button.hoverColor = palette.selection
        }
        previousButton.isEnabled = !query.isEmpty && store.findMatchCount > 0
        nextButton.isEnabled = previousButton.isEnabled
    }

    func repeatForCurrentPage() {
        if !query.isEmpty { store.findInPage(query) }
    }

    func findNext(forward: Bool) {
        guard !query.isEmpty else { focus(); return }
        store.findInPage(query, forward: forward, findNext: true)
    }

    func clear() { search.stringValue = ""; countLabel.stringValue = "" }

    func controlTextDidChange(_ notification: Notification) {
        if query.isEmpty { store.stopFinding() }
        else { store.findInPage(query) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            findNext(forward: !NSEvent.modifierFlags.contains(.shift)); return true
        }
        return false
    }

    override func layout() {
        super.layout()
        let fieldWidth = min(320, max(140, bounds.width - 250))
        search.frame = NSRect(x: 16, y: 10, width: fieldWidth, height: 25)
        countLabel.frame = NSRect(x: fieldWidth + 28, y: 14, width: 114, height: 18)
        previousButton.frame = NSRect(x: bounds.width - 102, y: 9, width: 28, height: 28)
        nextButton.frame = NSRect(x: bounds.width - 72, y: 9, width: 28, height: 28)
        closeButton.frame = NSRect(x: bounds.width - 38, y: 9, width: 28, height: 28)
    }
}
