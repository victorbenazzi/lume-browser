import AppKit

final class SettingsWindowController: NSWindowController {
    private let store: BrowserStore
    private let root = LumeView()
    private let heading = lumeLabel("Ajustes", size: 24, weight: .medium)
    private let appearanceHeading = lumeLabel("Aparência", size: 13, weight: .semibold)
    private let theme = NSSegmentedControl(labels: ["Sistema", "Claro", "Escuro"], trackingMode: .selectOne, target: nil, action: nil)
    private let sidebarToggle = NSButton(checkboxWithTitle: "Mostrar barra lateral", target: nil, action: nil)
    private let performanceHeading = lumeLabel("Memória das abas", size: 13, weight: .semibold)
    private let automaticToggle = NSButton(checkboxWithTitle: "Descartar abas inativas automaticamente", target: nil, action: nil)
    private let pinnedToggle = NSButton(checkboxWithTitle: "Manter abas fixadas carregadas", target: nil, action: nil)
    private let limitLabel = lumeLabel("Abas mantidas em memória", size: 12)
    private let minutesLabel = lumeLabel("Descartar após (minutos)", size: 12)
    private let limitField = NSTextField()
    private let minutesField = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "Abas descartadas recarregam ao abrir e podem perder formulários não salvos. A proteção de áudio e o congelamento de timers ainda não estão disponíveis.")
    private let discardButton = NSButton(title: "Descartar abas inativas…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var statusHeight: CGFloat = 30

    init(store: BrowserStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 512), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ajustes do Lume"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = root
        for view in [heading, appearanceHeading, theme, sidebarToggle, performanceHeading, automaticToggle, pinnedToggle, limitLabel, minutesLabel, limitField, minutesField, note, discardButton, status] { root.addSubview(view) }
        theme.target = self
        theme.action = #selector(changeTheme)
        sidebarToggle.target = self
        sidebarToggle.action = #selector(changeSidebar)
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
        limitField.setAccessibilityLabel("Limite de abas em memória")
        minutesField.setAccessibilityLabel("Minutos até descarte")
        note.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 11)
        discardButton.bezelStyle = .rounded
        discardButton.target = self
        discardButton.action = #selector(discardTabs)
        root.onLayout = { [weak self] in self?.layout() }
        refreshControls()
        applyTheme(appearance: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        super.showWindow(sender)
    }

    func applyTheme(appearance: NSAppearance?) {
        window?.appearance = appearance
        guard let window else { return }
        let palette = LumePalette.current(for: window.effectiveAppearance)
        root.fillColor = palette.background
        window.backgroundColor = palette.background
        for label in [heading, appearanceHeading, performanceHeading, limitLabel, minutesLabel] { label.textColor = palette.textPrimary }
        note.textColor = palette.textSecondary
        status.textColor = store.persistenceError == nil ? palette.textMuted : palette.error
        updateStatus()
    }

    private func refreshControls() {
        theme.selectedSegment = ThemeMode.allCases.firstIndex(of: store.settings.theme) ?? 0
        sidebarToggle.state = store.settings.sidebarVisible ? .on : .off
        let policy = store.settings.memoryPolicy
        automaticToggle.state = policy.automaticDiscardEnabled ? .on : .off
        pinnedToggle.state = policy.keepPinnedTabsAlive ? .on : .off
        limitField.integerValue = policy.warmTabLimit
        minutesField.integerValue = policy.discardAfterMinutes
        updateStatus()
    }

    private func updateStatus() {
        status.stringValue = store.persistenceError.map { "Não foi possível salvar as preferências: \($0)" }
            ?? store.persistenceRecoveryMessage
            ?? "Preferências salvas neste Mac."
        status.toolTip = status.stringValue
        let bounds = (status.stringValue as NSString).boundingRect(
            with: NSSize(width: 484, height: 160), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: status.font ?? NSFont.systemFont(ofSize: 11)])
        statusHeight = max(30, ceil(bounds.height) + 4)
        let contentHeight = max(512, 477 + statusHeight + 12)
        if window?.contentView?.bounds.height != contentHeight {
            window?.setContentSize(NSSize(width: 540, height: contentHeight))
        }
        status.frame = NSRect(x: 28, y: 477, width: 484, height: statusHeight)
    }

    private func layout() {
        heading.frame = NSRect(x: 28, y: 24, width: 484, height: 34)
        appearanceHeading.frame = NSRect(x: 28, y: 81, width: 180, height: 20)
        theme.frame = NSRect(x: 242, y: 77, width: 270, height: 28)
        sidebarToggle.frame = NSRect(x: 26, y: 118, width: 380, height: 24)
        performanceHeading.frame = NSRect(x: 28, y: 182, width: 300, height: 20)
        automaticToggle.frame = NSRect(x: 26, y: 217, width: 480, height: 24)
        limitLabel.frame = NSRect(x: 28, y: 255, width: 360, height: 20)
        limitField.frame = NSRect(x: 440, y: 252, width: 70, height: 24)
        minutesLabel.frame = NSRect(x: 28, y: 289, width: 360, height: 20)
        minutesField.frame = NSRect(x: 440, y: 286, width: 70, height: 24)
        pinnedToggle.frame = NSRect(x: 26, y: 323, width: 480, height: 24)
        note.frame = NSRect(x: 28, y: 358, width: 484, height: 60)
        discardButton.frame = NSRect(x: 22, y: 428, width: 210, height: 32)
        status.frame = NSRect(x: 28, y: 477, width: 484, height: statusHeight)
    }

    @objc private func changeTheme() {
        guard ThemeMode.allCases.indices.contains(theme.selectedSegment) else { return }
        store.setTheme(ThemeMode.allCases[theme.selectedSegment])
    }
    @objc private func changeSidebar() {
        if (sidebarToggle.state == .on) != store.settings.sidebarVisible { store.toggleSidebar() }
    }
    @objc private func changePolicy() {
        var policy = store.settings.memoryPolicy
        policy.warmTabLimit = max(1, limitField.integerValue)
        policy.discardAfterMinutes = max(1, minutesField.integerValue)
        policy.keepPinnedTabsAlive = pinnedToggle.state == .on
        policy.automaticDiscardEnabled = automaticToggle.state == .on
        store.updateMemoryPolicy(policy)
        refreshControls()
    }
    @objc private func discardTabs() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Descartar abas inativas?"
        alert.informativeText = "As páginas recarregam quando você voltar. Formulários não salvos e outros dados temporários podem ser perdidos. A aba atual e as abas fixadas protegidas serão mantidas."
        alert.addButton(withTitle: "Descartar abas")
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.discardInactiveTabs()
            self?.status.stringValue = "Descarte solicitado. Abas elegíveis recarregam ao abrir."
        }
    }
}
