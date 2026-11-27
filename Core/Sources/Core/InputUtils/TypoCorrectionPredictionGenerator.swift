import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct TypoCorrection: Sendable {
    let reading: String
    let candidate: Candidate
}

actor TypoCorrectionPredictionGenerator {
    static let shared = TypoCorrectionPredictionGenerator()

    private lazy var typoConverter = KanaKanjiConverter.withDefaultDictionary()
    private lazy var surfaceConverter = KanaKanjiConverter.withDefaultDictionary()

    enum Presentation {
        case prediction, mixedPrediction, conversion
    }

    // swiftlint:disable:next cyclomatic_complexity function_parameter_count
    func corrections(
        for input: ComposingText,
        inputStyle: InputStyle,
        keyboardLayout: Config.KeyboardLayout.Value,
        previousDisplay: String,
        leftSideContext: String,
        modelDirectory: URL,
        options: ConvertRequestOptions,
        afterBackspace: Bool,
        presentation: Presentation,
        onInitialCandidates: @MainActor @Sendable ([TypoCorrection]) -> Void
    ) async throws -> [TypoCorrection] {
        try Task.checkCancellation()
        guard DebugTypoCorrectionWeights.canReadRequiredWeightFiles(modelDirectoryURL: modelDirectory) else {
            return []
        }
        let languageModel = ExperimentalTypoCorrectionConfig.LanguageModel.ngram(
            .init(prefix: modelDirectory.appendingPathComponent("lm_").path)
        )
        let originalReading = input.convertTarget.toHiragana()
        let containsKana = originalReading.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) }
        let english = containsKana ? Self.englishRuns(in: originalReading) : []
        var segmentScores: [String: [Substring: Float]] = [:]
        func segmentScore(_ reading: Substring, context: String) -> Float? {
            if let cached = segmentScores[context]?[reading] {
                return cached
            }
            var text = ComposingText()
            text.insertAtCursorPosition(String(reading), inputStyle: .direct)
            let scores = self.typoConverter.experimentalRequestTypoCorrection(
                leftSideContext: context,
                composingText: text,
                options: options,
                inputStyle: .direct,
                config: .init(languageModel: languageModel, nBest: 1, maxSteps: 0)
            )
            guard let score = scores.first?.lmScore else {
                return nil
            }
            segmentScores[context, default: [:]][reading] = score
            return score
        }

        func readingScore(_ reading: String) -> Float? {
            guard !english.isEmpty else {
                return segmentScore(reading[...], context: leftSideContext)
            }
            guard Self.englishRuns(in: reading) == english else {
                return nil
            }
            let japanese = reading.split(whereSeparator: Self.isEnglishLetter)
            guard !japanese.isEmpty else {
                return nil
            }
            let startsWithEnglish = reading.first.map(Self.isEnglishLetter) ?? false
            var total: Float = 0
            for (index, segment) in japanese.enumerated() {
                let context = index == 0 && !startsWithEnglish ? leftSideContext : ""
                guard let score = segmentScore(segment, context: context) else {
                    return nil
                }
                total += score
            }
            return total
        }

        func correctionScore(_ reading: String, cost: Float) -> Float? {
            let penaltyPerUnitCost: Float = 0.02
            return readingScore(reading).map { $0 - penaltyPerUnitCost * cost }
        }

        let layout = TypoKeyboardLayout.layout(for: keyboardLayout)
        var costs: [String: Float] = [:]
        var oneKeyReadings: Set<String> = []
        func addReading(_ reading: String, cost: Float) {
            guard reading.count >= 2, reading != originalReading,
                  !reading.contains(where: { Self.detachedVoicingMarks[$0] != nil }) else { return }
            costs[reading] = min(costs[reading] ?? cost, cost)
        }

        func addModelRepairs(to seed: ComposingText, cost: Float) throws {
            try Task.checkCancellation()
            let results = self.typoConverter.experimentalRequestTypoCorrection(
                leftSideContext: leftSideContext,
                composingText: seed,
                options: options,
                inputStyle: inputStyle,
                config: .init(
                    languageModel: languageModel,
                    beamSize: 24,
                    topK: 32,
                    nBest: 12,
                    alpha: 0.5,
                    beta: afterBackspace ? 2 : 2.5,
                    gamma: 1.25
                )
            )
            let originalKeys = Array(seed.input.map(\.piece).inputString().lowercased())
            let original = results.first { $0.channelCost == 0 }
            let hasUniformInputStyle = originalKeys.count == seed.input.count && seed.input.allSatisfy { $0.inputStyle == inputStyle }
            let knownKeys = Set(originalKeys)
            for result in results where result.channelCost > 0 {
                let correctedKeys = Array(result.correctedInput)
                guard afterBackspace || correctedKeys.count == originalKeys.count else { continue }
                let canReplay = hasUniformInputStyle && (
                    inputStyle == .roman2kana || original?.correctedInput == String(originalKeys)
                    || correctedKeys.allSatisfy { $0.isASCII || knownKeys.contains($0) }
                )
                let reading = canReplay
                    ? Self.replayedReading(result.correctedInput, replacing: originalKeys, in: seed, inputStyle: inputStyle)
                    : result.convertedText.toHiragana()
                addReading(reading, cost: cost + result.channelCost)
            }
        }

        guard let baseline = readingScore(originalReading) else {
            return []
        }
        var seenSurfaces: Set<String> = [previousDisplay]
        var conversionOptions = options
        conversionOptions.learningType = .nothing
        conversionOptions.shouldResetMemory = false
        conversionOptions.experimentalZenzaiPredictiveInput = false
        var dictionaryOptions = conversionOptions
        dictionaryOptions.zenzaiMode = .off
        let usesZenzai = conversionOptions.zenzaiMode != .off

        func convertedCandidates(for text: ComposingText, options: ConvertRequestOptions) -> [Candidate] {
            let results = self.surfaceConverter.requestCandidates(text, options: options)
            self.surfaceConverter.stopComposition()
            var seen: Set<String> = []
            return results.mainResults.filter {
                (english.isEmpty || Self.englishRuns(in: $0.text) == english)
                    && $0.data.map(\.ruby).joined().toHiragana() == text.convertTarget
                    && seen.insert($0.text).inserted
            }
        }

        func dictionaryAlternative(
            for readings: [String], excluding excludedSurfaces: Set<String>
        ) throws -> TypoCorrection? {
            guard !readings.isEmpty else {
                return nil
            }
            var original = ComposingText()
            original.insertAtCursorPosition(originalReading, inputStyle: .direct)
            let originalCandidates = convertedCandidates(for: original, options: dictionaryOptions)
            guard let originalCandidate = originalCandidates.first(where: { $0.text.toHiragana() != originalReading }),
                  originalCandidate.data.count > 1 else { return nil }

            var best: TypoCorrection?
            for reading in readings {
                try Task.checkCancellation()
                var corrected = ComposingText()
                corrected.insertAtCursorPosition(reading, inputStyle: .direct)
                guard let candidate = convertedCandidates(for: corrected, options: dictionaryOptions).first,
                      candidate.data.count == 1, candidate.data.first?.word == candidate.text,
                      candidate.value > (best?.candidate.value ?? originalCandidate.value),
                      !excludedSurfaces.contains(candidate.text) else { continue }
                best = .init(reading: reading, candidate: candidate)
            }
            return best
        }

        func boundaryAlternative(
            for reading: String, dictionary: [Candidate], excluding excludedSurfaces: Set<String>
        ) throws -> TypoCorrection? {
            let leadingCandidates = dictionary.prefix(3)
            guard leadingCandidates.count == 3,
                  let firstRuby = leadingCandidates.first?.data.first?.ruby,
                  leadingCandidates.allSatisfy({ $0.data.count > 1 && $0.data.first?.ruby == firstRuby }) else { return nil }

            func lookup(_ reading: String) -> [Candidate] {
                var composing = ComposingText()
                composing.insertAtCursorPosition(reading, inputStyle: .direct)
                return convertedCandidates(for: composing, options: dictionaryOptions)
            }

            let boundary = firstRuby.count
            var best: Candidate?
            for split in [boundary - 1, boundary + 1] where split >= 2 && reading.count - split >= 2 {
                try Task.checkCancellation()
                let left = lookup(String(reading.prefix(split))).prefix(3)
                    .filter { $0.data.count == 1 && $0.data.first?.word == $0.text }
                guard !left.isEmpty else { continue }
                let right = lookup(String(reading.dropFirst(split))).prefix(3)
                for prefix in left {
                    for suffix in right {
                        let merged = self.surfaceConverter.mergeCandidates(prefix, suffix)
                        if !excludedSurfaces.contains(merged.text), best.map({ merged.value > $0.value }) ?? true {
                            best = merged
                        }
                    }
                }
            }
            return best.map { .init(reading: reading, candidate: $0) }
        }

        // swiftlint:disable:next cyclomatic_complexity
        func makeCorrections(includeSpellingAlternatives: Bool) throws -> [TypoCorrection] {
            let usesDictionaryAlternative = presentation != .mixedPrediction && includeSpellingAlternatives && english.isEmpty
            var ranked: [(reading: String, score: Float)] = []
            for (reading, cost) in costs {
                try Task.checkCancellation()
                if let score = correctionScore(reading, cost: cost),
                   score > baseline || (usesDictionaryAlternative && oneKeyReadings.contains(reading)) {
                    ranked.append((reading, score))
                }
            }
            ranked.sort {
                $0.score == $1.score ? $0.reading < $1.reading : $0.score > $1.score
            }
            var corrections: [TypoCorrection] = []
            let readingLimit = 3
            let spellingLimit = presentation == .conversion ? 2 : 4
            var spellingAlternatives = [[TypoCorrection]](repeating: [], count: spellingLimit)
            var replaceableSpelling: (rank: Int, offset: Int)?
            var sharedCorrectionPosition: Int?
            var boundarySource: (reading: String, dictionary: [Candidate])?
            for (reading, score) in ranked {
                guard score > baseline else { break }
                try Task.checkCancellation()
                if let sharedCorrectionPosition {
                    guard oneKeyReadings.contains(reading),
                          let position = Self.singleCharacterChange(from: originalReading, to: reading)?.position,
                          position != sharedCorrectionPosition else { continue }
                }
                var corrected = ComposingText()
                corrected.insertAtCursorPosition(reading, inputStyle: .direct)
                let candidates = convertedCandidates(for: corrected, options: conversionOptions)
                let dictionary = usesZenzai ? convertedCandidates(for: corrected, options: dictionaryOptions) : []
                let spellings = usesZenzai ? Self.fuseSpellingRankings(zenzai: candidates, dictionary: dictionary) : candidates
                guard let candidate = spellings.first, seenSurfaces.insert(candidate.text).inserted else { continue }

                if sharedCorrectionPosition != nil, let spelling = replaceableSpelling {
                    corrections.append(.init(reading: reading, candidate: candidate))
                    spellingAlternatives[spelling.rank].remove(at: spelling.offset)
                    replaceableSpelling = nil
                    break
                }
                if includeSpellingAlternatives, presentation == .conversion || (corrections.isEmpty && usesZenzai) {
                    if corrections.isEmpty, usesDictionaryAlternative, oneKeyReadings.contains(reading),
                       Self.singleCharacterChange(from: originalReading, to: reading) != nil {
                        boundarySource = (reading, dictionary)
                    }
                    let sourceLeaders = Set([candidates.first?.text, dictionary.first?.text].compactMap { $0 })
                    let alternatives = spellings.dropFirst()
                    let leaders = alternatives.filter { sourceLeaders.contains($0.text) }
                    let remaining = alternatives.filter { !sourceLeaders.contains($0.text) }
                    let selected = Set((leaders + remaining).prefix(spellingLimit).map(\.text))
                    for (index, candidate) in alternatives.filter({ selected.contains($0.text) }).enumerated() {
                        if corrections.isEmpty, !sourceLeaders.contains(candidate.text) {
                            replaceableSpelling = (index, spellingAlternatives[index].count)
                        }
                        spellingAlternatives[index].append(.init(reading: reading, candidate: candidate))
                    }
                }
                corrections.append(.init(reading: reading, candidate: candidate))
                if corrections.count == readingLimit {
                    guard replaceableSpelling != nil,
                          let position = Self.singleCharacterChange(from: originalReading, to: corrections[0].reading)?.position,
                          corrections.dropFirst().allSatisfy({
                              Self.singleCharacterChange(from: originalReading, to: $0.reading)?.position == position
                          }) else { break }
                    sharedCorrectionPosition = position
                }
            }
            if let spelling = replaceableSpelling {
                // 一打の訂正は、読みの点数に加えて辞書で一語として変換した結果も使う。
                let readings = ranked.lazy
                    .filter {
                        $0.score <= baseline && oneKeyReadings.contains($0.reading)
                            && Self.singleCharacterChange(from: originalReading, to: $0.reading) != nil
                    }
                    .prefix(readingLimit)
                    .map(\.reading)
                let excludedSurfaces = seenSurfaces.union(spellingAlternatives.joined().map { $0.candidate.text })
                let optionalSpelling = try dictionaryAlternative(for: Array(readings), excluding: excludedSurfaces)
                    ?? boundarySource.flatMap {
                        try boundaryAlternative(for: $0.reading, dictionary: $0.dictionary, excluding: excludedSurfaces)
                    }
                if let alternative = optionalSpelling {
                    let position = corrections.firstIndex { $0.reading == alternative.reading }.map { $0 + 1 }
                    corrections.insert(alternative, at: position ?? corrections.endIndex)
                    seenSurfaces.insert(alternative.candidate.text)
                    spellingAlternatives[spelling.rank].remove(at: spelling.offset)
                }
            }
            corrections.append(contentsOf: spellingAlternatives.joined().filter { seenSurfaces.insert($0.candidate.text).inserted })
            return corrections
        }

        let keys = Self.keyStrokes(in: input, inputStyle: inputStyle)
        let physicalKeys = Dictionary(uniqueKeysWithValues: keys.map { ($0.index, layout.unshiftedKeys[$0.raw] ?? $0.raw) })
        for (index, key) in physicalKeys {
            try Task.checkCancellation()
            let previous = physicalKeys[index - 1]
            let next = physicalKeys[index + 1]
            let repeatedKey = key == previous || key == next
            let adjacentKey = layout.neighbors[key]?.contains { $0.key == previous || $0.key == next } ?? false
            guard repeatedKey || adjacentKey else { continue }
            var remaining = input.input
            remaining.remove(at: index)
            addReading(Self.reading(for: remaining), cost: 0.5)
        }
        for repair in Self.detachedVoicingRepairs(for: originalReading) {
            addReading(repair.reading, cost: repair.cost)
        }
        var lastOccurrence: [Character: Int] = [:]
        var nextOccurrence: [Int: Int] = [:]
        for (index, key) in keys {
            if let previous = lastOccurrence.updateValue(index, forKey: key) {
                nextOccurrence[previous] = index
            }
        }
        for alternative in try Self.nearbyInputs(for: input, layout: layout, inputStyle: inputStyle, excluding: nil) {
            let reading = alternative.input.convertTarget.toHiragana()
            oneKeyReadings.insert(reading)
            addReading(reading, cost: alternative.cost)
            if let next = nextOccurrence[alternative.index] {
                var pieces = alternative.input.input
                pieces[next].piece = pieces[alternative.index].piece
                addReading(Self.reading(for: pieces), cost: 2 * alternative.cost)
            }
        }
        for reading in Self.voicingAlternatives(for: originalReading) {
            addReading(reading, cost: 0.5)
        }
        if afterBackspace, presentation != .mixedPrediction { try addModelRepairs(to: input, cost: 0) }
        let initial = try makeCorrections(includeSpellingAlternatives: presentation != .mixedPrediction)
        guard presentation != .mixedPrediction else {
            return initial
        }
        if !initial.isEmpty { await onInitialCandidates(initial) }
        try Task.checkCancellation()
        costs.removeAll(keepingCapacity: true)

        if !afterBackspace { try addModelRepairs(to: input, cost: 0) }
        var shifts: [(input: ComposingText, score: Float)] = []
        if keys.count > 1 {
            for shift in layout.shifts {
                try Task.checkCancellation()
                let replacements = keys.compactMap { index, raw -> (Int, InputPiece)? in
                    let key = layout.unshiftedKeys[raw] ?? raw
                    guard let target = shift[key] else {
                        return nil
                    }
                    return (index, Self.replacementKey(layout.character(for: target, matchingShiftOf: raw)))
                }
                guard replacements.count == keys.count else { continue }
                var pieces = input.input
                for (index, piece) in replacements {
                    pieces[index].piece = piece
                }
                var shifted = ComposingText()
                shifted.insertAtCursorPosition(pieces)
                let reading = shifted.convertTarget.toHiragana()
                addReading(reading, cost: 1)
                if let score = readingScore(reading) { shifts.append((shifted, score)) }
            }
        }

        // 全体のずれを戻した入力から、個別のキーのずれも探索する。
        for shift in shifts.sorted(by: { $0.score > $1.score }).prefix(2) {
            try addModelRepairs(to: shift.input, cost: 1)
            var refinements: [(alternative: KeyAlternative, score: Float)] = []
            for alternative in try Self.nearbyInputs(for: shift.input, layout: layout, inputStyle: inputStyle, excluding: nil) {
                try Task.checkCancellation()
                let reading = alternative.input.convertTarget.toHiragana()
                let cost = 1 + alternative.cost
                addReading(reading, cost: cost)
                if let score = correctionScore(reading, cost: cost) {
                    refinements.append((.init(input: alternative.input, cost: cost, index: alternative.index), score))
                }
            }
            for (refinement, _) in refinements.sorted(by: { $0.score > $1.score }).prefix(2) {
                for alternative in try Self.nearbyInputs(for: refinement.input, layout: layout, inputStyle: inputStyle, excluding: refinement.index) {
                    addReading(alternative.input.convertTarget.toHiragana(), cost: refinement.cost + alternative.cost)
                }
                try addModelRepairs(to: refinement.input, cost: refinement.cost)
            }
        }
        return initial + (try makeCorrections(includeSpellingAlternatives: false))
    }

    private static func isEnglishLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func englishRuns(in text: String) -> [Substring] {
        text.split { !self.isEnglishLetter($0) }
    }

    private static func fuseSpellingRankings(zenzai: [Candidate], dictionary: [Candidate]) -> [Candidate] {
        let rankingDepth = 5
        let rankOffset = 1
        struct RankedSpelling {
            let candidate: Candidate
            let score: Double
            let dictionaryRank: Int
        }
        var scores: [String: RankedSpelling] = [:]
        for (index, candidate) in dictionary.prefix(rankingDepth).enumerated() {
            let rank = index + 1
            scores[candidate.text] = .init(candidate: candidate, score: 1 / Double(rankOffset + rank), dictionaryRank: rank)
        }
        for (index, candidate) in zenzai.prefix(rankingDepth).enumerated() {
            let rank = index + 1
            let previous = scores[candidate.text]
            let score = 1 / Double(rankOffset + rank) + (previous?.score ?? 0)
            scores[candidate.text] = .init(candidate: candidate, score: score, dictionaryRank: previous?.dictionaryRank ?? .max)
        }
        return scores.values.sorted {
            $0.score == $1.score ? $0.dictionaryRank < $1.dictionaryRank : $0.score > $1.score
        }.map(\.candidate)
    }

    private static let detachedVoicingMarks: [Character: String] = ["゛": "\u{3099}", "゜": "\u{309A}"]

    private static func detachedVoicingRepairs(for reading: String) -> [(reading: String, cost: Float)] {
        var cleaned: [Character] = []
        var marksAfter: [Int: Set<String>] = [:]
        for character in reading {
            if let mark = Self.detachedVoicingMarks[character] {
                if let index = cleaned.indices.last {
                    marksAfter[index, default: []].insert(mark)
                }
            } else {
                cleaned.append(character)
            }
        }
        guard cleaned.count < reading.count else {
            return []
        }

        let removalCost = 0.5 * Float(reading.count - cleaned.count)
        var repairs = [(String(cleaned), removalCost)]
        for (index, marks) in marksAfter {
            for mark in marks {
                let combined = (String(cleaned[index]) + mark).precomposedStringWithCanonicalMapping
                guard combined.unicodeScalars.count == 1, let kana = combined.first else { continue }
                var repaired = cleaned
                repaired[index] = kana
                repairs.append((String(repaired), removalCost - 0.5))
            }
        }
        return repairs
    }

    private static func voicingAlternatives(for reading: String) -> [String] {
        let dakuten = "\u{3099}"
        let handakuten = "\u{309A}"
        return reading.indices.flatMap { index -> [String] in
            let original = String(reading[index])
            let base = original.decomposedStringWithCanonicalMapping
                .replacingOccurrences(of: dakuten, with: "")
                .replacingOccurrences(of: handakuten, with: "")
            guard base.unicodeScalars.count == 1 else {
                return []
            }
            return ["", dakuten, handakuten].compactMap { mark in
                let replacement = (base + mark).precomposedStringWithCanonicalMapping
                guard replacement != original, replacement.unicodeScalars.count == 1 else {
                    return nil
                }
                var corrected = reading
                corrected.replaceSubrange(index...index, with: replacement)
                return corrected
            }
        }
    }

    private static func keyStrokes(in input: ComposingText, inputStyle: InputStyle) -> [(index: Int, raw: Character)] {
        input.input.enumerated().compactMap { index, element in
            guard element.inputStyle == inputStyle,
                  let raw = [element.piece].inputString(preferIntention: false).first else { return nil }
            return (index, raw)
        }
    }

    private struct KeyAlternative {
        let input: ComposingText
        let cost: Float
        let index: Int
    }

    private static func nearbyInputs(
        for input: ComposingText,
        layout: TypoKeyboardLayout.Layout,
        inputStyle: InputStyle,
        excluding excludedIndex: Int?
    ) throws -> [KeyAlternative] {
        var alternatives: [KeyAlternative] = []
        let originalReading = input.convertTarget.toHiragana()
        func replacingKey(at index: Int, with key: InputPiece) -> ComposingText {
            var pieces = input.input
            pieces[index].piece = key
            var corrected = ComposingText()
            corrected.insertAtCursorPosition(pieces)
            return corrected
        }
        for (index, raw) in Self.keyStrokes(in: input, inputStyle: inputStyle) where index != excludedIndex {
            try Task.checkCancellation()
            let key = layout.unshiftedKeys[raw] ?? raw
            guard let adjacent = layout.neighbors[key] else { continue }
            for neighbor in adjacent {
                let replacement = layout.character(for: neighbor.key, matchingShiftOf: raw)
                let corrected = replacingKey(at: index, with: Self.replacementKey(replacement))
                alternatives.append(.init(input: corrected, cost: 0.5 * neighbor.distance, index: index))
            }
            if let shifted = layout.shiftedKeys[raw] {
                let corrected = replacingKey(at: index, with: Self.replacementKey(shifted))
                if Self.isMissingShiftCorrection(from: originalReading, to: corrected.convertTarget.toHiragana()) {
                    alternatives.append(.init(input: corrected, cost: 0.5, index: index))
                }
            }
        }
        return alternatives
    }

    private static let smallKana = Dictionary(uniqueKeysWithValues: zip("あいうえおつやゆよわかけ", "ぁぃぅぇぉっゃゅょゎゕゖ"))

    private struct CharacterChange {
        let position: Int
        let original: Character
        let replacement: Character
    }

    private static func singleCharacterChange(
        from original: String, to corrected: String
    ) -> CharacterChange? {
        guard original.count == corrected.count else {
            return nil
        }
        let changes = zip(original, corrected).enumerated().filter { $0.element.0 != $0.element.1 }
        guard changes.count == 1, let change = changes.first else {
            return nil
        }
        return .init(position: change.offset, original: change.element.0, replacement: change.element.1)
    }

    private static func isMissingShiftCorrection(from original: String, to corrected: String) -> Bool {
        guard let change = Self.singleCharacterChange(from: original, to: corrected) else {
            return false
        }
        return self.smallKana[change.original] == change.replacement || change.replacement == "ー"
    }

    private static func replacementKey(_ key: Character) -> InputPiece {
        key.isNumber ? .character(key) : .key(intention: KeyMap.h2zMap(key), input: key, modifiers: [])
    }

    private static func reading(for input: [ComposingText.InputElement]) -> String {
        var corrected = ComposingText()
        corrected.insertAtCursorPosition(input)
        return corrected.convertTarget.toHiragana()
    }

    private static func replayedReading(
        _ correctedKeys: String,
        replacing originalKeys: [Character],
        in input: ComposingText,
        inputStyle: InputStyle
    ) -> String {
        var elements = input.input
        for change in Array(correctedKeys).difference(from: originalKeys) {
            switch change {
            case .remove(let offset, _, _):
                elements.remove(at: offset)
            case .insert(let offset, let key, _):
                elements.insert(.init(character: key, inputStyle: inputStyle), at: offset)
            }
        }
        return Self.reading(for: elements)
    }
}
