import AppKit
import Quartz
import ScanKit

/// The one window. It renders purely from `ScanJob.state`: `render` maps the state to a screen,
/// transitions when the kind of screen changes, and otherwise updates the screen in place.
@MainActor
final class ScanWindowController: NSWindowController, ScreenContext, NSWindowDelegate {
    let job: ScanJob
    private let stage = NSView()
    private var screen: ScreenView?
    private var screenKind: ScreenKind?
    private var previous: ScanState = .looking
    private(set) var thumbnails: [CGImage] = []
    private var sheetThumbnails: [ObjectIdentifier: CGImage] = [:]
    private var documentThumbnails: [String: CGImage] = [:]
    private var popover: NSPopover?
    private(set) var latestIndex: FolderIndex?

    init(job: ScanJob) {
        self.job = job
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "FastScan"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        window.contentView = background
        stage.wantsLayer = true
        background.pin(stage)
        window.center()
        window.setFrameAutosaveName("ScanWindow")

        job.onChange = { [weak self] state in self?.render(state) }
        job.onSide = { [weak self] image in self?.thumbnails.append(displayCopy(image)) }
        job.onError = { [weak self] message in self?.showError(message) }
        render(job.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ state: ScanState) {
        if case .starting(_, 0) = state, !(previous.isJammed) { thumbnails = [] }
        let kind = ScreenKind(state)
        if kind != screenKind {
            show(makeScreen(kind), kind: kind)
        }
        screen?.update(state)
        updateDock(state)
        announce(state, from: previous)
        if case .filed = state, !(previous.isFiled) { celebrate() }
        if let document = state.batch?.document, state.batch?.documentFiled == true, previous.batch?.documentFiled != true {
            AppSettings.shared.noteFiled(into: document.folderPath)
        }
        previous = state
    }

    private func makeScreen(_ kind: ScreenKind) -> ScreenView {
        switch kind {
        case .looking: LookingScreen(context: self, target: self)
        case .notFound: NotFoundScreen(context: self, target: self)
        case .ready: ReadyScreen(context: self, target: self)
        case .scanning: ScanningScreen(context: self, target: self)
        case .jammed: JamScreen(context: self, target: self)
        case .reading: ReadingScreen(context: self, target: self)
        case .file: FileScreen(context: self, target: self)
        case .mixed: MixedScreen(context: self, target: self)
        case .filed: FiledScreen(context: self, target: self)
        case .failed: FailedScreen(context: self, target: self)
        }
    }

    /// Crossfades to the next screen with a short rise. Each screen animates from wherever its
    /// layer is on screen, so a quick second change redirects the motion instead of queueing it.
    private func show(_ next: ScreenView, kind: ScreenKind) {
        let old = screen
        screen = next
        screenKind = kind
        popover?.close()
        stage.pin(next)
        stage.layoutSubtreeIfNeeded()
        if let old, let oldLayer = old.layer, let newLayer = next.layer {
            Motion.fade(oldLayer, to: 0, duration: 0.16)
            newLayer.opacity = 0
            Motion.fade(newLayer, to: 1, duration: Motion.reduceMotion ? 0.2 : 0.28)
            if !Motion.reduceMotion {
                newLayer.transform = CATransform3DMakeTranslation(0, -10, 0)
                Motion.spring("transform", on: newLayer, to: NSValue(caTransform3D: CATransform3DIdentity), response: 0.45)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if old !== self?.screen { old.removeFromSuperview() }
            }
        }
        if let focus = next.initialFocus { window?.makeFirstResponder(focus) } else { window?.makeFirstResponder(nil) }
    }

    private func updateDock(_ state: ScanState) {
        NSApp.dockTile.badgeLabel = switch state {
        case .scanning(_, let pages) where pages > 0: "\(pages)"
        case .jammed: "!"
        default: nil
        }
    }

    private func announce(_ state: ScanState, from old: ScanState) {
        guard ScreenKind(state) != ScreenKind(old) else { return }
        let message: String? = switch state {
        case .ready: "Ready to scan."
        case .notFound: "Scanner not found."
        case .jammed(_, let pages): "The paper jammed. \(pages) pages are safe."
        case .starting: "Starting the scanner."
        case .reading: "Reading your document."
        case .reviewing(_, let batch, .document): batch.document.map { "Suggested: \($0.fileName) in \($0.destinationPath.split(separator: "/").last ?? "")." }
        case .reviewing(_, let batch, .mixed): "\(batch.paperSheets.count) papers and \(batch.photos.count) photos."
        case .filed: "Filed."
        default: nil
        }
        guard let message else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func celebrate() {
        let sound = NSSound(named: "Glass")
        sound?.volume = 0.3
        sound?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't file this"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    func thumbnail(for sheet: ScannedSheet) -> CGImage {
        let key = ObjectIdentifier(sheet.face.image)
        if let cached = sheetThumbnails[key] { return cached }
        let copy = displayCopy(sheet.face.image)
        sheetThumbnails[key] = copy
        return copy
    }

    func thumbnail(for document: DocumentDraft) -> CGImage? {
        // The staged URL stays put when pages are re-encoded, so the key also names what they hold.
        let key = "\(document.stagedURL.path)|\(document.pagesEncoding)|\(document.pages.count)|\(document.pages.first?.jpeg.count ?? 0)"
        if let cached = documentThumbnails[key] { return cached }
        guard let page = document.pages.first, let provider = CGDataProvider(data: page.jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let copy = displayCopy(image)
        documentThumbnails[key] = copy
        return copy
    }

    func injectThumbnails(_ images: [CGImage]) {
        thumbnails = images.map { displayCopy($0) }
    }

    func setIndex(_ index: FolderIndex?) { latestIndex = index }

    @objc func scan() { Task { await job.scan() } }
    @objc func stop() { job.stop() }
    @objc func scanRest() { Task { await job.scanRest() } }
    @objc func finishWithKept() { Task { await job.finishWithKept() } }

    @objc func retry() {
        if job.state.endpoint != nil { Task { await job.scan() } } else { Task { await job.discover() } }
    }

    @objc func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")!)
    }

    @objc func fileDocument() {
        (screen as? FileScreen)?.commitName()
        Task { await job.fileDocument() }
    }

    @objc func saveToInbox() {
        (screen as? FileScreen)?.commitName()
        Task { await job.fileDocument(toInbox: true) }
    }

    func rename(_ name: String) { job.rename(name) }

    @objc func colorChanged(_ sender: NSSegmentedControl) { chooseColor(ColorMode.allCases[sender.selectedSegment]) }

    @discardableResult
    func chooseColor(_ mode: ColorMode) -> Task<Void, Never>? { job.chooseColor(mode) }

    @objc func frontsOnlyChanged(_ sender: NSButton) { choosePages(sender.state == .on ? .frontsOnly : .allSides) }

    @discardableResult
    func choosePages(_ selection: PageSelection) -> Task<Void, Never>? { job.choosePages(selection) }

    @objc func flipSheet(_ sender: SheetTile) { Task { await job.flip(sender.sheetID) } }
    @objc func fileAll() { Task { await job.fileAll() } }
    @objc func oneAtATime() { job.focus(.document) }
    @objc func showAllItems() { job.focus(.mixed) }
    @objc func undoFiling() { Task { await job.undo() } }

    /// Edit > Undo (⌘Z) takes back a filing; while typing, the field editor handles it first.
    @objc func undo(_ sender: Any?) { undoFiling() }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(undo(_:)) {
            return MainActor.assumeIsolated { job.state.batch.map { $0.documentFiled || $0.photosFiled } ?? false }
        }
        return super.responds(to: selector)
    }
    @objc func scanMore() { job.finish() }

    @objc func showInFinder() {
        guard let batch = job.state.batch else { return }
        if let receipt = batch.documentReceipt {
            NSWorkspace.shared.activateFileViewerSelecting([receipt.fileURL])
        } else if let photos = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: photos, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func chooseFolder(_ sender: NSView) {
        guard let document = job.state.batch?.document else { return }
        let settings = AppSettings.shared
        let chooser = FolderChooser(
            document: document, index: latestIndex, recent: settings.recentDestinations, rootName: settings.filingCabinet.lastPathComponent,
            onChoose: { [weak self] destination in
                self?.popover?.close()
                self?.job.choose(folderPath: destination.folderPath, newSubfolder: destination.newSubfolder)
            },
            onChooseInFinder: { [weak self] in self?.chooseInFinder() })
        let popover = NSPopover()
        popover.contentViewController = chooser
        popover.behavior = .transient
        popover.animates = !Motion.reduceMotion
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: sender.isFlipped ? .minY : .maxY)
        self.popover = popover
    }

    private func chooseInFinder() {
        popover?.close()
        guard let window else { return }
        let root = AppSettings.shared.filingCabinet.standardizedFileURL
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.prompt = "Choose"
        panel.message = "Choose a folder in \(root.lastPathComponent)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url?.standardizedFileURL else { return }
            guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
                self?.showError("Choose a folder inside \(root.lastPathComponent).")
                return
            }
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            self?.job.choose(folderPath: relative, newSubfolder: nil)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        switch job.state {
        case .starting, .scanning: job.stop()
        case .reviewing(_, let batch, .document) where batch.isMixed: job.focus(.mixed)
        default: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", screen is FileScreen { togglePreview(nil) } else { super.keyDown(with: event) }
    }

    @objc func togglePreview(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { job.state.batch?.document != nil }
    }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

extension ScanWindowController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { job.state.batch?.document?.stagedURL as NSURL? }
    }
}

extension ScanState {
    var isJammed: Bool { if case .jammed = self { true } else { false } }
    var isFiled: Bool { if case .filed = self { true } else { false } }
}

