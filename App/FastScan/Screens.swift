import AppKit
import ScanKit

/// Which screen a state shows. Several states share one screen (filing keeps the review on
/// screen), and a change of kind is what triggers a transition.
enum ScreenKind: Equatable {
    case looking, notFound, ready, scanning, jammed, reading, file, mixed, filed, failed

    init(_ state: ScanState) {
        switch state {
        case .looking: self = .looking
        case .notFound: self = .notFound
        case .ready: self = .ready
        case .starting, .scanning: self = .scanning
        case .jammed: self = .jammed
        case .reading: self = .reading
        case .reviewing(_, _, let mode), .filing(_, _, let mode): self = mode == .mixed ? .mixed : .file
        case .filed: self = .filed
        case .failed: self = .failed
        }
    }
}

@MainActor
protocol ScreenContext: AnyObject {
    var thumbnails: [CGImage] { get }
    func thumbnail(for sheet: ScannedSheet) -> CGImage
    /// The first page as it was stored: gray and lifted to white when the paper had no color.
    func thumbnail(for document: DocumentDraft) -> CGImage?
}

@MainActor
class ScreenView: NSView {
    unowned let context: ScreenContext
    let target: AnyObject

    init(context: ScreenContext, target: AnyObject) {
        self.context = context
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ state: ScanState) {}
    var initialFocus: NSView? { nil }
}

/// The wireframes' common shape: an illustration in the open space, a title and a sentence under
/// it, and a fixed footer for actions.
class HeroScreen: ScreenView {
    let hero = NSView()
    let titleLabel = Typeface.title("")
    let bodyLabel = Typeface.body("")
    let footer = NSStackView()
    let textStack: NSStackView

    override init(context: ScreenContext, target: AnyObject) {
        textStack = vstack([titleLabel, bodyLabel], spacing: 6)
        super.init(context: context, target: target)
        hero.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .vertical
        footer.alignment = .centerX
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        for view in [hero, textStack, footer] { addSubview(view) }
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            textStack.topAnchor.constraint(equalTo: hero.bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            footer.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 28),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
            footer.heightAnchor.constraint(equalToConstant: 68),
        ])
    }

    func setHero(_ view: NSView) {
        hero.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
        ])
    }

    func setSingleAction(_ button: NSButton, note: NSView? = nil) {
        footer.setViews([button] + (note.map { [$0] } ?? []), in: .top)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    func setPair(_ primary: NSButton, _ secondary: NSButton, secondaryWidth: CGFloat = 150) {
        primary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = hstack([primary, secondary], spacing: 12)
        row.distribution = .fill
        footer.setViews([row], in: .top)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: footer.widthAnchor),
            secondary.widthAnchor.constraint(equalToConstant: secondaryWidth),
        ])
    }

    func setText(_ title: String, _ body: String) {
        Typeface.set(titleLabel, title)
        Typeface.set(bodyLabel, body)
        bodyLabel.isHidden = body.isEmpty
    }
}

final class LookingScreen: HeroScreen {
    override init(context: ScreenContext, target: AnyObject) {
        super.init(context: context, target: target)
        setHero(FeederIllustration(.looking))
        setText("Looking for your scanner…", "Finds the FastFoto on your Wi‑Fi automatically.")
        let spinner = Spinner(size: .small)
        spinner.isSpinning = true
        footer.setViews([spinner], in: .top)
        setAccessibilityLabel("Looking for your scanner")
    }
}

final class ReadyScreen: HeroScreen {
    private let scanButton: PillButton
    private let status = Typeface.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

    override init(context: ScreenContext, target: AnyObject) {
        scanButton = PillButton("Scan", role: .primary, target: target, action: #selector(ScanWindowController.scan))
        super.init(context: context, target: target)
        setHero(FeederIllustration(.ready))
        setText("Put your pages in the feeder",
                "Papers and photos can go in together.")
        setSingleAction(scanButton, note: Typeface.caption("or press Return", color: .secondaryLabelColor))
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        let chip = hstack([dot, status], spacing: 6)
        addSubview(chip)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            chip.centerYAnchor.constraint(equalTo: topAnchor, constant: 22),
        ])
    }

    override func update(_ state: ScanState) {
        guard let endpoint = state.endpoint else { return }
        let model = endpoint.name.replacingOccurrences(of: "EPSON", with: "").trimmingCharacters(in: .whitespaces)
        Typeface.set(status, model)
        status.setAccessibilityLabel("Connected to \(endpoint.name)")
    }
}

