import SpriteKit

/// Renders the pet and plays the animation for the current PetState.
/// The scene is presentation-only: state decisions live in PetController.
final class PetScene: SKScene {
    private enum ActionKey {
        static let stateLoop = "stateLoop"
        static let breathe = "breathe"
        static let eyePeek = "eyePeek"
        static let hop = "hop"
        static let zSpawner = "zSpawner"
    }

    /// SKView renders every frame while unpaused, even if nothing in the scene
    /// changed, so steady-state CPU is set by the frame rate — not by how much
    /// is animating. Every state runs calm (chatter frames last 0.2s, two whole
    /// ticks); only brief squash-and-stretch gestures boost.
    private enum FrameRate {
        static let calm = 10     // breathing, eye peeks, chatter, drifting z
        static let gesture = 60  // click hop / delivery gulp tweens
    }

    private struct Textures {
        let base: SKTexture
        let glint: SKTexture
        let asleep: SKTexture
        let eyeLeft: SKTexture
        let eyeRight: SKTexture
        let peek: SKTexture
        let chatterOpen: SKTexture
        let z: SKTexture

        init(palette: [Character: SpriteTheme.RGBA]) {
            base = Sprites.texture(from: PetFrames.base, palette: palette)
            glint = Sprites.texture(from: PetFrames.glint, palette: palette)
            asleep = Sprites.texture(from: PetFrames.asleep, palette: palette)
            eyeLeft = Sprites.texture(from: PetFrames.eyePeekLeft, palette: palette)
            eyeRight = Sprites.texture(from: PetFrames.eyePeekRight, palette: palette)
            peek = Sprites.texture(from: PetFrames.peek, palette: palette)
            chatterOpen = Sprites.texture(from: PetFrames.chatterOpen, palette: palette)
            z = Sprites.texture(from: PetFrames.zPixel, palette: palette)
        }
    }

    /// Height of the transparent strip under the sprite (window bottom margin).
    nonisolated static let baselineY: CGFloat = 8

    private let pixelScale: CGFloat
    private let tex: Textures
    private let mask: [[Bool]]
    private let pet: SKSpriteNode
    private var currentState: PetState = .idle
    private var openWide = false
    private var chewing = false
    private var poseLocked: Bool { openWide || chewing }

    init(size: CGSize, pixelScale: CGFloat, palette: [Character: SpriteTheme.RGBA]) {
        self.pixelScale = pixelScale
        tex = Textures(palette: palette)
        mask = Sprites.opaqueMask(from: PetFrames.base, palette: palette)
        pet = SKSpriteNode(texture: tex.base)
        super.init(size: size)

        backgroundColor = .clear
        scaleMode = .resizeFill

        pet.anchorPoint = CGPoint(x: 0.5, y: 0)  // grows/squashes from its base
        pet.size = CGSize(
            width: CGFloat(PetFrames.gridWidth) * pixelScale,
            height: CGFloat(PetFrames.gridHeight) * pixelScale
        )
        pet.position = CGPoint(x: size.width / 2, y: Self.baselineY)
        addChild(pet)

        play(.idle)
    }

    required init?(coder: NSCoder) {
        fatalError("PetScene is code-only")
    }

    /// play(.idle) runs in init, before the scene has a view to throttle.
    override func didMove(to view: SKView) {
        applyStateFrameRate()
    }

    private func applyStateFrameRate() {
        view?.preferredFramesPerSecond = FrameRate.calm
    }

    // MARK: - State animations

