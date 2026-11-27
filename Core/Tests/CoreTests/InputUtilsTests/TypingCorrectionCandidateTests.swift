#if os(macOS)
import Core
import EfficientNGram
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
@Test(.timeLimit(.minutes(1)))
func spaceOffersAdjacentKeyCorrectionWhenLiteralKanaLeadsDictionaryConversion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let models = DebugTypoCorrectionWeights.modelDirectoryURL(azooKeyApplicationSupportDirectoryURL: directory)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // 「ふくすう」の読みのスコアだけでは「あくすう」を上回らないモデルを作る。
    let corpus = [
        (reading: "アクスウ", count: 8),
        (reading: "フクスウ", count: 4),
        (reading: "アクウ", count: 12),
        (reading: "アンスウ", count: 16),
        (reading: "アクスイ", count: 12),
        (reading: "アクス", count: 16)
    ].flatMap { Array(repeating: "\u{EE00}" + $0.reading, count: $0.count) }
    trainNGram(lines: corpus, n: 5, baseFilePattern: "lm", outputDir: models.path, resumeFilePattern: nil)

    let tableURL = directory.appendingPathComponent("input.tsv")
    try "2\tふ\n3\tあ\n4\tう\nh\tく\nr\tす\n".write(to: tableURL, atomically: true, encoding: .utf8)
    let tableName = "typing-correction-\(UUID())"
    InputStyleManager.registerInputStyle(table: try InputStyleManager.loadTable(from: tableURL), for: tableName)
    let style = InputStyle.mapped(id: .tableName(tableName))
    let enabled = Config.DebugTypoCorrection().value
    defer { Config.DebugTypoCorrection().value = enabled }
    Config.DebugTypoCorrection().value = true

    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: directory.appendingPathComponent("memory", isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: false)
    )
    defer { manager.stopComposition() }
    manager.insertAtCursorPosition("3hr4", inputStyle: style)
    #expect(manager.convertTarget == "あくすう")
    manager.enterCandidateSelection(inputStyle: style)

    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
        if case let .selecting(candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
           let index = candidates.firstIndex(where: { $0.text == "複数" }) {
            #expect(manager.makeCandidatePresentations(candidates)[index].displayContext.annotationText == "訂正")
            manager.requestSelectingRow(index)
            #expect(manager.commitMarkedText(inputState: .selecting) == "複数")
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("Spaceで開く変換候補一覧に「複数」がありません。")
}
#endif