final class NotFoundScreen: HeroScreen {
    override init(context: ScreenContext, target: AnyObject) {
        super.init(context: context, target: target)
        setHero(FeederIllustration(.missing))
        setSingleAction(PillButton("Try Again", role: .primary, target: target, action: #selector(ScanWindowController.retry)),
                        note: LinkButton("Allow FastScan on your local network…", target: target,
                                         action: #selector(ScanWindowController.openLocalNetworkSettings)))
    }

    override func update(_ state: ScanState) {
        if case .notFound(.localNetworkDenied) = state {
            setText("FastScan can't look on your network",
                    "Turn on FastScan in Privacy & Security > Local Network, then try again.")
        } else {
            setText("Can't find your FastFoto", "Make sure it's turned on and on the same Wi‑Fi as this\u{00A0}Mac.")
        }
    }
}

final class FailedScreen: HeroScreen {
    override init(context: ScreenContext, target: AnyObject) {
        super.init(context: context, target: target)
        setHero(FeederIllustration(.missing))
        setSingleAction(PillButton("Try Again", role: .primary, target: target, action: #selector(ScanWindowController.retry)))
    }

    override func update(_ state: ScanState) {
        guard case .failed(_, let message) = state else { return }
        setText("Something went wrong", message)
    }
}

/// Starting the scanner and feeding the first page take seconds with nothing to count, so a
/// spinner holds the stack's place until the first page lands.
final class ScanningScreen: HeroScreen {
    private let stack = PageStackView()
    private let counter = Typeface.label("0", font: .monospacedDigitSystemFont(ofSize: 44, weight: .semibold), color: .labelColor, tracking: -0.5)
    private let startSpinner = Spinner(size: .regular)
    private let status = Typeface.body("")
    private var shown = 0

    override init(context: ScreenContext, target: AnyObject) {
        super.init(context: context, target: target)
        setHero(stack)
        hero.addSubview(startSpinner)
        NSLayoutConstraint.activate([
            startSpinner.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            startSpinner.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
        ])
        (status as? StyledLabel)?.singleLine(.byTruncatingTail)
        textStack.setViews([counter, status], in: .top)
        textStack.spacing = 2
        textStack.alignment = .centerX
        counter.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        status.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor).isActive = true
        setSingleAction(PillButton("Stop", role: .secondary, target: target, action: #selector(ScanWindowController.stop)))
        stack.setPages(context.thumbnails)
        shown = context.thumbnails.count
        counter.setAccessibilityRole(.staticText)
    }

    override func update(_ state: ScanState) {
        let pages: Int, starting: Bool
        switch state {
        case .starting(_, let kept): pages = kept; starting = true
        case .scanning(_, let count): pages = count; starting = false
        default: return
        }
        counter.isHidden = pages == 0
        startSpinner.isSpinning = pages == 0
        for image in context.thumbnails.dropFirst(shown) { stack.drop(image) }
        shown = context.thumbnails.count
        if counter.stringValue != "\(pages)" {
            if !Motion.reduceMotion, pages > 0 {
                let push = CATransition()
                push.type = .push
                push.subtype = .fromTop
                push.duration = 0.22
                push.timingFunction = CAMediaTimingFunction(name: .easeOut)
                counter.wantsLayer = true
                counter.layer?.add(push, forKey: "count")
            }
            Typeface.set(counter, "\(pages)")
        }
        Typeface.set(status, starting ? "Starting the scanner…"
            : pages == 0 ? "Feeding the first page…" : "\(pages == 1 ? "page" : "pages") so far. New pages drop onto the stack.")
        counter.setAccessibilityLabel("\(pages) \(pages == 1 ? "page" : "pages") scanned")
    }
}

final class ReadingScreen: HeroScreen {
    private let stack = PageStackView()
    private let progress = ThinProgressBar()
    private let step = Typeface.caption("", color: .secondaryLabelColor)
    private let spinner = Spinner(size: .small)

    override init(context: ScreenContext, target: AnyObject) {
        super.init(context: context, target: target)
        setHero(stack)
        stack.setPages(context.thumbnails)
        stack.isReading = true
        setText("Reading your document…", "Making it searchable and working out where it goes.")
        spinner.isSpinning = true
        let column = vstack([progress, hstack([spinner, step], spacing: 6)], spacing: 10)
        footer.setViews([column], in: .top)
        NSLayoutConstraint.activate([progress.widthAnchor.constraint(equalToConstant: 240), progress.heightAnchor.constraint(equalToConstant: 4)])
        progress.setAccessibilityLabel("Reading progress")
    }

    override func update(_ state: ScanState) {
        guard case .reading(_, let done, let total) = state else { return }
        if stack.topImage == nil, !context.thumbnails.isEmpty { stack.setPages(context.thumbnails) }
        progress.fraction = total == 0 ? 0 : Double(done) / Double(total)
        let pages = total - 1
        Typeface.set(step, done >= pages ? "Choosing a folder…" : "Page \(done + 1) of \(pages)")
    }
}

final class JamScreen: HeroScreen {
    private let stack = PageStackView()
    private let finishButton: PillButton

    override init(context: ScreenContext, target: AnyObject) {
        finishButton = PillButton("Finish", role: .secondary, target: target, action: #selector(ScanWindowController.finishWithKept))
        super.init(context: context, target: target)
        setHero(stack)
        stack.setPages(context.thumbnails)
        stack.badge = .alert
        setPair(PillButton("Scan the Rest", role: .primary, target: target, action: #selector(ScanWindowController.scanRest)), finishButton)
    }

    override func update(_ state: ScanState) {
        guard case .jammed(_, let pages) = state else { return }
        let noun = pages == 1 ? "page is" : "\(pages) pages are"
        setText("The paper jammed", pages == 0
            ? "Nothing was scanned yet. Clear the feeder, put the pages back in, and scan again."
            : "The first \(noun) safe. Clear the feeder, put the rest back in, and they'll be added to this document.")
        finishButton.title = "Finish with \(pages)"
        finishButton.isEnabled = pages > 0
    }
}

final class FiledScreen: HeroScreen {
    private let stack = PageStackView(pageBox: CGSize(width: 150, height: 190))
    private let undoButton: LinkButton
    private let secondary: PillButton

    override init(context: ScreenContext, target: AnyObject) {
        undoButton = LinkButton("Undo", target: target, action: #selector(ScanWindowController.undoFiling))
        secondary = PillButton("Show in Finder", role: .secondary, target: target, action: #selector(ScanWindowController.showInFinder))
        super.init(context: context, target: target)
        setHero(stack)
        textStack.addArrangedSubview(undoButton)
        textStack.setCustomSpacing(8, after: bodyLabel)
        setPair(PillButton("Scan More", role: .primary, target: target, action: #selector(ScanWindowController.scanMore)), secondary)
        undoButton.setAccessibilityLabel("Undo filing")
    }

    override func update(_ state: ScanState) {
        guard case .filed(_, let batch) = state else { return }
        if stack.topImage == nil {
            let image = batch.document.flatMap(context.thumbnail(for:)) ?? batch.sheets.first.map(context.thumbnail(for:))
            stack.setPages(image.map { [$0] } ?? [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.stack.badge = .check }
        }
        var lines: [String] = []
        if let receipt = batch.documentReceipt {
            let parts = receipt.relativePath.split(separator: "/").map(String.init)
            lines.append("\(parts.last ?? "") is in \(parts.dropLast().joined(separator: " › ").ifEmpty("your filing cabinet"))")
        }
        if let photos = batch.photoResult {
            lines.append("\(photos.saved) \(photos.saved == 1 ? "photo is" : "photos are") in Photos, in the album “\(photos.album)”")
        }
        setText("Filed", lines.joined(separator: ". ") + ".")
        secondary.title = batch.documentReceipt == nil ? "Open Photos" : "Show in Finder"
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
