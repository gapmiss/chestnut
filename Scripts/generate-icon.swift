import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum IconGenerator {
    static func main() throws {
        let palette = SpriteTheme.obsidianNight.palette
        let rows = PetFrames.peek
        let srcW = rows[0].count
        let srcH = rows.count

        let iconsetDir = ".build/Chestnut.iconset"
        let fm = FileManager.default
        try? fm.removeItem(atPath: iconsetDir)
        try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

        let specs: [(name: String, px: Int)] = [
            ("icon_16x16",      16),
            ("icon_16x16@2x",   32),
            ("icon_32x32",      32),
            ("icon_32x32@2x",   64),
            ("icon_128x128",    128),
            ("icon_128x128@2x", 256),
            ("icon_256x256",    256),
            ("icon_256x256@2x", 512),
            ("icon_512x512",    512),
            ("icon_512x512@2x", 1024),
        ]

        for spec in specs {
            let pixelScale = max(1, spec.px / srcW)
            let spriteW = srcW * pixelScale
            let spriteH = srcH * pixelScale
            let s = spec.px

            let spriteImage = renderSprite(
                rows: rows, palette: palette, scale: pixelScale
            )

            let ctx = CGContext(
                data: nil, width: s, height: s,
                bitsPerComponent: 8, bytesPerRow: s * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!

            // macOS squircle background — continuous corner curve.
            let radius = Double(s) * 0.225
            let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
            let squircle = CGPath(
                roundedRect: bgRect,
                cornerWidth: radius, cornerHeight: radius,
                transform: nil
            )
            // Dark purple-graphite gradient: shell shadow → shell color.
            ctx.saveGState()
            ctx.addPath(squircle)
            ctx.clip()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradientColors = [
                CGColor(colorSpace: colorSpace, components: [0.16, 0.14, 0.27, 1])!,
                CGColor(colorSpace: colorSpace, components: [0.24, 0.21, 0.38, 1])!,
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1]
            )!
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: s),
                options: []
            )
            ctx.restoreGState()

            // Sprite centered, nearest-neighbor scaled.
            ctx.interpolationQuality = .none
            let x = (s - spriteW) / 2
            let y = (s - spriteH) / 2
            ctx.draw(spriteImage, in: CGRect(x: x, y: y, width: spriteW, height: spriteH))

            let canvas = ctx.makeImage()!
            try writePNG(canvas, to: "\(iconsetDir)/\(spec.name).png")
        }

        print("iconset written to \(iconsetDir)")
    }

    static func renderSprite(
        rows: [String],
        palette: [Character: SpriteTheme.RGBA],
        scale: Int
    ) -> CGImage {
        let w = rows[0].count * scale
        let h = rows.count * scale
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * 4)
        for row in rows {
            var pixelRow = [UInt8]()
            pixelRow.reserveCapacity(w * 4)
            for ch in row {
                let c = palette[ch]!
                for _ in 0..<scale {
                    pixelRow.append(contentsOf: [c.r, c.g, c.b, c.a])
                }
            }
            for _ in 0..<scale {
                bytes.append(contentsOf: pixelRow)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

@main enum Tool {
    static func main() throws {
        try IconGenerator.main()
    }
}
