#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import KanaKanjiConverterModule

public enum CustomInputTableStore {
    /// The identifier used when registering the custom input table.
    public static let tableName: String = "azooKeyMac.customRomajiTable"
    private static let appSupportSubdir = "azooKeyMac"
    private static let directoryName = "CustomInputTable"
    private static let fileName = "custom_input_table.tsv"
    private static let registrationCache = RegistrationCache()

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appSupportSubdir, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var fileURL: URL {
        #if canImport(UniformTypeIdentifiers) && !os(Linux)
        return directoryURL.appendingPathComponent(fileName, conformingTo: .text)
        #else
        return directoryURL.appendingPathComponent(fileName)
        #endif
    }

    @discardableResult
    public static func save(exported: String) throws -> URL {
        try ensureDirectoryExists()
        let data = Data(exported.utf8)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    public static func load() -> String? {
        guard exists() else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    public static func loadTable() -> InputTable? {
        guard exists() else {
            return nil
        }
        return try? InputStyleManager.loadTable(from: fileURL)
    }

    /// Load and register the custom input table if it exists.
    /// Safe to call multiple times; unchanged files reuse the previous registration.
    @discardableResult
    public static func registerIfExists() -> Bool {
        registerIfExists(at: fileURL)
    }

    /// 指定ファイルをカスタム入力表として登録する。
    @discardableResult
    public static func registerIfExists(at url: URL) -> Bool {
        registrationCache.lock.lock()
        defer { registrationCache.lock.unlock() }
        guard let revision = FileRevision(at: url) else {
            registrationCache.revision = nil
            return false
        }
        if registrationCache.revision == revision {
            return true
        }
        registrationCache.revision = nil
        guard let table = try? InputStyleManager.loadTable(from: url) else {
            return false
        }
        InputStyleManager.registerInputStyle(table: table, for: tableName)
        registrationCache.revision = revision
        return true
    }

    public static func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    private static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // 登録済みの更新情報を保持し、確認から登録までをロックで保護する。
    private final class RegistrationCache: @unchecked Sendable {
        let lock = NSLock()
        var revision: FileRevision?
    }

    // 更新日時で入力表の変更を検知する。
    private struct FileRevision: Equatable {
        let url: URL
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64

        init?(at url: URL) {
            var metadata = stat()
            guard stat(url.path, &metadata) == 0 else {
                return nil
            }
            self.url = url
            #if canImport(Darwin)
            let modifiedAt = metadata.st_mtimespec
            #else
            let modifiedAt = metadata.st_mtim
            #endif
            modificationSeconds = Int64(modifiedAt.tv_sec)
            modificationNanoseconds = Int64(modifiedAt.tv_nsec)
        }
    }
}