    func play(_ state: PetState) {
        currentState = state
        applyStateFrameRate()  // before the guard: also ends a stuck gesture boost
        guard !poseLocked else { return }  // pose resumes when the palette closes
        pet.removeAction(forKey: ActionKey.stateLoop)
        pet.removeAction(forKey: ActionKey.eyePeek)
        pet.removeAction(forKey: ActionKey.breathe)
        removeAction(forKey: ActionKey.zSpawner)
        pet.setScale(1)

        switch state {
        case .idle:
            pet.texture = tex.base
            startBreathing(period: 2.6, amount: 1.03)
            scheduleEyePeek()
        case .peek:
            pet.texture = tex.peek
            startBreathing(period: 2.0, amount: 1.02)
        case .writing:
            // Acknowledge, then settle: continuous mouth-flapping for a whole
            // writing session is distracting. Two chatter cycles greet the
            // session, then an attentive glint pose with a single cycle every
            // 10–20s says "still with you" without becoming a metronome.
            pet.texture = tex.glint
            startBreathing(period: 2.0, amount: 1.02)
            let occasional = SKAction.sequence([
                SKAction.wait(forDuration: 15, withRange: 10),
                chatterBurst(cycles: 1),
            ])
            pet.run(
                .sequence([chatterBurst(cycles: 2), .repeatForever(occasional)]),
                withKey: ActionKey.stateLoop
            )
        case .sleep:
            pet.texture = tex.asleep
            startBreathing(period: 4.5, amount: 1.02)
            startZDrift()
        }
    }

    /// Vault Hopper pose: lid held open while the palette is up (full open-wide
    /// art with rolled-out tongue is on the frame-iteration list).
    func setOpenWide(_ open: Bool) {
        guard openWide != open else { return }
        openWide = open
        if open {
            pet.removeAction(forKey: ActionKey.stateLoop)
            pet.removeAction(forKey: ActionKey.eyePeek)
            pet.removeAction(forKey: ActionKey.breathe)
            removeAction(forKey: ActionKey.zSpawner)
            pet.setScale(1)
            pet.texture = tex.chatterOpen
            applyStateFrameRate()
        } else if chewing {
            startChewPose()
        } else {
            play(currentState)
        }
    }

    /// Plugin-running pose: continuous gentle chewing with a slow breathing
    /// sway, distinct from the static open-wide and the brief writing chatter.
    func setChewing(_ flag: Bool) {
        guard chewing != flag else { return }
        chewing = flag
        if flag {
            startChewPose()
        } else if openWide {
            pet.removeAction(forKey: ActionKey.stateLoop)
            pet.removeAction(forKey: ActionKey.breathe)
            pet.setScale(1)
            pet.texture = tex.chatterOpen
        } else {
            play(currentState)
        }
    }

    private func startChewPose() {
        pet.removeAction(forKey: ActionKey.stateLoop)
        pet.removeAction(forKey: ActionKey.eyePeek)
        pet.removeAction(forKey: ActionKey.breathe)
        removeAction(forKey: ActionKey.zSpawner)
        pet.setScale(1)
        let chew = SKAction.animate(
            with: [tex.chatterOpen, tex.glint, tex.base, tex.glint],
            timePerFrame: 0.3
        )
        pet.run(.repeatForever(chew), withKey: ActionKey.stateLoop)
        startBreathing(period: 3.0, amount: 1.02)
    }

    /// Delivery complete: gulp, satisfied squash, gem sparkle, back to state.
    func celebrateDelivery() {
        pet.removeAction(forKey: ActionKey.stateLoop)
        pet.removeAction(forKey: ActionKey.eyePeek)
        pet.removeAction(forKey: ActionKey.breathe)
        removeAction(forKey: ActionKey.zSpawner)
        view?.preferredFramesPerSecond = FrameRate.gesture  // play() restores
        let gulp = SKAction.sequence([
            SKAction.setTexture(tex.chatterOpen),
            SKAction.wait(forDuration: 0.15),
            SKAction.setTexture(tex.base),
            SKAction.scaleY(to: 0.9, duration: 0.1).with(timing: .easeIn),
            SKAction.scaleY(to: 1.0, duration: 0.12).with(timing: .easeOut),
            SKAction.setTexture(tex.glint),
            SKAction.wait(forDuration: 0.4),
            SKAction.run { [weak self] in
                guard let self else { return }
                self.play(self.currentState)
            },
        ])
        pet.run(gulp, withKey: ActionKey.hop)
    }

