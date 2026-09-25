import AppKit

/// Lume's settings, drawn on the page card of their own tab.
final class SettingsPage: NSObject {
    let view = LumeView()
    private let store: BrowserStore
    private let scroll = NSScrollView()
    private let document = LumeView()
    /// A fixed column, centered on wide pages.
    private let content = LumeView()
    private let heading = lumeLabel("Ajustes", size: 24, weight: .medium)
    private let appearanceHeading = lumeLabel("Aparência", size: 13, weight: .semibold)
    private let theme = NSSegmentedControl(labels: ["Sistema", "Claro", "Escuro"], trackingMode: .selectOne, target: nil, action: nil)
    private let sidebarToggle = NSButton(checkboxWithTitle: "Mostrar barra lateral", target: nil, action: nil)
    private let translucencyLabel = lumeLabel("Transparência", size: 13)
    private let translucency = NSSegmentedControl(labels: ["Alta", "Média", "Desligada"], trackingMode: .selectOne, target: nil, action: nil)
    private let favoritesLabel = lumeLabel("Favoritos na barra lateral", size: 13)
    private let favoritesLayout = NSSegmentedControl(labels: ["Lista", "Blocos"], trackingMode: .selectOne, target: nil, action: nil)
    private let performanceHeading = lumeLabel("Memória das guias", size: 13, weight: .semibold)
    private let automaticToggle = NSButton(checkboxWithTitle: "Descartar guias inativas automaticamente", target: nil, action: nil)
    private let pinnedToggle = NSButton(checkboxWithTitle: "Manter guias fixadas carregadas", target: nil, action: nil)
    private let limitLabel = lumeLabel("Guias mantidas em memória", size: 12)
    private let minutesLabel = lumeLabel("Descartar após (minutos)", size: 12)
    private let limitField = NSTextField()
    private let minutesField = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "Guias descartadas recarregam ao abrir e podem perder formulários não salvos. A proteção de áudio e o congelamento de timers ainda não estão disponíveis.")
    private let discardButton = NSButton(title: "Descartar guias inativas…", target: nil, action: nil)
    private let permissionsHeading = lumeLabel("Permissões dos sites", size: 13, weight: .semibold)
    private let permissionsNote = NSTextField(wrappingLabelWithString: "Respostas que você pediu para lembrar. Ao esquecer uma, o site volta a perguntar. Notificações ficam sempre desligadas.")
    private let forgetAllButton = NSButton(title: "Esquecer todas…", target: nil, action: nil)
    /// One row per remembered decision, rebuilt whenever the settings change.
    private var permissionRows: [NSView] = []
    private var shownPermissions: [SitePermissionDecision] = []
    private var permissionsBottom: CGFloat = 0
    private let status = NSTextField(wrappingLabelWithString: "")
    private var statusHeight: CGFloat = 30
    /// A result shown in place of the saved state until the next setting changes.
    private var notice: String?
    private var palette = LumePalette.light

    private static let columnWidth: CGFloat = 540
    private static let topInset: CGFloat = 24

    init(store: BrowserStore) {
        self.store = store
        super.init()
        view.addSubview(scroll)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        document.addSubview(content)
        for control in [heading, appearanceHeading, theme, sidebarToggle, translucencyLabel, translucency, favoritesLabel, favoritesLayout, performanceHeading, automaticToggle, pinnedToggle, limitLabel, minutesLabel, limitField, minutesField, note, discardButton, permissionsHeading, permissionsNote, forgetAllButton, status] { content.addSubview(control) }
        permissionsNote.font = .systemFont(ofSize: 12)
        forgetAllButton.bezelStyle = .rounded
        forgetAllButton.target = self
        forgetAllButton.action = #selector(forgetAllPermissions)
        theme.target = self
        theme.action = #selector(changeTheme)
        sidebarToggle.target = self
        sidebarToggle.action = #selector(changeSidebar)
        translucency.target = self
        translucency.action = #selector(changeTranslucency)
        translucency.toolTip = "Barras e painéis usam o material translúcido do macOS. O conteúdo das páginas não muda."
        translucency.setAccessibilityLabel("Transparência na interface")
        favoritesLayout.target = self
        favoritesLayout.action = #selector(changeFavoritesLayout)
        favoritesLayout.setAccessibilityLabel("Favoritos na barra lateral")
        automaticToggle.target = self
        automaticToggle.action = #selector(changePolicy)
        pinnedToggle.target = self
        pinnedToggle.action = #selector(changePolicy)
        for field in [limitField, minutesField] {
            field.alignment = .right
            field.font = .systemFont(ofSize: 12)
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 1
            formatter.maximum = field === limitField ? 100 : 10080
            formatter.allowsFloats = false
            field.formatter = formatter
            field.target = self
            field.action = #selector(changePolicy)
        }
        limitField.setAccessibilityLabel("Limite de guias em memória")
        minutesField.setAccessibilityLabel("Minutos até descarte")
        note.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 11)
        discardButton.bezelStyle = .rounded
        discardButton.target = self
        discardButton.action = #selector(discardTabs)
        layoutContent()
        view.onLayout = { [weak self] in self?.layout() }
        refresh()
    }

    /// Reads the stored settings into the controls. A number being typed is left alone.
    func refresh() {
        theme.selectedSegment = ThemeMode.allCases.firstIndex(of: store.settings.theme) ?? 0
        sidebarToggle.state = store.settings.sidebarVisible ? .on : .off
        translucency.selectedSegment = Translucency.allCases.firstIndex(of: store.settings.translucency) ?? 1
        favoritesLayout.selectedSegment = FavoritesLayout.allCases.firstIndex(of: store.settings.favoritesLayout) ?? 0
        let policy = store.settings.memoryPolicy
        automaticToggle.state = policy.automaticDiscardEnabled ? .on : .off
        pinnedToggle.state = policy.keepPinnedTabsAlive ? .on : .off
        if limitField.currentEditor() == nil { limitField.integerValue = policy.warmTabLimit }
        if minutesField.currentEditor() == nil { minutesField.integerValue = policy.discardAfterMinutes }
        rebuildPermissions()
        updateStatus()
    }

    func apply(_ palette: LumePalette) {
        self.palette = palette
        view.fillColor = palette.elevated
        for label in [heading, appearanceHeading, translucencyLabel, favoritesLabel, performanceHeading, limitLabel, minutesLabel, permissionsHeading] { label.textColor = palette.textPrimary }
        note.textColor = palette.textSecondary
        permissionsNote.textColor = palette.textSecondary
        status.textColor = store.persistenceError == nil ? palette.textMuted : palette.error
        rebuildPermissions()
    }

    /// Lists each remembered decision with a button that forgets it.
    private func rebuildPermissions() {
        permissionRows.forEach { $0.removeFromSuperview() }
        shownPermissions = store.sitePermissions
        var y = permissionsNote.frame.maxY + 8
        if shownPermissions.isEmpty {
            let empty = lumeLabel("Nenhuma resposta lembrada.", size: 12)
            empty.textColor = palette.textMuted
            empty.frame = NSRect(x: 28, y: y, width: 484, height: 20)
            permissionRows = [empty]
            y += 28
        } else {
            permissionRows = shownPermissions.enumerated().flatMap { index, decision -> [NSView] in
                let site = decision.origin.hasPrefix("https://") ? String(decision.origin.dropFirst("https://".count)) : decision.origin
                let label = lumeLabel(site, size: 12, weight: .medium)
                label.textColor = palette.textPrimary
                label.toolTip = decision.origin
                label.frame = NSRect(x: 28, y: y + 4, width: 190, height: 18)
                let state = lumeLabel("\(decision.permission.title): \(decision.allowed ? "permitido" : "bloqueado")", size: 12)
                state.textColor = palette.textSecondary
                state.toolTip = state.stringValue
                state.frame = NSRect(x: 224, y: y + 4, width: 204, height: 18)
                let forget = NSButton(title: "Esquecer", target: self, action: #selector(forgetPermission(_:)))
                forget.bezelStyle = .rounded
                forget.controlSize = .small
                forget.font = .systemFont(ofSize: 11)
                forget.tag = index
                forget.setAccessibilityLabel("Esquecer \(decision.permission.title) para \(site)")
                forget.frame = NSRect(x: 436, y: y, width: 76, height: 24)
                y += 30
                return [label, state, forget]
            }
        }
        permissionRows.forEach { content.addSubview($0) }
        forgetAllButton.isHidden = shownPermissions.isEmpty
        forgetAllButton.frame = NSRect(x: 22, y: y + 2, width: 150, height: 32)
        permissionsBottom = shownPermissions.isEmpty ? y : y + 40
        view.needsLayout = true
    }

    private func updateStatus() {
        status.stringValue = store.persistenceError.map { "Não foi possível salvar as preferências: \($0)" }
            ?? notice
            ?? store.persistenceRecoveryMessage
            ?? "Preferências salvas neste Mac."
        status.toolTip = status.stringValue
        status.textColor = store.persistenceError == nil ? palette.textMuted : palette.error
        let bounds = (status.stringValue as NSString).boundingRect(
            with: NSSize(width: 484, height: 160), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: status.font ?? NSFont.systemFont(ofSize: 11)])
        statusHeight = max(30, ceil(bounds.height) + 4)
        status.frame = NSRect(x: 28, y: statusY, width: 484, height: statusHeight)
        view.needsLayout = true
    }

    private var statusY: CGFloat { permissionsBottom + 12 }
    private var contentHeight: CGFloat { statusY + statusHeight + 12 }

    private func layout() {
        scroll.frame = view.bounds
        let width = scroll.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, contentHeight + Self.topInset * 2))
        content.frame = NSRect(x: max(0, ((width - Self.columnWidth) / 2).rounded()), y: Self.topInset, width: Self.columnWidth, height: contentHeight)
    }

    private func layoutContent() {
        heading.frame = NSRect(x: 28, y: 24, width: 484, height: 34)
        appearanceHeading.frame = NSRect(x: 28, y: 81, width: 180, height: 20)
        theme.frame = NSRect(x: 242, y: 77, width: 270, height: 28)
        sidebarToggle.frame = NSRect(x: 26, y: 118, width: 380, height: 24)
        translucencyLabel.frame = NSRect(x: 28, y: 156, width: 200, height: 20)
        translucency.frame = NSRect(x: 242, y: 152, width: 270, height: 28)
        favoritesLabel.frame = NSRect(x: 28, y: 196, width: 300, height: 20)
        favoritesLayout.frame = NSRect(x: 342, y: 192, width: 170, height: 28)
        performanceHeading.frame = NSRect(x: 28, y: 252, width: 300, height: 20)
        automaticToggle.frame = NSRect(x: 26, y: 287, width: 480, height: 24)
        limitLabel.frame = NSRect(x: 28, y: 325, width: 360, height: 20)
        limitField.frame = NSRect(x: 440, y: 322, width: 70, height: 24)
        minutesLabel.frame = NSRect(x: 28, y: 359, width: 360, height: 20)
        minutesField.frame = NSRect(x: 440, y: 356, width: 70, height: 24)
        pinnedToggle.frame = NSRect(x: 26, y: 393, width: 480, height: 24)
        note.frame = NSRect(x: 28, y: 428, width: 484, height: 60)
        discardButton.frame = NSRect(x: 22, y: 498, width: 210, height: 32)
        permissionsHeading.frame = NSRect(x: 28, y: 560, width: 300, height: 20)
        permissionsNote.frame = NSRect(x: 28, y: 586, width: 484, height: 34)
        status.frame = NSRect(x: 28, y: statusY, width: 484, height: statusHeight)
    }

    @objc private func changeTheme() {
        notice = nil
        guard ThemeMode.allCases.indices.contains(theme.selectedSegment) else { return }
        store.setTheme(ThemeMode.allCases[theme.selectedSegment])
    }
    @objc private func changeSidebar() {
        notice = nil
        if (sidebarToggle.state == .on) != store.settings.sidebarVisible { store.toggleSidebar() }
    }
    @objc private func changeTranslucency() {
        notice = nil
        guard Translucency.allCases.indices.contains(translucency.selectedSegment) else { return }
        store.setTranslucency(Translucency.allCases[translucency.selectedSegment])
    }
    @objc private func changeFavoritesLayout() {
        notice = nil
        guard FavoritesLayout.allCases.indices.contains(favoritesLayout.selectedSegment) else { return }
        store.setFavoritesLayout(FavoritesLayout.allCases[favoritesLayout.selectedSegment])
    }
    @objc private func changePolicy() {
        notice = nil
        var policy = store.settings.memoryPolicy
        policy.warmTabLimit = max(1, limitField.integerValue)
        policy.discardAfterMinutes = max(1, minutesField.integerValue)
        policy.keepPinnedTabsAlive = pinnedToggle.state == .on
        policy.automaticDiscardEnabled = automaticToggle.state == .on
        store.updateMemoryPolicy(policy)
        limitField.integerValue = store.settings.memoryPolicy.warmTabLimit
        minutesField.integerValue = store.settings.memoryPolicy.discardAfterMinutes
        refresh()
    }
    @objc private func forgetPermission(_ sender: NSButton) {
        guard shownPermissions.indices.contains(sender.tag) else { return }
        let decision = shownPermissions[sender.tag]
        notice = nil
        store.forgetPermission(origin: decision.origin, permission: decision.permission)
    }
    @objc private func forgetAllPermissions() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Esquecer todas as permissões?"
        alert.informativeText = "Os sites voltam a perguntar antes de usar câmera, microfone, localização e os outros recursos."
        alert.addButton(withTitle: "Esquecer todas")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.notice = nil
            self?.store.forgetAllPermissions()
        }
    }
    @objc private func discardTabs() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Descartar guias inativas?"
        alert.informativeText = "As páginas recarregam quando você voltar. Formulários não salvos e outros dados temporários podem ser perdidos. A guia atual e as guias fixadas protegidas serão mantidas."
        alert.addButton(withTitle: "Descartar guias")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.notice = "Descarte solicitado. Guias elegíveis recarregam ao abrir."
            self?.store.discardInactiveTabs()
            self?.updateStatus()
        }
    }
}
