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
        accent: .lumeHex(0x98A9E8), error: .lumeHex(0xE99185)
    )

    static func current(for appearance: NSAppearance) -> LumePalette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

enum LumeMetrics {
    static let toolbarHeight: CGFloat = 48
    static let sidebarWidth: CGFloat = 236
    static let tabHeight: CGFloat = 36
    static let controlRadius: CGFloat = 5
    static let fieldRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
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

final class QuietButton: NSButton {
    var hoverColor: NSColor = .clear
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
        if isEnabled && (hovered || cell?.isHighlighted == true) {
            hoverColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

func lumeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.lineBreakMode = .byTruncatingTail
    return label
}
