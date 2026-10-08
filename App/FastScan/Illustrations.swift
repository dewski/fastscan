import AppKit
import QuartzCore

/// The FastFoto drawn in strokes, after the wireframes: looking (Wi-Fi arcs pulse above it),
/// ready (a sheet waits over the feeder), or missing (an alert badge).
final class FeederIllustration: AppearanceView {
    enum Mode { case looking, ready, missing }

    var mode: Mode { didSet { if mode != oldValue { rebuild() } } }

    private let canvas = CALayer()
    private var strokes: [(CAShapeLayer, () -> NSColor)] = []
    private var fills: [(CAShapeLayer, () -> NSColor)] = []

    init(_ mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 220), heightAnchor.constraint(equalToConstant: 170)])
        canvas.frame = CGRect(x: 0, y: 0, width: 220, height: 170)
        // Drawn in the wireframe's SVG coordinates, which run top-down.
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        setAccessibilityElement(false)
        rebuild()
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
    }

    @discardableResult
    private func shape(_ path: CGPath, stroke: @escaping () -> NSColor = { .tertiaryLabelColor }, fill: (() -> NSColor)? = nil,
                       width: CGFloat = 2, dash: [NSNumber]? = nil) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.lineDashPattern = dash
        layer.fillColor = nil
        strokes.append((layer, stroke))
        if let fill { fills.append((layer, fill)) }
        canvas.addSublayer(layer)
        return layer
    }

    private func rebuild() {
        canvas.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokes = []
        fills = []
        let ink: () -> NSColor = mode == .ready ? { .labelColor } : { .tertiaryLabelColor }

        shape(CGPath(rect: CGRect(x: 54, y: 151, width: 112, height: 0.5), transform: nil), stroke: { .quaternaryLabelColor }, width: 1.5)

        switch mode {
        case .looking:
            let arcs = [CGFloat(40), 22].map { radius in
                let path = CGMutablePath()
                path.addArc(center: CGPoint(x: 110, y: 56.5), radius: radius, startAngle: -138.5 * .pi / 180,
                            endAngle: -41.5 * .pi / 180, clockwise: false)
                return path
            }
            let outer = shape(arcs[0], stroke: { .secondaryLabelColor })
            let inner = shape(arcs[1], stroke: { .secondaryLabelColor })
            let dot = shape(CGPath(ellipseIn: CGRect(x: 107, y: 53, width: 6, height: 6), transform: nil), stroke: { .secondaryLabelColor }, fill: { .secondaryLabelColor })
            pulse([dot, inner, outer])
            shape(tray(top: 70), stroke: ink)
        case .ready:
            let sheet = CALayer()
            sheet.frame = canvas.bounds
            let paper = shape(sheetPath(), stroke: { .labelColor }, fill: { .textBackgroundColor })
            let lines = shape(sheetLines(), stroke: { .tertiaryLabelColor }, width: 2)
            let arrow = shape(arrowPath(), stroke: { .controlAccentColor }, width: 2)
            for layer in [paper, lines, arrow] {
                layer.removeFromSuperlayer()
                sheet.addSublayer(layer)
            }
            canvas.addSublayer(sheet)
            bob(sheet)
        case .missing:
            shape(tray(top: 70), stroke: ink)
        }

        shape(CGPath(roundedRect: CGRect(x: 40, y: 96, width: 140, height: 46), cornerWidth: 12, cornerHeight: 12, transform: nil),
              stroke: ink, fill: { .controlBackgroundColor })
        shape(line(from: CGPoint(x: 68, y: 118), to: CGPoint(x: 152, y: 118)), stroke: ink, width: 3)

        if mode == .missing {
            shape(CGPath(ellipseIn: CGRect(x: 152, y: 56, width: 32, height: 32), transform: nil), stroke: { .systemOrange },
                  fill: { .controlBackgroundColor }, width: 2)
            shape(line(from: CGPoint(x: 168, y: 64), to: CGPoint(x: 168, y: 74)), stroke: { .systemOrange }, width: 2.5)
            shape(CGPath(ellipseIn: CGRect(x: 166.5, y: 78.5, width: 3, height: 3), transform: nil), stroke: { .systemOrange }, fill: { .systemOrange }, width: 1)
        }
        needsDisplay = true
        updateColors()
    }

    override func updateColors() {
        for (layer, color) in strokes { layer.strokeColor = color().cgColor }
        for (layer, color) in fills { layer.fillColor = color().cgColor }
    }

    private func tray(top: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 75, y: 96))
        path.addLine(to: CGPoint(x: 92, y: top))
        path.addLine(to: CGPoint(x: 128, y: top))
        path.addLine(to: CGPoint(x: 145, y: 96))
        return path
    }

    private func sheetPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 80, y: 112))
        path.addLine(to: CGPoint(x: 92, y: 42))
        path.addLine(to: CGPoint(x: 128, y: 42))
        path.addLine(to: CGPoint(x: 140, y: 112))
        path.closeSubpath()
        return path
    }

    private func sheetLines() -> CGPath {
        let path = CGMutablePath()
        for (index, y) in [54.0, 62, 70, 78].enumerated() {
            let inset = 6 + (y - 42) * 12 / 70
            let width = index == 0 ? 0.55 : [1, 0.85, 0.7][(index - 1) % 3]
            let left = 92 - (y - 42) * 12 / 70 + inset
            let right = 128 + (y - 42) * 12 / 70 - inset
            path.move(to: CGPoint(x: left, y: y))
            path.addLine(to: CGPoint(x: left + (right - left) * width, y: y))
        }
        return path
    }

    private func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 110, y: 10))
        path.addLine(to: CGPoint(x: 110, y: 28))
        path.move(to: CGPoint(x: 103, y: 21))
        path.addLine(to: CGPoint(x: 110, y: 28))
        path.addLine(to: CGPoint(x: 117, y: 21))
        return path
    }

    private func line(from a: CGPoint, to b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func pulse(_ layers: [CAShapeLayer]) {
        guard !Motion.reduceMotion else { return }
        for (index, layer) in layers.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.25, 1, 0.25, 0.25]
            animation.keyTimes = [0, 0.25, 0.55, 1]
            animation.duration = 1.8
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.22
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "pulse")
        }
    }

    private func bob(_ layer: CALayer) {
        guard !Motion.reduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = 0
        animation.toValue = 6
        animation.duration = 1.4
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "bob")
    }
}

