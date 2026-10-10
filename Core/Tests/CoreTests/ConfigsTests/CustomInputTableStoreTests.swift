import Core
import Foundation
import KanaKanjiConverterModule
import Testing

@Suite("カスタム入力表の登録")
@MainActor
struct CustomInputTableStoreTests {
    @Test("同じ入力表を繰り返し登録しても、かな変換を利用できる")
    func registerUnchangedTable() throws {
        try withTableFile { url in
            try Data("a\tあ\n".utf8).write(to: url, options: [.atomic])
            #expect(CustomInputTableStore.registerIfExists(at: url))
            #expect(CustomInputTableStore.registerIfExists(at: url))
            #expect(convert("a") == "あ")
        }
    }

    @Test("入力表の変更を次の登録で反映する")
    func reloadChangedTable() throws {
        try withTableFile { url in
            try Data("a\tあ\n".utf8).write(to: url, options: [.atomic])
            #expect(CustomInputTableStore.registerIfExists(at: url))
            try Data("a\tい\n".utf8).write(to: url, options: [.atomic])
            #expect(CustomInputTableStore.registerIfExists(at: url))
            #expect(convert("a") == "い")
        }
    }

    @Test("入力表を削除すると登録できない")
    func rejectDeletedTable() throws {
        try withTableFile { url in
            try Data("a\tあ\n".utf8).write(to: url, options: [.atomic])
            #expect(CustomInputTableStore.registerIfExists(at: url))
            try FileManager.default.removeItem(at: url)
            #expect(!CustomInputTableStore.registerIfExists(at: url))
        }
    }

    private func convert(_ input: String) -> String {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(input, inputStyle: .mapped(id: .tableName(CustomInputTableStore.tableName)))
        return composingText.convertTarget
    }

    private func withTableFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("table.tsv"))
    }
}
