import AppKit

/// The address field. It reports focus, so suggestions get ready before the first keystroke.
final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// The address field's editor. It says when text is being typed, and lets the completion in only once the typed
/// character has fully landed: changed during the edit, TextKit moves the selection back to the end, and the next
/// keystroke would then add to the completion instead of replacing it.
final class AddressFieldEditor: NSTextView {
    /// Characters typed, as opposed to pasted, deleted or completed.
    private(set) var isTyping = false
    /// The typed characters are in place, and the edit is over.
    var onTyped: (() -> Void)?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        isTyping = true
        super.insertText(string, replacementRange: replacementRange)
        isTyping = false
        onTyped?()
    }
}

/// The list that grows out of the address field while typing, as in Chrome: the address being completed, history,
/// favorites, open guias and the search engine's suggestions. Local rows are ready within the keystroke; the engine's
/// suggestions join below as they arrive, so rows already read never move.
final class AddressSuggestions {
    let list = SuggestionListView()
    /// A row was chosen with Return or a click.
    var onOpen: ((AutocompleteMatch) -> Void)?
    /// The list opened, closed, changed or moved its selection. The window restyles and lays out the field.
    var onChange: (() -> Void)?

    private let store: BrowserStore
    private unowned let field: NSTextField
    private var result = AutocompleteResult()
    private(set) var selectedIndex = 0
    /// What the user typed, without the completion or the text of a selected row.
    private var typed = ""
    /// The engine's latest answer and the text it answered.
    private var remote: (query: String, items: [String]) = ("", [])
    /// A completion waiting for the typed character's edit to end.
    private var pendingCompletion = ""

    var isOpen: Bool { !list.isHidden }
    var selectedMatch: AutocompleteMatch? {
        isOpen && result.matches.indices.contains(selectedIndex) ? result.matches[selectedIndex] : nil
    }

    init(store: BrowserStore, field: NSTextField) {
        self.store = store
        self.field = field
        list.isHidden = true
        list.onActivate = { [weak self] index in self?.activate(index) }
        list.onRemove = { [weak self] index in self?.remove(index) }
    }

    /// The field gained focus: the index and the connection to the engine get ready.
    func prepare() {
        close()
        typed = ""
        store.prepareAutocomplete()
        store.warmUpSearchSuggestions()
    }

    func textDidChange() {
        pendingCompletion = ""
        // A character still being composed, as with the dead keys of accents, is not text yet.
        guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        let text = editor.string
        // As in Chrome, only characters typed at the end complete: not deleting, pasting or editing in the middle.
        let typing = (editor as? AddressFieldEditor)?.isTyping == true
        let atEnd = editor.selectedRange() == NSRange(location: (text as NSString).length, length: 0)
        let allowInline = typing && atEnd && text.count > typed.count && text.hasPrefix(typed)
        typed = text
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { close(); return }
        if let cached = store.cachedSearchSuggestions(for: text) { remote = (query, cached) }
        result = store.autocomplete(text, allowInline: allowInline, suggestions: remoteItems())
        selectedIndex = 0
        // Only typing completes, and the editor lets the completion in as the keystroke ends.
        pendingCompletion = result.inlineCompletion
        show()
        if result.wantsSuggestions {
            store.requestSearchSuggestions(for: text) { [weak self] query, items in self?.receive(query, items) }
        }
    }

    /// The typed character is in place: the rest of the address goes after it, selected, so the next keystroke replaces it.
    func typingEnded() {
        let completion = pendingCompletion
        pendingCompletion = ""
        guard !completion.isEmpty, isOpen, selectedIndex == 0, let editor = field.currentEditor() as? NSTextView,
              !editor.hasMarkedText(), editor.string == typed else { return }
        let start = (typed as NSString).length
        editor.string = typed + completion
        editor.setSelectedRange(NSRange(location: start, length: (completion as NSString).length))
    }

