import Foundation

enum TypoKeyboardLayout {
    struct Neighbor: Sendable {
        let key: Character
        let distance: Float
    }

    struct Layout: Sendable {
        let neighbors: [Character: [Neighbor]]
        let shifts: [[Character: Character]]
        let shiftedKeys: [Character: Character]
        let unshiftedKeys: [Character: Character]

        func character(for key: Character, matchingShiftOf original: Character) -> Character {
            guard self.unshiftedKeys[original] != nil else {
                return key
            }
            return self.shiftedKeys[key] ?? key
        }
    }

    private static let qwertyRows = ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"]
    private static let shiftedQwertyRows = ["~!@#$%^&*()_+", "QWERTYUIOP{}|", "ASDFGHJKL:\"", "ZXCVBNM<>?"]
    private static let qwerty = makeLayout(rows: qwertyRows, shiftedRows: shiftedQwertyRows)
    private static let british = makeLayout(rows: qwertyRows, shiftedRows: ["~!@£$%^&*()_+"] + shiftedQwertyRows.dropFirst())
    private static let colemak = makeLayout(
        rows: ["`1234567890-=", "qwfpgjluy;[]\\", "arstdhneio'", "zxcvbkm,./"],
        shiftedRows: ["~!@#$%^&*()_+", "QWFPGJLUY:{}|", "ARSTDHNEIO\"", "ZXCVBKM<>?"]
    )
    private static let dvorak = makeLayout(
        rows: ["`1234567890[]", "',.pyfgcrl/=\\", "aoeuidhtns-", ";qjkxbmwvz"],
        shiftedRows: ["~!@#$%^&*(){}", "\"<>PYFGCRL?+|", "AOEUIDHTNS_", ":QJKXBMWVZ"]
    )

    static func layout(for layout: Config.KeyboardLayout.Value) -> Layout {
        switch layout {
        case .qwerty, .australian:
            self.qwerty
        case .british:
            self.british
        case .colemak:
            self.colemak
        case .dvorak, .dvorakQwertyCommand:
            self.dvorak
        }
    }

    private static func makeLayout(rows: [String], shiftedRows: [String]) -> Layout {
        let rowOffsets: [Float] = [-1.5, 0, 0.25, 0.75]
        let keys = rows.enumerated().flatMap { row, characters in
            characters.enumerated().map { column, key in
                (key: key, x: rowOffsets[row] + Float(column), y: Float(row))
            }
        }
        let neighbors = Dictionary(uniqueKeysWithValues: keys.map { source in
            let neighbors = keys.compactMap { target -> Neighbor? in
                let distance = hypot(source.x - target.x, source.y - target.y)
                guard distance > 0, distance <= 1.65 else {
                    return nil
                }
                return .init(key: target.key, distance: distance)
            }
            return (source.key, neighbors)
        })
        let shifts: [[Character: Character]] = [-1, 0, 1].flatMap { vertical in
            [-1, 0, 1].compactMap { horizontal in
                guard horizontal != 0 || vertical != 0 else {
                    return nil
                }
                return Dictionary(uniqueKeysWithValues: keys.compactMap { source in
                    let x = source.x + Float(horizontal)
                    let y = source.y + Float(vertical)
                    let target = keys.lazy.filter { $0.y == y }.min { abs($0.x - x) < abs($1.x - x) }
                    guard let target, abs(target.x - x) <= 0.5 else {
                        return nil
                    }
                    return (source.key, target.key)
                })
            }
        }
        let shiftedKeys = Dictionary(uniqueKeysWithValues: zip(rows, shiftedRows).flatMap { Array(zip($0, $1)) })
        let unshiftedKeys = Dictionary(uniqueKeysWithValues: shiftedKeys.map { ($0.value, $0.key) })
        return .init(neighbors: neighbors, shifts: shifts, shiftedKeys: shiftedKeys, unshiftedKeys: unshiftedKeys)
    }
}
