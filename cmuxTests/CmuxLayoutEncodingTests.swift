import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


final class CmuxLayoutEncodingTests: XCTestCase {

    func testPaneNodeRoundTrips() throws {
        let original = CmuxLayoutNode.pane(CmuxPaneDefinition(surfaces: [
            CmuxSurfaceDefinition(type: .terminal, name: "shell")
        ]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxLayoutNode.self, from: data)

        if case .pane(let pane) = decoded {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node after round-trip")
        }
    }

    func testSplitNodeRoundTrips() throws {
        let original = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .vertical,
            split: 0.7,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal)])),
                .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .browser, url: "http://localhost")]))
            ]
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxLayoutNode.self, from: data)

        if case .split(let split) = decoded {
            XCTAssertEqual(split.direction, .vertical)
            XCTAssertEqual(split.split, 0.7)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node after round-trip")
        }
    }
}