    /// Keys the field passes on. True when the list used the key.
    func handle(_ selector: Selector) -> Bool {
        guard isOpen else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            select(selectedIndex + 1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            select(selectedIndex - 1)
        case #selector(NSResponder.insertNewline(_:)):
            activate(selectedIndex)
        case #selector(NSResponder.cancelOperation(_:)):
            // As in Chrome, Escape first brings back what was typed, then closes the list, then leaves the field.
            if selectedIndex > 0 { select(0) } else { dismiss() }
        case #selector(NSResponder.deleteForward(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) == true:
            guard selectedMatch?.isRemovable == true else { return false }
            remove(selectedIndex)
        default:
            return false
        }
        return true
    }

    func endEditing() {
        close()
        typed = ""
    }

    func close() {
        guard isOpen else { return }
        list.isHidden = true
        result = AutocompleteResult()
        selectedIndex = 0
        remote = ("", [])
        onChange?()
    }

    /// The icon of a row, also shown in the field while the row is selected.
    func image(for match: AutocompleteMatch) -> NSImage? {
        func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        switch match.kind {
        case .typedSearch, .suggestion: return symbol("magnifyingglass")
        case .pastSearch: return symbol("clock.arrow.circlepath")
        case .internalPage: return symbol(InternalPage(url: match.detail)?.symbol ?? "globe")
        case .typedAddress, .history, .bookmark, .tab: return match.url.flatMap { store.favicon(forURL: $0) } ?? symbol("globe")
        }
    }

    private func show() {
        guard !result.matches.isEmpty else { close(); return }
        let opening = list.isHidden
        list.update(result.matches, selected: selectedIndex, typed: typed) { [weak self] in self?.image(for: $0) }
        list.isHidden = false
        onChange?()
        if opening { list.animateOpening() }
    }

    /// The engine's answer for the text, or an earlier one narrowed to what still fits, so rows hold while typing on.
    private func remoteItems() -> [String] {
        let query = AutocompleteText.fold(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        let answered = AutocompleteText.fold(remote.query)
        guard !remote.items.isEmpty, !answered.isEmpty, query.starts(with: answered) else { return [] }
        return query == answered ? remote.items : remote.items.filter { AutocompleteText.fold($0).starts(with: query) }
    }

    private func receive(_ query: String, _ items: [String]) {
        let current = AutocompleteText.fold(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isOpen, current.starts(with: AutocompleteText.fold(query)) else { return }
        remote = (query, items)
        let selected = selectedMatch
        var updated = store.autocomplete(typed, allowInline: !result.inlineCompletion.isEmpty, suggestions: remoteItems())
        // The field keeps what it shows. A row chosen with the arrows stays chosen, or the list waits.
        updated.inlineCompletion = result.inlineCompletion
        let index = selected.flatMap { selected in updated.matches.firstIndex { $0.destination == selected.destination } }
        guard selectedIndex == 0 || index != nil else { return }
        result = updated
        selectedIndex = index ?? 0
        show()
    }

    /// The arrows show a row's text in the field. The first row brings back what was typed, with its completion.
    private func select(_ index: Int) {
        guard !result.matches.isEmpty, let editor = field.currentEditor() as? NSTextView else { return }
        let index = min(max(0, index), result.matches.count - 1)
        guard index != selectedIndex else { return }
        selectedIndex = index
        if index == 0 {
            editor.string = typed + result.inlineCompletion
            editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: (result.inlineCompletion as NSString).length))
        } else {
            let text = result.matches[index].fillText
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        list.select(index)
        onChange?()
    }

    /// The first Escape leaves the typed text alone in the field, without the completion or the list.
    private func dismiss() {
        if let editor = field.currentEditor() as? NSTextView, !result.inlineCompletion.isEmpty {
            editor.string = typed
            editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
        }
        close()
    }

    private func activate(_ index: Int) {
        guard result.matches.indices.contains(index) else { return }
        let match = result.matches[index]
        close()
        onOpen?(match)
    }

    /// Removes the page from history and shows the list again without it.
    private func remove(_ index: Int) {
        guard result.matches.indices.contains(index), result.matches[index].isRemovable, let url = result.matches[index].url else { return }
        let kept = selectedIndex
        store.removeHistory(url: url)
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = typed
            editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
        }
        result = store.autocomplete(typed, allowInline: false, suggestions: remoteItems())
        selectedIndex = min(kept, max(0, result.matches.count - 1))
        if selectedIndex > 0, let editor = field.currentEditor() as? NSTextView {
            let text = result.matches[selectedIndex].fillText
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        show()
    }
}

/// The card behind the field and the rows below it. It draws the field's surface too, so the field and its list
/// read as one piece that grows downward.
final class SuggestionListView: NSView {
    struct Metrics: Equatable {
        let header: CGFloat
        let rowHeight: CGFloat
        let iconX: CGFloat
        let textX: CGFloat
        let titleSize: CGFloat
        let detailSize: CGFloat
        let radius: CGFloat

