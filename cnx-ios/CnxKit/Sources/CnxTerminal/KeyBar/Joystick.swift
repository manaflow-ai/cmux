#if os(iOS)
import Observation
import SwiftUI
import UIKit

enum JoystickDirection: Sendable, Equatable {
    case up, down, left, right

    var key: KeyBarKey {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

/// The joystick's state machine (SPEC 10.3): the thumb follows the finger within
/// 28 pt; direction is quantized to 4 ways; distance picks the gear:
/// 8-16 pt repeats every 160 ms, 16-24 pt every 80 ms, beyond 24 pt every 30 ms.
/// The first key fires on crossing 8 pt. Haptics per key in gears 1-2 and every
/// 4th key in gear 3.
@MainActor
@Observable
final class JoystickEngine {
    static let radius: CGFloat = 28
    static let deadZone: CGFloat = 8

    private(set) var thumb: CGSize = .zero
    private(set) var gear = 0
    private(set) var direction: JoystickDirection?
    private(set) var keysSent = 0
    var send: (JoystickDirection) -> Void = { _ in }

    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let selection = UISelectionFeedbackGenerator()

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    static func gear(for distance: CGFloat) -> Int {
        switch distance {
        case ..<deadZone: 0
        case ..<16: 1
        case ..<24: 2
        default: 3
        }
    }

    static func interval(gear: Int) -> Duration {
        switch gear {
        case 1: .milliseconds(160)
        case 2: .milliseconds(80)
        default: .milliseconds(30)
        }
    }

    static func direction(for offset: CGSize) -> JoystickDirection {
        abs(offset.width) >= abs(offset.height)
            ? (offset.width >= 0 ? .right : .left)
            : (offset.height >= 0 ? .down : .up)
    }

    /// The finger moved to `translation` from the center.
    func update(_ translation: CGSize) {
        let distance = hypot(translation.width, translation.height)
        let scale = distance > Self.radius ? Self.radius / distance : 1
        thumb = CGSize(width: translation.width * scale, height: translation.height * scale)
        let newGear = Self.gear(for: distance)
        let newDirection = newGear == 0 ? nil : Self.direction(for: translation)
        let crossed = gear == 0 && newGear > 0
        let changedDirection = newDirection != direction
        gear = newGear
        direction = newDirection
        guard let newDirection else {
            repeatTask?.cancel()
            repeatTask = nil
            return
        }
        if crossed || changedDirection {
            fire(newDirection)
            restartRepeat()
        }
    }

    func release() {
        repeatTask?.cancel()
        repeatTask = nil
        gear = 0
        direction = nil
        thumb = .zero
    }

    private func fire(_ direction: JoystickDirection) {
        keysSent += 1
        send(direction)
        if gear < 3 || keysSent % 4 == 0 { selection.selectionChanged() }
    }

    private func restartRepeat() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, let direction = self.direction {
                do { try await self.clock.sleep(for: Self.interval(gear: self.gear)) } catch { return }
                guard !Task.isCancelled, self.direction == direction else { continue }
                self.fire(direction)
            }
        }
    }
}

/// 36 pt glass circle with a 14 pt thumb.
struct Joystick: View {
    let engine: JoystickEngine

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(engine.gear > 0 ? 0.16 : 0.08))
                .frame(width: 36, height: 36)
            Circle()
                .fill(Color.secondary)
                .frame(width: 14, height: 14)
                .offset(engine.thumb)
                .animation(engine.gear == 0 ? .spring(response: 0.3, dampingFraction: 0.6) : nil, value: engine.thumb)
        }
        .frame(width: 40, height: 40)
        .contentShape(.circle)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { engine.update($0.translation) }
                .onEnded { _ in engine.release() }
        )
        .accessibilityElement()
        .accessibilityLabel("Cursor joystick")
        .accessibilityHint("Drag to move the cursor; farther moves faster.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: engine.send(.right)
            case .decrement: engine.send(.left)
            @unknown default: break
            }
        }
    }
}
#endif