/// Scanned pages fanned in a loose stack. New pages drop onto it with a spring; while reading, a
/// scan line sweeps the top page.
final class PageStackView: AppearanceView {
    enum Badge: Equatable { case none, check, alert }

    private let pageBox: CGSize
    private var pages: [CALayer] = []
    private let badgeLayer = CALayer()
    private let badgeSymbol = CALayer()
    private let scanLine = CAGradientLayer()
    private static let tilts: [CGFloat] = [-4, 3, -1.5, 2.5]
    private static let maxVisible = 4

    var badge: Badge = .none { didSet { if badge != oldValue { updateBadge(animated: true) } } }
    var isReading = false { didSet { if isReading != oldValue { updateScanLine() } } }

    init(pageBox: CGSize = CGSize(width: 132, height: 172)) {
        self.pageBox = pageBox
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: pageBox.width + 70),
            heightAnchor.constraint(equalToConstant: pageBox.height + 50),
        ])
        badgeLayer.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        badgeLayer.cornerRadius = 22
        badgeLayer.opacity = 0
        badgeLayer.shadowOpacity = 0.18
        badgeLayer.shadowRadius = 6
        badgeLayer.shadowOffset = CGSize(width: 0, height: -2)
        badgeSymbol.frame = badgeLayer.bounds.insetBy(dx: 11, dy: 11)
        badgeSymbol.contentsGravity = .resizeAspect
        badgeLayer.addSublayer(badgeSymbol)
        layer?.addSublayer(badgeLayer)
        scanLine.startPoint = CGPoint(x: 0.5, y: 0)
        scanLine.endPoint = CGPoint(x: 0.5, y: 1)
        scanLine.opacity = 0
        setAccessibilityElement(false)
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY + 4) }

    private func size(for image: CGImage) -> CGSize {
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let landscapeBox = CGSize(width: pageBox.height, height: pageBox.width)
        let box = aspect > 1 ? landscapeBox : pageBox
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func makePage(_ image: CGImage) -> CALayer {
        let page = CALayer()
        page.contents = image
        page.contentsGravity = .resizeAspectFill
        page.bounds = CGRect(origin: .zero, size: size(for: image))
        page.position = center
        page.cornerRadius = 3
        page.masksToBounds = false
        page.borderWidth = 0.5
        page.shadowOpacity = 0.16
        page.shadowRadius = 7
        page.shadowOffset = CGSize(width: 0, height: -3)
        page.shadowPath = CGPath(roundedRect: page.bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
        page.borderColor = NSColor.separatorColor.cgColor
        return page
    }

    func setPages(_ images: [CGImage]) {
        pages.forEach { $0.removeFromSuperlayer() }
        pages = []
        for image in images.suffix(Self.maxVisible) { place(makePage(image)) }
        retilt(animated: false)
        layer?.insertSublayer(badgeLayer, at: UInt32(layer?.sublayers?.count ?? 0))
    }

    func drop(_ image: CGImage) {
        let page = makePage(image)
        place(page)
        if pages.count > Self.maxVisible {
            let oldest = pages.removeFirst()
            oldest.removeFromSuperlayer()
        }
        retilt(animated: true)
        if Motion.reduceMotion {
            page.opacity = 0
            Motion.fade(page, to: 1, duration: 0.25)
        } else {
            page.position = CGPoint(x: center.x, y: center.y + 90)
            page.opacity = 0
            Motion.fade(page, to: 1, duration: 0.12)
            // The page arrives with the momentum of being fed, so it may settle with a little give.
            Motion.spring("position", on: page, to: NSValue(point: center), response: 0.42, damping: 0.78)
        }
        bringBadgeToFront()
    }

    var topImage: CGImage? { pages.last.map { $0.contents as! CGImage } }

    private func place(_ page: CALayer) {
        layer?.addSublayer(page)
        pages.append(page)
    }

    private func retilt(animated: Bool) {
        for (depth, page) in pages.reversed().enumerated() {
            let angle = depth == 0 ? 0 : Self.tilts[(depth - 1) % Self.tilts.count] * .pi / 180
            let transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            if animated && !Motion.reduceMotion {
                Motion.spring("transform", on: page, to: NSValue(caTransform3D: transform), response: 0.5)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                page.transform = transform
                CATransaction.commit()
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for page in pages where page.animation(forKey: "position") == nil { page.position = center }
        if let top = pages.last {
            badgeLayer.position = CGPoint(x: center.x + top.bounds.width / 2 - 6, y: center.y - top.bounds.height / 2 + 6)
        }
        CATransaction.commit()
        updateScanLine()
    }

    private func bringBadgeToFront() {
        badgeLayer.removeFromSuperlayer()
        layer?.addSublayer(badgeLayer)
        needsLayout = true
    }

    private func updateBadge(animated: Bool) {
        bringBadgeToFront()
        let symbol: String? = switch badge {
        case .none: nil
        case .check: "checkmark"
        case .alert: "exclamationmark"
        }
        updateColors()
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .bold).applying(.init(paletteColors: [.white]))) {
            badgeSymbol.contents = image
        }
        let visible = badge != .none
        if animated, visible, !Motion.reduceMotion {
            badgeLayer.opacity = 1
            badgeLayer.transform = CATransform3DMakeScale(0.4, 0.4, 1)
            Motion.spring("transform", on: badgeLayer, to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.45, damping: 0.6)
        } else {
            Motion.fade(badgeLayer, to: visible ? 1 : 0, duration: animated ? 0.2 : 0)
        }
    }

    private func updateScanLine() {
        guard let top = pages.last else { return }
        scanLine.removeFromSuperlayer()
        guard isReading else { return }
        top.addSublayer(scanLine)
        top.masksToBounds = false
        scanLine.frame = CGRect(x: -6, y: top.bounds.height * 0.6, width: top.bounds.width + 12, height: 18)
        scanLine.opacity = 1
        updateColors()
        guard !Motion.reduceMotion else { return }
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = top.bounds.height
        sweep.toValue = 0
        sweep.duration = 1.8
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scanLine.add(sweep, forKey: "sweep")
    }

    override func updateColors() {
        for page in pages { page.borderColor = NSColor.separatorColor.cgColor; page.backgroundColor = NSColor.white.cgColor }
        badgeLayer.backgroundColor = (badge == .alert ? NSColor.systemOrange : NSColor.controlAccentColor).cgColor
        let accent = NSColor.controlAccentColor
        scanLine.colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.35).cgColor,
                           accent.cgColor, accent.withAlphaComponent(0.35).cgColor, accent.withAlphaComponent(0).cgColor]
        scanLine.locations = [0, 0.4, 0.5, 0.6, 1]
    }
}