        /// Icon and text line up with the field's own.
        static let toolbar = Metrics(header: 32, rowHeight: 34, iconX: 10, textX: 33, titleSize: 13, detailSize: 12, radius: 10)
        static let hero = Metrics(header: LumeMetrics.heroFieldHeight, rowHeight: 40, iconX: 16, textX: 43, titleSize: 14, detailSize: 13, radius: 14)
    }

    var onActivate: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    private(set) var metrics = Metrics.toolbar
    private let card = SuggestionCard()
    private let separator = NSView()
    private var rows: [SuggestionRow] = []
    private var matches: [AutocompleteMatch] = []
    private var selected = 0
    private var typed = ""
    private var image: (AutocompleteMatch) -> NSImage? = { _ in nil }
    private var palette = LumePalette.light
    private var rowsNeedContent = false
    /// The row under the pointer. The list tracks the pointer as one area, so a missed exit never leaves a row lit.
    private var hovered: Int? {
        didSet { for (index, row) in rows.enumerated() { row.isHovered = index == hovered } }
    }
    private static let padding: CGFloat = 6

    override var isFlipped: Bool { true }

    /// Chromium ignores the pointer over views that answer yes, so the page below neither reacts nor sets the cursor.
    @objc func nonWebContentView() -> Bool { true }

    /// The field's height and the rows, which the window caps to the room it has.
    var contentHeight: CGFloat {
        matches.isEmpty ? metrics.header : metrics.header + 1 + Self.padding * 2 + CGFloat(matches.count) * metrics.rowHeight
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOffset = .zero
        layer?.shadowOpacity = 1
        addSubview(card)
        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.cornerCurve = .continuous
        card.addSubview(separator)
        separator.wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Sugestões")
    }

    required init?(coder: NSCoder) { nil }

    func update(_ matches: [AutocompleteMatch], selected: Int, typed: String, image: @escaping (AutocompleteMatch) -> NSImage?) {
        self.matches = matches
        self.selected = selected
        self.typed = typed
        self.image = image
        rowsNeedContent = true
        needsLayout = true
    }

    func select(_ index: Int) {
        selected = index
        for (row, position) in zip(rows, rows.indices) { row.isSelected = position == index }
    }

    /// The card is always opaque: it floats over the page, or sits on the new tab page like its field.
    func apply(_ palette: LumePalette, hero: Bool) {
        let metrics: Metrics = hero ? .hero : .toolbar
        let scale = window?.backingScaleFactor ?? 2
        card.layer?.backgroundColor = palette.elevated.cgColor
        card.layer?.cornerRadius = metrics.radius
        card.layer?.borderWidth = 1 / scale
        card.layer?.borderColor = palette.pageBorder.cgColor
        separator.layer?.backgroundColor = palette.separator.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.45 : 0.14).cgColor
        layer?.shadowRadius = hero ? 22 : 16
        guard palette.isDark != self.palette.isDark || metrics != self.metrics else { return }
        self.palette = palette
        self.metrics = metrics
        rowsNeedContent = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        separator.frame = NSRect(x: 12, y: metrics.header, width: max(0, bounds.width - 24), height: 1 / scale)
        separator.isHidden = matches.isEmpty
        while rows.count < matches.count {
            let row = SuggestionRow()
            let index = rows.count
            row.onActivate = { [weak self] in self?.onActivate?(index) }
            row.onRemove = { [weak self] in self?.onRemove?(index) }
            card.addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= matches.count
            guard index < matches.count else { continue }
            row.frame = NSRect(x: 0, y: metrics.header + 1 + Self.padding + CGFloat(index) * metrics.rowHeight,
                               width: bounds.width, height: metrics.rowHeight)
            if rowsNeedContent { row.configure(matches[index], image: image(matches[index]), typed: typed, palette: palette, metrics: metrics) }
            row.isSelected = index == selected
            row.isHovered = index == hovered
        }
        rowsNeedContent = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    private func hover(at location: NSPoint) {
        let point = card.convert(location, from: nil)
        hovered = rows.indices.first { !rows[$0].isHidden && rows[$0].frame.contains(point) }
    }

