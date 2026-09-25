import AppKit

/// Favorites at the top of the sidebar: folders with their own icons and bookmarks, as a list or as an icon grid.
/// Dragging reorders them and drops bookmarks into folders.
final class FavoritesView: LumeView, NSDraggingSource {
    /// Where a drag would land. Indexes count the destination as shown, the dragged favorite included.
    private enum DropTarget: Equatable {
        case into(UUID)
        case bookmark(folder: UUID?, index: Int, line: NSRect)
        case folder(index: Int, line: NSRect)

        var line: NSRect? {
            switch self {
            case .into: return nil
            case .bookmark(_, _, let line), .folder(_, let line): return line
            }
        }
    }

    private let store: BrowserStore
    private let heading = lumeLabel("FAVORITOS", size: 10, weight: .semibold)
    /// The whole heading row folds the favorites away, in both layouts, like the chevron at its end.
    private let headerButton = NSButton()
    private lazy var chevron = QuietButton(symbol: "chevron.down", title: "Ocultar favoritos") { [weak self] in self?.toggleCollapsed() }
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Use ⌘D para guardar a página atual aqui.")
    private let dropIndicator = LumeView()
    /// Closes the favorites off from the tabs below.
    private let divider = LumeView()
    private var items: [FavoriteItem] = []
    private var expandedFolders = Set<UUID>()
    private var palette = LumePalette.light
    private var dragged: FavoriteItem.Kind?
    private var dropTarget: DropTarget? { didSet { if dropTarget != oldValue { showDropTarget() } } }
    private var layoutMode: FavoritesLayout { store.settings.favoritesLayout }
    private var collapsed: Bool { store.settings.favoritesCollapsed }
    /// Folder expansion is view state: the owner lays the sidebar out again.
    var onExpansionChange: (() -> Void)?
    /// Asks the owner for the favorite editor, pointing at a rectangle of this view.
    var onEditBookmark: ((UUID, NSRect) -> Void)?

