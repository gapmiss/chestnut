import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum HeroGifGenerator {
    static let pixelScale = 4
    static let spriteW = PetFrames.gridWidth * pixelScale
    static let spriteH = PetFrames.gridHeight * pixelScale
    static let zScale = 2
    static let zW = PetFrames.zPixel[0].count * zScale
    static let zH = PetFrames.zPixel.count * zScale

    static let hopHeight = 12
    static let canvasW = spriteW + 52
    static let canvasH = spriteH + hopHeight + 40

    // Sprite pinned to bottom-center of canvas.
    static let spriteX = (canvasW - spriteW) / 2

    struct ZBubble { let x: Int; let y: Int }

    struct Frame {
        let pet: [String]
        let delay: Int
        let offsetY: Int
        let zBubbles: [ZBubble]
    }

    static func main() throws {
        let outputPath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : "docs/hero.gif"

        let palette = SpriteTheme.obsidianNight.palette

        // Z drift path: starts above the lid, drifts up and right.
        let zOriginX = spriteX + spriteW / 2 + 8
        let zStep = 16

        func zAt(_ stage: Int) -> ZBubble {
            ZBubble(
                x: zOriginX + stage * 10,
                y: hopHeight + spriteH + 2 + stage * zStep
            )
        }

        let frames: [Frame] = [
            // Idle breathe.
            Frame(pet: PetFrames.base,  delay: 100, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.glint, delay: 80,  offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.base,  delay: 60,  offsetY: 0, zBubbles: []),

            // Eye peek.
            Frame(pet: PetFrames.eyePeekLeft,  delay: 30, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.peek,         delay: 50, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.eyePeekRight, delay: 40, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.peek,         delay: 30, offsetY: 0, zBubbles: []),

            // Hop up.
            Frame(pet: PetFrames.peek, delay: 6, offsetY: 4,         zBubbles: []),
            Frame(pet: PetFrames.peek, delay: 6, offsetY: 8,         zBubbles: []),
            Frame(pet: PetFrames.peek, delay: 6, offsetY: hopHeight, zBubbles: []),
            // Hang.
            Frame(pet: PetFrames.peek, delay: 8, offsetY: hopHeight, zBubbles: []),
            // Fall.
            Frame(pet: PetFrames.peek, delay: 6, offsetY: 8, zBubbles: []),
            Frame(pet: PetFrames.peek, delay: 6, offsetY: 4, zBubbles: []),
            Frame(pet: PetFrames.base, delay: 6, offsetY: 0, zBubbles: []),

            // Chatter.
            Frame(pet: PetFrames.chatterOpen, delay: 16, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.base,        delay: 12, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.chatterOpen, delay: 16, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.base,        delay: 12, offsetY: 0, zBubbles: []),

            // Settle into sleep.
            Frame(pet: PetFrames.base,   delay: 80, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.glint,  delay: 60, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.asleep, delay: 60, offsetY: 0, zBubbles: []),

            // Z drift: one rises, then a second follows at fixed offset.
            Frame(pet: PetFrames.asleep, delay: 40, offsetY: 0,
                  zBubbles: [zAt(0)]),
            Frame(pet: PetFrames.asleep, delay: 40, offsetY: 0,
                  zBubbles: [zAt(1)]),
            Frame(pet: PetFrames.asleep, delay: 40, offsetY: 0,
                  zBubbles: [zAt(2), zAt(0)]),
            Frame(pet: PetFrames.asleep, delay: 40, offsetY: 0,
                  zBubbles: [zAt(3), zAt(1)]),
            Frame(pet: PetFrames.asleep, delay: 40, offsetY: 0,
                  zBubbles: [zAt(2)]),
            Frame(pet: PetFrames.asleep, delay: 50, offsetY: 0, zBubbles: []),

            // Wake.
            Frame(pet: PetFrames.base,  delay: 40, offsetY: 0, zBubbles: []),
            Frame(pet: PetFrames.glint, delay: 40, offsetY: 0, zBubbles: []),
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
            let image = renderFrame(
                rows: frame.pet, palette: palette,
                offsetY: frame.offsetY, zBubbles: frame.zBubbles
            )
            let props = [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: Double(frame.delay) / 100.0,
            ]] as CFDictionary
            CGImageDestinationAddImage(dest, image, props)
        }

        CGImageDestinationFinalize(dest)
        print("wrote \(outputPath)")
    }

    static func renderFrame(
        rows: [String], palette: [Character: SpriteTheme.RGBA],
        offsetY: Int, zBubbles: [ZBubble]
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .none

        let sprite = renderSprite(rows: rows, palette: palette, scale: pixelScale)
        ctx.draw(sprite, in: CGRect(
            x: spriteX, y: offsetY, width: spriteW, height: spriteH
        ))

        if !zBubbles.isEmpty {
            let zSprite = renderSprite(rows: PetFrames.zPixel, palette: palette, scale: zScale)
            for z in zBubbles {
                ctx.draw(zSprite, in: CGRect(x: z.x, y: z.y, width: zW, height: zH))
            }
        }

        return ctx.makeImage()!
    }

    static func renderSprite(
        rows: [String], palette: [Character: SpriteTheme.RGBA], scale: Int
    ) -> CGImage {
        let w = rows[0].count * scale
        let h = rows.count * scale
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * 4)
        for row in rows {
            var pixelRow = [UInt8]()
            for ch in row {
                let c = palette[ch]!
                for _ in 0..<scale {
                    pixelRow.append(contentsOf: [c.r, c.g, c.b, c.a])
                }
            }
            for _ in 0..<scale { bytes.append(contentsOf: pixelRow) }
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
