import CmuxControlSocket
import CmuxSimulator
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Simulator control gestures")
struct SimulatorControlGestureTests {
    @Test("Control gestures map logical touches and edges through every orientation")
    func controlGestureOrientationMapping() throws {
        let touch = ControlSimulatorTouch(
            phase: "moved", x: 0.2, y: 0.3,
            secondX: 0.7, secondY: 0.8, edge: "left"
        )
        let cases: [(SimulatorOrientation, SimulatorPoint, SimulatorPoint, SimulatorEdge)] = [
            (.portrait, SimulatorPoint(x: 0.2, y: 0.3), SimulatorPoint(x: 0.7, y: 0.8), .left),
            (.portraitUpsideDown, SimulatorPoint(x: 0.8, y: 0.7),
             SimulatorPoint(x: 0.3, y: 0.2), .right),
            (.landscapeLeft, SimulatorPoint(x: 0.3, y: 0.8),
             SimulatorPoint(x: 0.8, y: 0.3), .bottom),
            (.landscapeRight, SimulatorPoint(x: 0.7, y: 0.2),
             SimulatorPoint(x: 0.2, y: 0.7), .top)
        ]

        for (orientation, primary, secondary, edge) in cases {
            let geometry = SimulatorOrientationGeometry(
                rawWidth: 100, rawHeight: 200, requestedOrientation: orientation
            )
            let event = try controlSimulatorPointerEvent(touch, geometry: geometry)
            #expect(event.phase == .moved)
            expectEqual(event.primary, primary)
            expectEqual(try #require(event.secondary), secondary)
            #expect(event.edge == edge)
        }
    }

    private func expectEqual(_ actual: SimulatorPoint, _ expected: SimulatorPoint) {
        // Unit coordinates can differ by one rounding step after a 1 - value transform.
        #expect(abs(actual.x - expected.x) <= Double.ulpOfOne)
        #expect(abs(actual.y - expected.y) <= Double.ulpOfOne)
    }
}
