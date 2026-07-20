import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum HeroGifGenerator {
    static let pixelScale = 4
    static let spriteW = PetFrames.gridWidth * pixelScale
    static let spriteH = PetFrames.gridHeight * pixelScale

    static let hopHeight = 12
    static let canvasW = spriteW
    static let canvasH = spriteH + hopHeight

    struct Frame {
        let pet: [String]
        let delay: Int
        let offsetY: Int
    }

    static func main() throws {
        let outputPath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "docs/hero.gif"

        let palette = SpriteTheme.obsidianNight.palette

        let frames: [Frame] = [
            // Idle breathe.
            Frame(pet: PetFrames.base,  delay: 100, offsetY: 0),
            Frame(pet: PetFrames.glint, delay: 80,  offsetY: 0),
            Frame(pet: PetFrames.base,  delay: 60,  offsetY: 0),

            // Eye peek.
            Frame(pet: PetFrames.eyePeekLeft,  delay: 30, offsetY: 0),
            Frame(pet: PetFrames.peek,         delay: 50, offsetY: 0),
            Frame(pet: PetFrames.eyePeekRight, delay: 40, offsetY: 0),
            Frame(pet: PetFrames.peek,         delay: 30, offsetY: 0),

            // Hop up.
            Frame(pet: PetFrames.peek, delay: 6,  offsetY: 4),
            Frame(pet: PetFrames.peek, delay: 6,  offsetY: 8),
            Frame(pet: PetFrames.peek, delay: 6,  offsetY: hopHeight),
            // Hang.
            Frame(pet: PetFrames.peek, delay: 8,  offsetY: hopHeight),
            // Fall.
            Frame(pet: PetFrames.peek, delay: 6,  offsetY: 8),
            Frame(pet: PetFrames.peek, delay: 6,  offsetY: 4),
            Frame(pet: PetFrames.base, delay: 6,  offsetY: 0),

            // Chatter.
            Frame(pet: PetFrames.chatterOpen, delay: 16, offsetY: 0),
            Frame(pet: PetFrames.base,        delay: 12, offsetY: 0),
            Frame(pet: PetFrames.chatterOpen, delay: 16, offsetY: 0),
            Frame(pet: PetFrames.base,        delay: 12, offsetY: 0),

            // Settle.
            Frame(pet: PetFrames.base,  delay: 80, offsetY: 0),
            Frame(pet: PetFrames.glint, delay: 60, offsetY: 0),
        ]

        let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outputPath) as CFURL,
            "com.compuserve.gif" as CFString,
            frames.count, nil
        )!

        let gifProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFHasGlobalColorMap: false,
            kCGImagePropertyGIFLoopCount: 0,
        ]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)

        for frame in frames {
            let image = renderFrame(rows: frame.pet, palette: palette, offsetY: frame.offsetY)
            let props = [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: Double(frame.delay) / 100.0,
            ]] as CFDictionary
            CGImageDestinationAddImage(dest, image, props)
        }

        CGImageDestinationFinalize(dest)
        print("wrote \(outputPath)")
    }

    static func renderFrame(
        rows: [String], palette: [Character: SpriteTheme.RGBA], offsetY: Int
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .none

        let sprite = renderSprite(rows: rows, palette: palette)
        // CG origin is bottom-left; offsetY pushes the sprite up.
        ctx.draw(sprite, in: CGRect(x: 0, y: offsetY, width: spriteW, height: spriteH))

        return ctx.makeImage()!
    }

    static func renderSprite(
        rows: [String], palette: [Character: SpriteTheme.RGBA]
    ) -> CGImage {
        let w = rows[0].count * pixelScale
        let h = rows.count * pixelScale
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * 4)
        for row in rows {
            var pixelRow = [UInt8]()
            for ch in row {
                let c = palette[ch]!
                for _ in 0..<pixelScale {
                    pixelRow.append(contentsOf: [c.r, c.g, c.b, c.a])
                }
            }
            for _ in 0..<pixelScale { bytes.append(contentsOf: pixelRow) }
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
}

@main enum Tool {
    static func main() throws {
        try HeroGifGenerator.main()
    }
}
