import Foundation

/// 日英混在候補に同梱する辞書のライセンス。
public enum MixedLanguageDictionary {
    public static var licenseURL: URL? {
        Bundle.module.url(forResource: "CSpell-LICENSE", withExtension: "txt", subdirectory: "MixedLanguage")
    }

    @MainActor
    public static func resetLearningData() {
        MixedLanguageLearning.shared.reset()
    }
}

struct MixedLanguageLexicon {
    private(set) var words: Set<String> = []
    private(set) var technicalWords: Set<String> = []
    private(set) var maximumLength = 0
    private var sortedWords: [String] = []
    private var sortedTechnicalWords: [String] = []

    init() throws {
        // OSの辞書は再配布せず、システムにあるものを参照する。
        if let systemWords = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            self.add(systemWords, technical: false)
        }
        let directory = Bundle.module.resourceURL!.appendingPathComponent("MixedLanguage", isDirectory: true)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension == "txt", url.lastPathComponent != "CSpell-LICENSE.txt" else {
                continue
            }
            self.add(try String(contentsOf: url, encoding: .utf8), technical: true)
        }
        self.sortedWords = self.words.sorted()
        self.sortedTechnicalWords = self.technicalWords.sorted()
    }

    mutating func add(_ source: String, technical: Bool) {
        for line in source.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("//") else {
                continue
            }
            let body = line.components(separatedBy: " #")[0]
            for field in body.split(whereSeparator: \.isWhitespace) {
                let word = field.lowercased()
                guard word.utf8.contains(where: { (97...122).contains($0) }), word.utf8.allSatisfy(Self.isWordByte) else {
                    continue
                }
                self.words.insert(word)
                if technical {
                    self.technicalWords.insert(word)
                }
                self.maximumLength = max(self.maximumLength, word.count)
            }
        }
    }

    static func isWordByte(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte) || [39, 43, 35, 45, 46, 95].contains(byte)
    }

    struct Span: Sendable {
        let range: Range<Int>
        let text: String
        let score: Int
    }

    func technicalWord(containing acronym: Range<Int>, in characters: [Character?], learnedWords: Set<String>) -> Range<Int> {
        let limit = max(self.maximumLength, learnedWords.map(\.count).max() ?? 0)
        let firstStart = max(0, acronym.upperBound - limit)
        var longest = acronym
        for start in firstStart...acronym.lowerBound {
            var word = ""
            for end in start..<min(characters.count, start + limit) {
                guard let character = characters[end],
                      let byte = String(character).lowercased().utf8.first,
                      character.isASCII, Self.isWordByte(byte) else { break }
                word.append(contentsOf: character.lowercased())
                if end + 1 >= acronym.upperBound, word.count > longest.count,
                   self.technicalWords.contains(word) || learnedWords.contains(word) {
                    longest = start..<(end + 1)
                }
            }
        }
        return longest
    }

    private struct Completion {
        let span: Span
        let learned: Bool
        let technical: Bool
    }

    /// 入力途中の英字も辞書の前方一致で補完し、完全一致の解釈と合わせる。
    func predictionVariants(for characters: [Character], learnedWords: Set<String>) -> [[Span]] {
        let exact = self.variants(for: characters, learnedWords: learnedWords)
        var completions: [Completion] = []
        guard characters.count >= 2 else {
            return exact
        }
        let maximumLength = max(self.maximumLength, learnedWords.map(\.count).max() ?? 0)
        for start in max(0, characters.count - maximumLength)..<(characters.count - 1) {
            let typed = String(characters[start...])
            let prefix = typed.lowercased()
            guard prefix.utf8.allSatisfy(Self.isWordByte) else { continue }
            let learned = learnedWords.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
            guard prefix.count >= 3 || !learned.isEmpty else { continue }
            let dictionary = prefix.count >= 3
                ? Self.prefixMatches(prefix, in: self.sortedTechnicalWords) + Self.prefixMatches(prefix, in: self.sortedWords)
                : []
            for word in Set(dictionary).union(learned) where word.count > prefix.count {
                completions.append(.init(
                    span: .init(range: start..<characters.count, text: typed + word.dropFirst(prefix.count), score: word.count * word.count - 9),
                    learned: learnedWords.contains(word), technical: self.technicalWords.contains(word)
                ))
            }
        }
        completions.sort {
            if $0.learned != $1.learned {
                return $0.learned
            }
            if $0.span.range.count != $1.span.range.count {
                return $0.span.range.count > $1.span.range.count
            }
            if $0.technical != $1.technical {
                return $0.technical
            }
            if $0.span.text.count != $1.span.text.count {
                return $0.span.text.count < $1.span.text.count
            }
            return $0.span.text < $1.span.text
        }
        var expanded: [[Span]] = []
        for completion in completions.prefix(8) {
            let prefixes = self.variants(for: Array(characters.prefix(completion.span.range.lowerBound)), learnedWords: learnedWords)
            expanded += ([[]] + Array(prefixes.prefix(3))).map { $0 + [completion.span] }
        }
        return Array((0..<max(exact.count, expanded.count)).flatMap { index in
            [expanded, exact].compactMap { index < $0.count ? $0[index] : nil }
        }.prefix(64))
    }

    private static func prefixMatches(_ prefix: String, in words: [String]) -> [String] {
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if words[middle] < prefix { lower = middle + 1 } else { upper = middle }
        }
        return Array(words.dropFirst(lower).prefix(while: { $0.hasPrefix(prefix) }).prefix(64))
    }

    private struct Hypothesis {
        var score: Int
        var spans: [Int]
    }

    /// 重ならない英語区間の組み合わせと単独の区間を探索する。
    func variants(for characters: [Character], learnedWords: Set<String>) -> [[Span]] {
        let matches = self.matches(in: characters, learnedWords: learnedWords)
        guard !matches.isEmpty else {
            return []
        }
        var startingAt = Array(repeating: [Int](), count: characters.count + 1)
        for (index, match) in matches.enumerated() {
            startingAt[match.range.lowerBound].append(index)
        }
        var states = Array(repeating: [[Int]: Hypothesis](), count: characters.count + 1)
        states[0][[]] = .init(score: 0, spans: [])
        for index in characters.indices {
            for state in states[index].values.sorted(by: Self.better).prefix(64) {
                states[index + 1][state.spans] = state
                for matchIndex in startingAt[index] {
                    let match = matches[matchIndex]
                    let next = Hypothesis(score: state.score + match.score, spans: state.spans + [matchIndex])
                    states[match.range.upperBound][next.spans] = next
                }
            }
            states[index].removeAll(keepingCapacity: false)
        }
        let combinations = states[characters.count].values.filter { !$0.spans.isEmpty }.sorted(by: Self.better)
        let singles = matches.indices.map { Hypothesis(score: matches[$0].score, spans: [$0]) }.sorted(by: Self.better)
        var result: [[Span]] = []
        var seen: Set<[Int]> = []
        for index in 0..<max(combinations.count, singles.count) {
            for list in [combinations, singles] where index < list.count {
                let state = list[index]
                if seen.insert(state.spans).inserted {
                    result.append(state.spans.map { matches[$0] })
                    if result.count == 64 {
                        return result
                    }
                }
            }
        }
        return result
    }

    private func matches(in characters: [Character], learnedWords: Set<String>) -> [Span] {
        var matches: [Span] = []
        let maximumLength = max(self.maximumLength, learnedWords.map(\.count).max() ?? 0)
        for start in characters.indices {
            var word = ""
            for end in start..<min(characters.count, start + maximumLength) {
                let character = String(characters[end]).lowercased()
                guard character.utf8.count == 1, let byte = character.utf8.first, Self.isWordByte(byte) else {
                    break
                }
                word += character
                if self.words.contains(word) || learnedWords.contains(word) {
                    let length = end + 1 - start
                    matches.append(.init(
                        range: start..<end + 1,
                        text: String(characters[start...end]),
                        score: length * length - 9 + (self.technicalWords.contains(word) || learnedWords.contains(word) ? 4 : 0)
                    ))
                }
            }
        }
        return matches
    }

    private static func better(_ lhs: Hypothesis, _ rhs: Hypothesis) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.spans.count != rhs.spans.count {
            return lhs.spans.count < rhs.spans.count
        }
        return lhs.spans.lexicographicallyPrecedes(rhs.spans)
    }
}
