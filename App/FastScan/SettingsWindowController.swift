import AppKit
import ScanKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let cabinetPopup = NSPopUpButton()
    private let unsurePopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let scannerDot = NSView()
    private let scannerLabel = Typeface.label("", font: .systemFont(ofSize: 13), color: .labelColor, alignment: .left)
    private let settings = AppSettings.shared
    private let cabinetNote = Typeface.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lineHeight: 15, alignment: .left)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)

        cabinetPopup.target = self
        cabinetPopup.action = #selector(cabinetChanged)
        cabinetPopup.setAccessibilityLabel("Filing cabinet")
        unsurePopup.addItems(withTitles: ["Save to Inbox", "Use Best Guess"])
        unsurePopup.target = self
        unsurePopup.action = #selector(unsureChanged)
        unsurePopup.setAccessibilityLabel("When unsure")
        colorPopup.addItems(withTitles: ColorMode.allCases.map(\.title))
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged)
        colorPopup.setAccessibilityLabel("Color")

        let unsureNote = Typeface.label("When FastScan can't tell where a document goes, the folder starts as your Inbox.",
                                        font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lineHeight: 15, alignment: .left)
        let colorNote = Typeface.label("Automatic keeps color only for pages that have it, such as a stamp or a logo. You can change it for each document before filing.",
                                       font: .systemFont(ofSize: 11), color: .secondaryLabelColor, lineHeight: 15, alignment: .left)
        scannerDot.wantsLayer = true
        scannerDot.layer?.cornerRadius = 3.5
        scannerDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scannerDot.widthAnchor.constraint(equalToConstant: 7), scannerDot.heightAnchor.constraint(equalToConstant: 7)])

        let grid = NSGridView(views: [
            [label("Filing cabinet"), vstack([cabinetPopup, cabinetNote], spacing: 4, alignment: .leading)],
            [label("When unsure"), vstack([unsurePopup, unsureNote], spacing: 4, alignment: .leading)],
            [label("Color"), vstack([colorPopup, colorNote], spacing: 4, alignment: .leading)],
            [label("Scanner"), hstack([scannerDot, scannerLabel], spacing: 6)],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        grid.rowSpacing = 16
        grid.columnSpacing = 14
        for row in 0..<4 { grid.row(at: row).yPlacement = .top }
        let content = NSView()
        content.pin(grid, insets: NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 28))
        for note in [cabinetNote, unsureNote, colorNote] { note.widthAnchor.constraint(equalToConstant: 250).isActive = true }
        cabinetPopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        unsurePopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        colorPopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        window.contentView = content
        window.center()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> NSTextField {
        let field = Typeface.label(text, font: .systemFont(ofSize: 13), color: .labelColor, alignment: .right)
        field.maximumNumberOfLines = 1
        return field
    }

    func reload() {
        cabinetPopup.removeAllItems()
        let root = settings.filingCabinet
        let item = NSMenuItem(title: FileManager.default.displayName(atPath: root.path), action: nil, keyEquivalent: "")
        let icon = NSWorkspace.shared.icon(forFile: root.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        item.toolTip = root.path
        cabinetPopup.menu?.addItem(item)
        cabinetPopup.menu?.addItem(.separator())
        cabinetPopup.addItem(withTitle: "Choose…")
        cabinetPopup.selectItem(at: 0)
        cabinetPopup.isEnabled = settings.rootOverride == nil
        Typeface.set(cabinetNote, settings.rootOverride == nil
            ? "Suggestions are learned from how this folder is organized."
            : "Set by FASTSCAN_ROOT for testing. Suggestions are learned from how this folder is organized.")
        unsurePopup.selectItem(at: settings.whenUnsure == .inbox ? 0 : 1)
        colorPopup.selectItem(at: ColorMode.allCases.firstIndex(of: settings.colorMode) ?? 0)
    }

    func showScanner(_ state: ScanState) {
        let (text, color): (String, NSColor) = switch state {
        case .looking: ("Looking…", .systemYellow)
        case .notFound(.localNetworkDenied): ("Local Network access is off", .systemOrange)
        case .notFound: ("Not found", .systemOrange)
        case .failed(nil, _): ("Not found", .systemOrange)
        default: ("\(state.endpoint?.name ?? "Scanner") · Connected", .systemGreen)
        }
        Typeface.set(scannerLabel, text)
        scannerDot.layer?.backgroundColor = color.cgColor
    }

    @objc private func cabinetChanged() {
        guard cabinetPopup.indexOfSelectedItem == cabinetPopup.numberOfItems - 1, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.filingCabinet
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.settings.filingCabinet = url }
            self?.reload()
        }
    }

    @objc private func colorChanged() {
        settings.colorMode = ColorMode.allCases[colorPopup.indexOfSelectedItem]
    }

    @objc private func unsureChanged() {
        settings.whenUnsure = unsurePopup.indexOfSelectedItem == 0 ? .inbox : .bestGuess
    }
}

extension ColorMode {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .color: "Color"
        case .grayscale: "Grayscale"
        }
    }

    /// The File screen's segment labels, short enough for a compact control beside the page.
    var shortTitle: String {
        switch self {
        case .automatic: "Auto"
        case .color: "Color"
        case .grayscale: "Gray"
        }
    }
}
