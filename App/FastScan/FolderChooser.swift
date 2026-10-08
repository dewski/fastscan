import AppKit
import ScanKit

final class FolderChooser: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Destination: Equatable {
        var folderPath: String
        var newSubfolder: String?
    }

    private enum Row: Equatable {
        case header(String)
        case folder(Destination)
    }

    private let index: FolderIndex?
    private let suggested: [Destination]
    private let recent: [Destination]
    private let scores: [String: Double]
    private let rootName: String
    private let onChoose: (Destination) -> Void
    private let onChooseInFinder: () -> Void
    private var rows: [Row] = []
    private let search = NSSearchField()
    private let table = NSTableView()

    init(document: DocumentDraft, index: FolderIndex?, recent: [String], rootName: String,
         onChoose: @escaping (Destination) -> Void, onChooseInFinder: @escaping () -> Void) {
        self.index = index
        self.rootName = rootName
        let suggestion = Destination(folderPath: document.suggestion.folderPath, newSubfolder: document.suggestion.newSubfolder)
        var suggested = [suggestion]
        for candidate in document.result.candidates where suggested.count < 4 {
            let destination = Destination(folderPath: candidate.path, newSubfolder: nil)
            if !suggested.contains(destination) { suggested.append(destination) }
        }
        let inbox = Destination(folderPath: CandidateRanker.inboxName, newSubfolder: nil)
        if !suggested.contains(inbox) { suggested.append(inbox) }
        self.suggested = suggested
        self.recent = recent.map { Destination(folderPath: $0, newSubfolder: nil) }
            .filter { destination in !suggested.contains(destination) && (index?.folder(at: destination.folderPath) != nil) }
        scores = Dictionary(document.result.candidates.map { ($0.path, $0.score) }, uniquingKeysWith: max)
        self.onChoose = onChoose
        self.onChooseInFinder = onChooseInFinder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        search.placeholderString = "Search all folders"
        search.delegate = self
        search.setAccessibilityLabel("Search folders")
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("folder"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Folders")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let finder = NSButton(title: "Choose in Finder…", target: self, action: #selector(chooseInFinder))
        finder.isBordered = false
        finder.alignment = .left
        finder.font = .systemFont(ofSize: 13)
        finder.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 318))
        for subview in [search, scroll, separator, finder] { view.addSubview(subview) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            finder.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            finder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            finder.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        self.view = view
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            rows = [.header("Suggested")] + suggested.map(Row.folder)
            if !recent.isEmpty { rows += [.header("Recent")] + recent.map(Row.folder) }
        } else {
            let words = query.lowercased().split(separator: " ")
            let matches = (index?.folders ?? [])
                .filter { !$0.path.isEmpty && words.allSatisfy($0.path.lowercased().contains) }
                .sorted { a, b in
                    let (sa, sb) = (scores[a.path] ?? 0, scores[b.path] ?? 0)
                    if sa != sb { return sa > sb }
                    let nameMatch = (words.allSatisfy(a.name.lowercased().contains), words.allSatisfy(b.name.lowercased().contains))
                    if nameMatch.0 != nameMatch.1 { return nameMatch.0 }
                    return a.components.count != b.components.count ? a.components.count < b.components.count : a.path < b.path
                }
                .prefix(60)
            rows = matches.isEmpty ? [.header("No folders match")] : matches.map { .folder(Destination(folderPath: $0.path, newSubfolder: nil)) }
        }
        table.reloadData()
        table.scrollRowToVisible(0)
        if let first = rows.firstIndex(where: { if case .folder = $0 { true } else { false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(table.selectedRow); return true
        default: return false
        }
    }

    private func moveSelection(by step: Int) {
        var row = table.selectedRow
        repeat { row += step } while row >= 0 && row < rows.count && !isFolder(row)
        guard row >= 0, row < rows.count else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func isFolder(_ row: Int) -> Bool { if case .folder = rows[row] { true } else { false } }

    @objc private func clicked() { choose(table.clickedRow) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { choose(table.selectedRow) } else { super.keyDown(with: event) }
    }

    private func choose(_ row: Int) {
        guard row >= 0, row < rows.count, case .folder(let destination) = rows[row] else { return }
        onChoose(destination)
    }

    @objc private func chooseInFinder() { onChooseInFinder() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 22 : 30 }
        return 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isFolder(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ChooserRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = NSView()
            let label = Typeface.section(title)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        case .folder(let destination):
            let components = destination.folderPath.split(separator: "/").map(String.init)
            let parent: [String]
            let name: String
            if let newFolder = destination.newSubfolder {
                parent = components
                name = "New: \(newFolder)"
            } else {
                parent = Array(components.dropLast())
                name = components.last ?? rootName
            }
            let top = Typeface.label((parent.isEmpty ? [rootName] : parent).joined(separator: " › ") + " ›", font: .systemFont(ofSize: 11),
                                     color: .secondaryLabelColor, alignment: .left)
            let bottom = Typeface.label(name, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor, alignment: .left)
            (top as? StyledLabel)?.singleLine(.byTruncatingHead)
            (bottom as? StyledLabel)?.singleLine(.byTruncatingTail)
            let cell = ChooserCell(labels: [top, bottom])
            let stack = vstack([top, bottom], spacing: 1, alignment: .leading)
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                top.widthAnchor.constraint(equalTo: stack.widthAnchor),
                bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            cell.setAccessibilityLabel("\(name), in \(parent.joined(separator: ", "))")
            return cell
        }
    }
}

final class ChooserRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

final class ChooserCell: NSTableCellView {
    private let labels: [NSTextField]
    private let colors: [NSColor?]

    init(labels: [NSTextField]) {
        self.labels = labels
        colors = labels.map(\.textColor)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            for (label, color) in zip(labels, colors) {
                label.textColor = backgroundStyle == .emphasized ? (label === labels.last ? .white : .white.withAlphaComponent(0.75)) : color
            }
        }
    }
}
