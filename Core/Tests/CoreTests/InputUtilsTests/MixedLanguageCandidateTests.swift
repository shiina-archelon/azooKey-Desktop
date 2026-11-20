@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
private final class MixedLanguageDelegate: SegmentManagerDelegate {
    var updated: (() -> Void)?

    nonisolated func getLeftSideContext(maxCount: Int) -> String? { nil }
    nonisolated func getRightSideContext(maxCount: Int) -> String? { nil }
    func candidatesDidChange() { self.updated?() }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MixedLanguageCandidateTests {
    @MainActor
    private func manager() throws -> SegmentsManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory, containerURL: nil, context: .init(useZenzai: false))
    }

    @MainActor
    private func candidates(_ manager: SegmentsManager) -> [Candidate] {
        guard case let .selecting(candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
            Issue.record("変換候補が表示されていません。")
            return []
        }
        return candidates
    }

    @MainActor
    private func update(_ manager: SegmentsManager, delegate: MixedLanguageDelegate) async {
        await self.changeCandidates(manager, delegate: delegate) {
            manager.update(requestRichCandidates: true)
        }
    }

    @MainActor
    private func changeCandidates(_ manager: SegmentsManager, delegate: MixedLanguageDelegate, operation: () -> Void) async {
        manager.delegate = delegate
        await withCheckedContinuation { continuation in
            delegate.updated = { continuation.resume() }
            operation()
        }
        delegate.updated = nil
    }

    @MainActor
    @Test func keepsFirstCandidateAndCommitsTheWholeMixedInput() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousLearning = Config.Learning().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.Learning().value = previousLearning
        }
        Config.MixedLanguageCandidates().value = true
        Config.Learning().value = .nothing
        let manager = try self.manager()
        let delegate = MixedLanguageDelegate()
        manager.delegate = delegate
        manager.insertAtCursorPosition("atarashiimacchouhoshii", inputStyle: .mapped(id: .defaultRomanToKana))
        manager.insertCompositionSeparator(inputStyle: .mapped(id: .defaultRomanToKana), skipUpdate: true)
        var original: [Candidate] = []
        await withCheckedContinuation { continuation in
            delegate.updated = { continuation.resume() }
            manager.update(requestRichCandidates: true)
            original = self.candidates(manager)
        }
        let result = self.candidates(manager)
        #expect(result.first == original.first)
        let index = try #require(result.firstIndex { $0.text == "新しいmac超欲しい" })
        #expect(index == 1)
        if original.count > 1 {
            #expect(result.firstIndex(of: original[1]) == 2)
        }
        manager.requestSelectingRow(index)
        #expect(manager.commitMarkedText(inputState: .selecting) == "新しいmac超欲しい")
        #expect(manager.isEmpty)
    }

    @MainActor
    @Test func supportsKanaInputAndPreservesTheSelectedCandidate() async throws {
        let previous = Config.MixedLanguageCandidates().value
        defer { Config.MixedLanguageCandidates().value = previous }
        Config.MixedLanguageCandidates().value = true
        let manager = try self.manager()
        let delegate = MixedLanguageDelegate()
        manager.delegate = delegate
        manager.insertAtCursorPosition("3qodemaca）4ーde", inputStyle: .mapped(id: .defaultKanaJIS))
        var selected: Candidate?
        await withCheckedContinuation { continuation in
            delegate.updated = { continuation.resume() }
            manager.update(requestRichCandidates: true)
            manager.requestSelectingRow(1)
            selected = manager.selectedCandidate
        }
        #expect(self.candidates(manager).contains { $0.text == "新しいmac超欲しい" })
        #expect(manager.selectedCandidate == selected)
    }

    @MainActor
    @Test func supportsCustomInputTables() async throws {
        let previous = Config.MixedLanguageCandidates().value
        defer { Config.MixedLanguageCandidates().value = previous }
        Config.MixedLanguageCandidates().value = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "q\tあ\nw\tた\ne\tら\nr\tし\nt\tい\ny\tち\nu\tょ\nx\tう\no\tほ\nm\tも\na\tち\nc\tそ\n".write(to: url, atomically: true, encoding: .utf8)
        let name = "mixed-language-tests-\(UUID().uuidString)"
        InputStyleManager.registerInputStyle(table: try InputStyleManager.loadTable(from: url), for: name)
        let manager = try self.manager()
        manager.insertAtCursorPosition("qwertmacyuxort", inputStyle: .mapped(id: .tableName(name)))
        await self.update(manager, delegate: MixedLanguageDelegate())
        #expect(self.candidates(manager).contains { $0.text == "新しいmac超欲しい" })
    }

    @MainActor
    @Test func recognizesAnEnglishWordAfterEditingItsFirstLetter() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousLearning = Config.Learning().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.Learning().value = previousLearning
        }
        Config.MixedLanguageCandidates().value = true
        Config.Learning().value = .nothing
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "s\tと\nc\tそ\no\tら\nr\tす\ne\tい\nw\tで\nf\tは\ny\tん\nt\tて\nx\tさ\n".write(to: url, atomically: true, encoding: .utf8)
        let name = "mixed-language-edit-tests-\(UUID().uuidString)"
        InputStyleManager.registerInputStyle(table: try InputStyleManager.loadTable(from: url), for: name)
        let style = InputStyle.mapped(id: .tableName(name))
        for replacesFirstLetter in [false, true] {
            let manager = try self.manager()
            manager.insertAtCursorPosition(replacesFirstLetter ? "xcorewfyte" : "corewfyte", inputStyle: style)
            manager.moveCursor(count: -100)
            if replacesFirstLetter {
                manager.moveCursor(count: 1)
                manager.deleteBackwardFromCursorPosition()
            }
            manager.insertAtCursorPosition("s", inputStyle: style)
            manager.insertCompositionSeparator(inputStyle: style, skipUpdate: true)
            await self.update(manager, delegate: MixedLanguageDelegate())
            let result = self.candidates(manager)
            let index = try #require(result.firstIndex { $0.text == "scoreで判定" })
            #expect(index == 1)
            manager.requestSelectingRow(index)
            #expect(manager.commitMarkedText(inputState: .selecting) == "scoreで判定")
            #expect(manager.isEmpty)
        }
    }

    @MainActor
    @Test func keepsWeakerMixedInterpretationsOutOfTheFirstPage() async throws {
        let previous = Config.MixedLanguageCandidates().value
        defer { Config.MixedLanguageCandidates().value = previous }
        Config.MixedLanguageCandidates().value = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "g\tき\no\tら\nl\tり\ne\tい\nw\tで\nd\tし\nb\tべ\nq\tた\n".write(to: url, atomically: true, encoding: .utf8)
        let name = "mixed-language-ranking-tests-\(UUID().uuidString)"
        InputStyleManager.registerInputStyle(table: try InputStyleManager.loadTable(from: url), for: name)
        let manager = try self.manager()
        manager.insertAtCursorPosition("googlewdobq", inputStyle: .mapped(id: .tableName(name)))
        await self.update(manager, delegate: MixedLanguageDelegate())
        let result = self.candidates(manager).map(\.text)
        #expect(result.firstIndex(of: "googleで調べた") == 1)
        for alternative in ["キラogleで調べた", "googleでdo下手", "goo切り位で調べた"] {
            #expect(result.contains(alternative))
            #expect(!result.prefix(9).contains(alternative))
        }
    }

    @MainActor
    @Test func convertsAnAdjustedRangeWithoutConsumingTheSuffix() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousLearning = Config.Learning().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.Learning().value = previousLearning
        }
        Config.MixedLanguageCandidates().value = true
        Config.Learning().value = .nothing
        let manager = try self.manager()
        let delegate = MixedLanguageDelegate()
        manager.insertAtCursorPosition("macnihonngo", inputStyle: .mapped(id: .defaultRomanToKana))
        await self.changeCandidates(manager, delegate: delegate) { manager.editSegment(count: -4) }
        var index = try #require(self.candidates(manager).firstIndex { $0.text == "mac" })
        manager.requestSelectingRow(index)
        await self.changeCandidates(manager, delegate: delegate) { manager.editSegment(count: 1) }
        index = try #require(self.candidates(manager).firstIndex { $0.text == "macに" })
        manager.requestSelectingRow(index)
        await self.changeCandidates(manager, delegate: delegate) { manager.editSegment(count: -1) }
        index = try #require(self.candidates(manager).firstIndex { $0.text == "mac" })
        manager.requestSelectingRow(index)
        let selected = try #require(manager.selectedCandidate)
        manager.prefixCandidateCommited(selected, leftSideContext: "")
        #expect(manager.convertTarget == "にほんご")
        #expect(!manager.isEmpty)
    }

    @MainActor
    @Test func offersMixedCandidatesAfterConfirmingTheLeadingClause() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousLearning = Config.Learning().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.Learning().value = previousLearning
        }
        Config.MixedLanguageCandidates().value = true
        Config.Learning().value = .nothing
        let manager = try self.manager()
        let delegate = MixedLanguageDelegate()
        manager.insertAtCursorPosition("nihonngomac", inputStyle: .mapped(id: .defaultRomanToKana))
        await self.changeCandidates(manager, delegate: delegate) { manager.editSegment(count: -2) }
        let index = try #require(self.candidates(manager).firstIndex { $0.text == "日本語" })
        manager.requestSelectingRow(index)
        let selected = try #require(manager.selectedCandidate)
        await self.changeCandidates(manager, delegate: delegate) {
            manager.prefixCandidateCommited(selected, leftSideContext: "")
        }
        let remainingIndex = try #require(self.candidates(manager).firstIndex { $0.text == "mac" })
        manager.requestSelectingRow(remainingIndex)
        #expect(manager.commitMarkedText(inputState: .selecting) == "mac")
        #expect(manager.isEmpty)
    }

    @MainActor
    @Test func completesAnUnlistedPrefixAfterTheOrdinaryPredictions() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousPrediction = Config.DebugPredictiveTyping().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.DebugPredictiveTyping().value = previousPrediction
        }
        Config.MixedLanguageCandidates().value = true
        Config.DebugPredictiveTyping().value = true
        let manager = try self.manager()
        let delegate = MixedLanguageDelegate()
        var original: [SegmentsManager.PredictionCandidate] = []
        await self.changeCandidates(manager, delegate: delegate) {
            manager.insertAtCursorPosition("githu", inputStyle: .mapped(id: .defaultRomanToKana))
            original = manager.requestPredictionCandidates()
        }
        let result = manager.requestPredictionCandidates()
        #expect(Array(result.prefix(original.count)) == original)
        let mixed = result.filter(\.isMixedLanguage)
        #expect(!mixed.isEmpty)
        #expect(mixed.count <= 2)
        #expect(mixed.contains { $0.displayText.lowercased() == "github" })
        #expect(result.dropFirst(original.count).allSatisfy { $0.isMixedLanguage })
    }

    @MainActor
    @Test func acceptsAnEnglishCompletionAndContinuesCustomInput() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousPrediction = Config.DebugPredictiveTyping().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.DebugPredictiveTyping().value = previousPrediction
        }
        Config.MixedLanguageCandidates().value = true
        Config.DebugPredictiveTyping().value = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "g\tき\ni\tに\nt\tか\nh\tく\nu\tな\nq\tた\n".write(to: url, atomically: true, encoding: .utf8)
        let name = "mixed-language-prediction-tests-\(UUID().uuidString)"
        InputStyleManager.registerInputStyle(table: try InputStyleManager.loadTable(from: url), for: name)
        let style = InputStyle.mapped(id: .tableName(name))
        let manager = try self.manager()
        await self.changeCandidates(manager, delegate: MixedLanguageDelegate()) {
            manager.insertAtCursorPosition("githu", inputStyle: style)
        }
        let prediction = try #require(manager.requestPredictionCandidates().first { $0.isMixedLanguage && $0.displayText.lowercased() == "github" })
        manager.acceptPredictionCandidate(prediction)
        #expect(!manager.isEmpty)
        #expect(manager.convertTarget == "github")
        manager.insertAtCursorPosition("q", inputStyle: style)
        #expect(manager.convertTarget == "githubた")
        manager.acceptPredictionCandidate(prediction)
        #expect(manager.convertTarget == "githubた")
    }

    @MainActor
    @Test func offersAnExistingEnglishWordInsideCustomJapaneseInput() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousPrediction = Config.DebugPredictiveTyping().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.DebugPredictiveTyping().value = previousPrediction
        }
        Config.MixedLanguageCandidates().value = true
        Config.DebugPredictiveTyping().value = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "g\tき\no\tら\nl\tり\ne\tい\nw\tて\n「\t゛\nて「\tで\nq\tた\n".write(to: url, atomically: true, encoding: .utf8)
        let name = "mixed-language-existing-word-tests-\(UUID().uuidString)"
        InputStyleManager.registerInputStyle(table: try InputStyleManager.loadTable(from: url), for: name)
        let style = InputStyle.mapped(id: .tableName(name))
        let manager = try self.manager()
        await self.changeCandidates(manager, delegate: MixedLanguageDelegate()) {
            manager.insertAtCursorPosition("googlew「", inputStyle: style)
        }
        let prediction = try #require(manager.requestPredictionCandidates().first { $0.isMixedLanguage && $0.displayText.hasPrefix("googleで") })
        manager.acceptPredictionCandidate(prediction)
        #expect(manager.convertTarget.hasPrefix("googleで"))
        #expect(!manager.isEmpty)
        let accepted = manager.convertTarget
        manager.insertAtCursorPosition("q", inputStyle: style)
        #expect(manager.convertTarget == accepted + "た")
    }

    @MainActor
    @Test func discardsMixedPredictionsWhenTheInputIsReplaced() async throws {
        let previous = Config.MixedLanguageCandidates().value
        let previousPrediction = Config.DebugPredictiveTyping().value
        defer {
            Config.MixedLanguageCandidates().value = previous
            Config.DebugPredictiveTyping().value = previousPrediction
        }
        Config.MixedLanguageCandidates().value = true
        Config.DebugPredictiveTyping().value = true
        let manager = try self.manager()
        let style = InputStyle.mapped(id: .defaultRomanToKana)
        await self.changeCandidates(manager, delegate: MixedLanguageDelegate()) {
            manager.insertAtCursorPosition("githu", inputStyle: style)
            manager.stopComposition()
            manager.insertAtCursorPosition("docke", inputStyle: style)
        }
        let result = manager.requestPredictionCandidates().filter(\.isMixedLanguage)
        #expect(result.contains { $0.displayText.lowercased() == "docker" })
        #expect(!result.contains { $0.displayText.lowercased().contains("github") })
        Config.MixedLanguageCandidates().value = false
        #expect(!manager.requestPredictionCandidates().contains { $0.isMixedLanguage })
        let before = manager.convertTarget
        if let prediction = result.first { manager.acceptPredictionCandidate(prediction) }
        #expect(manager.convertTarget == before)
    }

    @MainActor
    @Test func discardsResultsAfterTheInputChanges() async throws {
        let previous = Config.MixedLanguageCandidates().value
        defer { Config.MixedLanguageCandidates().value = previous }
        Config.MixedLanguageCandidates().value = true
        let manager = try self.manager()
        manager.insertAtCursorPosition("githubniko-do", inputStyle: .mapped(id: .defaultRomanToKana))
        manager.update(requestRichCandidates: true)
        manager.stopComposition()
        manager.insertAtCursorPosition("atarashiimacchouhoshii", inputStyle: .mapped(id: .defaultRomanToKana))
        await self.update(manager, delegate: MixedLanguageDelegate())
        #expect(self.candidates(manager).contains { $0.text == "新しいmac超欲しい" })
        #expect(!self.candidates(manager).contains { $0.text.lowercased().contains("github") })
    }

    @MainActor
    @Test func learningRecognizesFigmaAsOneWordAndCanBeForgotten() async throws {
        let suite = "azooKey.MixedLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let learning = MixedLanguageLearning(defaults: defaults)
        let generator = MixedLanguageCandidateGenerator()
        var input = ComposingText()
        input.insertAtCursorPosition("Figmawotukau", inputStyle: .mapped(id: .defaultRomanToKana))
        let before = try await generator.candidates(for: input, learnedWords: [])
        let selected = try #require(before.first { $0.candidate.text == "Figmaを使う" })
        learning.learn(selected.englishWords, enabled: true)
        let restored = MixedLanguageLearning(defaults: defaults)
        let result = try await generator.candidates(for: input, learnedWords: restored.words)
        #expect(result.first?.candidate.text == "Figmaを使う")
        #expect(result.first?.englishWords.contains("Figma") == true)
        #expect(result.first?.preferred == true)
        learning.forget(["Figma"])
        #expect(restored.words.isEmpty)
        learning.learn(["Figma"], enabled: false)
        #expect(restored.words.isEmpty)
        learning.learn(["Figma"], enabled: true)
        learning.reset()
        #expect(restored.words.isEmpty)
    }

    @MainActor
    @Test func keepsOrdinaryCandidatesAheadForJapaneseInput() async throws {
        let previous = Config.MixedLanguageCandidates().value
        defer { Config.MixedLanguageCandidates().value = previous }
        Config.MixedLanguageCandidates().value = true
        let manager = try self.manager()
        let delegate = MixedLanguageDelegate()
        manager.delegate = delegate
        manager.insertAtCursorPosition("konnnichiha", inputStyle: .mapped(id: .defaultRomanToKana))
        var original: [Candidate] = []
        await withCheckedContinuation { continuation in
            delegate.updated = { continuation.resume() }
            manager.update(requestRichCandidates: true)
            original = self.candidates(manager)
        }
        #expect(Array(self.candidates(manager).prefix(original.count)) == original)
    }
}
