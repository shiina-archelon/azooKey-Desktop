import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct MixedLanguageCandidate: Sendable {
    var candidate: Candidate
    let input: ComposingText
    let englishWords: [String]
    let preferred: Bool
    let preservesAcronym: Bool
}

/// 入力処理と別の実行コンテキストで、専用の変換器と辞書を保持する。
actor MixedLanguageCandidateGenerator {
    static let shared = MixedLanguageCandidateGenerator()

    private var lexicon: MixedLanguageLexicon?
    private lazy var converter = KanaKanjiConverter.withDefaultDictionary()
    private lazy var textReplacer = TextReplacer.withDefaultEmojiDictionary()

    private struct Reading {
        let input: ComposingText
        let typedInput: ComposingText
        let score: Double
        let words: [String]
        let learnedCount: Int
        let plausibleWords: Bool
        let hasLongWord: Bool
        let acronymCount: Int
        let index: Int
    }

    func candidates(for input: ComposingText, learnedWords: Set<String>) throws -> [MixedLanguageCandidate] {
        try self.generate(for: input, learnedWords: learnedWords, completingWords: false)
    }

    func predictions(for input: ComposingText, learnedWords: Set<String>) throws -> [MixedLanguageCandidate] {
        try Task.checkCancellation()
        if let acronym = self.explicitAcronymPrediction(for: input, lexicon: try self.loadLexicon(), learnedWords: learnedWords) {
            return [acronym]
        }
        let interpretations = try self.generate(for: input, learnedWords: learnedWords, completingWords: true).filter(\.preferred)
        var predictions: [MixedLanguageCandidate] = []
        var seen: Set<String> = []
        for mixed in interpretations.prefix(4) {
            try Task.checkCancellation()
            let target = mixed.input.convertTarget.toHiragana()
            let ruby = mixed.candidate.data.map(\.ruby).joined().toHiragana()
            let candidates: [Candidate]
            if mixed.preservesAcronym || (ruby.hasPrefix(target) && ruby.count > target.count) {
                candidates = [mixed.candidate]
            } else {
                let result = self.converter.requestCandidates(mixed.input, options: self.options(nBest: 10, predicting: true))
                self.converter.stopComposition()
                let continuations = result.predictionResults.filter {
                    let ruby = $0.data.map(\.ruby).joined().toHiragana()
                    return ruby.hasPrefix(target) && ruby.count > target.count
                }
                candidates = continuations.isEmpty ? [mixed.candidate] : continuations
            }
            for candidate in candidates where seen.insert(candidate.text).inserted {
                predictions.append(.init(
                    candidate: candidate, input: mixed.input, englishWords: mixed.englishWords,
                    preferred: true, preservesAcronym: mixed.preservesAcronym
                ))
                if predictions.count == 2 {
                    return predictions
                }
            }
        }
        return predictions
    }

    private func generate(for input: ComposingText, learnedWords: Set<String>, completingWords: Bool) throws -> [MixedLanguageCandidate] {
        try Task.checkCancellation()
        let lexicon = try self.loadLexicon()
        // 文字を表示しない区切りは、英単語の探索に含めない。
        let keys = input.input.enumerated().compactMap { index, element in
            Self.rawCharacter(of: element.piece).map { (index: index, character: $0) }
        }
        let searchableIndices = keys.map(\.index)
        let characters = keys.map(\.character)
        let rawCharacters = characters.map(Optional.some)
        let variants = completingWords
            ? lexicon.predictionVariants(for: characters, learnedWords: learnedWords)
            : lexicon.variants(for: characters, learnedWords: learnedWords)
        guard !variants.isEmpty else {
            return []
        }
        let options = self.options(nBest: 10, predicting: false)
        let baseline = self.fullCandidates(for: input, options: options).first.map { Double($0.value) } ?? -.infinity
        var scoreCache: [String: Double] = [:]
        var seenReadings: Set<String> = [input.convertTarget]
        var readings: [Reading] = []
        for (index, variant) in variants.enumerated() {
            try Task.checkCancellation()
            let spans = variant.map { span in
                MixedLanguageLexicon.Span(
                    range: searchableIndices[span.range.lowerBound]..<(searchableIndices[span.range.upperBound - 1] + 1),
                    text: span.text, score: span.score
                )
            }
            let mixed = Self.replacing(input, spans: spans, replacement: .completed)
            guard seenReadings.insert(mixed.convertTarget).inserted else {
                continue
            }
            let scoringInput = Self.replacing(input, spans: spans, replacement: .placeholder)
            let score: Double
            if let cached = scoreCache[scoringInput.convertTarget] {
                score = cached
            } else {
                score = self.fullCandidates(for: scoringInput, options: options).first.map { Double($0.value) } ?? -.infinity
                scoreCache[scoringInput.convertTarget] = score
            }
            let words = Self.englishWords(spans: spans, input: input)
            let acronymCount = variant.allSatisfy {
                Self.isExplicitAcronym($0, in: characters)
                    && lexicon.technicalWord(containing: $0.range, in: rawCharacters, learnedWords: learnedWords) == $0.range
            } ? variant.count : 0
            readings.append(.init(
                input: mixed, typedInput: completingWords ? Self.replacing(input, spans: spans, replacement: .typed) : mixed,
                score: score, words: words,
                learnedCount: words.filter { learnedWords.contains($0.lowercased()) }.count,
                plausibleWords: spans.allSatisfy { $0.text.count > 1 || $0.text == $0.text.uppercased() },
                hasLongWord: spans.contains { $0.text.count >= 3 },
                acronymCount: acronymCount,
                index: index
            ))
        }
        readings.sort {
            if $0.acronymCount != $1.acronymCount {
                return $0.acronymCount > $1.acronymCount
            }
            if $0.learnedCount != $1.learnedCount {
                return $0.learnedCount > $1.learnedCount
            }
            return $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        return try self.converting(readings, inputCount: input.input.count, baseline: baseline)
    }

    private func loadLexicon() throws -> MixedLanguageLexicon {
        if let lexicon = self.lexicon {
            return lexicon
        }
        let lexicon = try MixedLanguageLexicon()
        self.lexicon = lexicon
        return lexicon
    }

    private func explicitAcronymPrediction(
        for input: ComposingText,
        lexicon: MixedLanguageLexicon,
        learnedWords: Set<String>
    ) -> MixedLanguageCandidate? {
        let characters = input.input.map { Self.rawCharacter(of: $0.piece) }
        var spans: [MixedLanguageLexicon.Span] = []
        var index = 0
        while index < characters.count {
            let start = index
            var word = ""
            while index < characters.count, let character = characters[index], character.isASCII, character.isUppercase {
                word.append(character)
                index += 1
            }
            if index == start {
                index += 1
                continue
            }
            if word.count >= 2, lexicon.words.contains(word.lowercased()) || learnedWords.contains(word.lowercased()) {
                let range = lexicon.technicalWord(containing: start..<index, in: characters, learnedWords: learnedWords)
                if spans.last.map({ $0.range.upperBound <= range.lowerBound }) ?? true {
                    spans.append(.init(range: range, text: String(characters[range].compactMap { $0 }), score: 0))
                    index = range.upperBound
                }
            }
        }
        guard !spans.isEmpty else {
            return nil
        }
        let mixed = Self.replacing(input, spans: spans, replacement: .typed)
        guard mixed.convertTarget != input.convertTarget,
              var candidate = self.fullCandidates(for: mixed, options: self.options(nBest: 10, predicting: false)).first else { return nil }
        candidate.composingCount = .inputCount(input.input.count)
        return .init(
            candidate: candidate, input: mixed, englishWords: spans.map(\.text),
            preferred: true, preservesAcronym: true
        )
    }

    private static func rawCharacter(of piece: InputPiece) -> Character? {
        switch piece {
        case .character(let character), .key(_, let character, _): character
        case .compositionSeparator: nil
        }
    }

    private func converting(_ readings: [Reading], inputCount: Int, baseline: Double) throws -> [MixedLanguageCandidate] {
        var results: [(result: MixedLanguageCandidate, score: Double)] = []
        var seen: Set<String> = []
        let conversionOptions = self.options(nBest: 10, predicting: false)
        for reading in readings {
            try Task.checkCancellation()
            guard var candidate = self.fullCandidates(for: reading.input, options: conversionOptions).first,
                  seen.insert(candidate.text).inserted else {
                continue
            }
            // 表記の長さが変わっても、元の打鍵列全体を確定する。
            candidate.composingCount = .inputCount(inputCount)
            // 短い語は偶然一致しやすいので、日本語の接続評価の改善を求める。
            let margin = reading.hasLongWord ? -8.0 : 4.0
            results.append((.init(
                candidate: candidate,
                input: reading.typedInput,
                englishWords: reading.words,
                preferred: reading.acronymCount > 0 || reading.learnedCount > 0 || (reading.plausibleWords && reading.score >= baseline + margin),
                preservesAcronym: reading.acronymCount > 0
            ), reading.score))
        }
        let bestScore = results.filter { $0.result.preferred && !$0.result.preservesAcronym }.map(\.score).max() ?? -.infinity
        return results.map { result, score in
            .init(
                candidate: result.candidate, input: result.input, englishWords: result.englishWords,
                preferred: result.preferred && (result.preservesAcronym || score >= bestScore - 6),
                preservesAcronym: result.preservesAcronym
            )
        }
    }

    private static func isExplicitAcronym(_ span: MixedLanguageLexicon.Span, in characters: [Character]) -> Bool {
        guard span.range.count > 1, span.range.count == span.text.count,
              span.text.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return false }
        let start = span.range.lowerBound
        let end = span.range.upperBound
        return (start == 0 || !characters[start - 1].isUppercase)
            && (end == characters.count || !characters[end].isUppercase)
    }

    private func options(nBest: Int, predicting: Bool) -> ConvertRequestOptions {
        let memory = FileManager.default.temporaryDirectory.appendingPathComponent("azooKey-mixed-language", isDirectory: true)
        return .init(
            N_best: nBest,
            requireJapanesePrediction: predicting ? .manualMix : .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: memory,
            sharedContainerURL: memory,
            textReplacer: self.textReplacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: .off,
            preloadDictionary: false,
            experimentalZenzaiPredictiveInput: false,
            typoCorrectionMode: .disabled,
            metadata: .init(versionString: "azooKey Upa")
        )
    }

    private func fullCandidates(for input: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
        let result = self.converter.requestCandidates(input, options: options)
        self.converter.stopComposition()
        return result.mainResults.filter { candidate in
            var remaining = input
            remaining.prefixComplete(composingCount: candidate.composingCount)
            return remaining.isEmpty
        }
    }

    private enum Replacement {
        case placeholder, typed, completed
    }

    private static func replacing(_ input: ComposingText, spans: [MixedLanguageLexicon.Span], replacement: Replacement) -> ComposingText {
        let byStart = Dictionary(uniqueKeysWithValues: spans.map { ($0.range.lowerBound, $0) })
        var elements: [ComposingText.InputElement] = []
        var index = 0
        while index < input.input.count {
            if let span = byStart[index] {
                if replacement == .placeholder {
                    elements += "テスト".map { .init(character: $0, inputStyle: .direct) }
                } else {
                    let original = input.input[span.range].filter { $0.piece != .compositionSeparator }
                    elements += original.map { .init(piece: $0.piece, inputStyle: .direct) }
                    if replacement == .completed {
                        elements += span.text.dropFirst(original.count).map { .init(character: $0, inputStyle: .direct) }
                    }
                }
                index = span.range.upperBound
            } else {
                elements.append(input.input[index])
                index += 1
            }
        }
        var result = ComposingText()
        result.insertAtCursorPosition(elements)
        return result
    }

    private static func englishWords(spans: [MixedLanguageLexicon.Span], input: ComposingText) -> [String] {
        var words: [String] = []
        var previousEnd = -1
        for span in spans {
            let joinsPrevious = previousEnd >= 0 && input.input[previousEnd..<span.range.lowerBound].allSatisfy {
                $0.piece == .compositionSeparator
            }
            if joinsPrevious, !words.isEmpty {
                words[words.count - 1] += span.text
            } else {
                words.append(span.text)
            }
            previousEnd = span.range.upperBound
        }
        return words
    }
}
