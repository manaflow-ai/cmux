import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the SIGBUS / stack-overflow on the
/// `com.cmuxterm.app.sessionPersistence` queue when a workspace's split tree is
/// deeply nested. See https://github.com/manaflow-ai/cmux/issues/4656.
///
/// The original recursive `Codable` conformance on
/// `SessionSplitLayoutSnapshot` consumed ~7-8 Swift stack frames per nested
/// split. A workspace ~70 levels deep blew the 512 KB stack that production
/// `DispatchQueue` worker threads get on macOS and SIGBUS-killed cmux. The
/// regression depth is set high enough that the recursive chain (~2 KB per
/// level) overflows even the more generous XCTest main-thread stack (~8 MB),
/// so the regression manifests as a process crash if the iterative-Codable
/// fix is missing.
final class SessionLayoutSnapshotDeepNestingTests: XCTestCase {
    /// Deep enough that the recursive Codable chain is well over the
    /// XCTest main-thread stack budget but iterative encode/decode is still
    /// O(1) in tree depth.
    fileprivate static let regressionDepth: Int = 6000
}

// Test methods are placed in an extension so the Swift compiler emits them
// as an Obj-C category, matching the discovery shape XCTest uses to find
// other Codable round-trip tests in this target (e.g. SessionPersistenceTests).
extension SessionLayoutSnapshotDeepNestingTests {

    func testEncodeDeepLinearSplitTreeDoesNotOverflowStack() throws {
        let layout = SessionLayoutSnapshotDeepNestingTests.makeLinearLayout(
            depth: SessionLayoutSnapshotDeepNestingTests.regressionDepth
        )
        let encoded = try JSONEncoder().encode(layout)
        XCTAssertGreaterThan(encoded.count, 0, "encoded payload should be non-empty")
    }

    func testRoundTripDeepLinearSplitTree() throws {
        let layout = SessionLayoutSnapshotDeepNestingTests.makeLinearLayout(
            depth: SessionLayoutSnapshotDeepNestingTests.regressionDepth
        )
        // .sortedKeys so the byte comparison is deterministic; JSONEncoder
        // does not guarantee object key ordering by default.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(layout)
        let restored = try JSONDecoder().decode(SessionWorkspaceLayoutSnapshot.self, from: encoded)
        let reEncoded = try encoder.encode(restored)
        XCTAssertEqual(
            encoded,
            reEncoded,
            "round-tripped layout must produce byte-identical JSON"
        )
    }

    func testDecodeLegacyRecursiveLayoutJSON() throws {
        // Shallow legacy payload to verify the decoder still accepts the
        // original recursive nested shape. Backwards-compat for sessions saved
        // before the iterative wire format landed.
        let legacy = """
        {
          "type": "split",
          "split": {
            "orientation": "horizontal",
            "dividerPosition": 0.5,
            "first": {
              "type": "pane",
              "pane": { "panelIds": [], "selectedPanelId": null }
            },
            "second": {
              "type": "split",
              "split": {
                "orientation": "vertical",
                "dividerPosition": 0.25,
                "first": {
                  "type": "pane",
                  "pane": { "panelIds": [], "selectedPanelId": null }
                },
                "second": {
                  "type": "pane",
                  "pane": { "panelIds": [], "selectedPanelId": null }
                }
              }
            }
          }
        }
        """
        let data = try XCTUnwrap(legacy.data(using: .utf8))
        let restored = try JSONDecoder().decode(SessionWorkspaceLayoutSnapshot.self, from: data)

        guard case .split(let topSplit) = restored else {
            XCTFail("expected top-level split, got \(restored)"); return
        }
        XCTAssertEqual(topSplit.orientation, .horizontal)
        guard case .pane = topSplit.first else {
            XCTFail("expected first child to be pane"); return
        }
        guard case .split(let nested) = topSplit.second else {
            XCTFail("expected second child to be split"); return
        }
        XCTAssertEqual(nested.orientation, .vertical)
        XCTAssertEqual(nested.dividerPosition, 0.25, accuracy: 1e-9)
    }

    // MARK: - Helpers

    /// Build a worst-case linear chain: `depth` left-nested splits ending in a
    /// pane. Mirrors the shape produced by repeatedly running
    /// `cmux new-split <dir>` into the same focused pane, which is the
    /// real-world reproducer.
    fileprivate static func makeLinearLayout(depth: Int) -> SessionWorkspaceLayoutSnapshot {
        let leafPane = SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
        var layout: SessionWorkspaceLayoutSnapshot = .pane(leafPane)
        for index in 0..<depth {
            let orientation: SessionSplitOrientation = index.isMultiple(of: 2)
                ? .horizontal
                : .vertical
            let other = SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
            layout = .split(
                SessionSplitLayoutSnapshot(
                    orientation: orientation,
                    dividerPosition: 0.5,
                    first: layout,
                    second: .pane(other)
                )
            )
        }
        return layout
    }
}
