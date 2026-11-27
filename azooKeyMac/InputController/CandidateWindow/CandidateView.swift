import Cocoa
import Core
import KanaKanjiConverterModule

@MainActor protocol CandidatesViewControllerDelegate: AnyObject {
    func candidateSubmitted()
    func candidateSelectionChanged(_ row: Int)
}

class NumberedCandidatesViewController: BaseCandidateViewController {
    private static let maximumNumberedRows = 9
    fileprivate(set) var firstNumberedRow = 0
    var showsCandidateNumbers: Bool { true }

    override var numberOfVisibleRows: Int {
        min(Self.maximumNumberedRows, self.tableView.numberOfRows)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let scrollView = self.tableView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self, selector: #selector(renumberAfterScrolling), name: NSScrollView.didLiveScrollNotification, object: scrollView
            )
        }
    }

    override func updateCandidatePresentations(_ candidates: [CandidatePresentation], selectionIndex: Int?, cursorLocation: CGPoint) {
        let lastPageStart = max(0, candidates.count - Self.maximumNumberedRows)
        self.firstNumberedRow = selectionIndex == nil ? 0 : min(self.firstNumberedRow, lastPageStart)
        super.updateCandidatePresentations(
            candidates,
            selectionIndex: selectionIndex,
            cursorLocation: cursorLocation
        )
    }

    override internal func updateSelectionCallback(_ row: Int, notifySelectionChange: Bool) {
        if row < self.firstNumberedRow {
            self.firstNumberedRow = row
        } else if row >= self.firstNumberedRow + Self.maximumNumberedRows {
            self.firstNumberedRow = row - Self.maximumNumberedRows + 1
        }
    }

    @objc private func renumberAfterScrolling() {
        let rows = self.tableView.rows(in: self.tableView.visibleRect)
        guard self.showsCandidateNumbers, rows.length > 0 else {
            return
        }
        let lastPageStart = max(0, self.candidates.count - Self.maximumNumberedRows)
        self.firstNumberedRow = min(rows.location, lastPageStart)
        self.updateVisibleRows()
    }

    func getNumberCandidate(num: Int) -> Int? {
        guard self.showsCandidateNumbers, (1...Self.maximumNumberedRows).contains(num) else {
            return nil
        }
        let row = self.firstNumberedRow + num - 1
        return self.candidates.indices.contains(row) ? row : nil
    }

    fileprivate func numberPrefix(forRow row: Int) -> NSAttributedString? {
        let number = row - self.firstNumberedRow + 1
        guard self.getNumberCandidate(num: number) == row else {
            return nil
        }
        return NSAttributedString(string: "\(number).", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: self.currentSelectedRow == row ? NSColor.white : NSColor.secondaryLabelColor,
            .baselineOffset: 2
        ])
    }
}

class CandidatesViewController: NumberedCandidatesViewController {
    weak var delegate: (any CandidatesViewControllerDelegate)?
    var showCandidateIndex = false
    override var showsCandidateNumbers: Bool { self.showCandidateIndex }

    override internal func updateSelectionCallback(_ row: Int, notifySelectionChange: Bool) {
        super.updateSelectionCallback(row, notifySelectionChange: notifySelectionChange)
        if notifySelectionChange {
            self.delegate?.candidateSelectionChanged(row)
        }
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let presentation = self.candidates[row]
        let text = NSMutableAttributedString()
        if let numberPrefix = self.numberPrefix(forRow: row) {
            text.append(numberPrefix)
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: presentation.candidate.text))
        cell.candidateTextField.attributedStringValue = text
        cell.updateAnnotation(presentation.displayContext.annotationText, selected: self.currentSelectedRow == row)
    }

    func selectCandidatePage(_ count: Int) -> Int? {
        guard !self.candidates.isEmpty else {
            return nil
        }
        let pageSize = self.numberOfVisibleRows
        let row = min(max(0, self.currentSelectedRow + count * pageSize), self.candidates.count - 1)
        guard row != self.currentSelectedRow else {
            return row
        }
        let firstRow = min(max(0, self.firstNumberedRow + count * pageSize), self.candidates.count - pageSize)
        self.firstNumberedRow = firstRow
        self.tableView.scrollRowToVisible(firstRow + pageSize - 1)
        self.tableView.scrollRowToVisible(firstRow)
        self.updateSelection(to: row, notifySelectionChange: false)
        return row
    }

    func hide() {
        self.currentSelectedRow = -1
        self.firstNumberedRow = 0
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        let hasAnnotation = self.candidates.contains { $0.displayContext.annotationText != nil }
        if self.showCandidateIndex {
            return maxContentWidth + 48 + (hasAnnotation ? 56 : 0)
        } else {
            return maxContentWidth + 20 + (hasAnnotation ? 56 : 0)
        }
    }
}

