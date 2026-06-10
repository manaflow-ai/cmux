import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


final class CmuxCommandIdentityTests: XCTestCase {

    func testCommandIdIsDeterministic() {
        let cmd = CmuxCommandDefinition(name: "Run tests", command: "test")
        XCTAssertEqual(cmd.id, "cmux.config.command.Run%20tests")
    }

    func testCommandIdEncodesSpecialCharacters() {
        let cmd = CmuxCommandDefinition(name: "build & deploy", command: "make")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertFalse(cmd.id.contains("&"))
        XCTAssertFalse(cmd.id.contains(" "))
    }

    func testCommandIdIsUniqueForDifferentNames() {
        let cmd1 = CmuxCommandDefinition(name: "build", command: "make build")
        let cmd2 = CmuxCommandDefinition(name: "test", command: "make test")
        XCTAssertNotEqual(cmd1.id, cmd2.id)
    }

    func testCommandIdDoesNotCollideWithBuiltinPrefix() {
        let cmd = CmuxCommandDefinition(name: "palette.newWorkspace", command: "echo")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertNotEqual(cmd.id, "palette.newWorkspace")
    }
}

// MARK: - Workspace command execution

