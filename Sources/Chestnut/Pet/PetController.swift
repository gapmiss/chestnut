import Foundation

enum PetState: Equatable {
    case idle
    case peek
    case writing
    case sleep
}

/// Pure state machine: events update timestamps/flags; the current state is
/// derived from them. No timers, no UI — the controller drives it with a clock.
struct PetStateMachine {
    static let writingDecay: TimeInterval = 30    // writing → idle after silence
    static let sleepAfter: TimeInterval = 5 * 60  // idle → sleep

    private var hovering = false
    private var lastWriting: Date = .distantPast
    private var lastInteraction: Date

    init(now: Date) {
        lastInteraction = now
    }

    /// Most recent thing that should keep the pet awake.
    private var lastActivity: Date { max(lastWriting, lastInteraction) }

    func state(at now: Date) -> PetState {
        if hovering { return .peek }
        if now.timeIntervalSince(lastWriting) < Self.writingDecay { return .writing }
        if now.timeIntervalSince(lastActivity) >= Self.sleepAfter { return .sleep }
        return .idle
    }

    /// When the derived state will next change on its own (decay), if ever.
    func nextDeadline(after now: Date) -> Date? {
        switch state(at: now) {
        case .writing:
            return lastWriting.addingTimeInterval(Self.writingDecay)
        case .idle, .peek:
            return lastActivity.addingTimeInterval(Self.sleepAfter)
        case .sleep:
            return nil
        }
    }

    mutating func hover(_ over: Bool, at now: Date) {
        hovering = over
        if over { lastInteraction = now }
    }

    mutating func writingActivity(at now: Date) {
        lastWriting = now
    }

    /// Click, drag, capture … anything the user did to the pet directly.
    mutating func interaction(at now: Date) {
        lastInteraction = now
    }

}

/// Owns the state machine and a decay timer; publishes state changes to the scene.
@MainActor
final class PetController {
    var onStateChange: ((PetState) -> Void)?

    private var machine = PetStateMachine(now: Date())
    private var lastPublished: PetState?
    private var decayTimer: Timer?

    func start() {
        publish()
    }

    func noteHover(_ over: Bool) {
        machine.hover(over, at: Date())
        publish()
    }

    func noteWritingActivity() {
        machine.writingActivity(at: Date())
        publish()
    }

    func noteInteraction() {
        machine.interaction(at: Date())
        publish()
    }

    private func publish() {
        let now = Date()
        let state = machine.state(at: now)
        if state != lastPublished {
            lastPublished = state
            onStateChange?(state)
        }
        scheduleDecay(after: now)
    }

    private func scheduleDecay(after now: Date) {
        decayTimer?.invalidate()
        decayTimer = nil
        guard let deadline = machine.nextDeadline(after: now) else { return }
        let interval = max(deadline.timeIntervalSince(now), 0.1)
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        decayTimer = timer
    }
}
