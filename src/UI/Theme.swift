import AppKit

struct LumePalette {
    let background: NSColor
    let surface: NSColor
    let elevated: NSColor
    let selection: NSColor
    let separator: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textMuted: NSColor
    let accent: NSColor
    let error: NSColor
    var isDark = false
    var translucency: Translucency = .off
    var isTranslucent: Bool { translucency != .off }

    static let light = LumePalette(
        background: .lumeHex(0xF4F3F0), surface: .lumeHex(0xFAF9F7),
        elevated: .lumeHex(0xFFFFFF), selection: .lumeHex(0xE7E8EC),
        separator: .lumeHex(0xDEDFDC), textPrimary: .lumeHex(0x272A2B),
        textSecondary: .lumeHex(0x626866), textMuted: .lumeHex(0x6C726C),
        accent: .lumeHex(0x4B62AF), error: .lumeHex(0xAB3F36)
    )
    static let dark = LumePalette(
        background: .lumeHex(0x181919), surface: .lumeHex(0x202121),
        elevated: .lumeHex(0x292A2A), selection: .lumeHex(0x333538),
        separator: .lumeHex(0x343636), textPrimary: .lumeHex(0xE8EAE8),
        textSecondary: .lumeHex(0xABB0AC), textMuted: .lumeHex(0x8F9792),
        accent: .lumeHex(0x98A9E8), error: .lumeHex(0xE99185), isDark: true
    )

    /// Over the system material, opaque fills become white or black tints so the material shows through.
    static func current(for appearance: NSAppearance, translucency: Translucency = .off) -> LumePalette {
        let base: LumePalette = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        guard translucency != .off else { return base }
        let dark = base.isDark
        return LumePalette(background: base.background,
                           surface: dark ? .white.withAlphaComponent(0.07) : .white.withAlphaComponent(0.6),
                           elevated: base.elevated,
                           selection: dark ? .white.withAlphaComponent(0.11) : .white.withAlphaComponent(0.85),
                           separator: dark ? .white.withAlphaComponent(0.08) : .black.withAlphaComponent(0.07),
                           textPrimary: base.textPrimary, textSecondary: base.textSecondary, textMuted: base.textMuted,
                           accent: base.accent, error: base.error, isDark: dark, translucency: translucency)
    }

    /// Lifts the system material toward white or black, so the glass reads light instead of grey.
    /// The less tint, the more the desktop shows through.
    var glassTint: NSColor {
        let alpha: CGFloat
        switch translucency {
        case .high: alpha = isDark ? 0.05 : 0.15
        case .medium: alpha = isDark ? 0.18 : 0.4
        case .off: alpha = 1
        }
        return isDark ? .black.withAlphaComponent(alpha) : .white.withAlphaComponent(alpha)
    }
    /// Hairline around the page, drawn above the web content.
    var pageBorder: NSColor { isDark ? .white.withAlphaComponent(0.09) : .black.withAlphaComponent(0.08) }
}

/// Apple's translucent material, blurred from what is behind the window. Only app chrome sits on it.
final class LumeGlassView: NSVisualEffectView {
    private let tint = LumeView()

    init(material: NSVisualEffectView.Material, cornerRadius: CGFloat = 0) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = .behindWindow
        // Stays translucent while Settings is key, so toggling the preference shows its effect at once.
        state = .active
        autoresizingMask = [.width, .height]
        tint.cornerRadius = cornerRadius
        addSubview(tint)
        guard cornerRadius > 0 else { return }
        let edge = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        maskImage = mask
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the glass only for a translucent palette.
    func apply(_ palette: LumePalette) {
        isHidden = !palette.isTranslucent
        tint.fillColor = palette.glassTint
    }

    override func layout() {
        super.layout()
        tint.frame = bounds
    }
}

enum LumeMetrics {
    static let toolbarHeight: CGFloat = 48
    static let sidebarWidth: CGFloat = 236
    static let tabHeight: CGFloat = 36
    static let controlRadius: CGFloat = 5
    static let fieldRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
    static let pageRadius: CGFloat = 10
    /// Gap between the page card and the window edges it does not share with the sidebar.
    static let pageInset: CGFloat = 6
    /// The symbols at the end of the sidebar headings, so the chevron and the plus read as one size and weight.
    static let headingSymbol = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    /// The address field on the new tab page: the toolbar's field, larger by about the same proportion.
    static let heroFieldHeight: CGFloat = 44
    static let heroFieldRadius: CGFloat = 11
}

/// Curves shared by Lume's transitions.
enum LumeMotion {
    /// Starts at once and settles softly, for what enters or leaves.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// iOS-like drawer curve, for panels that slide.
    static let drawer = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
}

extension NSColor {
    static func lumeHex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

class LumeView: NSView {
    override var isFlipped: Bool { true }
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var onLayout: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

extension NSView {
    /// Tracking areas report only changes, so a view created under a resting pointer asks where the pointer is.
    var containsPointer: Bool {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

final class QuietButton: NSButton {
    var hoverColor: NSColor = .clear
    /// Fill shown while the pointer is elsewhere, for tiles and chosen options.
    var restingColor: NSColor = .clear { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 5
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    var actionHandler: (() -> Void)?

    convenience init(symbol: String, title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        toolTip = title
        setAccessibilityLabel(title)
        actionHandler = action
        target = self
        self.action = #selector(performAction)
    }

    @objc private func performAction() { actionHandler?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        (isEnabled && (hovered || cell?.isHighlighted == true) ? hoverColor : restingColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius).fill()
        super.draw(dirtyRect)
    }
}

func lumeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.lineBreakMode = .byTruncatingTail
    return label
}
