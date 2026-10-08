import AppKit
import ScanKit

/// The document's first page, ready to be dragged out as the PDF itself. Space or a double-click
/// previews it with Quick Look.
final class DocumentThumbnailView: AppearanceView, NSDraggingSource {
    private let page = CALayer()
    private let badge = TagView("", style: .filled)
    private let spinner = Spinner(size: .regular)
    var fileURL: URL?
    var onPreview: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    init(size: CGSize) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height)])
        page.cornerRadius = 3
        page.borderWidth = 0.5
        page.contentsGravity = .resizeAspectFill
        page.masksToBounds = false
        page.shadowOpacity = 0.18
        page.shadowRadius = 8
        page.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(page)
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 8),
        ])
        addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    func show(_ image: CGImage?, pages: Int) {
        page.contents = image
        badge.setText(pages == 1 ? "1 page" : "\(pages) pages")
        setAccessibilityLabel("Scanned document, \(pages == 1 ? "1 page" : "\(pages) pages"). Drag to share it, or press Space to preview.")
    }

    /// Dims the page under a spinner while it is being encoded again.
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            spinner.isSpinning = isBusy
            Motion.fade(page, to: isBusy ? 0.35 : 1, duration: 0.15)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.frame = bounds
        page.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
        CATransaction.commit()
    }

    override func updateColors() {
        page.borderColor = NSColor.separatorColor.cgColor
        page.backgroundColor = NSColor.white.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 { onPreview?() }
        Motion.spring("transform", on: page, to: NSValue(caTransform3D: CATransform3DMakeScale(0.97, 0.97, 1)), response: 0.2)
    }

    override func mouseUp(with event: NSEvent) {
        Motion.spring("transform", on: page, to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.3)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fileURL, let start = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil
        Motion.spring("transform", on: page, to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.3)
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let image = NSImage(size: bounds.size)
        if let contents = page.contents { image.addRepresentation(NSBitmapImageRep(cgImage: contents as! CGImage)) }
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class FolderRow: NSControl {
    private let path = Typeface.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, alignment: .left)
    private let leaf = Typeface.label("", font: .systemFont(ofSize: 14, weight: .medium), color: .labelColor, alignment: .left)
    private let newTag = TagView("NEW FOLDER", style: .outlined, size: 10)
    private let change = NSImageView(image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!)
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        (path as? StyledLabel)?.singleLine(.byTruncatingHead)
        (leaf as? StyledLabel)?.singleLine(.byTruncatingTail)
        change.contentTintColor = .secondaryLabelColor
        change.setContentHuggingPriority(.required, for: .horizontal)
        change.setContentCompressionResistancePriority(.required, for: .horizontal)
        newTag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bottom = hstack([leaf, newTag, NSView(), change], spacing: 8)
        let column = vstack([path, bottom], spacing: 3, alignment: .leading)
        pin(column, insets: NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11))
        bottom.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        path.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(breadcrumb: String, leaf name: String, isNew: Bool) {
        Typeface.set(path, breadcrumb)
        Typeface.set(leaf, name)
        newTag.isHidden = !isNew
        setAccessibilityLabel("Folder")
        setAccessibilityValue("\(breadcrumb) \(name)\(isNew ? ", a new folder" : ""). Press to change.")
    }

    /// The path above the destination, starting at the cabinet when it fits. The cabinet is
    /// dropped before anything is cut, since every path starts there.
    static func breadcrumb(root: String, parents: [String], width: CGFloat) -> String {
        let full = ([root] + parents).joined(separator: " › ") + " ›"
        guard !parents.isEmpty, (full as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width > width
        else { return full }
        return parents.joined(separator: " › ") + " ›"
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
        (pressed ? NSColor.quaternaryLabelColor : hovering ? NSColor.quaternaryLabelColor.withAlphaComponent(0.5) : NSColor.clear).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 125 { sendAction(action, to: target) } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
}

final class NameField: AppearanceView, NSTextFieldDelegate {
    let field = NSTextField()
    private let suffix = Typeface.label(".pdf", font: .systemFont(ofSize: 14), color: .tertiaryLabelColor, alignment: .left)
    private var editing = false { didSet { updateColors() } }
    var onCommit: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("File name")
        suffix.setContentHuggingPriority(.required, for: .horizontal)
        suffix.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = hstack([field, suffix], spacing: 1, alignment: .firstBaseline)
        pin(row, insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5
    }

    var name: String {
        get { field.stringValue }
        set { if field.currentEditor() == nil { field.stringValue = newValue } }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { editing = true }
    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        onCommit?(field.stringValue)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    override func updateColors() {
        layer?.borderColor = (editing ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
    }
}

final class FileScreen: ScreenView {
    let thumbnail = DocumentThumbnailView(size: CGSize(width: 96, height: 124))
    private let title = Typeface.label("", font: .systemFont(ofSize: 20, weight: .semibold), color: .labelColor, tracking: -0.3, lineHeight: 24, alignment: .left)
    private let subtitle = Typeface.label("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lineHeight: 16, alignment: .left)
    private let hint = Typeface.label("Drag the page to share it. Press Space to preview.", font: .systemFont(ofSize: 11),
                                      color: .tertiaryLabelColor, lineHeight: 15, alignment: .left)
    let nameField = NameField()
    let folderRow = FolderRow()
    private let colorControl = NSSegmentedControl(labels: ColorMode.allCases.map(\.shortTitle), trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let frontsOnly = NSButton(checkboxWithTitle: "Fronts only", target: nil, action: nil)
    private let reason = Typeface.label("", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, lineHeight: 15, alignment: .left)
    private let fileButton: PillButton
    private let inboxButton: PillButton
    private let backButton: LinkButton

    override init(context: ScreenContext, target: AnyObject) {
        fileButton = PillButton("File It", role: .primary, target: target, action: #selector(ScanWindowController.fileDocument))
        inboxButton = PillButton("Save to Inbox", role: .secondary, target: target, action: #selector(ScanWindowController.saveToInbox))
        backButton = LinkButton("‹ All items", target: target, action: #selector(ScanWindowController.showAllItems))
        super.init(context: context, target: target)

        colorControl.target = target
        colorControl.action = #selector(ScanWindowController.colorChanged(_:))
        colorControl.controlSize = .small
        colorControl.setAccessibilityLabel("Color")
        for (segment, mode) in ColorMode.allCases.enumerated() {
            colorControl.setToolTip(mode == .automatic ? "Color only for pages that have it" : "Every page in \(mode.title.lowercased())",
                                    forSegment: segment)
        }
        frontsOnly.target = target
        frontsOnly.action = #selector(ScanWindowController.frontsOnlyChanged(_:))
        frontsOnly.controlSize = .small
        frontsOnly.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        frontsOnly.toolTip = "Leave out the back of each sheet"
        let controls = hstack([colorControl, frontsOnly], spacing: 14)
        let texts = vstack([title, subtitle, hint, controls], spacing: 4, alignment: .leading)
        texts.setCustomSpacing(10, after: hint)
        let card = hstack([thumbnail, texts], spacing: 18)
        folderRow.target = target
        folderRow.action = #selector(ScanWindowController.chooseFolder(_:))
        let nameSection = vstack([Typeface.section("Name"), nameField], spacing: 6, alignment: .leading)
        let folderSection = vstack([Typeface.section("Folder"), folderRow, reason], spacing: 6, alignment: .leading)
        let fields = vstack([nameSection, folderSection], spacing: 14, alignment: .leading)
        fileButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = hstack([fileButton, inboxButton], spacing: 12)
        buttons.distribution = .fill

        for view in [card, fields, buttons, backButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88),
            backButton.centerYAnchor.constraint(equalTo: topAnchor, constant: 22),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            texts.widthAnchor.constraint(equalToConstant: 440 - 64 - 96 - 18),
            fields.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 30),
            fields.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            fields.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            nameSection.widthAnchor.constraint(equalTo: fields.widthAnchor),
            folderSection.widthAnchor.constraint(equalTo: fields.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: nameSection.widthAnchor),
            folderRow.widthAnchor.constraint(equalTo: folderSection.widthAnchor),
            reason.widthAnchor.constraint(equalTo: folderSection.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            inboxButton.widthAnchor.constraint(equalToConstant: 132),
        ])
        nameField.onCommit = { [weak target] name in (target as? ScanWindowController)?.rename(name) }
        thumbnail.onPreview = { [weak target] in (target as? ScanWindowController)?.togglePreview(nil) }
    }

    override func update(_ state: ScanState) {
        let filing: Bool
        let batch: Batch
        switch state {
        case .reviewing(_, let b, _): batch = b; filing = false
        case .filing(_, let b, _): batch = b; filing = true
        default: return
        }
        guard let document = batch.document else { return }
        thumbnail.show(context.thumbnail(for: document), pages: document.pages.count)
        thumbnail.fileURL = document.stagedURL
        thumbnail.isBusy = document.isReencoding
        colorControl.selectedSegment = ColorMode.allCases.firstIndex(of: document.encoding.color) ?? 0
        colorControl.isEnabled = !filing
        frontsOnly.isHidden = !batch.documentHasBacks
        frontsOnly.state = document.encoding.selection == .frontsOnly ? .on : .off
        frontsOnly.isEnabled = !filing
        Typeface.set(title, document.suggestion.title)
        Typeface.set(subtitle, Self.subtitle(document))
        nameField.name = document.fileName

        let root = AppSettings.shared.filingCabinet.lastPathComponent
        let components = document.folderPath.split(separator: "/").map(String.init)
        let parents = document.newSubfolder == nil ? Array(components.dropLast()) : components
        folderRow.show(breadcrumb: FolderRow.breadcrumb(root: root, parents: parents, width: 352),
                       leaf: document.newSubfolder ?? components.last ?? root, isNew: document.newSubfolder != nil)
        Typeface.set(reason, Self.reason(document))
        backButton.isHidden = !batch.isMixed
        // The working button stays enabled so its "Filing…" reads clearly; the job ignores a second press.
        fileButton.isEnabled = filing || !document.isReencoding
        inboxButton.isEnabled = !filing && !document.isReencoding
        fileButton.isWorking = filing
        fileButton.title = filing ? "Filing…" : "File It"
        folderRow.isEnabled = !filing
        nameField.field.isEnabled = !filing
    }

    func commitName() {
        if nameField.field.currentEditor() != nil { window?.makeFirstResponder(nil) }
    }

    static func subtitle(_ document: DocumentDraft) -> String {
        let event = document.newSubfolder ?? document.folderPath.split(separator: "/").last.map(String.init)
        let what = event.flatMap { CandidateRanker.eventDate(of: $0) != nil ? CandidateRanker.eventName(of: $0) : nil }
            ?? document.evidence.documentType
        return [what, document.evidence.date?.display].compactMap { $0 }.joined(separator: " · ")
    }

    static func reason(_ document: DocumentDraft) -> String {
        if document.folderPath == CandidateRanker.inboxName {
            return document.suggestion.confidence == .low && document.suggestion.folderPath == CandidateRanker.inboxName
                ? "Not sure where this goes, so it’s set to your Inbox. Choose a folder to file it now."
                : "Saved to your Inbox to sort later."
        }
        return document.destinationPath == document.suggestion.destinationPath ? document.suggestion.reason : "Chosen by you."
    }
}