    private static let headerHeight: CGFloat = 30
    private static let emptyHeight: CGFloat = 32
    /// Room under the last favorite, where a drop lands at the end of the top level.
    private static let dropMargin: CGFloat = 12
    private static let rowPitch: CGFloat = 34
    private static let columns = 4
    private static let tileHeight: CGFloat = 40
    private static let tileGap: CGFloat = 6

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        emptyLabel.font = .systemFont(ofSize: 11)
        dropIndicator.cornerRadius = 1
        dropIndicator.isHidden = true
        headerButton.isBordered = false
        headerButton.title = ""
        headerButton.target = self
        headerButton.action = #selector(toggleCollapsed)
        // The chevron speaks for the row.
        headerButton.setAccessibilityElement(false)
        chevron.symbolConfiguration = LumeMetrics.headingSymbol
        for view in [heading, headerButton, chevron, emptyLabel, divider] { addSubview(view) }
        registerForDraggedTypes([.lumeFavorite])
    }

    required init?(coder: NSCoder) { nil }

    func refresh(palette: LumePalette) {
        self.palette = palette
        divider.fillColor = palette.separator
        heading.textColor = palette.textMuted
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        chevron.toolTip = collapsed ? "Mostrar favoritos" : "Ocultar favoritos"
        chevron.setAccessibilityLabel(chevron.toolTip)
        chevron.contentTintColor = palette.textMuted
        chevron.hoverColor = palette.selection
        chevron.needsDisplay = true
        emptyLabel.textColor = palette.textMuted
        dropIndicator.fillColor = palette.accent
        items.forEach { $0.removeFromSuperview() }
        items = collapsed ? [] : layoutMode == .icons ? makeTiles() : makeRows()
        for item in items {
            item.alphaValue = item.kind == dragged ? 0.4 : 1
            addSubview(item)
        }
        // Above the favorites, which are rebuilt on every change.
        dropIndicator.removeFromSuperview()
        addSubview(dropIndicator)
        emptyLabel.isHidden = !items.isEmpty || collapsed
        showDropTarget()
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if collapsed { return Self.headerHeight }
        if items.isEmpty { return Self.headerHeight + Self.emptyHeight + Self.dropMargin }
        guard layoutMode == .icons else { return Self.headerHeight + CGFloat(items.count) * Self.rowPitch - 2 + Self.dropMargin }
        let lines = (items.count + Self.columns - 1) / Self.columns
        return Self.headerHeight + CGFloat(lines) * (Self.tileHeight + Self.tileGap) - Self.tileGap + Self.dropMargin
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        heading.frame = NSRect(x: 9, y: 5, width: 120, height: 14)
        headerButton.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        chevron.frame = NSRect(x: width - 26, y: 0, width: 24, height: 24)
        emptyLabel.frame = NSRect(x: 9, y: Self.headerHeight, width: width - 18, height: Self.emptyHeight)
        divider.frame = NSRect(x: 6, y: bounds.height - 1, width: max(0, width - 12), height: 1)
        if layoutMode == .icons {
            let tileWidth = (width - Self.tileGap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
            for (index, tile) in items.enumerated() {
                let column = CGFloat(index % Self.columns), line = CGFloat(index / Self.columns)
                tile.frame = NSRect(x: column * (tileWidth + Self.tileGap), y: Self.headerHeight + line * (Self.tileHeight + Self.tileGap),
                                    width: tileWidth, height: Self.tileHeight)
            }
        } else {
            for (index, row) in items.enumerated() {
                row.frame = NSRect(x: 0, y: Self.headerHeight + CGFloat(index) * Self.rowPitch, width: width, height: Self.rowPitch - 2)
            }
        }
    }

    @objc private func toggleCollapsed() { store.toggleFavoritesCollapsed() }

    // MARK: List

    private func makeRows() -> [FavoriteItem] {
        var rows: [FavoriteItem] = []
        for (position, folder) in store.bookmarkFolders.enumerated() {
            let expanded = expandedFolders.contains(folder.id)
            let row = FavoriteItem(kind: .folder(folder.id), folderID: nil, position: position, title: folder.name,
                                   image: symbol(folder.icon), tint: palette.textSecondary,
                                   style: .row(indent: 0, chevron: expanded ? "chevron.down" : "chevron.right"), palette: palette)
            row.menu = folderMenu(folder)
            row.action = { [weak self] in self?.toggleFolder(folder.id) }
            row.setAccessibilityValue(expanded ? "Aberta" : "Fechada")
            rows.append(row)
            if expanded {
                rows += store.bookmarks(inFolder: folder.id).enumerated().map { bookmarkItem($1, position: $0, style: .row(indent: 14, chevron: nil)) }
            }
        }
        return rows + store.bookmarks(inFolder: nil).enumerated().map { bookmarkItem($1, position: $0, style: .row(indent: 0, chevron: nil)) }
    }

    private func bookmarkItem(_ bookmark: Bookmark, position: Int, style: FavoriteItem.Style) -> FavoriteItem {
        let favicon = store.favicon(for: bookmark)
        let item = FavoriteItem(kind: .bookmark(bookmark.id), folderID: bookmark.folderID, position: position, title: title(of: bookmark),
                                image: favicon ?? symbol("globe"), tint: favicon == nil ? palette.textMuted : nil, style: style, palette: palette)
        item.menu = bookmarkMenu(bookmark)
        item.action = { [weak self] in self?.store.openBookmark(bookmark.id) }
        return item
    }

    private func toggleFolder(_ id: UUID) {
        if expandedFolders.remove(id) == nil { expandedFolders.insert(id) }
        onExpansionChange?()
    }

    // MARK: Icons

    private func makeTiles() -> [FavoriteItem] {
        let folders = store.bookmarkFolders.enumerated().map { position, folder in
            let mosaic = mosaic(of: folder)
            let tile = FavoriteItem(kind: .folder(folder.id), folderID: nil, position: position, title: folder.name,
                                    image: mosaic ?? symbol(folder.icon), tint: mosaic == nil ? palette.textSecondary : nil, style: .tile, palette: palette)
            tile.menu = folderMenu(folder)
            tile.action = { [weak self, weak tile] in if let tile { self?.showFolderContents(folder, from: tile) } }
            return tile
        }
        let bookmarks = store.bookmarks(inFolder: nil).enumerated().map { bookmarkItem($1, position: $0, style: .tile) }
        return folders + bookmarks
    }

    /// The folder's first four favicons in a 2 by 2 grid, the size of one favicon. Free cells, and favorites
    /// without an icon, stay faint squares, so the tile still reads as a folder. Nil for an empty folder.
    private func mosaic(of folder: BookmarkFolder) -> NSImage? {
        let favicons = store.bookmarks(inFolder: folder.id).prefix(4).map { store.favicon(for: $0) }
        guard !favicons.isEmpty else { return nil }
        let placeholder = palette.textMuted.withAlphaComponent(0.2)
        return NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            for index in 0..<4 {
                let cell = NSRect(x: CGFloat(index % 2) * 10, y: CGFloat(index / 2) * 10, width: 8, height: 8)
                guard favicons.indices.contains(index), let favicon = favicons[index], favicon.size.width > 0, favicon.size.height > 0 else {
                    placeholder.setFill()
                    NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2).fill()
                    continue
                }
                // Fitted whole, so a favicon that is not square keeps its proportions.
                let scale = min(cell.width / favicon.size.width, cell.height / favicon.size.height)
                let size = NSSize(width: favicon.size.width * scale, height: favicon.size.height * scale)
                favicon.draw(in: NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                             hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            return true
        }
    }

    private func showFolderContents(_ folder: BookmarkFolder, from tile: NSView) {
        let menu = NSMenu()
        // The tile shows only icons, so the menu names the folder.
        menu.addItem(.sectionHeader(title: folder.name))
        let bookmarks = store.bookmarks(inFolder: folder.id)
        for bookmark in bookmarks {
            menu.addItem(menuItem(title(of: bookmark), image: sized(store.favicon(for: bookmark), 16) ?? symbol("globe")) { [weak self] in
                self?.store.openBookmark(bookmark.id)
            })
        }
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: "Pasta vazia", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        folderMenu(folder).items.forEach { item in item.menu?.removeItem(item); menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tile.bounds.height + 4), in: tile)
    }

    // MARK: Dragging

    fileprivate func beginDrag(_ item: FavoriteItem, event: NSEvent) {
        let draggingItem = NSDraggingItem(pasteboardWriter: item.kind.pasteboardItem(in: store))
        draggingItem.setDraggingFrame(item.frame, contents: item.dragImage())
        dragged = item.kind
        items.first { $0.kind == item.kind }?.alphaValue = 0.4
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragged = nil
        dropTarget = nil
        items.forEach { $0.alphaValue = 1 }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget = draggedKind(sender).flatMap { dropTarget(for: $0, at: convert(sender.draggingLocation, from: nil)) }
        return dropTarget == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let kind = draggedKind(sender), let target = dropTarget(for: kind, at: convert(sender.draggingLocation, from: nil)) else { return false }
        dropTarget = nil
        switch (kind, target) {
        case (.bookmark(let id), .into(let folder)):
            store.moveBookmark(id, toFolder: folder)
        case (.bookmark(let id), .bookmark(let folder, let index, _)):
            FavoriteActions.placeBookmark(id, inFolder: folder, at: index, store: store)
        case (.folder(let id), .folder(let index, _)):
            FavoriteActions.placeFolder(id, at: index, store: store)
        default: return false
        }
        return true
    }

    private func draggedKind(_ sender: NSDraggingInfo) -> FavoriteItem.Kind? {
        FavoriteKind(pasteboard: sender.draggingPasteboard, in: store)
    }

    private func dropTarget(for kind: FavoriteItem.Kind, at point: NSPoint) -> DropTarget? {
        guard !items.isEmpty, point.y >= Self.headerHeight - 4 else { return nil }
        return layoutMode == .icons ? gridTarget(for: kind, at: point) : listTarget(for: kind, at: point)
    }

    /// Bookmarks go into a folder over its row and between rows elsewhere. Folders move as a block with their open contents.
    private func listTarget(for kind: FavoriteItem.Kind, at point: NSPoint) -> DropTarget? {
        guard let last = items.last else { return nil }
        // Rows are 2 points apart, so each one owns half of the gap on both sides.
        let row = items.first { point.y < $0.frame.maxY + 1 }
        switch kind {
        case .bookmark:
            guard let row else {
                return .bookmark(folder: nil, index: store.bookmarks(inFolder: nil).count, line: horizontalLine(y: last.frame.maxY + 1, indent: 0))
            }
            if case .folder(let id) = row.kind { return .into(id) }
            let below = point.y > row.frame.midY
            return .bookmark(folder: row.folderID, index: row.position + (below ? 1 : 0),
                             line: horizontalLine(y: below ? row.frame.maxY + 1 : row.frame.minY - 1, indent: row.indent))
        case .folder:
            var blocks: [(position: Int, frame: NSRect)] = []
            for item in items {
                if case .folder = item.kind { blocks.append((item.position, item.frame)) }
                else if item.folderID != nil, let block = blocks.popLast() { blocks.append((block.position, block.frame.union(item.frame))) }
            }
            guard let lastBlock = blocks.last else { return nil }
            guard let block = blocks.first(where: { point.y < $0.frame.maxY + 1 }) else {
                return .folder(index: blocks.count, line: horizontalLine(y: lastBlock.frame.maxY + 1, indent: 0))
            }
            let below = point.y > block.frame.midY
            return .folder(index: block.position + (below ? 1 : 0), line: horizontalLine(y: below ? block.frame.maxY + 1 : block.frame.minY - 1, indent: 0))
        }
    }

    /// Tiles read left to right: the pointer's half of a tile picks the side. Bookmarks go into folder tiles.
    private func gridTarget(for kind: FavoriteItem.Kind, at point: NSPoint) -> DropTarget? {
        let tile = items.first { $0.frame.insetBy(dx: -Self.tileGap / 2, dy: -Self.tileGap / 2).contains(point) }
        let after = tile.map { point.x > $0.frame.midX } ?? true
        switch kind {
        case .bookmark:
            if case .folder(let id)? = tile?.kind { return .into(id) }
            guard let tile, case .bookmark = tile.kind else {
                return .bookmark(folder: nil, index: store.bookmarks(inFolder: nil).count, line: verticalLine(after: items[items.count - 1]))
            }
            return .bookmark(folder: nil, index: tile.position + (after ? 1 : 0), line: after ? verticalLine(after: tile) : verticalLine(before: tile))
        case .folder:
            let folders = items.filter { if case .folder = $0.kind { return true }; return false }
            guard let lastFolder = folders.last else { return nil }
            guard let tile, case .folder = tile.kind else { return .folder(index: folders.count, line: verticalLine(after: lastFolder)) }
            return .folder(index: tile.position + (after ? 1 : 0), line: after ? verticalLine(after: tile) : verticalLine(before: tile))
        }
    }

    private func horizontalLine(y: CGFloat, indent: CGFloat) -> NSRect {
        NSRect(x: 6 + indent, y: y - 1, width: max(0, bounds.width - 12 - indent), height: 2)
    }

    private func verticalLine(before tile: NSView) -> NSRect { verticalLine(x: tile.frame.minX - Self.tileGap / 2, tile: tile) }
    private func verticalLine(after tile: NSView) -> NSRect { verticalLine(x: tile.frame.maxX + Self.tileGap / 2, tile: tile) }
    private func verticalLine(x: CGFloat, tile: NSView) -> NSRect {
        NSRect(x: min(max(0, x - 1), bounds.width - 2), y: tile.frame.minY + 6, width: 2, height: tile.frame.height - 12)
    }

    private func showDropTarget() {
        for item in items {
            if case .into(let id) = dropTarget { item.dropHighlighted = item.kind == .folder(id) }
            else { item.dropHighlighted = false }
        }
        dropIndicator.isHidden = dropTarget?.line == nil
        if let line = dropTarget?.line { dropIndicator.frame = line }
    }

    // MARK: Menus

    private func bookmarkMenu(_ bookmark: Bookmark) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Abrir") { [weak self] in self?.store.openBookmark(bookmark.id) })
        menu.addItem(menuItem("Abrir em nova guia") { [weak self] in self?.store.newTab(url: bookmark.url) })
        menu.addItem(.separator())
        menu.addItem(menuItem("Renomear…") { [weak self] in self?.editBookmark(bookmark.id) })
        menu.addItem(FavoriteActions.moveMenuItem(for: bookmark, store: store) { [weak self] in self?.editFolder(nil, moving: bookmark.id) })
        menu.addItem(.separator())
        menu.addItem(menuItem("Apagar favorito") { [weak self] in self?.store.removeBookmark(bookmark.id) })
        return menu
    }

    private func folderMenu(_ folder: BookmarkFolder) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Editar pasta…") { [weak self] in self?.editFolder(folder) })
        menu.addItem(.separator())
        menu.addItem(menuItem("Apagar pasta") { [weak self] in self?.store.removeBookmarkFolder(folder.id) })
        return menu
    }

    /// The favorite editor opens beside the row. Inside a folder shown as a tile, it points at the folder.
    private func editBookmark(_ id: UUID) {
        let folderID = store.bookmarks.first { $0.id == id }?.folderID
        guard let anchor = items.first(where: { $0.kind == .bookmark(id) }) ?? items.first(where: { $0.kind == folderID.map(FavoriteItem.Kind.folder) })
        else { return }
        onEditBookmark?(id, anchor.frame)
    }

    // MARK: Dialogs

    /// A new folder opens in the list, with the bookmark it was made for.
    private func editFolder(_ folder: BookmarkFolder?, moving bookmarkID: UUID? = nil) {
        guard let window else { return }
        FavoriteActions.editFolder(folder, store: store, in: window, moving: bookmarkID) { [weak self] id in self?.expandedFolders.insert(id) }
    }

    // MARK: Helpers

    private func title(of bookmark: Bookmark) -> String {
        bookmark.title.isEmpty ? URL(string: bookmark.url)?.host ?? bookmark.url : bookmark.title
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    }

    /// A resized copy: the cached favicon is shared with other views.
    private func sized(_ image: NSImage?, _ side: CGFloat) -> NSImage? {
        guard let copy = image?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: side, height: side)
        return copy
    }
}

