import SpriteKit

/// Hand-coded pixel frames: string matrices + a theme palette → SKTextures.
/// Rows are top-to-bottom; every row in a frame must have equal length.
/// Colors live in SpriteTheme; frames define roles only.
enum Sprites {
    static func texture(
        from rows: [String], palette: [Character: SpriteTheme.RGBA]
    ) -> SKTexture {
        let height = rows.count
        let width = rows[0].count
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for row in rows {
            precondition(row.count == width, "ragged sprite frame: \(row)")
            for ch in row {
                guard let c = palette[ch] else {
                    preconditionFailure("unknown palette character: \(ch)")
                }
                bytes.append(contentsOf: [c.r, c.g, c.b, c.a])
            }
        }
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            preconditionFailure("failed to build sprite CGImage")
        }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    /// True where the frame has a visible pixel — used for per-pixel
    /// hit-testing. Only alpha matters, and `.` is transparent in every theme
    /// (custom overrides can't touch it), so the mask is theme-independent.
    static func opaqueMask(
        from rows: [String], palette: [Character: SpriteTheme.RGBA]
    ) -> [[Bool]] {
        rows.map { row in row.map { (palette[$0]?.a ?? 0) > 0 } }
    }
}