    /// Click reaction: squash-and-stretch hop, then back to the current state.
    func handleClick() {
        guard pet.action(forKey: ActionKey.hop) == nil else { return }
        pet.removeAction(forKey: ActionKey.breathe)
        view?.preferredFramesPerSecond = FrameRate.gesture  // play() restores
        let jump = SKAction.sequence([
            SKAction.moveBy(x: 0, y: 5 * pixelScale, duration: 0.18).with(timing: .easeOut),
            SKAction.moveBy(x: 0, y: -5 * pixelScale, duration: 0.18).with(timing: .easeIn),
        ])
        let squash = SKAction.sequence([
            SKAction.scaleX(to: 0.92, y: 1.08, duration: 0.18),
            SKAction.scaleX(to: 1.08, y: 0.92, duration: 0.18),
        ])
        let hop = SKAction.sequence([
            SKAction.group([jump, squash]),
            SKAction.scaleX(to: 1.0, y: 1.0, duration: 0.08),
            SKAction.run { [weak self] in
                guard let self else { return }
                self.play(self.currentState)
            },
        ])
        pet.run(hop, withKey: ActionKey.hop)
    }

    /// Quick open/close mouth cycles, settling on the attentive glint pose.
    private func chatterBurst(cycles: Int) -> SKAction {
        .sequence([
            SKAction.repeat(
                SKAction.animate(
                    with: [tex.base, tex.chatterOpen, tex.glint, tex.chatterOpen],
                    timePerFrame: 0.2  // two whole ticks at FrameRate.calm
                ),
                count: cycles
            ),
            SKAction.setTexture(tex.glint),
        ])
    }

    private func startBreathing(period: TimeInterval, amount: CGFloat) {
        let breathe = SKAction.sequence([
            SKAction.scaleY(to: amount, duration: period / 2).with(timing: .easeInEaseOut),
            SKAction.scaleY(to: 1.0, duration: period / 2).with(timing: .easeInEaseOut),
        ])
        pet.run(.repeatForever(breathe), withKey: ActionKey.breathe)
    }

    /// Idle: every 8–20s an eye peeks out from under the lid and looks around.
    private func scheduleEyePeek() {
        let peekOnce = SKAction.sequence([
            SKAction.wait(forDuration: 14, withRange: 12),  // 8–20s
            SKAction.setTexture(tex.eyeLeft),
            SKAction.wait(forDuration: 0.5),
            SKAction.setTexture(tex.eyeRight),
            SKAction.wait(forDuration: 0.5),
            SKAction.setTexture(tex.eyeLeft),
            SKAction.wait(forDuration: 0.35),
            SKAction.setTexture(tex.base),
        ])
        pet.run(.repeatForever(peekOnce), withKey: ActionKey.eyePeek)
    }

    /// Sleep: "z" pixels drift up from the lid and fade.
    private func startZDrift() {
        let spawn = SKAction.run { [weak self] in self?.spawnZ() }
        let loop = SKAction.sequence([SKAction.wait(forDuration: 1.6), spawn])
        run(.repeatForever(loop), withKey: ActionKey.zSpawner)
    }

    private func spawnZ() {
        let z = SKSpriteNode(texture: tex.z)
        let zScale = max(pixelScale / 2, 2)
        z.size = CGSize(
            width: CGFloat(PetFrames.zPixel[0].count) * zScale,
            height: CGFloat(PetFrames.zPixel.count) * zScale
        )
        z.position = CGPoint(
            x: pet.position.x + pet.size.width * 0.25,
            y: pet.position.y + pet.size.height * 0.9
        )
        addChild(z)
        z.run(.sequence([
            SKAction.group([
                SKAction.moveBy(x: 2 * pixelScale, y: 6 * pixelScale, duration: 2.2),
                SKAction.fadeOut(withDuration: 2.2),
            ]),
            SKAction.removeFromParent(),
        ]))
    }

    // MARK: - Hit-testing

    /// Per-pixel hit test against the base silhouette (identical across states).
    /// Tracks the pet's current position/scale via coordinate conversion.
    func petContainsOpaquePixel(at scenePoint: CGPoint) -> Bool {
        let local = pet.convert(scenePoint, from: self)
        let cols = mask[0].count
        let rows = mask.count
        let col = Int((local.x / pixelScale + CGFloat(cols) * pet.anchorPoint.x).rounded(.down))
        let row = Int((CGFloat(rows) * (1 - pet.anchorPoint.y) - local.y / pixelScale).rounded(.down))
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return false }
        return mask[row][col]
    }
}

extension SKAction {
    func with(timing mode: SKActionTimingMode) -> SKAction {
        timingMode = mode
        return self
    }
}
