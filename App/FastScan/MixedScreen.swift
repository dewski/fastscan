import AppKit
import ScanKit

final class SheetTile: NSControl {
    let sheetID: Int
    private let imageLayer = CALayer()
    private let hint: NSTextField
    private var caption: TagView?
    private var hovering = false { didSet { updateHover() } }

    init(sheetID: Int, image: CGImage, caption text: String?, flipTo kind: PageKind, cornerRadius: CGFloat) {
        self.sheetID = sheetID
        hint = Typeface.label(kind == .photo ? "Make Photo" : "Make Paper", font: .systemFont(ofSize: 10, weight: .semibold), color: .white)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = cornerRadius
        imageLayer.borderWidth = 0.5
        layer?.addSublayer(imageLayer)
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hint.layer?.cornerRadius = 4
        hint.alphaValue = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([hint.centerXAnchor.constraint(equalTo: centerXAnchor), hint.centerYAnchor.constraint(equalTo: centerYAnchor)])
        if let text {
            let tag = TagView("“\(text.count > 18 ? text.prefix(17) + "…" : text)”", style: .filled, size: 9)
            addSubview(tag)
            NSLayoutConstraint.activate([
                tag.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                tag.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                tag.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ])
            caption = tag
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let what = kind == .photo ? "Page" : "Photo"
        setAccessibilityLabel("\(what) \(sheetID + 1)\(text.map { ", writing on the back: \($0)" } ?? "")")
        setAccessibilityHelp(kind == .photo ? "Switches it to a photo." : "Switches it to paper.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageLayer.borderColor = NSColor.separatorColor.cgColor
            imageLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
    }

    private func updateHover() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            hint.animator().alphaValue = hovering && isEnabled ? 1 : 0
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: imageLayer.cornerRadius, yRadius: imageLayer.cornerRadius).fill() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        Motion.spring("transform", on: imageLayer, to: NSValue(caTransform3D: CATransform3DMakeScale(0.95, 0.95, 1)), response: 0.2)
    }
    override func mouseUp(with event: NSEvent) {
        Motion.spring("transform", on: imageLayer, to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.3)
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { sendAction(action, to: target) } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// Papers and photos from one batch, each going its own way: papers into one searchable PDF,
/// photos into Photos.
final class MixedScreen: ScreenView {
    private let title = Typeface.label("", font: .systemFont(ofSize: 20, weight: .semibold), color: .labelColor, tracking: -0.3, alignment: .left)
    private let subtitle = Typeface.label("Sorted automatically. Click an item to switch it between Paper and Photo.",
                                          font: .systemFont(ofSize: 12), color: .secondaryLabelColor, lineHeight: 16, alignment: .left)
    private let content = NSStackView()
    private let fileAllButton: PillButton
    private let oneButton: PillButton
    private var shownRevision: (UUID, Int)?

    override init(context: ScreenContext, target: AnyObject) {
        fileAllButton = PillButton("File All", role: .primary, target: target, action: #selector(ScanWindowController.fileAll))
        oneButton = PillButton("One at a Time", role: .secondary, target: target, action: #selector(ScanWindowController.oneAtATime))
        super.init(context: context, target: target)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        let header = vstack([title, subtitle], spacing: 4, alignment: .leading)
        fileAllButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = hstack([fileAllButton, oneButton], spacing: 12)
        buttons.distribution = .fill
        for view in [header, content, buttons] { addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            title.widthAnchor.constraint(equalTo: header.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: header.widthAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            content.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            oneButton.widthAnchor.constraint(equalToConstant: 150),
        ])
    }

    override func update(_ state: ScanState) {
        let batch: Batch
        let filing: Bool
        switch state {
        case .reviewing(_, let b, _): batch = b; filing = false
        case .filing(_, let b, _): batch = b; filing = true
        default: return
        }
        fileAllButton.isEnabled = filing || !batch.isRebuildingDocument
        fileAllButton.isWorking = filing
        oneButton.isEnabled = !filing && !batch.isRebuildingDocument
        oneButton.isHidden = batch.document == nil || batch.documentFiled
        fileAllButton.title = filing ? "Filing…" : batch.documentFiled ? (batch.photos.count == 1 ? "Add Photo" : "Add Photos") : "File All"
        guard shownRevision.map({ $0 != (batch.id, batch.revision) }) ?? true else { return }
        let animate = shownRevision?.0 == batch.id
        shownRevision = (batch.id, batch.revision)
        rebuild(batch, locked: filing || batch.documentFiled || batch.photosFiled || batch.isRebuildingDocument)
        if animate {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.reduceMotion ? 0.15 : 0.25
            content.layer?.add(fade, forKey: "contents")
        }
    }

    private func rebuild(_ batch: Batch, locked: Bool) {
        let photos = batch.photos.count
        // The papers of a batch become one PDF, so they count as one paper.
        let hasPaper = !batch.paperSheets.isEmpty && (batch.document != nil || batch.isRebuildingDocument)
        let paperText = hasPaper ? "1 paper" : nil
        let photoText = photos == 0 ? nil : "\(photos) \(photos == 1 ? "photo" : "photos")"
        Typeface.set(title, [paperText, photoText].compactMap { $0 }.joined(separator: " and "))
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if hasPaper {
            content.addArrangedSubview(paperSection(batch.document, batch: batch, locked: locked))
        }
        if photos > 0 {
            content.addArrangedSubview(photoSection(batch, locked: locked))
        }
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }

    /// While a flip rebuilds the document, the row keeps its place with a spinner instead of Edit.
    private func paperSection(_ document: DocumentDraft?, batch: Batch, locked: Bool) -> NSView {
        let thumbs = batch.paperSheets.prefix(5).map { sheet -> NSView in
            let tile = SheetTile(sheetID: sheet.id, image: context.thumbnail(for: sheet), caption: nil, flipTo: .photo, cornerRadius: 2)
            tile.target = target
            tile.action = #selector(ScanWindowController.flipSheet(_:))
            tile.isEnabled = !locked
            NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 34), tile.heightAnchor.constraint(equalToConstant: 44)])
            return tile
        }
        let pages = batch.paperSheets.reduce(0) { $0 + $1.sides(document?.encoding.selection ?? .allSides).count }
        let name = Typeface.label("\(document?.fileName ?? "Document").pdf · \(pages) \(pages == 1 ? "page" : "pages")",
                                  font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor, alignment: .left)
        let pathText = batch.isRebuildingDocument || document == nil
            ? "Working out where it goes…" : document!.destinationPath.split(separator: "/").joined(separator: " › ")
        let path = Typeface.label(pathText, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, alignment: .left)
        (name as? StyledLabel)?.singleLine(.byTruncatingMiddle)
        (path as? StyledLabel)?.singleLine(.byTruncatingHead)
        let texts = vstack([name, path], spacing: 2, alignment: .leading)
        let trailing: NSView
        if batch.documentFiled {
            trailing = Typeface.label("Filed ✓", font: .systemFont(ofSize: 12, weight: .medium), color: .systemGreen)
        } else if batch.isRebuildingDocument {
            let spinner = Spinner(size: .small)
            spinner.isSpinning = true
            trailing = spinner
        } else {
            trailing = LinkButton("Edit", target: target, action: #selector(ScanWindowController.oneAtATime))
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = hstack([hstack(Array(thumbs), spacing: -12), texts, trailing], spacing: 12)
        let card = RoundedBox()
        card.pin(row, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12))
        return vstack([Typeface.section("Paper → searchable PDF"), card], spacing: 8, alignment: .leading).fillingWidth(card)
    }

    private func photoSection(_ batch: Batch, locked: Bool) -> NSView {
        let tiles = batch.photos.map { photo -> NSView in
            let tile = SheetTile(sheetID: photo.id, image: context.thumbnail(for: photo.sheet), caption: photo.caption, flipTo: .paper, cornerRadius: 4)
            tile.target = target
            tile.action = #selector(ScanWindowController.flipSheet(_:))
            tile.isEnabled = !locked
            tile.heightAnchor.constraint(equalToConstant: 70).isActive = true
            return tile
        }
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for start in stride(from: 0, to: tiles.count, by: 3) {
            var row = Array(tiles[start..<min(start + 3, tiles.count)])
            while row.count < 3 { row.append(NSGridCell.emptyContentView) }
            grid.addRow(with: row)
        }
        for column in 0..<3 { grid.column(at: column).xPlacement = .fill }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let tileWidth = (440 - 64 - 16) / 3.0
        for tile in tiles { tile.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = tiles.count > 6
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.addSubview(grid)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: document.topAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let rows = min(2, (tiles.count + 2) / 3)
        scroll.heightAnchor.constraint(equalToConstant: CGFloat(rows) * 70 + CGFloat(rows - 1) * 8).isActive = true

        let album = PhotoAlbum.name(for: CalendarDate(.now))
        let note = batch.photosFiled
            ? "Added to Photos, in the album “\(batch.photoResult?.album ?? album)”."
            : "To Photos, album “\(album)”. Writing on the back becomes the caption."
        let footnote = Typeface.label(note, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lineHeight: 15, alignment: .left)
        return vstack([Typeface.section("Photos → images"), scroll, footnote], spacing: 8, alignment: .leading)
            .fillingWidth(scroll).fillingWidth(footnote)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class RoundedBox: AppearanceView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
    }

    override func updateColors() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
    }
}

extension NSStackView {
    func fillingWidth(_ view: NSView) -> NSStackView {
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        return self
    }
}
