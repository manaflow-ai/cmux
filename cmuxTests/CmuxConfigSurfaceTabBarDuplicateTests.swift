import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CmuxConfigSurfaceTabBarDuplicateTests {
    @Test func testDecodeDuplicateSurfaceTabBarButtonsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": ["newTerminal", "newTerminal"],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeDuplicateSurfaceTabBarButtonIdsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "run",
              "icon": { "type": "symbol", "name": "play" },
              "command": "npm run dev"
            },
            {
              "id": "run",
              "icon": { "type": "symbol", "name": "checkmark" },
              "command": "npm test"
            }
          ],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeDuplicateSurfaceTabBarMenuItemIdsThrows() {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "tools",
              "type": "menu",
              "menu": [
                {
                  "id": "run",
                  "icon": { "type": "symbol", "name": "play" },
                  "command": "npm run dev"
                },
                {
                  "id": "run",
                  "icon": { "type": "symbol", "name": "checkmark" },
                  "command": "npm test"
                }
              ]
            }
          ],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @Test func testDecodeSurfaceTabBarMenuItemCannotReuseTopLevelId() {
        let json = """
        {
          "surfaceTabBarButtons": [
            {
              "id": "run",
              "icon": { "type": "symbol", "name": "play" },
              "command": "npm run dev"
            },
            {
              "id": "tools",
              "type": "menu",
              "menu": [
                {
                  "id": "run",
                  "icon": { "type": "symbol", "name": "checkmark" },
                  "command": "npm test"
                }
              ]
            }
          ],
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }
}
