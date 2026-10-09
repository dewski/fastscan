import AppKit
import ScanKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ScanWindowController?
    private var settingsController: SettingsWindowController?
    private var acknowledgementsController: AcknowledgementsWindowController?
    private var job: ScanJob?
    private var demo: Demo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        if environment["FASTSCAN_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if environment["FASTSCAN_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        Self.forgetRemovedPreferences()
        NSApp.mainMenu = makeMainMenu()

        let demoState = environment["FASTSCAN_DEMO"]
        let photoWriter: any PhotoLibraryWriter = if let directory = environment["FASTSCAN_PHOTOS_DRYRUN"] ?? (demoState != nil ? NSTemporaryDirectory() + "fastscan-demo-photos" : nil) {
            DryRunPhotoWriter(directory: URL(filePath: directory))
        } else {
            PhotoKitWriter()
        }
        let job = ScanJob(reader: makeReader(), photoWriter: photoWriter)
        self.job = job
        let controller = ScanWindowController(job: job)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()

        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        job.onChange = { [weak self, weak controller] state in
            controller?.render(state)
            self?.settingsController?.showScanner(state)
        }

        if let demoState {
            demo = Demo(state: demoState, controller: controller, job: job, openSettings: { [weak self] in self?.showSettings(nil) },
                        openAcknowledgements: { [weak self] in self?.showAcknowledgements(nil) })
            demo?.run(snapshot: environment["FASTSCAN_SNAPSHOT"].map { URL(filePath: $0) },
                      delay: environment["FASTSCAN_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5)
        } else {
            refreshIndex()
            Task { await job.discover() }
            if let path = environment["FASTSCAN_SNAPSHOT"] {
                let delay = environment["FASTSCAN_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 8
                Snapshot.after(.seconds(delay), to: URL(filePath: path), windows: { [weak controller] in [controller?.window].compactMap { $0 } })
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeReader() -> BatchReader {
        let settings = AppSettings.shared
        return BatchReader(root: settings.filingCabinet, whenUnsure: settings.whenUnsure, colorMode: settings.colorMode)
    }

    private func settingsChanged() {
        guard let job else { return }
        let rootChanged = job.reader.root != AppSettings.shared.filingCabinet
        job.reader = BatchReader(root: AppSettings.shared.filingCabinet, indexStore: job.reader.indexStore,
                                 whenUnsure: AppSettings.shared.whenUnsure, colorMode: AppSettings.shared.colorMode)
        if rootChanged { refreshIndex() }
    }

    private func refreshIndex() {
        guard let job, let controller = windowController else { return }
        let store = job.reader.indexStore, root = job.reader.root
        Task {
            controller.setIndex(try? await store.current(root: root))
            controller.setIndex(try? await store.refresh(root: root))
        }
    }

    /// v1 kept scan options the user could change; v2 has none. `sides` was a short-lived Sides
    /// setting, replaced by each document's Fronts only.
    private static func forgetRemovedPreferences() {
        for key in ["scanSettings", "skipBlankPages", "destination", "sides"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.reload()
        if let job { settingsController?.showScanner(job.state) }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        if acknowledgementsController == nil { acknowledgementsController = AcknowledgementsWindowController() }
        acknowledgementsController?.showWindow(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "FastScan")
        app.addItem(withTitle: "About FastScan", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Acknowledgements", action: #selector(showAcknowledgements(_:)), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide FastScan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit FastScan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        for submenu in [app, edit, window] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }
}

/// Writes the app's windows to a PNG, for checking the UI from a script on machines where the
/// shell has no screen-recording permission. Child windows such as popovers are composited at
/// their place over the main window.
enum Snapshot {
    static func after(_ delay: Duration, to url: URL, windows: @escaping @MainActor () -> [NSWindow], then: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            write(windows(), to: url)
            then?()
        }
    }

    @MainActor
    static func write(_ windows: [NSWindow], to url: URL) {
        guard let main = windows.first, let mainView = main.contentView?.superview ?? main.contentView else { return }
        let scale = main.backingScaleFactor
        let size = mainView.bounds.size
        let others = NSApp.windows.filter { $0 !== main && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        let union = others.reduce(main.frame) { $0.union($1.frame) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for window in [main] + others {
            // A popover's own frame is glass the window server draws, which caching can't capture,
            // so it is stood in for by a plain rounded panel with a shadow.
            let isMain = window === main
            guard let view = isMain ? mainView : window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let frame = view.convert(view.bounds, to: nil)
            let origin = CGPoint(x: window.frame.minX + (isMain ? 0 : frame.minX) - union.minX,
                                 y: window.frame.minY + (isMain ? 0 : frame.minY) - union.minY)
            let rect = CGRect(origin: origin, size: isMain ? size : view.bounds.size)
            if !isMain {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = .black.withAlphaComponent(0.25)
                shadow.shadowBlurRadius = 24
                shadow.shadowOffset = NSSize(width: 0, height: -8)
                shadow.set()
                let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                NSColor(white: dark ? 0.16 : 1, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if isMain {
                rep.draw(in: rect)
            } else if let context = NSGraphicsContext.current?.cgContext, let layer = view.layer {
                // Popover content is vibrant; caching draws it washed out, so render its layers directly.
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                if !layer.isGeometryFlipped && view.isFlipped {
                    context.translateBy(x: 0, y: rect.height)
                    context.scaleBy(x: 1, y: -1)
                }
                layer.render(in: context)
                context.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