    /// The card grows from the field down to the last row. The field is already in place, so typing is never held back.
    func animateOpening() {
        layoutSubtreeIfNeeded()
        // Shown again, possibly under a resting pointer: the pointer says which row it is on.
        if let window, window.isKeyWindow { hover(at: window.mouseLocationOutsideOfEventStream) } else { hovered = nil }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, bounds.height > metrics.header else { return }
        let final = bounds
        card.frame = NSRect(x: 0, y: 0, width: final.width, height: metrics.header)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = LumeMotion.easeOut
            context.allowsImplicitAnimation = true
            card.animator().frame = final
        }
    }
}

private final class SuggestionCard: NSView {
    override var isFlipped: Bool { true }
}

private final class SuggestionRow: NSView {
    var onActivate: (() -> Void)?
    var onRemove: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            setAccessibilitySelected(isSelected)
            refreshRemove()
        }
    }
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// An open guia: the row switches to it instead of loading the page again.
    private let badge = LumeView()
    private let badgeLabel = lumeLabel("Ir para a guia", size: 11, weight: .medium)
    private lazy var removeButton: QuietButton = {
        let button = QuietButton(symbol: "xmark", title: "Remover do histórico (⇧⌦)") { [weak self] in self?.onRemove?() }
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        // A click on it must not take focus from the field, which would close the list first.
        button.refusesFirstResponder = true
        button.cornerRadius = 10
        return button
    }()
    private var palette = LumePalette.light
    private var metrics = SuggestionListView.Metrics.toolbar
    private var titleWidth: CGFloat = 0
    private var detailWidth: CGFloat = 0
    private var removable = false
    private var pressed = false
    /// Set by the list, which follows the pointer.
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            refreshRemove()
        }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
        }
        badge.cornerRadius = 5
        badge.addSubview(badgeLabel)
        badgeLabel.alignment = .center
        for view in [icon, titleLabel, detailLabel, badge, removeButton] { addSubview(view) }
        removeButton.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ match: AutocompleteMatch, image: NSImage?, typed: String, palette: LumePalette, metrics: SuggestionListView.Metrics) {
        self.palette = palette
        self.metrics = metrics
        let font = NSFont.systemFont(ofSize: metrics.titleSize)
        let strong = NSFont.systemFont(ofSize: metrics.titleSize, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: metrics.detailSize)
        let detailStrong = NSFont.systemFont(ofSize: metrics.detailSize, weight: .semibold)
        let words = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        let title: NSAttributedString
        var detail: NSAttributedString?
        switch match.kind {
        case .suggestion, .pastSearch:
            title = Self.completing(match.title, typed: typed, font: font, strong: strong, color: palette.textPrimary)
        case .typedSearch:
            title = Self.plain(match.title, font: font, color: palette.textPrimary)
            detail = Self.plain(match.detail, font: detailFont, color: palette.textMuted)
        case .typedAddress:
            title = Self.plain(match.title, font: font, color: palette.textPrimary)
        case .history, .bookmark, .tab, .internalPage:
            title = Self.emphasized(match.title, words: words, font: font, strong: strong, color: palette.textPrimary, anywhere: false)
            if match.detail != match.title {
                detail = Self.emphasized(match.detail, words: words, font: detailFont, strong: detailStrong, color: palette.textMuted, anywhere: true)
            }
        }
        titleLabel.attributedStringValue = title
        detailLabel.attributedStringValue = detail ?? NSAttributedString()
        // The cell's size, which includes the padding it draws on each side of the text.
        titleWidth = ceil(titleLabel.cell?.cellSize.width ?? title.size().width + 4)
        detailWidth = detail.map { ceil(detailLabel.cell?.cellSize.width ?? $0.size().width + 4) } ?? 0
        icon.image = image
        icon.contentTintColor = palette.textMuted
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: metrics.titleSize - 1, weight: .regular)
        badge.isHidden = match.tabID == nil
        badge.fillColor = palette.accent.withAlphaComponent(palette.isDark ? 0.2 : 0.1)
        badgeLabel.textColor = palette.accent
        removable = match.isRemovable
        removeButton.contentTintColor = palette.textMuted
        removeButton.hoverColor = palette.isDark ? .white.withAlphaComponent(0.1) : .black.withAlphaComponent(0.07)
        refreshRemove()
        setAccessibilityLabel([match.title, match.detail, match.tabID == nil ? "" : "Ir para a guia"].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSize: CGFloat = 16
        icon.frame = NSRect(x: metrics.iconX, y: round((height - iconSize) / 2), width: iconSize, height: iconSize)
        var trailing = bounds.width - 10
        if !removeButton.isHidden {
            removeButton.frame = NSRect(x: bounds.width - 32, y: round((height - 20) / 2), width: 20, height: 20)
            trailing = removeButton.frame.minX - 6
        }
        if !badge.isHidden {
            let width = ceil(badgeLabel.intrinsicContentSize.width) + 14
            badge.frame = NSRect(x: trailing - width, y: round((height - 20) / 2), width: width, height: 20)
            badgeLabel.frame = NSRect(x: 0, y: 3, width: width, height: 14)
            trailing = badge.frame.minX - 8
        }
        let available = max(0, trailing - metrics.textX)
        let gap: CGFloat = 8
        let lineHeight = ceil(metrics.titleSize * 1.35)
        var titleSpace = min(titleWidth, available)
        if detailWidth > 0 {
            // The title keeps most of the room; the address takes what is left and truncates first.
            titleSpace = min(titleWidth, max(available - detailWidth - gap, available * 0.6))
        }
        titleLabel.frame = NSRect(x: metrics.textX, y: round((height - lineHeight) / 2), width: titleSpace, height: lineHeight)
        let detailX = metrics.textX + titleSpace + gap
        let detailHeight = ceil(metrics.detailSize * 1.35)
        detailLabel.frame = NSRect(x: detailX, y: round((height - detailHeight) / 2) + 0.5, width: max(0, trailing - detailX), height: detailHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        (isSelected ? palette.selection : palette.selection.withAlphaComponent(0.5)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    private func refreshRemove() {
        let show = removable && (isHovered || isSelected)
        guard removeButton.isHidden == show else { return }
        removeButton.isHidden = !show
        needsLayout = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === removeButton || hit.isDescendant(of: removeButton) ? hit : self
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    // MARK: Text

    private static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func plain(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(font, color))
    }

    /// Bold where a typed word matches: from a word start in titles, anywhere in addresses.
    private static func emphasized(_ text: String, words: [String], font: NSFont, strong: NSFont, color: NSColor, anywhere: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes(font, color))
        let string = text as NSString
        for word in words {
            var start = 0
            while start < string.length {
                let found = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: NSRange(location: start, length: string.length - start))
                guard found.location != NSNotFound, found.length > 0 else { break }
                if anywhere || found.location == 0 || !isWordCharacter(string.character(at: found.location - 1)) {
                    result.addAttribute(.font, value: strong, range: found)
                }
                start = found.location + found.length
            }
        }
        return result
    }

    /// Searches bold what they add to the typed text, as Chrome does.
    private static func completing(_ text: String, typed: String, font: NSFont, strong: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes(font, color))
        let string = text as NSString
        let typedPart = string.range(of: typed.trimmingCharacters(in: .whitespacesAndNewlines),
                                     options: [.caseInsensitive, .diacriticInsensitive, .anchored])
        let start = typedPart.location == NSNotFound ? 0 : typedPart.length
        if start < string.length { result.addAttribute(.font, value: strong, range: NSRange(location: start, length: string.length - start)) }
        return result
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
