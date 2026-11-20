import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct MixedLanguageCandidate: Sendable {
    var candidate: Candidate
    let input: ComposingText
    let englishWords: [String]
    let preferred: Bool
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
        let index: Int
    }

    func candidates(for input: ComposingText, learnedWords: Set<String>) throws -> [MixedLanguageCandidate] {
        try self.generate(for: input, learnedWords: learnedWords, completingWords: false)
    }

    func predictions(for input: ComposingText, learnedWords: Set<String>) throws -> [MixedLanguageCandidate] {
        let interpretations = try self.generate(for: input, learnedWords: learnedWords, completingWords: true).filter(\.preferred)
        var predictions: [MixedLanguageCandidate] = []
        var seen: Set<String> = []
        for mixed in interpretations.prefix(4) {
            try Task.checkCancellation()
            let target = mixed.input.convertTarget.toHiragana()
            let ruby = mixed.candidate.data.map(\.ruby).joined().toHiragana()
            let candidates: [Candidate]
            if ruby.hasPrefix(target), ruby.count > target.count {
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
                predictions.append(.init(candidate: candidate, input: mixed.input, englishWords: mixed.englishWords, preferred: true))
                if predictions.count == 2 {
                    return predictions
                }
            }
        }
        return predictions
    }

    private func generate(for input: ComposingText, learnedWords: Set<String>, completingWords: Bool) throws -> [MixedLanguageCandidate] {
        try Task.checkCancellation()
        if self.lexicon == nil {
            self.lexicon = try MixedLanguageLexicon()
        }
        // 文字を表示しない区切りは、英単語の探索に含めない。
        let searchableIndices = input.input.indices.filter {
            input.input[$0].piece != .compositionSeparator
        }
        let characters = searchableIndices.map { index -> Character in
            switch input.input[index].piece {
            case .character(let character), .key(_, let character, _): character
            case .compositionSeparator: "\0"
            }
        }
        let variants = completingWords
            ? self.lexicon?.predictionVariants(for: characters, learnedWords: learnedWords)
            : self.lexicon?.variants(for: characters, learnedWords: learnedWords)
        guard let variants, !variants.isEmpty else {
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
            readings.append(.init(
                input: mixed, typedInput: completingWords ? Self.replacing(input, spans: spans, replacement: .typed) : mixed,
                score: score, words: words,
                learnedCount: words.filter { learnedWords.contains($0.lowercased()) }.count,
                plausibleWords: spans.allSatisfy { $0.text.count > 1 || $0.text == $0.text.uppercased() },
                hasLongWord: spans.contains { $0.text.count >= 3 },
                index: index
            ))
        }
        readings.sort {
            if $0.learnedCount != $1.learnedCount {
                return $0.learnedCount > $1.learnedCount
            }
            return $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        return try self.converting(readings, inputCount: input.input.count, baseline: baseline)
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
                preferred: reading.learnedCount > 0 || (reading.plausibleWords && reading.score >= baseline + margin)
            ), reading.score))
        }
        let bestScore = results.filter { $0.result.preferred }.map(\.score).max() ?? -.infinity
        return results.map { result, score in
            .init(
                candidate: result.candidate, input: result.input, englishWords: result.englishWords,
                preferred: result.preferred && score >= bestScore - 6
            )
        }
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
