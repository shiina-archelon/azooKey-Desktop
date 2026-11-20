import Foundation

@MainActor
struct MixedLanguageLearning {
    static let shared = MixedLanguageLearning(defaults: Config.userDefaults)
    private static let key = "jp.archelon-inc.inputmethod.azooKeyMac.learning.mixedLanguageWords"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var words: Set<String> {
        Set((self.defaults.array(forKey: Self.key) as? [String] ?? []).map { $0.lowercased() })
    }

    func learn(_ words: [String], enabled: Bool) {
        guard enabled else {
            return
        }
        self.defaults.set(Array(self.words.union(words.map { $0.lowercased() })).sorted(), forKey: Self.key)
    }

    func forget(_ words: [String]) {
        self.defaults.set(Array(self.words.subtracting(words.map { $0.lowercased() })).sorted(), forKey: Self.key)
    }

    func reset() {
        self.defaults.removeObject(forKey: Self.key)
    }
}
