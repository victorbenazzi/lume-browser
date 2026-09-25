import AppKit

final class BrowserWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let store: BrowserStore
    private let root = LumeView()
    private let toolbar = LumeView()
    private let sidebar = LumeView()
    private let addressContainer = LumeView()
    private let address = NSTextField()
    private let addressIcon = NSImageView()
    private let pageHost = LumeView()
    private let blankState = LumeView()
    private let blankTitle = lumeLabel("Lume", size: 30, weight: .medium)
    private let blankDescription = lumeLabel("Abra um endereço ou faça uma busca.", size: 14)
    private let blankHint = lumeLabel("⌘L  abrir endereço       ⌘K  comandos       ⌘T  nova aba", size: 11)
    private let errorState = LumeView()
    private let errorTitle = lumeLabel("Não foi possível abrir esta página", size: 20, weight: .medium)
    private let errorDescription = NSTextField(wrappingLabelWithString: "")
    private let errorRetry = NSButton(title: "Tentar novamente", target: nil, action: nil)
    private let workspacePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let workspaceLabel = lumeLabel("ESPAÇO", size: 10, weight: .semibold)
    private let tabsScroll = NSScrollView()
    private let tabsDocument = LumeView()
    private let sidebarFooter = lumeLabel("⌘K  comandos", size: 11)
    private let loadingLine = LumeView()
    private var tabRows: [LumeTabRow] = []
    private var palette = LumePalette.light
    private var paletteController: CommandPaletteController!
    private var settingsController: SettingsWindowController?
    private var libraryController: LibraryWindowController?
    private lazy var findBar = FindBar(store: store)
    private let zoomButton = NSButton()
    private var presentedTabID: UUID?
    private var presentedURL: String?
    private var keyMonitor: Any?
    private var displayedBrowserView: NSView?
    private var isEditingAddress = false
    private var applyingAppearance = false
    private var callbackInstalled = false

    private lazy var backButton = QuietButton(symbol: "chevron.left", title: "Voltar (⌘[)") { [weak self] in self?.store.back() }
    private lazy var forwardButton = QuietButton(symbol: "chevron.right", title: "Avançar (⌘])") { [weak self] in self?.store.forward() }
    private lazy var reloadButton = QuietButton(symbol: "arrow.clockwise", title: "Recarregar (⌘R)") { [weak self] in
        guard let self else { return }
        self.store.activeTab?.page.status.isLoading == true ? self.store.stop() : self.store.reload()
    }
    private lazy var sidebarButton = QuietButton(symbol: "sidebar.left", title: "Alternar barra lateral (⌘⇧S)") { [weak self] in self?.store.toggleSidebar() }
    private lazy var commandButton = QuietButton(symbol: "command", title: "Comandos (⌘K)") { [weak self] in self?.openCommandPalette() }
    private lazy var newTabButton = QuietButton(symbol: "plus", title: "Nova aba (⌘T)") { [weak self] in self?.createTab() }
    private lazy var newWorkspaceButton = QuietButton(symbol: "plus", title: "Novo espaço de trabalho") { [weak self] in self?.createWorkspace() }
    private lazy var settingsButton = QuietButton(symbol: "slider.horizontal.3", title: "Ajustes (⌘,)") { [weak self] in self?.showSettings() }
    private lazy var bookmarkButton = QuietButton(symbol: "star", title: "Favoritar página (⌘D)") { [weak self] in self?.toggleBookmark() }
    private lazy var downloadsButton = QuietButton(symbol: "arrow.down.circle", title: "Downloads (⇧⌘J)") { [weak self] in self?.showDownloads() }
    private lazy var libraryButton = QuietButton(symbol: "books.vertical", title: "Histórico e favoritos") { [weak self] in self?.showHistory() }
    private lazy var blankOpenButton = NSButton(title: "Abrir endereço", target: self, action: #selector(focusAddressAction(_:)))

    init(store: BrowserStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Lume"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LumeMainWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        paletteController = CommandPaletteController(store: store)
        buildInterface()
        installCallbacks()
        update()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func buildInterface() {
        root.addSubview(pageHost)
        root.addSubview(sidebar)
        root.addSubview(toolbar)
        root.addSubview(loadingLine)
        root.addSubview(findBar)
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFind() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow === self.window, event.keyCode == 53, !self.findBar.isHidden else { return event }
            self.hideFind()
            return nil
        }
        toolbar.addSubview(addressContainer)
        addressContainer.cornerRadius = LumeMetrics.fieldRadius
        addressContainer.addSubview(addressIcon)
        addressContainer.addSubview(address)
        addressContainer.addSubview(bookmarkButton)
        addressContainer.addSubview(zoomButton)
        zoomButton.isBordered = false
        zoomButton.font = .systemFont(ofSize: 11, weight: .medium)
        zoomButton.target = self
        zoomButton.action = #selector(showZoomMenu(_:))
        zoomButton.setAccessibilityLabel("Zoom da página")
        address.isBordered = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.font = .systemFont(ofSize: 13)
        address.placeholderString = "Buscar ou digitar um endereço"
        address.delegate = self
        address.target = self
        address.action = #selector(navigateAddress(_:))
        address.setAccessibilityLabel("Endereço e busca")
        addressIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        addressIcon.imageScaling = .scaleProportionallyDown
        for button in [backButton, forwardButton, reloadButton, sidebarButton, commandButton, newTabButton, downloadsButton] { toolbar.addSubview(button) }
        sidebar.addSubview(workspaceLabel)
        sidebar.addSubview(workspacePicker)
        sidebar.addSubview(newWorkspaceButton)
        workspacePicker.isBordered = false
        workspacePicker.font = .systemFont(ofSize: 13, weight: .medium)
        workspacePicker.target = self
        workspacePicker.action = #selector(workspaceSelected(_:))
        workspacePicker.setAccessibilityLabel("Espaço de trabalho atual")
        tabsScroll.documentView = tabsDocument
        tabsScroll.drawsBackground = false
        tabsScroll.hasVerticalScroller = true
        tabsScroll.autohidesScrollers = true
        sidebar.addSubview(tabsScroll)
        sidebar.addSubview(sidebarFooter)
        sidebar.addSubview(settingsButton)
        sidebar.addSubview(libraryButton)
        pageHost.addSubview(blankState)
        for view in [blankTitle, blankDescription, blankHint, blankOpenButton] { blankState.addSubview(view) }
        blankOpenButton.bezelStyle = .rounded
        pageHost.addSubview(errorState)
        for view in [errorTitle, errorDescription, errorRetry] { errorState.addSubview(view) }
        errorDescription.font = .systemFont(ofSize: 13)
        errorRetry.bezelStyle = .rounded
        errorRetry.target = self
        errorRetry.action = #selector(retryNavigation(_:))
        errorState.isHidden = true
        root.onLayout = { [weak self] in self?.layoutInterface() }
        root.onAppearanceChange = { [weak self] in
            guard let self, !self.applyingAppearance else { return }
            self.update()
        }
    }

    private func installCallbacks() {
        guard !callbackInstalled else { return }
        callbackInstalled = true
        store.onChange = { [weak self] in self?.update() }
        store.onFocusAddress = { [weak self] in self?.focusAddress() }
        store.onShowSettings = { [weak self] in self?.showSettings() }
        store.onCreateWorkspace = { [weak self] in self?.createWorkspace() }
        store.onShowHistory = { [weak self] in self?.showHistory() }
        store.onShowBookmarks = { [weak self] in self?.showBookmarks() }
        store.onShowDownloads = { [weak self] in self?.showDownloads() }
        store.onShowFind = { [weak self] in self?.showFind() }
    }

    private func update() {
        guard isWindowLoaded else { return }
        applyTheme()
        let activeTab = store.activeTab
        if presentedTabID != store.activeTabID || presentedURL != activeTab?.url {
            findBar.isHidden = true
            findBar.clear()
            presentedTabID = store.activeTabID
            presentedURL = activeTab?.url
        }
        findBar.refresh(palette: palette)
        if libraryController?.window?.isVisible == true { libraryController?.refresh() }
        let bookmarked = store.isCurrentPageBookmarked
        bookmarkButton.image = NSImage(systemSymbolName: bookmarked ? "star.fill" : "star", accessibilityDescription: nil)
        bookmarkButton.toolTip = bookmarked ? "Remover favorito (⌘D)" : "Favoritar página (⌘D)"
        bookmarkButton.setAccessibilityLabel(bookmarkButton.toolTip)
        bookmarkButton.isEnabled = activeTab?.url.hasPrefix("https://") == true || activeTab?.url.hasPrefix("http://") == true
        bookmarkButton.contentTintColor = bookmarked ? palette.accent : palette.textMuted
        downloadsButton.isHidden = store.downloads.isEmpty
        let activeDownloads = store.downloads.filter { $0.state == .inProgress }.count
        downloadsButton.image = NSImage(systemSymbolName: activeDownloads > 0 ? "arrow.down.circle.fill" : "arrow.down.circle", accessibilityDescription: nil)
        downloadsButton.contentTintColor = activeDownloads > 0 ? palette.accent : palette.textSecondary
        downloadsButton.setAccessibilityLabel(activeDownloads > 0 ? "Downloads: \(activeDownloads) em andamento" : "Downloads")
        zoomButton.title = "\(store.zoomPercentage)%"
        zoomButton.isHidden = store.zoomPercentage == 100
        zoomButton.toolTip = "Zoom da página: \(store.zoomPercentage)%"
        zoomButton.setAccessibilityValue("\(store.zoomPercentage)%")
        if !isEditingAddress { address.stringValue = activeTab?.url == "about:blank" ? "" : activeTab?.url ?? "" }
        backButton.isEnabled = activeTab?.page.canGoBack ?? false
        forwardButton.isEnabled = activeTab?.page.canGoForward ?? false
        reloadButton.isEnabled = activeTab != nil && activeTab?.url != "about:blank"
        let loading = activeTab?.page.status.isLoading == true
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Interromper" : "Recarregar")
        reloadButton.toolTip = loading ? "Interromper carregamento" : "Recarregar (⌘R)"
        reloadButton.setAccessibilityLabel(loading ? "Interromper carregamento" : "Recarregar")
        loadingLine.isHidden = !loading
        sidebar.isHidden = !store.settings.sidebarVisible
        workspacePicker.removeAllItems()
        workspacePicker.addItems(withTitles: store.workspaces.map(\.name))
        if let index = store.workspaces.firstIndex(where: { $0.id == store.selectedWorkspaceID }) { workspacePicker.selectItem(at: index) }
        tabRows.forEach { $0.removeFromSuperview() }
        tabRows = store.visibleTabs.map { tab in
            let row = LumeTabRow(tab: tab, active: tab.id == store.activeTabID, palette: palette,
                                 select: { [weak self] in self?.store.selectTab(tab.id) },
                                 close: { [weak self] in self?.store.closeTab(tab.id) },
                                 pin: { [weak self] in self?.store.togglePin(tab.id) },
                                 mute: { [weak self] in self?.store.toggleMute(tab.id) })
            tabsDocument.addSubview(row)
            return row
        }
        let isBlank = activeTab == nil || activeTab?.url == "about:blank"
        let errorMessage = activeTab?.page.errorMessage
        blankState.isHidden = !isBlank || errorMessage != nil
        errorState.isHidden = errorMessage == nil
        errorDescription.stringValue = errorMessage ?? ""
        if !isBlank, let id = activeTab?.id {
            let view = store.contentView(for: id)
            if displayedBrowserView !== view {
                displayedBrowserView?.removeFromSuperview()
                pageHost.addSubview(view, positioned: .below, relativeTo: blankState)
                displayedBrowserView = view
            }
        } else {
            displayedBrowserView?.removeFromSuperview()
            displayedBrowserView = nil
        }
        window?.title = activeTab.map { $0.url == "about:blank" ? "Nova aba | Lume" : $0.title.isEmpty ? "Lume" : "\($0.title) | Lume" } ?? "Lume"
        layoutInterface()
    }

    private func applyTheme() {
        guard let window, !applyingAppearance else { return }
        applyingAppearance = true
        defer { applyingAppearance = false }
        switch store.settings.theme {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
        palette = .current(for: window.effectiveAppearance)
        root.fillColor = palette.background
        toolbar.fillColor = palette.background
        sidebar.fillColor = palette.surface
        pageHost.fillColor = palette.elevated
        blankState.fillColor = palette.elevated
        errorState.fillColor = palette.elevated
        window.backgroundColor = palette.background
        addressContainer.fillColor = isEditingAddress ? palette.elevated : palette.surface
        addressContainer.wantsLayer = true
        addressContainer.layer?.cornerRadius = LumeMetrics.fieldRadius
        addressContainer.layer?.borderWidth = isEditingAddress ? 1.5 : 0
        addressContainer.layer?.borderColor = palette.accent.withAlphaComponent(0.65).cgColor
        address.textColor = palette.textPrimary
        addressIcon.contentTintColor = palette.textMuted
        workspaceLabel.textColor = palette.textMuted
        sidebarFooter.textColor = palette.textMuted
        blankTitle.textColor = palette.textPrimary
        blankDescription.textColor = palette.textSecondary
        blankHint.textColor = palette.textMuted
        errorTitle.textColor = palette.textPrimary
        errorDescription.textColor = palette.textSecondary
        loadingLine.fillColor = palette.accent
        for button in [backButton, forwardButton, reloadButton, sidebarButton, commandButton, newTabButton, newWorkspaceButton, settingsButton, bookmarkButton, downloadsButton, libraryButton] {
            button.contentTintColor = palette.textSecondary
            button.hoverColor = palette.selection
            button.needsDisplay = true
        }
        zoomButton.contentTintColor = palette.textSecondary
        findBar.refresh(palette: palette)
        settingsController?.applyTheme(appearance: window.appearance)
        libraryController?.applyTheme(appearance: window.appearance)
    }

    private func layoutInterface() {
        let size = root.bounds.size
        let toolbarHeight = LumeMetrics.toolbarHeight
        let sidebarWidth = store.settings.sidebarVisible ? LumeMetrics.sidebarWidth : 0
        toolbar.frame = NSRect(x: 0, y: 0, width: size.width, height: toolbarHeight)
        sidebar.frame = NSRect(x: 0, y: toolbarHeight, width: sidebarWidth, height: size.height - toolbarHeight)
        let findHeight: CGFloat = findBar.isHidden ? 0 : 44
        findBar.frame = NSRect(x: sidebarWidth, y: toolbarHeight, width: size.width - sidebarWidth, height: findHeight)
        pageHost.frame = NSRect(x: sidebarWidth, y: toolbarHeight + findHeight, width: max(0, size.width - sidebarWidth), height: max(0, size.height - toolbarHeight - findHeight))
        let toolbarItems = [sidebarButton, backButton, forwardButton, reloadButton]
        for (index, button) in toolbarItems.enumerated() { button.frame = NSRect(x: 86 + CGFloat(index) * 30, y: 10, width: 28, height: 28) }
        let addressX: CGFloat = 216
        addressContainer.frame = NSRect(x: addressX, y: 8, width: max(180, size.width - addressX - (downloadsButton.isHidden ? 82 : 116)), height: 32)
        addressIcon.frame = NSRect(x: 11, y: 9, width: 14, height: 14)
        let zoomWidth: CGFloat = zoomButton.isHidden ? 0 : 48
        address.frame = NSRect(x: 33, y: 7, width: addressContainer.bounds.width - 71 - zoomWidth, height: 20)
        bookmarkButton.frame = NSRect(x: addressContainer.bounds.width - 32, y: 2, width: 28, height: 28)
        zoomButton.frame = NSRect(x: addressContainer.bounds.width - 82, y: 5, width: 46, height: 23)
        downloadsButton.frame = NSRect(x: size.width - 106, y: 10, width: 28, height: 28)
        commandButton.frame = NSRect(x: size.width - 72, y: 10, width: 28, height: 28)
        newTabButton.frame = NSRect(x: size.width - 38, y: 10, width: 28, height: 28)
        workspaceLabel.frame = NSRect(x: 17, y: 22, width: 150, height: 14)
        workspacePicker.frame = NSRect(x: 12, y: 41, width: 184, height: 26)
        newWorkspaceButton.frame = NSRect(x: 198, y: 41, width: 24, height: 24)
        tabsScroll.frame = NSRect(x: 8, y: 85, width: max(0, sidebarWidth - 16), height: max(0, sidebar.bounds.height - 135))
        let docWidth = max(0, sidebarWidth - 16)
        tabsDocument.frame = NSRect(x: 0, y: 0, width: docWidth, height: max(tabsScroll.bounds.height, CGFloat(tabRows.count) * 40))
        for (index, row) in tabRows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(index) * 40, width: docWidth, height: 36); row.needsLayout = true }
        sidebarFooter.frame = NSRect(x: 17, y: sidebar.bounds.height - 31, width: 140, height: 16)
        libraryButton.frame = NSRect(x: 165, y: sidebar.bounds.height - 37, width: 28, height: 28)
        settingsButton.frame = NSRect(x: 199, y: sidebar.bounds.height - 37, width: 28, height: 28)
        displayedBrowserView?.frame = pageHost.bounds
        displayedBrowserView?.autoresizingMask = [.width, .height]
        blankState.frame = pageHost.bounds
        errorState.frame = pageHost.bounds
        let contentWidth = min(430, max(280, pageHost.bounds.width - 64))
        let centerX = (pageHost.bounds.width - contentWidth) / 2
        let centerY = max(64, pageHost.bounds.height * 0.40 - 54)
        blankTitle.frame = NSRect(x: centerX, y: centerY, width: contentWidth, height: 42)
        blankDescription.frame = NSRect(x: centerX + 1, y: centerY + 54, width: contentWidth, height: 24)
        blankOpenButton.frame = NSRect(x: centerX - 5, y: centerY + 100, width: 133, height: 32)
        blankHint.frame = NSRect(x: centerX + 1, y: centerY + 164, width: contentWidth, height: 18)
        errorTitle.frame = NSRect(x: centerX, y: centerY, width: contentWidth, height: 30)
        errorDescription.frame = NSRect(x: centerX, y: centerY + 44, width: contentWidth, height: 68)
        errorRetry.frame = NSRect(x: centerX - 5, y: centerY + 123, width: 160, height: 32)
        loadingLine.frame = NSRect(x: sidebarWidth, y: toolbarHeight - 1, width: max(0, size.width - sidebarWidth), height: 2)
        positionWindowControls()
    }

    private func positionWindowControls() {
        guard let window else { return }
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let desired = NSRect(x: 16 + CGFloat(index) * 20, y: 17, width: button.frame.width, height: button.frame.height)
            button.frame = root.convert(desired, to: parent)
        }
    }

    func focusAddress() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(address)
        address.selectText(nil)
    }

    func openCommandPalette() { if let window { paletteController.show(relativeTo: window) } }

    func showSettings() {
        if settingsController == nil { settingsController = SettingsWindowController(store: store) }
        settingsController?.applyTheme(appearance: window?.appearance)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    func showFind() {
        guard store.activeTab?.url != "about:blank" else { return }
        window?.makeKeyAndOrderFront(nil)
        findBar.isHidden = false
        findBar.repeatForCurrentPage()
        findBar.refresh(palette: palette)
        layoutInterface()
        findBar.focus()
    }

    func hideFind() {
        findBar.isHidden = true
        store.stopFinding()
        layoutInterface()
        window?.makeFirstResponder(displayedBrowserView ?? root)
    }

    func findNext() { if findBar.isHidden { showFind() }; findBar.findNext(forward: true) }
    func findPrevious() { if findBar.isHidden { showFind() }; findBar.findNext(forward: false) }
    func showHistory() { showLibrary(.history) }
    func showBookmarks() { showLibrary(.bookmarks) }
    func showDownloads() { showLibrary(.downloads) }
    func toggleBookmark() { store.toggleBookmark() }
    func zoomIn() { store.zoomIn() }
    func zoomOut() { store.zoomOut() }
    func resetZoom() { store.resetZoom() }
    func reopenClosedTab() { store.reopenClosedTab(); window?.makeKeyAndOrderFront(nil) }
    func printPage() { store.printPage() }

    private func showLibrary(_ section: LibraryWindowController.Section) {
        if libraryController == nil {
            let controller = LibraryWindowController(store: store)
            controller.onOpenURL = { [weak self] url in
                guard let self else { return }
                self.store.newTab(url: url)
                self.window?.makeKeyAndOrderFront(nil)
            }
            libraryController = controller
        }
        libraryController?.show(section: section, appearance: window?.appearance)
    }

    private func createTab() { store.newTab(); focusAddress() }

    private func createWorkspace() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Novo espaço de trabalho"
        alert.informativeText = "Organize suas abas em um espaço separado."
        alert.addButton(withTitle: "Criar espaço")
        alert.addButton(withTitle: "Cancelar")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        input.placeholderString = "Nome do espaço"
        input.setAccessibilityLabel("Nome do espaço")
        alert.accessoryView = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { self?.store.newWorkspace(name: name) }
        }
        alert.window.initialFirstResponder = input
        alert.window.makeFirstResponder(input)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditingAddress = true; applyTheme() }
    func controlTextDidEndEditing(_ obj: Notification) { isEditingAddress = false; applyTheme() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            address.stringValue = store.activeTab?.url == "about:blank" ? "" : store.activeTab?.url ?? ""
            window?.makeFirstResponder(displayedBrowserView ?? root)
            return true
        }
        return false
    }

    @objc private func navigateAddress(_ sender: Any?) {
        let input = address.stringValue
        isEditingAddress = false
        store.navigate(input)
        window?.makeFirstResponder(displayedBrowserView ?? root)
        applyTheme()
    }
    @objc private func workspaceSelected(_ sender: Any?) {
        let index = workspacePicker.indexOfSelectedItem
        if store.workspaces.indices.contains(index) { store.switchWorkspace(store.workspaces[index].id) }
    }
    @objc private func retryNavigation(_ sender: Any?) {
        if store.activeTab?.url == "about:blank" { focusAddress() }
        else { store.reload() }
    }
    @objc private func focusAddressAction(_ sender: Any?) { focusAddress() }
    @objc private func commandPaletteAction(_ sender: Any?) { openCommandPalette() }
    @objc private func newTabAction(_ sender: Any?) { createTab() }
    @objc private func closeTabAction(_ sender: Any?) {
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.performClose(sender)
            return
        }
        if let id = store.activeTabID { store.closeTab(id) }
    }
    @objc private func sidebarAction(_ sender: Any?) { store.toggleSidebar() }
    @objc private func settingsAction(_ sender: Any?) { showSettings() }
    @objc private func backAction(_ sender: Any?) { store.back() }
    @objc private func forwardAction(_ sender: Any?) { store.forward() }
    @objc private func reloadAction(_ sender: Any?) { store.reload() }
    @objc private func devToolsAction(_ sender: Any?) { store.showDevTools() }
    @objc private func nextTabAction(_ sender: Any?) { cycleTab(1) }
    @objc private func previousTabAction(_ sender: Any?) { cycleTab(-1) }
    @objc private func themeAction(_ sender: Any?) { store.cycleTheme() }
    @objc private func findAction(_ sender: Any?) { showFind() }
    @objc private func findNextAction(_ sender: Any?) { findNext() }
    @objc private func findPreviousAction(_ sender: Any?) { findPrevious() }
    @objc private func historyAction(_ sender: Any?) { showHistory() }
    @objc private func bookmarksAction(_ sender: Any?) { showBookmarks() }
    @objc private func downloadsAction(_ sender: Any?) { showDownloads() }
    @objc private func bookmarkAction(_ sender: Any?) { toggleBookmark() }
    @objc private func zoomInAction(_ sender: Any?) { zoomIn() }
    @objc private func zoomOutAction(_ sender: Any?) { zoomOut() }
    @objc private func resetZoomAction(_ sender: Any?) { resetZoom() }
    @objc private func reopenAction(_ sender: Any?) { reopenClosedTab() }
    @objc private func printAction(_ sender: Any?) { printPage() }
    @objc private func showZoomMenu(_ sender: Any?) {
        let menu = NSMenu()
        for (title, selector) in [("Ampliar", #selector(zoomInAction(_:))), ("Reduzir", #selector(zoomOutAction(_:))), ("Tamanho real (100%)", #selector(resetZoomAction(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: zoomButton.bounds.height + 3), in: zoomButton)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenAction(_:)) { return store.canReopenClosedTab }
        if menuItem.action == #selector(bookmarkAction(_:)) {
            menuItem.title = store.isCurrentPageBookmarked ? "Remover página dos favoritos" : "Favoritar página"
            return bookmarkButton.isEnabled
        }
        let pageActions: [Selector] = [#selector(findAction(_:)), #selector(findNextAction(_:)), #selector(findPreviousAction(_:)), #selector(zoomInAction(_:)), #selector(zoomOutAction(_:)), #selector(resetZoomAction(_:)), #selector(printAction(_:))]
        if let action = menuItem.action, pageActions.contains(action) { return store.activeTab != nil && store.activeTab?.url != "about:blank" }
        return true
    }
    private func cycleTab(_ offset: Int) {
        let tabs = store.visibleTabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where: { $0.id == store.activeTabID }) ?? 0
        store.selectTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.saveSession()
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) { store.saveSession() }

    func installMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child
            menu.addItem(item)
            return child
        }
        func item(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu, shift: Bool = false, option: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            var modifiers: NSEvent.ModifierFlags = [.command]
            if shift { modifiers.insert(.shift) }
            if option { modifiers.insert(.option) }
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = submenu("Lume")
        let about = NSMenuItem(title: "Sobre o Lume", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(about)
        app.addItem(.separator())
        item("Ajustes…", #selector(settingsAction(_:)), ",", in: app)
        app.addItem(.separator())
        app.addItem(withTitle: "Ocultar Lume", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Encerrar Lume", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("Arquivo")
        item("Nova aba", #selector(newTabAction(_:)), "t", in: file)
        item("Reabrir aba fechada", #selector(reopenAction(_:)), "t", in: file, shift: true)
        item("Fechar aba", #selector(closeTabAction(_:)), "w", in: file)
        item("Abrir endereço…", #selector(focusAddressAction(_:)), "l", in: file)
        file.addItem(.separator())
        item("Imprimir…", #selector(printAction(_:)), "p", in: file)
        let edit = submenu("Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        item("Buscar na página…", #selector(findAction(_:)), "f", in: edit)
        item("Próximo resultado", #selector(findNextAction(_:)), "g", in: edit)
        item("Resultado anterior", #selector(findPreviousAction(_:)), "g", in: edit, shift: true)
        let view = submenu("Visualizar")
        item("Comandos…", #selector(commandPaletteAction(_:)), "k", in: view)
        item("Alternar barra lateral", #selector(sidebarAction(_:)), "s", in: view, shift: true)
        item("Alternar tema", #selector(themeAction(_:)), "d", in: view, shift: true)
        item("Ferramentas do desenvolvedor", #selector(devToolsAction(_:)), "i", in: view, option: true)
        view.addItem(.separator())
        item("Ampliar", #selector(zoomInAction(_:)), "+", in: view)
        item("Reduzir", #selector(zoomOutAction(_:)), "-", in: view)
        item("Tamanho real", #selector(resetZoomAction(_:)), "0", in: view)
        let library = submenu("Biblioteca")
        item("Histórico", #selector(historyAction(_:)), "y", in: library)
        item("Favoritos", #selector(bookmarksAction(_:)), "b", in: library, shift: true)
        item("Downloads", #selector(downloadsAction(_:)), "j", in: library, shift: true)
        library.addItem(.separator())
        item("Favoritar página", #selector(bookmarkAction(_:)), "d", in: library)
        let navigation = submenu("Navegação")
        item("Voltar", #selector(backAction(_:)), "[", in: navigation)
        item("Avançar", #selector(forwardAction(_:)), "]", in: navigation)
        item("Recarregar", #selector(reloadAction(_:)), "r", in: navigation)
        navigation.addItem(.separator())
        item("Próxima aba", #selector(nextTabAction(_:)), "]", in: navigation, shift: true)
        item("Aba anterior", #selector(previousTabAction(_:)), "[", in: navigation, shift: true)
        let windows = submenu("Janela")
        windows.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Ampliar", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
}

private final class LumeTabRow: LumeView {
    private let selectionButton = NSButton()
    private let titleLabel: NSTextField
    private let icon = NSImageView()
    private let marker = LumeView()
    private let closeButton: QuietButton
    private let active: Bool
    private let select: () -> Void
    private let pin: () -> Void
    private let mute: () -> Void

    init(tab: Tab, active: Bool, palette: LumePalette, select: @escaping () -> Void, close: @escaping () -> Void, pin: @escaping () -> Void, mute: @escaping () -> Void) {
        self.active = active
        self.select = select
        self.pin = pin
        self.mute = mute
        titleLabel = lumeLabel(tab.title.isEmpty || tab.url == "about:blank" ? "Nova aba" : tab.title, weight: active ? .medium : .regular)
        closeButton = QuietButton(symbol: "xmark", title: "Fechar aba", action: close)
        super.init(frame: .zero)
        cornerRadius = 7
        fillColor = active ? palette.selection : .clear
        titleLabel.textColor = active ? palette.textPrimary : palette.textSecondary
        let symbol = tab.page.status.isLoading ? "arrow.trianglehead.2.clockwise.rotate.90" : tab.muted ? "speaker.slash" : tab.pinned ? "pin" : tab.page.memoryState == .discarded ? "moon.zzz" : "globe"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = active ? palette.textPrimary : palette.textMuted
        marker.fillColor = palette.accent
        marker.cornerRadius = 1
        marker.isHidden = !active
        selectionButton.isBordered = false
        selectionButton.title = ""
        selectionButton.target = self
        selectionButton.action = #selector(selectTab)
        selectionButton.setAccessibilityLabel(titleLabel.stringValue + (tab.page.memoryState == .discarded ? ". Descartada, recarrega ao abrir" : ""))
        selectionButton.setAccessibilityValue(active ? "Aba atual" : "")
        selectionButton.toolTip = tab.url == "about:blank" ? "Nova aba" : tab.url
        closeButton.contentTintColor = palette.textMuted
        closeButton.hoverColor = palette.elevated
        addSubview(selectionButton)
        addSubview(marker)
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(closeButton)
        let context = NSMenu()
        let pinItem = NSMenuItem(title: tab.pinned ? "Desafixar aba" : "Fixar aba", action: #selector(pinTab), keyEquivalent: "")
        pinItem.target = self
        context.addItem(pinItem)
        let muteItem = NSMenuItem(title: tab.muted ? "Ativar som da aba" : "Silenciar aba", action: #selector(muteTab), keyEquivalent: "")
        muteItem.target = self
        context.addItem(muteItem)
        menu = context
        selectionButton.menu = context
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        selectionButton.frame = bounds
        marker.frame = NSRect(x: 1, y: 12, width: 2, height: 12)
        icon.frame = NSRect(x: 12, y: 11, width: 14, height: 14)
        titleLabel.frame = NSRect(x: 35, y: 9, width: max(0, bounds.width - 65), height: 20)
        closeButton.frame = NSRect(x: bounds.width - 28, y: 7, width: 23, height: 23)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton || hit.isDescendant(of: closeButton) ? hit : selectionButton
    }

    @objc private func selectTab() { select() }
    @objc private func pinTab() { pin() }
    @objc private func muteTab() { mute() }
}
