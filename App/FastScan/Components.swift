import AppKit
import QuartzCore

/// Type styles. SF Pro sizes come from the wireframes; tracking follows Apple's optical tables,
/// tight for display sizes and slightly open for small caps labels.
@MainActor
enum Typeface {
    static func title(_ text: String, size: CGFloat = 22) -> NSTextField {
        label(text, font: .systemFont(ofSize: size, weight: .semibold), color: .labelColor, tracking: -0.3)
    }

    static func body(_ text: String) -> NSTextField {
        label(text, font: .systemFont(ofSize: 13), color: .secondaryLabelColor, lineHeight: 18)
    }

    static func caption(_ text: String, color: NSColor = .tertiaryLabelColor) -> NSTextField {
        label(text, font: .systemFont(ofSize: 11), color: color, lineHeight: 15)
    }

    static func section(_ text: String) -> NSTextField {
        label(text.uppercased(), font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor, tracking: 0.4)
    }

    static func label(_ text: String, font: NSFont, color: NSColor, tracking: CGFloat = 0, lineHeight: CGFloat? = nil,
                      alignment: NSTextAlignment = .center) -> NSTextField {
        let field = StyledLabel(font: font, color: color, tracking: tracking, lineHeight: lineHeight, alignment: alignment)
        field.text = text
        return field
    }

    static func set(_ field: NSTextField, _ text: String) {
        if let styled = field as? StyledLabel { styled.text = text } else { field.stringValue = text }
    }
}

final class StyledLabel: NSTextField {
    private var attributes: [NSAttributedString.Key: Any]

    init(font: NSFont, color: NSColor, tracking: CGFloat, lineHeight: CGFloat?, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        attributes = [.font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: paragraph]
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.truncatesLastVisibleLine = true
        self.font = font
        textColor = color
        self.alignment = alignment
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String = "" {
        didSet {
            attributedStringValue = NSAttributedString(string: text, attributes: attributes)
            setAccessibilityLabel(nil)
        }
    }

    func singleLine(_ mode: NSLineBreakMode) {
        let paragraph = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineBreakMode = mode
        attributes[.paragraphStyle] = paragraph
        maximumNumberOfLines = 1
        lineBreakMode = mode
        cell?.wraps = false
        let current = text
        text = current
    }

    override var textColor: NSColor? {
        didSet {
            guard let textColor else { return }
            attributes[.foregroundColor] = textColor
            if !text.isEmpty { attributedStringValue = NSAttributedString(string: text, attributes: attributes) }
        }
    }
}

final class PillButton: NSButton {
    enum Role { case primary, secondary }

    convenience init(_ title: String, role: Role, target: AnyObject?, action: Selector) {
        self.init(title: title, target: target, action: action)
        // .push adopts the Liquid Glass capsule on macOS 26 and, unlike .glass, still draws
        // into cacheDisplay, which the snapshot hook relies on.
        bezelStyle = .push
        controlSize = .extraLarge
        borderShape = .capsule
        font = .systemFont(ofSize: role == .primary ? 15 : 14, weight: role == .primary ? .semibold : .medium)
        if role == .primary {
            tintProminence = .primary
            keyEquivalent = "\r"
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }

    private lazy var spinner: Spinner = {
        let spinner = Spinner(size: .small)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return spinner
    }()

    /// A spinner inside the capsule while the button's action runs.
    var isWorking: Bool {
        get { spinner.isSpinning }
        set { spinner.isSpinning = newValue }
    }
}

/// The system's indeterminate spinner, hidden while stopped.
final class Spinner: NSProgressIndicator {
    convenience init(size: NSControl.ControlSize) {
        self.init(frame: .zero)
        style = .spinning
        controlSize = size
        isIndeterminate = true
        isDisplayedWhenStopped = false
        translatesAutoresizingMaskIntoConstraints = false
        let side: CGFloat = switch size {
        case .regular, .large, .extraLarge: 32
        case .small: 16
        default: 10
        }
        // Without a size the spinner stretches with its stack view and draws as a bar.
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
    }

    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            if isSpinning { startAnimation(nil) } else { stopAnimation(nil) }
        }
    }
}

final class LinkButton: NSButton {
    private var hovering = false { didSet { updateTitle() } }
    private let text: String
    private let size: CGFloat

    init(_ text: String, size: CGFloat = 12, target: AnyObject?, action: Selector) {
        self.text = text
        self.size = size
        super.init(frame: .zero)
        isBordered = false
        self.target = target
        self.action = action
        setButtonType(.momentaryChange)
        updateTitle()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: hovering ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        if hovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["FASTSCAN_REDUCE_MOTION"] != nil
    }

    /// A spring in Apple's designer terms: `response` is roughly the time to settle in seconds and
    /// `damping` 1 means no overshoot. It starts from the layer's on-screen value, so a new spring
    /// added mid-flight continues smoothly instead of jumping.
    static func spring(_ keyPath: String, on layer: CALayer, to value: Any, response: Double = 0.38, damping: Double = 1) {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / response, 2)
        animation.damping = 4 * .pi * damping / response
        animation.duration = animation.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: keyPath)
    }

    static func fade(_ layer: CALayer, to opacity: Float, duration: Double = 0.2) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        layer.add(animation, forKey: "opacity")
    }
}

/// A small, memory-light copy of a scan for display. Full scans are tens of megabytes each.
func displayCopy(_ image: CGImage, maxPixels: Int = 420) -> CGImage {
    let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}

class AppearanceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { updateColors() } }
    func updateColors() {}
}

final class ThinProgressBar: AppearanceView {
    private let fill = CALayer()
    var fraction: Double = 0 {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 2
        fill.cornerRadius = 2
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    override func layout() {
        super.layout()
        let width = bounds.width * CGFloat(max(0, min(1, fraction)))
        let target = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        if Motion.reduceMotion || fill.bounds.width == 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = target
            CATransaction.commit()
        } else {
            fill.anchorPoint = .zero
            fill.position = .zero
            Motion.spring("bounds", on: fill, to: NSValue(rect: CGRect(origin: .zero, size: target.size)), response: 0.5)
        }
        setAccessibilityValue(NSNumber(value: fraction))
    }

    override func updateColors() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }
}

final class TagView: AppearanceView {
    enum Style { case filled, outlined }
    private let label: NSTextField
    private let style: Style

    init(_ text: String, style: Style, size: CGFloat = 11) {
        self.style = style
        label = Typeface.label(text, font: .systemFont(ofSize: size, weight: .semibold), color: style == .filled ? .white : .secondaryLabelColor,
                               tracking: style == .outlined ? 0.3 : 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style == .filled ? 8 : 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: style == .filled ? -8 : -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: style == .filled ? 3 : 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: style == .filled ? -3 : -1),
        ])
        setAccessibilityElement(false)
    }

    func setText(_ text: String) { Typeface.set(label, text) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = style == .filled ? bounds.height / 2 : 4
    }

    override func updateColors() {
        switch style {
        case .filled:
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
            label.textColor = .windowBackgroundColor
        case .outlined:
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.secondaryLabelColor.cgColor
        }
    }
}

extension NSView {
    func pin(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

@MainActor
func vstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerX) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.spacing = spacing
    stack.alignment = alignment
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

@MainActor
func hstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = spacing
    stack.alignment = alignment
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}
