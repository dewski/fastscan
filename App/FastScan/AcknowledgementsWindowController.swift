import AppKit

/// Shows THIRD-PARTY-NOTICES.md from the app's resources: the licenses of the SANE and
/// libjpeg-turbo builds bundled in Contents/Frameworks.
@MainActor
final class AcknowledgementsWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Acknowledgements"
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)

        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "THIRD-PARTY-NOTICES.md is missing from this copy of FastScan."
        window.contentView = scrollView
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