class PredictionCandidatesViewController: NumberedCandidatesViewController {
    private let numberTabStop: CGFloat = 16
    private let candidateTabStop: CGFloat = 36
    private let prefixSymbolName = "arrow.forward.to.line.compact"
    private let prefixFontSize: CGFloat = 12

    override func updateCandidatePresentations(_ candidates: [CandidatePresentation], selectionIndex: Int?, cursorLocation: CGPoint) {
        let selectedText = self.getSelectedCandidate()?.text
        let retainedIndex = selectedText.flatMap { text in candidates.firstIndex { $0.candidate.text == text } }
        super.updateCandidatePresentations(
            candidates,
            selectionIndex: selectionIndex ?? retainedIndex ?? (candidates.isEmpty ? nil : 0),
            cursorLocation: cursorLocation
        )
    }

    func handleNavigation(_ event: KeyEventCore, selectionKeys: Config.PredictionCandidateSelectionKeys.Value) -> Bool {
        guard event.modifierFlags == selectionKeys.modifiers, !self.candidates.isEmpty else {
            return false
        }
        switch event.keyCode {
        case 126:
            self.selectPrevCandidate()
        case 125:
            self.selectNextCandidate()
        default:
            return false
        }
        return true
    }

    override internal func configureCellView(_ cell: CandidateTableCellView, forRow row: Int) {
        let candidateText = candidates[row].candidate.text
        let attributedString = NSMutableAttributedString()

        let isSelected = currentSelectedRow == row
        let candidateColor = isSelected ? NSColor.white : NSColor.labelColor

        if let symbol = NSImage(systemSymbolName: prefixSymbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: prefixFontSize, weight: .regular)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let attachment = NSTextAttachment()
            attachment.image = configured
            attachment.bounds = NSRect(x: 0, y: -2, width: prefixFontSize + 2, height: prefixFontSize + 2)
            attributedString.append(NSAttributedString(attachment: attachment))
        }
        attributedString.append(NSAttributedString(string: "\t"))
        if let numberPrefix = self.numberPrefix(forRow: row) {
            attributedString.append(numberPrefix)
        }
        attributedString.append(NSAttributedString(string: "\t"))
        let candidateAttributed = NSAttributedString(
            string: candidateText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: candidateColor
            ]
        )
        attributedString.append(candidateAttributed)

        let fullRange = NSRange(location: 0, length: attributedString.length)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: numberTabStop, options: [:]),
            NSTextTab(textAlignment: .left, location: candidateTabStop, options: [:])
        ]
        paragraphStyle.defaultTabInterval = 24
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        cell.candidateTextField.attributedStringValue = attributedString
        cell.updateAnnotation(candidates[row].displayContext.annotationText, selected: isSelected)
    }

    override func getWindowWidth(maxContentWidth: CGFloat) -> CGFloat {
        let hasAnnotation = self.candidates.contains { $0.displayContext.annotationText != nil }
        return maxContentWidth + candidateTabStop + 20 + (hasAnnotation ? 36 : 0)
    }
}

private extension CandidateTableCellView {
    func updateAnnotation(_ annotation: String?, selected: Bool) {
        self.showCandidateAnnotationTextField(annotation != nil)
        self.candidateAnnotationTextField.attributedStringValue = NSAttributedString(
            string: annotation ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: selected ? NSColor.white : NSColor.systemGray
            ]
        )
    }
}
