import Foundation

/// Chestnut's frames, 24×18 logical pixels: the classic chest — trim hasp on
/// the lid, trim lock plate with a purple gem on the base. This is the
/// original drawing (kept after the 32×24 vault redraw lost at the screen,
/// 2026-07-15) with theme-neutral role characters. Variants are derived from
/// `base` (row swaps / palette substitutions) so the silhouette stays
/// identical across states — which also lets hit-testing use a single opaque
/// mask.
///
/// Roles (colored per-theme in SpriteTheme): `.` transparent, `o` outline,
/// `s`/`S`/`d` shell/highlight/shadow, `m` trim (hasp, lock plate),
/// `p`/`P` gem/glint, `k` interior, `t` tongue, `e`/`b` eye/pupil, `z` sleep.
enum PetFrames {
    static let gridWidth = 24
    static let gridHeight = 18

    /// Closed chest: rows 0–6 lid, row 7 seam, rows 8–17 base.
    static let base: [String] = [
        "......oooooooooooo......",
        "....oossssssssssssoo....",
        "...osSSssssssssssSSso...",
        "..osssssssssssssssssso..",
        "..osssssssmmmmssssssso..",
        "..osssssssmmmmssssssso..",
        "..osssssssssssssssssso..",
        "..oooooooooooooooooooo..",
        "..osssssssmmmmmsssssso..",
        "..osssssssmpppmsssssso..",
        "..osssssssmpPpmsssssso..",
        "..osssssssmpppmsssssso..",
        "..osssssssmmmmmsssssso..",
        "..osssssssssssssssssso..",
        "..osSssssssssssssssSso..",
        "...osssssssssssssssso...",
        "....oossssssssssssoo....",
        "......oooooooooooo......",
    ]

    /// Gem glint: bright/dim rings swapped.
    static let glint: [String] = base.map { row in
        String(row.map { $0 == "p" ? "P" : ($0 == "P" ? "p" : $0) })
    }

    /// Asleep: gems go dark, nothing shines.
    static let asleep: [String] = base.map { row in
        String(row.map { $0 == "p" || $0 == "P" ? "d" : $0 })
    }

    /// One eye peeks out from under the lid (left / right variants for the
    /// idle "looks around" beat).
    static let eyePeekLeft: [String] = base
        .replacing(row: 6, with: "..osssebssssssssssssso..")
        .replacing(row: 7, with: "..oooookkooooooooooooo..")

    static let eyePeekRight: [String] = base
        .replacing(row: 6, with: "..osssssssssssssebssso..")
        .replacing(row: 7, with: "..ooooooooooooookkoooo..")

    /// Hover: lid cracks open along the whole seam, both eyes out.
    static let peek: [String] = base
        .replacing(row: 6, with: "..ossebssssssssssebsso..")
        .replacing(row: 7, with: "..okkkkkkkkkkkkkkkkkko..")

    /// Writing chatter: mouth open showing dark interior and tongue.
    static let chatterOpen: [String] = base
        .replacing(row: 6, with: "..okkkkkkkttttttkkkkko..")

    /// 4×4 "z" pixel for the sleep drift. The diagonal needs two steps to
    /// read as a z — a 3×3 collapses to an I-beam.
    static let zPixel: [String] = [
        "zzzz",
        "..z.",
        ".z..",
        "zzzz",
    ]

    // MARK: - Validation (Foundation-only, exercised by `make check`)

    /// Every role character the frames may reference; each theme's palette
    /// must color all of them.
    static let roleCharacters: Set<Character> = [
        ".", "o", "s", "S", "d", "m", "p", "P", "k", "t", "e", "b", "z",
    ]

    /// The body frames (zPixel is a separate 3×3 overlay).
    static let bodyVariants: [(name: String, rows: [String])] = [
        ("base", base), ("glint", glint), ("asleep", asleep),
        ("eyePeekLeft", eyePeekLeft), ("eyePeekRight", eyePeekRight),
        ("peek", peek), ("chatterOpen", chatterOpen),
    ]

    /// Frame-matrix problems, empty when the art is well-formed: grid-sized
    /// rectangular frames, only known role characters, and the invariant that
    /// every variant shares base's silhouette (one opaque mask serves
    /// hit-testing and click-through for all states).
    static func validationFailures() -> [String] {
        var failures: [String] = []
        func silhouette(_ rows: [String]) -> [[Bool]] {
            rows.map { row in row.map { $0 != "." } }
        }
        for (name, rows) in bodyVariants + [("zPixel", zPixel)] {
            for ch in Set(rows.joined()) where !roleCharacters.contains(ch) {
                failures.append("\(name): unknown role character '\(ch)'")
            }
        }
        for (name, rows) in bodyVariants {
            if rows.count != gridHeight || rows.contains(where: { $0.count != gridWidth }) {
                failures.append("\(name): frame is not \(gridWidth)×\(gridHeight)")
                continue
            }
            if silhouette(rows) != silhouette(base) {
                failures.append("\(name): silhouette differs from base")
            }
        }
        return failures
    }
}

private extension [String] {
    func replacing(row: Int, with newRow: String) -> [String] {
        precondition(newRow.count == self[row].count, "row width mismatch")
        var copy = self
        copy[row] = newRow
        return copy
    }
}