/// A folder or bookmark in the sidebar, as a list row or an icon tile. A click runs its action and a drag moves it.
private final class FavoriteItem: LumeView {
    typealias Kind = FavoriteKind

    enum Style {
        case row(indent: CGFloat, chevron: String?)
        case tile
    }

    let kind: Kind
    /// The folder holding a bookmark. Nil for folders and for bookmarks at the top level.
    let folderID: UUID?
    /// Index among the folders, or among the bookmarks sharing the folder.
    let position: Int
    var action: (() -> Void)?
    var dropHighlighted = false { didSet { if dropHighlighted != oldValue { updateFill() } } }
    var indent: CGFloat { if case .row(let indent, _) = style { return indent }; return 0 }

    private let title: String
    private let style: Style
    private let palette: LumePalette
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let chevron = NSImageView()
    private var hovered = false { didSet { if hovered != oldValue { updateFill() } } }
    private var hoverTracking: NSTrackingArea?

    init(kind: Kind, folderID: UUID?, position: Int, title: String, image: NSImage?, tint: NSColor?, style: Style, palette: LumePalette) {
        self.kind = kind
        self.folderID = folderID
        self.position = position
        self.title = title
        self.style = style
        self.palette = palette
        var emphasized = false
        if case .folder = kind { emphasized = true }
        titleLabel = lumeLabel(title, weight: emphasized ? .medium : .regular)
        super.init(frame: .zero)
        titleLabel.textColor = emphasized ? palette.textPrimary : palette.textSecondary
        icon.image = image
        if let tint { icon.contentTintColor = tint }
        toolTip = title
        switch style {
        case .row(_, let chevronSymbol):
            cornerRadius = 7
            chevron.image = chevronSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            chevron.contentTintColor = palette.textMuted
            chevron.isHidden = chevronSymbol == nil
            for view in [icon, titleLabel, chevron] { addSubview(view) }
        case .tile:
            cornerRadius = 8
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            addSubview(icon)
        }
        updateFill()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        switch style {
        case .row(let indent, _):
            icon.frame = NSRect(x: 10 + indent, y: 8, width: 16, height: 16)
            let trailing: CGFloat = chevron.isHidden ? 8 : 26
            titleLabel.frame = NSRect(x: 31 + indent, y: 6, width: max(0, bounds.width - 31 - indent - trailing), height: 20)
            chevron.frame = NSRect(x: bounds.width - 21, y: 11, width: 10, height: 10)
        case .tile:
            icon.frame = NSRect(x: ((bounds.width - 18) / 2).rounded(), y: ((bounds.height - 18) / 2).rounded(), width: 18, height: 18)
        }
    }

    private func updateFill() {
        if dropHighlighted {
            fillColor = palette.accent.withAlphaComponent(palette.isDark ? 0.3 : 0.16)
            return
        }
        switch style {
        case .row: fillColor = .clear
        case .tile: fillColor = hovered ? palette.selection : palette.surface
        }
    }

    /// The item on an opaque fill, so the dragged copy stays legible over the page.
    func dragImage() -> NSImage {
        fillColor = palette.elevated
        defer { updateFill() }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    /// Tracks the press here, like a button does, because the sidebar can rebuild this item before the mouse goes up.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        guard let window else { return }
        let start = event.locationInWindow
        let area = convert(bounds, to: nil)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if area.contains(next.locationInWindow) { action?() }
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 {
                favoritesView?.beginDrag(self, event: next)
                return
            }
        }
    }

    private var favoritesView: FavoritesView? {
        var view = superview
        while let current = view, !(current is FavoritesView) { view = current.superview }
        return view as? FavoritesView
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        hovered = containsPointer
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return action != nil
    }
}
