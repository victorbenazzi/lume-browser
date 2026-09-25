import AppKit

final class BrowserWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let store: BrowserStore
    private let root = LumeView()
    private let chromeMaterial = LumeGlassView(material: .sidebar)
    private let toolbar = LumeView()
    private let sidebar = LumeView()
    private let addressContainer = LumeView()
    private let address = NSTextField()
    private let addressIcon = NSImageView()
    private let pageShadow = NSView()
    private let pageHost = LumeView()
    /// The page's DevTools, a card of its own on the right, as the sidebar sits on the left.
    private let devToolsHost = LumeView()
    private let devToolsShadow = NSView()
    private let devToolsDivider = PanelDivider()
    private var displayedDevToolsView: NSView?
    /// The width asked for. The layout keeps both the page and DevTools usable.
    private var devToolsWidth: CGFloat = 440
    private var devToolsDragStart: CGFloat = 0
    /// The new tab page. Its bear and address field sit apart, in `newTabHero`, so they can outlive it for a moment.
    private let newTabPage = LumeView()
    /// The bear, and below it the address field itself, moved here from the toolbar while the new tab page shows.
    private let newTabHero = LumeView()
    private let newTabMark = NSImageView()
    /// Whether the address field belongs on the new tab page. While the hero sinks, the field is still there.
    private var addressInHero = false
    /// Set while Enter on the new tab page navigates, so the field leaves the page with a transition.
    private var heroExitRequested = false
    /// The hero is sinking: the field keeps its text, icon and look until it reaches the toolbar.
    private var heroExiting = false
    /// Tells a finished exit whether a newer placement replaced it.
    private var heroGeneration = 0
    private static let heroAnimationKey = "heroTransition"
    private let errorState = LumeView()
    private let errorTitle = lumeLabel("Não foi possível abrir esta página", size: 20, weight: .medium)
    private let errorDescription = NSTextField(wrappingLabelWithString: "")
    private let errorRetry = NSButton(title: "Tentar novamente", target: nil, action: nil)
    private let sidebarScroll = NSScrollView()
    /// Favorites, then the tabs, in one scrolling column.
    private let sidebarDocument = LumeView()
    private lazy var favorites = FavoritesView(store: store)
    private let tabsLabel = lumeLabel("GUIAS", size: 10, weight: .semibold)
    private let loadingLine = LumeView()
    private var tabRows: [LumeTabRow] = []
    private var palette = LumePalette.light
    private lazy var settingsPage = SettingsPage(store: store)
    private lazy var libraryPage: LibraryPage = {
        let page = LibraryPage(store: store)
        page.onOpenURL = { [weak self] url in self?.store.newTab(url: url) }
        page.onEditBookmark = { [weak self] id, rect, view in self?.showBookmarkEditor(id, isNew: false, relativeTo: rect, of: view, edge: .maxY) }
        return page
    }()
    private var bookmarkPopover: NSPopover?
    /// The click that dismisses the favorite popover also reaches the star, which must not reopen it.
    private var bookmarkPopoverClosedAt = Date.distantPast
    private lazy var findBar = FindBar(store: store)
    private let zoomButton = NSButton()
    private var presentedTabID: UUID?
    private var presentedURL: String?
    private var keyMonitor: Any?
    /// The engine page or the Lume page on the card.
    private var displayedPageView: NSView?
    private var isEditingAddress = false
    private var applyingAppearance = false
    /// Whether the page card leaves the sidebar's column free. It changes as a transition starts; the sidebar hides as one ends.
    private var sidebarOpen = true { didSet { newTabButton.isHidden = sidebarOpen } }
    /// The last visibility asked for, which an animation may still be reaching.
    private var sidebarTarget = true
    /// Tells a finished transition whether a newer one replaced it.
    private var sidebarGeneration = 0
    /// While the card narrows, the web page keeps its wider size, clipped by the card, and resizes once at the end.
    private var heldPageWidth: CGFloat?
    private static let sidebarAnimationKey = "sidebarTransition"
    /// A page in fullscreen, such as a video, fills the whole window with the app chrome hidden.
    private var contentFullscreen = false
    /// Whether the page, not the user, put the window in full screen, so leaving the page's fullscreen restores the window.
    private var windowFullScreenForContent = false
    /// AppKit ignores a full screen toggle while the window is still animating, so the window catches up once it ends.
    private var windowFullScreenTransition = false

    private lazy var backButton = QuietButton(symbol: "chevron.left", title: "Voltar (⌘[)") { [weak self] in self?.store.back() }
    private lazy var forwardButton = QuietButton(symbol: "chevron.right", title: "Avançar (⌘])") { [weak self] in self?.store.forward() }
    private lazy var reloadButton = QuietButton(symbol: "arrow.clockwise", title: "Recarregar (⌘R)") { [weak self] in
        guard let self else { return }
        self.store.activeTab?.page.status.isLoading == true ? self.store.stop() : self.store.reload()
    }
    private lazy var sidebarButton = QuietButton(symbol: "sidebar.left", title: "Alternar barra lateral (⌘⇧S)") { [weak self] in self?.store.toggleSidebar() }
    /// Shown while DevTools is open, above its panel, as the sidebar button sits above the sidebar.
    private lazy var devToolsButton = QuietButton(symbol: "sidebar.right", title: "Fechar ferramentas do desenvolvedor (⌥⌘I)") { [weak self] in self?.store.toggleDevTools() }
    /// Beside the tab heading. The toolbar copy only shows while the sidebar is hidden.
    private lazy var sidebarNewTabButton = QuietButton(symbol: "plus", title: "Nova guia (⌘T)") { [weak self] in self?.createTab() }
    private lazy var newTabButton = QuietButton(symbol: "plus", title: "Nova guia (⌘T)") { [weak self] in self?.createTab() }
    private lazy var optionsButton = QuietButton(symbol: "ellipsis.circle", title: "Opções") { [weak self] in self?.showOptionsMenu() }
    private lazy var bookmarkButton = QuietButton(symbol: "star", title: "Favoritar página (⌘D)") { [weak self] in self?.editBookmark() }
    private lazy var downloadsButton = QuietButton(symbol: "arrow.down.circle", title: "Downloads (⇧⌘J)") { [weak self] in self?.showDownloads() }

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
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LumeMainWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        devToolsWidth = CGFloat(store.settings.devToolsWidth)
        buildInterface()
        store.onChange = { [weak self] in self?.update() }
        sidebarTarget = store.settings.sidebarVisible
        showSidebar(sidebarTarget, animated: false)
        update()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func buildInterface() {
        root.addSubview(chromeMaterial)
        // Below the card, which slides over it as it closes.
        root.addSubview(sidebar)
        root.addSubview(pageShadow)
        root.addSubview(pageHost)
        root.addSubview(devToolsShadow)
        root.addSubview(devToolsHost)
        root.addSubview(devToolsDivider)
        sidebar.wantsLayer = true
        root.addSubview(toolbar)
        root.addSubview(findBar)
        // The page and DevTools are rounded cards. Clipping also rounds the web content drawn inside them.
        for (card, shadow) in [(pageHost, pageShadow), (devToolsHost, devToolsShadow)] {
            card.wantsLayer = true
            card.layer?.cornerRadius = LumeMetrics.pageRadius
            card.layer?.cornerCurve = .continuous
            card.layer?.masksToBounds = true
            shadow.wantsLayer = true
            shadow.layer?.cornerRadius = LumeMetrics.pageRadius
            shadow.layer?.cornerCurve = .continuous
            shadow.layer?.shadowOffset = .zero
            shadow.layer?.shadowRadius = 2
            shadow.layer?.shadowOpacity = 1
        }
        for view in [devToolsHost, devToolsShadow, devToolsDivider] { view.isHidden = true }
        devToolsDivider.onBegin = { [weak self] in
            guard let self else { return }
            self.devToolsDragStart = self.devToolsHost.frame.width
        }
        devToolsDivider.onDrag = { [weak self] offset in
            guard let self else { return }
            self.devToolsWidth = self.devToolsDragStart - offset
            self.layoutInterface()
        }
        devToolsDivider.onEnd = { [weak self] in
            guard let self else { return }
            self.devToolsWidth = self.devToolsHost.frame.width
            self.store.setDevToolsWidth(Double(self.devToolsWidth))
        }
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFind() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow === self.window, event.keyCode == 53 else { return event }
            // With Alloy, Esc reaches the page unless Lume ends the page's fullscreen itself.
            if self.contentFullscreen { self.store.exitFullscreen(); return nil }
            guard !self.findBar.isHidden else { return event }
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
        // A square box and a symbol drawn at its own size: favicons scale down whole, symbols are never squeezed.
        addressIcon.imageScaling = .scaleProportionallyDown
        addressIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        for button in [backButton, forwardButton, reloadButton, sidebarButton, devToolsButton, newTabButton, downloadsButton] { toolbar.addSubview(button) }
        sidebarDocument.addSubview(favorites)
        sidebarDocument.addSubview(tabsLabel)
        sidebarDocument.addSubview(sidebarNewTabButton)
        sidebarNewTabButton.symbolConfiguration = LumeMetrics.headingSymbol
        favorites.onExpansionChange = { [weak self] in self?.update() }
        favorites.onEditBookmark = { [weak self] id, rect in
            guard let self else { return }
            self.showBookmarkEditor(id, isNew: false, relativeTo: rect, of: self.favorites, edge: .maxX)
        }
        sidebarScroll.documentView = sidebarDocument
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebar.addSubview(sidebarScroll)
        sidebar.addSubview(optionsButton)
        pageHost.addSubview(newTabPage)
        pageHost.addSubview(errorState)
        for view in [errorTitle, errorDescription, errorRetry] { errorState.addSubview(view) }
        errorDescription.font = .systemFont(ofSize: 13)
        errorRetry.bezelStyle = .rounded
        errorRetry.target = self
        errorRetry.action = #selector(retryNavigation(_:))
        errorState.isHidden = true
        // Above the page and its states, so it can sink over the page that starts loading.
        pageHost.addSubview(newTabHero)
        newTabHero.wantsLayer = true
        newTabHero.isHidden = true
        newTabHero.addSubview(newTabMark)
        newTabMark.image = NSApp.applicationIconImage
        newTabMark.imageScaling = .scaleProportionallyUpOrDown
        newTabMark.setAccessibilityElement(false)
        pageHost.addSubview(loadingLine)
        root.onLayout = { [weak self] in self?.layoutInterface() }
        root.onAppearanceChange = { [weak self] in
            guard let self, !self.applyingAppearance else { return }
            self.update()
        }
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
        let internalPage = activeTab?.internalPage
        switch internalPage {
        case .settings: settingsPage.refresh()
        case .library: libraryPage.refresh()
        case nil: break
        }
        let bookmarked = store.isCurrentPageBookmarked
        bookmarkButton.image = NSImage(systemSymbolName: bookmarked ? "star.fill" : "star", accessibilityDescription: nil)
        bookmarkButton.toolTip = bookmarked ? "Editar favorito (⌘D)" : "Favoritar página (⌘D)"
        bookmarkButton.setAccessibilityLabel(bookmarkButton.toolTip)
        bookmarkButton.isEnabled = activeTab?.url.hasPrefix("https://") == true || activeTab?.url.hasPrefix("http://") == true
        bookmarkButton.contentTintColor = bookmarked ? palette.accent : palette.textMuted
        downloadsButton.isHidden = store.downloads.isEmpty
        let activeDownloads = store.downloads.filter { $0.state == .inProgress }.count
        downloadsButton.image = NSImage(systemSymbolName: activeDownloads > 0 ? "arrow.down.circle.fill" : "arrow.down.circle", accessibilityDescription: nil)
        downloadsButton.contentTintColor = activeDownloads > 0 ? palette.accent : palette.textSecondary
        downloadsButton.setAccessibilityLabel(activeDownloads > 0 ? "Downloads: \(activeDownloads) em andamento" : "Downloads")
        zoomButton.title = "\(store.zoomPercentage)%"
        zoomButton.toolTip = "Zoom da página: \(store.zoomPercentage)%"
        zoomButton.setAccessibilityValue("\(store.zoomPercentage)%")
        let isBlank = internalPage == nil && (activeTab == nil || activeTab?.url == "about:blank")
        let errorMessage = internalPage == nil ? activeTab?.page.errorMessage : nil
        // From a blank tab, the page shows as soon as an address is asked for, so its load appears in place of the new tab page.
        let leavingBlank = isBlank && store.pendingNavigationURL.map { $0 != "about:blank" } == true
        let showsNewTab = isBlank && !leavingBlank && errorMessage == nil
        placeAddress(inHero: showsNewTab && !contentFullscreen)
        zoomButton.isHidden = store.zoomPercentage == 100 || addressContainer.superview === newTabHero
        // A sinking field keeps what it showed on the new tab page.
        if !heroExiting { refreshAddress() }
        backButton.isEnabled = activeTab?.page.canGoBack ?? false
        forwardButton.isEnabled = activeTab?.page.canGoForward ?? false
        let loading = activeTab?.page.status.isLoading == true
        // A blank tab can be stopped while its first page loads.
        reloadButton.isEnabled = activeTab != nil && internalPage == nil && (activeTab?.url != "about:blank" || loading)
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Interromper" : "Recarregar")
        reloadButton.toolTip = loading ? "Interromper carregamento" : "Recarregar (⌘R)"
        reloadButton.setAccessibilityLabel(loading ? "Interromper carregamento" : "Recarregar")
        loadingLine.isHidden = !loading
        let wantsFullscreen = store.fullscreenTabID != nil && store.fullscreenTabID == store.activeTabID
        if wantsFullscreen != contentFullscreen { presentContentFullscreen(wantsFullscreen) }
        // A sidebar change made in fullscreen waits for the chrome to come back.
        if !contentFullscreen { syncSidebar() }
        favorites.refresh(palette: palette)
        tabRows.forEach { $0.removeFromSuperview() }
        tabRows = store.visibleTabs.map { tab in
            let row = LumeTabRow(tab: tab, favicon: store.favicon(for: tab), active: tab.id == store.activeTabID, palette: palette,
                                 select: { [weak self] in self?.store.selectTab(tab.id) },
                                 close: { [weak self] in self?.store.closeTab(tab.id) },
                                 pin: { [weak self] in self?.store.togglePin(tab.id) },
                                 mute: { [weak self] in self?.store.toggleMute(tab.id) })
            sidebarDocument.addSubview(row)
            return row
        }
        newTabPage.isHidden = !showsNewTab
        errorState.isHidden = errorMessage == nil
        errorDescription.stringValue = errorMessage ?? ""
        let pageView: NSView?
        switch internalPage {
        case .settings: pageView = settingsPage.view
        case .library: pageView = libraryPage.view
        case nil: pageView = isBlank && !leavingBlank ? nil : activeTab.map { store.contentView(for: $0.id) }
        }
        if displayedPageView !== pageView {
            displayedPageView?.removeFromSuperview()
            if let pageView { pageHost.addSubview(pageView, positioned: .below, relativeTo: newTabPage) }
            displayedPageView = pageView
        }
        // DevTools belongs to its tab: another tab shows its own, or none.
        let devToolsView = contentFullscreen || internalPage != nil ? nil : activeTab.flatMap { store.devToolsView(for: $0.id) }
        if displayedDevToolsView !== devToolsView {
            displayedDevToolsView?.removeFromSuperview()
            if let devToolsView { devToolsHost.addSubview(devToolsView) }
            displayedDevToolsView = devToolsView
        }
        for view in [devToolsHost, devToolsShadow, devToolsDivider, devToolsButton] { view.isHidden = devToolsView == nil }
        window?.title = activeTab.map { $0.url == "about:blank" ? "Nova guia | Lume" : $0.title.isEmpty ? "Lume" : "\($0.title) | Lume" } ?? "Lume"
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
        palette = .current(for: window.effectiveAppearance, translucency: store.settings.translucency)
        chromeMaterial.apply(palette)
        // Toolbar and sidebar share one surface, glass or opaque, so the page card reads as the only layer above it.
        root.fillColor = palette.isTranslucent ? .clear : palette.background
        for (card, shadow) in [(pageHost, pageShadow), (devToolsHost, devToolsShadow)] {
            card.fillColor = palette.elevated
            card.layer?.borderWidth = 1 / window.backingScaleFactor
            card.layer?.borderColor = palette.pageBorder.cgColor
            shadow.layer?.backgroundColor = palette.elevated.cgColor
            shadow.layer?.shadowColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.3 : 0.06).cgColor
        }
        if contentFullscreen { pageHost.layer?.borderWidth = 0 }
        newTabPage.fillColor = palette.elevated
        errorState.fillColor = palette.elevated
        window.backgroundColor = palette.background
        styleAddress()
        tabsLabel.textColor = palette.textMuted
        errorTitle.textColor = palette.textPrimary
        errorDescription.textColor = palette.textSecondary
        loadingLine.fillColor = palette.accent
        sidebarNewTabButton.contentTintColor = palette.textMuted
        sidebarNewTabButton.hoverColor = palette.selection
        sidebarNewTabButton.needsDisplay = true
        for button in [backButton, forwardButton, reloadButton, sidebarButton, devToolsButton, newTabButton, optionsButton, bookmarkButton, downloadsButton] {
            button.contentTintColor = palette.textSecondary
            button.hoverColor = palette.selection
            button.needsDisplay = true
        }
        zoomButton.contentTintColor = palette.textSecondary
        findBar.refresh(palette: palette)
        // Lume pages sit on the opaque card, so they take the opaque palette.
        let pagePalette = LumePalette.current(for: window.effectiveAppearance)
        settingsPage.apply(pagePalette)
        libraryPage.apply(pagePalette)
    }

    /// In the toolbar the field sits on the chrome; on the new tab page it floats on the card, which is always opaque.
    private func styleAddress() {
        guard let window else { return }
        let hero = addressContainer.superview === newTabHero
        // A sinking field keeps the focused look it had when Enter was pressed.
        let focused = isEditingAddress || heroExiting
        let fieldPalette = hero ? LumePalette.current(for: window.effectiveAppearance) : palette
        let radius = hero ? LumeMetrics.heroFieldRadius : LumeMetrics.fieldRadius
        addressContainer.wantsLayer = true
        addressContainer.cornerRadius = radius
        addressContainer.fillColor = focused || hero ? fieldPalette.elevated : fieldPalette.surface
        addressContainer.layer?.cornerRadius = radius
        addressContainer.layer?.borderWidth = focused ? 1.5 : hero ? 1 / window.backingScaleFactor : 0
        addressContainer.layer?.borderColor = focused ? palette.accent.withAlphaComponent(0.65).cgColor : fieldPalette.pageBorder.cgColor
        addressContainer.layer?.shadowOpacity = hero ? 1 : 0
        addressContainer.layer?.shadowOffset = .zero
        addressContainer.layer?.shadowRadius = 10
        addressContainer.layer?.shadowColor = NSColor.black.withAlphaComponent(fieldPalette.isDark ? 0.32 : 0.07).cgColor
        if !hero { addressContainer.layer?.shadowPath = nil }
        address.textColor = palette.textPrimary
        addressIcon.contentTintColor = palette.textMuted
    }

    /// The address and its icon for the page on screen.
    private func refreshAddress() {
        let activeTab = store.activeTab
        if !isEditingAddress { address.stringValue = displayedAddress }
        if addressInHero {
            addressIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        } else if let tab = activeTab, tab.internalPage == nil, let favicon = store.favicon(for: tab) {
            // The site's icon, as in its tab. Lume pages show their symbol, and pages without an icon a globe.
            addressIcon.image = favicon
        } else {
            addressIcon.image = NSImage(systemSymbolName: activeTab?.internalPage?.symbol ?? "globe", accessibilityDescription: nil)
        }
    }

    /// A blank tab shows the address it is loading, if any, until the engine commits it.
    private var displayedAddress: String {
        guard let tab = store.activeTab else { return "" }
        guard tab.url == "about:blank" else { return tab.url }
        return store.pendingNavigationURL.flatMap { $0 == "about:blank" ? nil : $0 } ?? ""
    }

    /// Moves the one address field between the toolbar and the new tab page. Enter on the new tab page sinks it there;
    /// it then appears in the toolbar. Every other move is immediate: opening a tab or switching to one happens too often to animate.
    private func placeAddress(inHero hero: Bool) {
        guard hero != addressInHero else { return }
        addressInHero = hero
        heroGeneration += 1
        let generation = heroGeneration
        let cards = [pageShadow, pageHost]
        for layer in [newTabHero.layer, addressContainer.layer] + cards.map(\.layer) { layer?.removeAnimation(forKey: Self.heroAnimationKey) }
        guard !hero, heroExitRequested, window?.isVisible == true, addressContainer.superview === newTabHero else {
            heroExiting = false
            newTabHero.isHidden = !hero
            moveAddress(to: hero ? newTabHero : toolbar)
            styleAddress()
            layoutInterface()
            return
        }
        heroExiting = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The card, risen into the empty toolbar, settles back under it, carrying the hero down as it fades.
        let cardStarts = cards.map { ($0.frame, $0.layer?.bounds ?? .zero, $0.layer?.position ?? .zero) }
        layoutInterface()
        let cardMoves = !reduceMotion && pageHost.frame.minY != cardStarts[1].0.minY
        let size = newTabHero.bounds.size
        // Down on screen, whichever way the card's layer counts y. A settling card already moves the hero down.
        let down: CGFloat = newTabHero.layer?.superlayer?.contentsAreFlipped() == false ? -1 : 1
        let drop: CGFloat = cardMoves ? 0 : 8
        // View layers are anchored at a corner, so the scale is taken about the middle.
        var sunk = CATransform3DMakeTranslation(size.width / 2, size.height / 2 + drop * down, 0)
        sunk = CATransform3DScale(sunk, 0.97, 0.97, 1)
        sunk = CATransform3DTranslate(sunk, -size.width / 2, -size.height / 2, 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let sink = CABasicAnimation(keyPath: "transform")
        sink.fromValue = CATransform3DIdentity
        sink.toValue = sunk
        let group = CAAnimationGroup()
        // Reduced motion keeps the fade and drops the movement.
        group.animations = reduceMotion ? [fade] : [fade, sink]
        group.duration = reduceMotion ? 0.12 : 0.16
        group.timingFunction = LumeMotion.easeOut
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.heroGeneration == generation else { return }
            self.heroExiting = false
            self.newTabHero.isHidden = true
            self.newTabHero.layer?.removeAnimation(forKey: Self.heroAnimationKey)
            self.moveAddress(to: self.toolbar)
            self.update()
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.12
            appear.timingFunction = LumeMotion.easeOut
            self.addressContainer.layer?.add(appear, forKey: Self.heroAnimationKey)
        }
        newTabHero.layer?.add(group, forKey: Self.heroAnimationKey)
        CATransaction.commit()
        guard cardMoves else { return }
        // Outside the hero's transaction, so the field reaches the toolbar as the hero ends, while the card still settles.
        for (card, start) in zip(cards, cardStarts) {
            guard let layer = card.layer else { continue }
            let bounds = CABasicAnimation(keyPath: "bounds")
            bounds.fromValue = NSValue(rect: start.1)
            bounds.toValue = NSValue(rect: layer.bounds)
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: start.2)
            position.toValue = NSValue(point: layer.position)
            let settle = CAAnimationGroup()
            settle.animations = [bounds, position]
            settle.duration = 0.22
            settle.timingFunction = LumeMotion.drawer
            layer.add(settle, forKey: Self.heroAnimationKey)
        }
    }

    /// The field keeps its text, focus aside, when it changes place. Its size and look follow the place.
    private func moveAddress(to parent: NSView) {
        guard addressContainer.superview !== parent else { return }
        parent.addSubview(addressContainer)
        let hero = parent === newTabHero
        address.font = .systemFont(ofSize: hero ? 17 : 13)
        addressIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: hero ? 15 : 12, weight: .regular)
        bookmarkButton.isHidden = hero
        refreshAddress()
        styleAddress()
        layoutInterface()
    }

    /// The bear and the field sit a little above the middle of the card, where the eye settles.
    private func layoutNewTabPage() {
        let bounds = pageHost.bounds
        newTabPage.frame = bounds
        // A sinking hero rides the card as it settles, instead of being centered again on the way out.
        guard !heroExiting else { return }
        let mark: CGFloat = 72
        let width = min(620, max(240, bounds.width - 96))
        let height = mark + 16 + LumeMetrics.heroFieldHeight
        newTabHero.frame = NSRect(x: round((bounds.width - width) / 2), y: max(24, round(bounds.height * 0.42 - height / 2)), width: width, height: height)
        newTabMark.frame = NSRect(x: round((width - mark) / 2), y: 0, width: mark, height: mark)
    }

    /// The page takes the whole window, and the window the whole screen unless it already has it.
    private func presentContentFullscreen(_ fullscreen: Bool) {
        contentFullscreen = fullscreen
        toolbar.isHidden = fullscreen
        sidebar.isHidden = fullscreen || !sidebarOpen
        pageShadow.isHidden = fullscreen
        pageHost.layer?.cornerRadius = fullscreen ? 0 : LumeMetrics.pageRadius
        pageHost.layer?.borderWidth = fullscreen ? 0 : 1 / (window?.backingScaleFactor ?? 2)
        if fullscreen && !findBar.isHidden {
            findBar.isHidden = true
            findBar.clear()
            DispatchQueue.main.async { [weak self] in self?.store.stopFinding() }
        }
        matchWindowFullScreen()
        layoutInterface()
    }

    /// Takes the window into full screen for the page, or back out when the page put it there.
    private func matchWindowFullScreen() {
        guard let window, !windowFullScreenTransition else { return }
        let windowIsFullScreen = window.styleMask.contains(.fullScreen)
        if contentFullscreen && !windowIsFullScreen {
            windowFullScreenForContent = true
            window.toggleFullScreen(nil)
        } else if !contentFullscreen && windowFullScreenForContent {
            windowFullScreenForContent = false
            if windowIsFullScreen { window.toggleFullScreen(nil) }
        }
    }

    private func layoutInterface() {
        let size = root.bounds.size
        let toolbarHeight = LumeMetrics.toolbarHeight
        chromeMaterial.frame = root.bounds
        if contentFullscreen {
            pageHost.frame = root.bounds
            pageShadow.frame = pageHost.frame
            displayedPageView?.autoresizingMask = []
            displayedPageView?.frame = pageHost.bounds
            newTabPage.frame = pageHost.bounds
            errorState.frame = pageHost.bounds
            loadingLine.frame = NSRect(x: 0, y: 0, width: pageHost.bounds.width, height: 2)
            return
        }
        // The sidebar keeps its width while hidden, so its contents never squeeze during a transition.
        let sidebarWidth = LumeMetrics.sidebarWidth
        toolbar.frame = NSRect(x: 0, y: 0, width: size.width, height: toolbarHeight)
        sidebar.frame = NSRect(x: 0, y: toolbarHeight, width: sidebarWidth, height: size.height - toolbarHeight)
        let findHeight: CGFloat = findBar.isHidden ? 0 : 44
        let inset = LumeMetrics.pageInset
        let pageX = max(sidebarOpen ? sidebarWidth : 0, inset)
        // DevTools takes a column on the right and leaves the page at least a narrow window's width.
        let columns = max(0, size.width - pageX - inset)
        let panelWidth = devToolsHost.isHidden ? 0 : min(max(devToolsWidth, 280), max(280, columns - inset - 360))
        let pageWidth = max(0, columns - (panelWidth > 0 ? panelWidth + inset : 0))
        findBar.frame = NSRect(x: pageX, y: toolbarHeight, width: pageWidth, height: findHeight)
        // On the new tab page the toolbar has no field, so the card rises to the top beside the sidebar,
        // which keeps the window controls. Without the sidebar the card stays under them.
        let pageTop = addressInHero && sidebarOpen ? inset : toolbarHeight + findHeight
        pageHost.frame = NSRect(x: pageX, y: pageTop, width: pageWidth, height: max(0, size.height - pageTop - inset))
        pageShadow.frame = pageHost.frame
        devToolsHost.frame = NSRect(x: size.width - inset - panelWidth, y: toolbarHeight, width: panelWidth, height: max(0, size.height - toolbarHeight - inset))
        devToolsShadow.frame = devToolsHost.frame
        // A little wider than the gap, so the edge is easy to catch.
        devToolsDivider.frame = NSRect(x: pageHost.frame.maxX - 2, y: toolbarHeight, width: inset + 4, height: devToolsHost.frame.height)
        displayedDevToolsView?.frame = devToolsHost.bounds
        let toolbarItems = [sidebarButton, backButton, forwardButton, reloadButton]
        for (index, button) in toolbarItems.enumerated() { button.frame = NSRect(x: 86 + CGFloat(index) * 30, y: 10, width: 28, height: 28) }
        // The address field starts at the page's left edge, after the navigation buttons.
        let addressX = max(216, pageX)
        // Trailing buttons line up from the right edge, skipping hidden ones.
        var trailingX = size.width - 38
        var buttonsMinX = CGFloat.greatestFiniteMagnitude
        for button in [devToolsButton, newTabButton, downloadsButton] where !button.isHidden {
            button.frame = NSRect(x: trailingX, y: 10, width: 28, height: 28)
            buttonsMinX = trailingX
            trailingX -= 34
        }
        layoutNewTabPage()
        if addressContainer.superview === newTabHero {
            // Larger by one proportion, with the star and zoom hidden: a blank page has neither.
            let height = LumeMetrics.heroFieldHeight
            addressContainer.frame = NSRect(x: 0, y: newTabHero.bounds.height - height, width: newTabHero.bounds.width, height: height)
            addressIcon.frame = NSRect(x: 15, y: 13, width: 18, height: 18)
            address.frame = NSRect(x: 43, y: 11, width: max(0, addressContainer.bounds.width - 59), height: 24)
        } else {
            // The field spans the page card below it, short of any button above the card. With DevTools open, the buttons sit above its panel.
            let addressMaxX = min(pageHost.frame.maxX, buttonsMinX - 10)
            addressContainer.frame = NSRect(x: addressX, y: 8, width: max(180, addressMaxX - addressX), height: 32)
            addressIcon.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
            let zoomWidth: CGFloat = zoomButton.isHidden ? 0 : 48
            address.frame = NSRect(x: 33, y: 7, width: addressContainer.bounds.width - 71 - zoomWidth, height: 20)
            bookmarkButton.frame = NSRect(x: addressContainer.bounds.width - 32, y: 2, width: 28, height: 28)
            zoomButton.frame = NSRect(x: addressContainer.bounds.width - 82, y: 5, width: 46, height: 23)
        }
        if addressContainer.layer?.shadowOpacity ?? 0 > 0 {
            let radius = LumeMetrics.heroFieldRadius
            addressContainer.layer?.shadowPath = CGPath(roundedRect: addressContainer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        sidebarScroll.frame = NSRect(x: 8, y: 10, width: max(0, sidebarWidth - 16), height: max(0, sidebar.bounds.height - 60))
        let docWidth = max(0, sidebarWidth - 16)
        favorites.frame = NSRect(x: 0, y: 7, width: docWidth, height: favorites.height(forWidth: docWidth))
        tabsLabel.frame = NSRect(x: 9, y: favorites.frame.maxY + 10, width: 150, height: 14)
        sidebarNewTabButton.frame = NSRect(x: docWidth - 26, y: tabsLabel.frame.minY - 5, width: 24, height: 24)
        let rowsTop = tabsLabel.frame.maxY + 10
        sidebarDocument.frame = NSRect(x: 0, y: 0, width: docWidth, height: max(sidebarScroll.bounds.height, rowsTop + CGFloat(tabRows.count) * 40))
        for (index, row) in tabRows.enumerated() {
            row.frame = NSRect(x: 0, y: rowsTop + CGFloat(index) * 40, width: docWidth, height: 36)
            row.needsLayout = true
        }
        optionsButton.frame = NSRect(x: 12, y: sidebar.bounds.height - 38, width: 28, height: 28)
        // Sized only here, so a transition can hold the web page at its earlier width.
        displayedPageView?.autoresizingMask = []
        displayedPageView?.frame = NSRect(x: 0, y: 0, width: max(heldPageWidth ?? 0, pageHost.bounds.width), height: pageHost.bounds.height)
        errorState.frame = pageHost.bounds
        let contentWidth = min(430, max(280, pageHost.bounds.width - 64))
        let centerX = (pageHost.bounds.width - contentWidth) / 2
        let centerY = max(64, pageHost.bounds.height * 0.40 - 54)
        errorTitle.frame = NSRect(x: centerX, y: centerY, width: contentWidth, height: 30)
        errorDescription.frame = NSRect(x: centerX, y: centerY + 44, width: contentWidth, height: 68)
        errorRetry.frame = NSRect(x: centerX - 5, y: centerY + 123, width: 160, height: 32)
        loadingLine.frame = NSRect(x: 0, y: 0, width: pageHost.bounds.width, height: 2)
        positionWindowControls()
    }

    /// A click animates the sidebar. The shortcut, the command palette and a window still opening switch it at once.
    private func syncSidebar() {
        let visible = store.settings.sidebarVisible
        guard visible != sidebarTarget else { return }
        sidebarTarget = visible
        showSidebar(visible, animated: window?.isVisible == true && NSApp.currentEvent?.type != .keyDown)
    }

    /// The card's edge and the sidebar move as layers, so nothing is laid out again on each frame. The web page resizes once:
    /// closing, at the start, uncovered as the card widens; opening, at the end, clipped by the narrowing card until then.
    private func showSidebar(_ visible: Bool, animated: Bool) {
        sidebarGeneration += 1
        let generation = sidebarGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let moving: [NSView] = animated && !reduceMotion ? [pageShadow, pageHost] + (findBar.isHidden ? [] : [findBar]) : []
        // A transition cut short continues from where it is on screen.
        func onScreen(_ layer: CALayer?) -> CALayer? {
            layer?.animation(forKey: Self.sidebarAnimationKey) != nil ? layer?.presentation() : nil
        }
        struct Start { let shownBounds: CGRect; let shownPosition: CGPoint }
        let starts = moving.map { view -> Start in
            let shown = onScreen(view.layer) ?? view.layer
            return Start(shownBounds: shown?.bounds ?? .zero, shownPosition: shown?.position ?? .zero)
        }
        let sidebarOnScreen = onScreen(sidebar.layer)
        let fromOpacity = sidebarOnScreen?.opacity ?? (visible ? 0 : 1)
        let fromOffset = (sidebarOnScreen?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue
        for view in [pageShadow, pageHost, findBar, sidebar] { view.layer?.removeAnimation(forKey: Self.sidebarAnimationKey) }

        sidebarOpen = visible
        if visible || !animated { sidebar.isHidden = !visible }
        heldPageWidth = visible && !moving.isEmpty && store.activeTab?.internalPage == nil ? displayedPageView?.frame.width : nil
        layoutInterface()
        guard animated else { return }

        let duration = visible ? 0.24 : 0.2
        func transition(_ animations: [CABasicAnimation]) -> CAAnimationGroup {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.timingFunction = LumeMotion.drawer
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            return group
        }
        func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            return animation
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.sidebarGeneration == generation else { return }
            if !visible { self.sidebar.isHidden = true }
            if self.heldPageWidth != nil {
                self.heldPageWidth = nil
                self.layoutInterface()
            }
            for view in [self.pageShadow, self.pageHost, self.findBar, self.sidebar] { view.layer?.removeAnimation(forKey: Self.sidebarAnimationKey) }
        }
        // The layout already set the end state on the model layers. On the new tab page the card's top moves too,
        // since the card only rises beside an open sidebar.
        for (view, start) in zip(moving, starts) {
            guard let layer = view.layer else { continue }
            layer.add(transition([basic("bounds", from: NSValue(rect: start.shownBounds), to: NSValue(rect: layer.bounds)),
                                  basic("position", from: NSValue(point: start.shownPosition), to: NSValue(point: layer.position))]),
                      forKey: Self.sidebarAnimationKey)
        }
        let offset: Double = reduceMotion ? 0 : -12
        sidebar.layer?.add(transition([basic("opacity", from: fromOpacity, to: visible ? 1 : 0),
                                       basic("transform.translation.x", from: fromOffset ?? (visible ? offset : 0), to: visible ? 0 : offset)]),
                           forKey: Self.sidebarAnimationKey)
        CATransaction.commit()
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

    func showSettings() {
        store.openInternalPage(.settings)
        window?.makeKeyAndOrderFront(nil)
    }

    func showFind() {
        guard let tab = store.activeTab, tab.url != "about:blank", tab.internalPage == nil else { return }
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
        window?.makeFirstResponder(displayedPageView ?? root)
    }

    func findNext() { if findBar.isHidden { showFind() }; findBar.findNext(forward: true) }
    func findPrevious() { if findBar.isHidden { showFind() }; findBar.findNext(forward: false) }
    func showHistory() { showLibrary(.history) }
    func showBookmarks() { showLibrary(.bookmarks) }
    func showDownloads() { showLibrary(.downloads) }
    /// Bookmarks the page if needed, then opens its editor under the star. A second press closes it.
    func editBookmark() {
        if let bookmarkPopover { bookmarkPopover.performClose(nil); return }
        guard Date().timeIntervalSince(bookmarkPopoverClosedAt) > 0.3 else { return }
        let isNew = !store.isCurrentPageBookmarked
        guard let id = store.bookmarkCurrentPage() else { return }
        window?.makeKeyAndOrderFront(nil)
        showBookmarkEditor(id, isNew: isNew, relativeTo: bookmarkButton.frame, of: addressContainer, edge: .maxY)
    }
    func zoomIn() { store.zoomIn() }
    func zoomOut() { store.zoomOut() }
    func resetZoom() { store.resetZoom() }
    func reopenClosedTab() { store.reopenClosedTab(); window?.makeKeyAndOrderFront(nil) }
    func printPage() { store.printPage() }

    private func showBookmarkEditor(_ id: UUID, isNew: Bool, relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        bookmarkPopover?.performClose(nil)
        let editor = BookmarkEditorController(store: store, bookmarkID: id, isNew: isNew, palette: palette)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.delegate = editor
        popover.appearance = window?.effectiveAppearance
        editor.popover = popover
        editor.onClose = { [weak self, weak popover] in
            guard let self, self.bookmarkPopover === popover else { return }
            self.bookmarkPopover = nil
            self.bookmarkPopoverClosedAt = Date()
        }
        bookmarkPopover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    /// Library and Settings share one button at the foot of the sidebar.
    private func showOptionsMenu() {
        let menu = NSMenu()
        for (title, symbol, selector, key) in [("Biblioteca", "books.vertical", #selector(historyAction(_:)), "y"),
                                               ("Ajustes…", "slider.horizontal.3", #selector(settingsAction(_:)), ",")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: optionsButton.frame.minX, y: optionsButton.frame.minY - menu.size.height - 4), in: sidebar)
    }

    private func showLibrary(_ section: LibraryPage.Section) {
        libraryPage.select(section)
        store.openInternalPage(.library)
        window?.makeKeyAndOrderFront(nil)
        libraryPage.focusSearch()
    }

    private func createTab() { store.newTab(); focusAddress() }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditingAddress = true; applyTheme() }
    func controlTextDidEndEditing(_ obj: Notification) { isEditingAddress = false; applyTheme() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            address.stringValue = displayedAddress
            window?.makeFirstResponder(displayedPageView ?? root)
            return true
        }
        return false
    }

    @objc private func navigateAddress(_ sender: Any?) {
        let input = address.stringValue
        // An empty Enter on the new tab page has nowhere to go, so the field stays.
        if addressInHero && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isEditingAddress = false
        heroExitRequested = true
        store.navigate(input)
        heroExitRequested = false
        window?.makeFirstResponder(displayedPageView ?? root)
        applyTheme()
    }
    @objc private func retryNavigation(_ sender: Any?) {
        if store.activeTab?.url == "about:blank" { focusAddress() }
        else { store.reload() }
    }
    @objc private func focusAddressAction(_ sender: Any?) { focusAddress() }
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
    @objc private func devToolsAction(_ sender: Any?) { store.toggleDevTools() }
    @objc private func nextTabAction(_ sender: Any?) { cycleTab(1) }
    @objc private func previousTabAction(_ sender: Any?) { cycleTab(-1) }
    @objc private func themeAction(_ sender: Any?) { store.cycleTheme() }
    @objc private func findAction(_ sender: Any?) { showFind() }
    @objc private func findNextAction(_ sender: Any?) { findNext() }
    @objc private func findPreviousAction(_ sender: Any?) { findPrevious() }
    @objc private func historyAction(_ sender: Any?) { showHistory() }
    @objc private func bookmarksAction(_ sender: Any?) { showBookmarks() }
    @objc private func downloadsAction(_ sender: Any?) { showDownloads() }
    @objc private func bookmarkAction(_ sender: Any?) { editBookmark() }
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
        if menuItem.action == #selector(toggleFullScreenAction(_:)) {
            menuItem.title = window?.styleMask.contains(.fullScreen) == true ? "Sair da tela cheia" : "Entrar em tela cheia"
            return window != nil
        }
        if menuItem.action == #selector(bookmarkAction(_:)) {
            menuItem.title = store.isCurrentPageBookmarked ? "Editar favorito…" : "Favoritar página…"
            return bookmarkButton.isEnabled
        }
        if menuItem.action == #selector(devToolsAction(_:)) {
            menuItem.title = store.showsDevTools ? "Fechar ferramentas do desenvolvedor" : "Ferramentas do desenvolvedor"
        }
        let pageActions: [Selector] = [#selector(devToolsAction(_:)), #selector(findAction(_:)), #selector(findNextAction(_:)), #selector(findPreviousAction(_:)), #selector(zoomInAction(_:)), #selector(zoomOutAction(_:)), #selector(resetZoomAction(_:)), #selector(printAction(_:))]
        if let action = menuItem.action, pageActions.contains(action) {
            return store.activeTab.map { $0.url != "about:blank" && $0.internalPage == nil } ?? false
        }
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

    func windowWillEnterFullScreen(_ notification: Notification) { windowFullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { windowFullScreenTransition = false; matchWindowFullScreen() }
    func windowDidExitFullScreen(_ notification: Notification) { windowFullScreenTransition = false; matchWindowFullScreen() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { windowFullScreenTransition = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { windowFullScreenTransition = false }

    /// Leaving full screen from the green button or the menu also ends the page's fullscreen.
    func windowWillExitFullScreen(_ notification: Notification) {
        windowFullScreenTransition = true
        // Only the user leaves while the page is in fullscreen. Lume leaves after the page already has.
        if contentFullscreen {
            windowFullScreenForContent = false
            store.exitFullscreen()
        }
    }

    @objc private func toggleFullScreenAction(_ sender: Any?) {
        if contentFullscreen { store.exitFullscreen() }
        else { window?.toggleFullScreen(sender) }
    }

    func installMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child
            menu.addItem(item)
            return child
        }
        func item(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu, shift: Bool = false, option: Bool = false, control: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            var modifiers: NSEvent.ModifierFlags = [.command]
            if shift { modifiers.insert(.shift) }
            if option { modifiers.insert(.option) }
            if control { modifiers.insert(.control) }
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
        item("Nova guia", #selector(newTabAction(_:)), "t", in: file)
        item("Reabrir guia fechada", #selector(reopenAction(_:)), "t", in: file, shift: true)
        item("Fechar guia", #selector(closeTabAction(_:)), "w", in: file)
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
        item("Alternar barra lateral", #selector(sidebarAction(_:)), "s", in: view, shift: true)
        item("Alternar tema", #selector(themeAction(_:)), "d", in: view, shift: true)
        item("Ferramentas do desenvolvedor", #selector(devToolsAction(_:)), "i", in: view, option: true)
        view.addItem(.separator())
        item("Ampliar", #selector(zoomInAction(_:)), "+", in: view)
        item("Reduzir", #selector(zoomOutAction(_:)), "-", in: view)
        item("Tamanho real", #selector(resetZoomAction(_:)), "0", in: view)
        view.addItem(.separator())
        item("Entrar em tela cheia", #selector(toggleFullScreenAction(_:)), "f", in: view, control: true)
        let library = submenu("Biblioteca")
        item("Histórico", #selector(historyAction(_:)), "y", in: library)
        item("Favoritos", #selector(bookmarksAction(_:)), "b", in: library, shift: true)
        item("Downloads", #selector(downloadsAction(_:)), "j", in: library, shift: true)
        library.addItem(.separator())
        item("Favoritar página…", #selector(bookmarkAction(_:)), "d", in: library)
        let navigation = submenu("Navegação")
        item("Voltar", #selector(backAction(_:)), "[", in: navigation)
        item("Avançar", #selector(forwardAction(_:)), "]", in: navigation)
        item("Recarregar", #selector(reloadAction(_:)), "r", in: navigation)
        navigation.addItem(.separator())
        item("Próxima guia", #selector(nextTabAction(_:)), "]", in: navigation, shift: true)
        item("Guia anterior", #selector(previousTabAction(_:)), "[", in: navigation, shift: true)
        let windows = submenu("Janela")
        windows.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Ampliar", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
}

/// The gap between the page and DevTools. Dragging it resizes the panel, as in Chrome.
private final class PanelDivider: NSView {
    var onBegin: (() -> Void)?
    /// How far the pointer moved since the drag began.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x; onBegin?() }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x - startX) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

private final class LumeTabRow: LumeView {
    private let selectionButton = NSButton()
    private let titleLabel: NSTextField
    private let icon = NSImageView()
    private let closeButton: QuietButton
    private let active: Bool
    private let select: () -> Void
    private let close: () -> Void
    private let pin: () -> Void
    private let mute: () -> Void
    private var hoverTracking: NSTrackingArea?
    /// One pointer, one hovered tab: a row that missed its exit event gives way to the next one entered.
    private static weak var hoveredRow: LumeTabRow?
    /// The close button shows only under the pointer, so resting titles use the full width.
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            if hovered {
                if Self.hoveredRow !== self { Self.hoveredRow?.hovered = false }
                Self.hoveredRow = self
            } else if Self.hoveredRow === self {
                Self.hoveredRow = nil
            }
            closeButton.isHidden = !hovered
            needsLayout = true
        }
    }

    init(tab: Tab, favicon: NSImage?, active: Bool, palette: LumePalette, select: @escaping () -> Void, close: @escaping () -> Void, pin: @escaping () -> Void, mute: @escaping () -> Void) {
        self.active = active
        self.select = select
        self.close = close
        self.pin = pin
        self.mute = mute
        titleLabel = lumeLabel(tab.title.isEmpty || tab.url == "about:blank" ? "Nova guia" : tab.title, weight: active ? .medium : .regular)
        closeButton = QuietButton(symbol: "xmark", title: "Fechar guia", action: close)
        super.init(frame: .zero)
        cornerRadius = 7
        fillColor = active ? palette.selection : .clear
        titleLabel.textColor = active ? palette.textPrimary : palette.textSecondary
        // The site icon wins over the resting states. Without one, a symbol stands in.
        if let page = tab.internalPage {
            icon.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
            icon.contentTintColor = active ? palette.textPrimary : palette.textMuted
        } else if !tab.page.status.isLoading && !tab.muted, let favicon {
            icon.image = favicon
        } else {
            let symbol = tab.page.status.isLoading ? "arrow.trianglehead.2.clockwise.rotate.90" : tab.muted ? "speaker.slash" : tab.pinned ? "pin" : tab.page.memoryState == .discarded ? "moon.zzz" : "globe"
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = active ? palette.textPrimary : palette.textMuted
        }
        selectionButton.isBordered = false
        selectionButton.title = ""
        selectionButton.target = self
        selectionButton.action = #selector(selectTab)
        let sleeping = tab.internalPage == nil && tab.page.memoryState == .discarded
        selectionButton.setAccessibilityLabel(titleLabel.stringValue + (sleeping ? ". Descartada, recarrega ao abrir" : ""))
        selectionButton.setAccessibilityValue(active ? "Guia atual" : "")
        selectionButton.toolTip = tab.url == "about:blank" ? "Nova guia" : tab.url
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = palette.textMuted
        closeButton.hoverColor = palette.isTranslucent ? palette.separator : palette.elevated
        closeButton.isHidden = true
        addSubview(selectionButton)
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(closeButton)
        let context = NSMenu()
        let pinItem = NSMenuItem(title: tab.pinned ? "Desafixar guia" : "Fixar guia", action: #selector(pinTab), keyEquivalent: "")
        pinItem.target = self
        context.addItem(pinItem)
        let muteItem = NSMenuItem(title: tab.muted ? "Ativar som da guia" : "Silenciar guia", action: #selector(muteTab), keyEquivalent: "")
        muteItem.target = self
        context.addItem(muteItem)
        context.addItem(.separator())
        let closeItem = NSMenuItem(title: "Fechar guia", action: #selector(closeTab), keyEquivalent: "")
        closeItem.target = self
        context.addItem(closeItem)
        menu = context
        selectionButton.menu = context
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        selectionButton.frame = bounds
        icon.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        titleLabel.frame = NSRect(x: 31, y: 9, width: max(0, bounds.width - (hovered ? 57 : 39)), height: 20)
        closeButton.frame = NSRect(x: bounds.width - 26, y: 8, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // Rows are rebuilt on every change, often under a resting pointer. An area added under the pointer
        // reports the exit only when told the pointer starts inside.
        let inside = containsPointer
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if inside { options.insert(.assumeInside) }
        let tracking = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        hovered = inside
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton || hit.isDescendant(of: closeButton) ? hit : selectionButton
    }

    @objc private func selectTab() { select() }
    @objc private func closeTab() { close() }
    @objc private func pinTab() { pin() }
    @objc private func muteTab() { mute() }
}
