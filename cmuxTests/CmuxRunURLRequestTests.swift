import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Secure command deep links")
struct CmuxRunURLRequestTests {
    private let scheme = "cmux-test"

    @Test func parsesMinimalWorkspaceRequest() throws {
        let request = try parsed([
            .init(name: "command", value: "  claude --resume  "),
            .init(name: "cwd", value: "/tmp/project")
        ])

        #expect(request.command == "claude --resume")
        #expect(request.workingDirectory == "/tmp/project")
        #expect(request.placement == .workspace)
        #expect(request.workspaceId == nil)
        #expect(request.anchor == nil)
    }

    @Test func parsesSurfacePlacementWithPaneAnchor() throws {
        let workspaceId = UUID()
        let paneId = UUID()
        let request = try parsed([
            .init(name: "command", value: "codex"),
            .init(name: "cwd", value: "/tmp/project"),
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: workspaceId.uuidString),
            .init(name: "pane", value: paneId.uuidString)
        ])

        #expect(request.workspaceId == workspaceId)
        #expect(request.anchor == .pane(paneId))
        #expect(request.direction == nil)
    }

    @Test func parsesPanePlacementWithStableSurfaceAnchor() throws {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let request = try parsed([
            .init(name: "command", value: "npm test"),
            .init(name: "cwd", value: "/tmp/project"),
            .init(name: "placement", value: "pane"),
            .init(name: "workspace", value: workspaceId.uuidString),
            .init(name: "surface", value: surfaceId.uuidString),
            .init(name: "direction", value: "left")
        ])

        #expect(request.workspaceId == workspaceId)
        #expect(request.anchor == .surface(surfaceId))
        #expect(request.direction == .left)
    }

    @Test func allowsVisibleMultilineShellCommands() throws {
        let request = try parsed([
            .init(name: "command", value: "printf 'one\\n'\nprintf '\ttwo\\n'"),
            .init(name: "cwd", value: "/tmp")
        ])

        #expect(request.command.contains("\n"))
        #expect(request.command.contains("\t"))
    }

    @Test func shellWrapperPreservesQuotesAndExpansion() {
        let command = "printf '%s\\n' \"$HOME\""
        #expect(
            CmuxRunShellCommandBuilder.launchCommand(for: command)
                == "/bin/zsh -lc 'printf '\"'\"'%s\\n'\"'\"' \"$HOME\"'"
        )
    }

    @Test(arguments: ["\u{0000}", "\r", "\u{202E}", "\u{2066}", "\u{2028}"])
    func rejectsHiddenCommandCharacters(_ hidden: String) throws {
        let result = parse([
            .init(name: "command", value: "echo safe\(hidden)unsafe"),
            .init(name: "cwd", value: "/tmp")
        ])
        #expect(result == .failure(.unsafeCharacters("command")))
    }

    @Test func rejectsCaseInsensitiveDuplicateParameters() throws {
        let url = try #require(URL(string: "\(scheme)://run?command=true&Command=false&cwd=/tmp"))
        #expect(
            CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
                == .failure(.duplicateParameter("Command"))
        )
    }

    @Test func rejectsUnknownAuthorityExpandingParameters() throws {
        let result = parse([
            .init(name: "command", value: "true"),
            .init(name: "cwd", value: "/tmp"),
            .init(name: "env", value: "TOKEN=secret")
        ])
        #expect(result == .failure(.unsupportedParameter("env")))
    }

    @Test func byteLimitCannotBeBypassedWithCombiningScalars() {
        let oversized = "echo " + String(repeating: "\u{0301}", count: 4_000)
        #expect(oversized.count < CmuxRunURLRequest.maxCommandLength)
        #expect(oversized.utf8.count > CmuxRunURLRequest.maxCommandLength)

        #expect(parse([
            .init(name: "command", value: oversized),
            .init(name: "cwd", value: "/tmp")
        ]) == .failure(.valueTooLong(
            parameter: "command",
            maxLength: CmuxRunURLRequest.maxCommandLength
        )))
    }

    @Test func rejectsMissingCommandAndDirectory() {
        #expect(parse([.init(name: "cwd", value: "/tmp")]) == .failure(.missingParameter("command")))
        #expect(parse([.init(name: "command", value: "true")]) == .failure(.missingParameter("cwd")))
    }

    @Test func rejectsHiddenDirectoryCharacters() {
        #expect(parse([
            .init(name: "command", value: "true"),
            .init(name: "cwd", value: "/tmp/safe\u{202E}hidden")
        ]) == .failure(.unsafeCharacters("cwd")))
    }

    @Test func rejectsInvalidPlacementDirectionAndIdentifiers() {
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let base = [
            URLQueryItem(name: "command", value: "true"),
            URLQueryItem(name: "cwd", value: "/tmp")
        ]

        #expect(parse(base + [
            .init(name: "placement", value: "window")
        ]) == .failure(.invalidPlacement("placement")))
        #expect(parse(base + [
            .init(name: "placement", value: "pane"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId),
            .init(name: "direction", value: "diagonal")
        ]) == .failure(.invalidDirection("direction")))
        #expect(parse(base + [
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: "not-a-uuid"),
            .init(name: "pane", value: paneId)
        ]) == .failure(.invalidIdentifier("workspace")))
    }

    @Test func rejectsAmbiguousOrIncompletePlacementTargets() {
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let surfaceId = UUID().uuidString
        let base = [
            URLQueryItem(name: "command", value: "true"),
            URLQueryItem(name: "cwd", value: "/tmp")
        ]

        #expect(parse(base + [
            .init(name: "placement", value: "workspace"),
            .init(name: "workspace", value: workspaceId)
        ]) == .failure(.invalidTargetCombination))
        #expect(parse(base + [
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId),
            .init(name: "surface", value: surfaceId)
        ]) == .failure(.invalidTargetCombination))
        #expect(parse(base + [
            .init(name: "placement", value: "pane"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId)
        ]) == .failure(.missingParameter("direction")))
        #expect(parse(base + [
            .init(name: "placement", value: "surface"),
            .init(name: "workspace", value: workspaceId),
            .init(name: "pane", value: paneId),
            .init(name: "direction", value: "right")
        ]) == .failure(.invalidTargetCombination))
    }

    @Test func rejectsURLAuthorityAndPathAmbiguity() throws {
        for rawURL in [
            "\(scheme)://user@run?command=true&cwd=/tmp",
            "\(scheme)://run/extra?command=true&cwd=/tmp",
            "\(scheme)://run?command=true&cwd=/tmp#fragment"
        ] {
            let url = try #require(URL(string: rawURL))
            #expect(
                CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
                    == .failure(.unsupportedURLShape)
            )
        }
    }

    @Test func ignoresOtherSchemesAndRoutes() throws {
        let otherScheme = try #require(URL(string: "https://run?command=true&cwd=/tmp"))
        let otherRoute = try #require(URL(string: "\(scheme)://prompt?command=true&cwd=/tmp"))
        #expect(CmuxRunURLRequest.parse(otherScheme, supportedSchemes: [scheme]) == .success(nil))
        #expect(CmuxRunURLRequest.parse(otherRoute, supportedSchemes: [scheme]) == .success(nil))
    }

    @Test func resolvesAndCanonicalizesExistingDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CmuxRunWorkingDirectoryResolver().resolve(link.path) == .success(real.path))
    }

    @Test func rejectsRelativeMissingAndFileWorkingDirectories() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(
            CmuxRunWorkingDirectoryResolver().resolve("relative/path")
                == .failure(.workingDirectoryMustBeAbsolute)
        )
        #expect(
            CmuxRunWorkingDirectoryResolver().resolve("/tmp/cmux-missing-\(UUID().uuidString)")
                == .failure(.workingDirectoryNotFound)
        )
        #expect(
            CmuxRunWorkingDirectoryResolver().resolve(file.path)
                == .failure(.workingDirectoryNotFound)
        )
    }

    private func parsed(_ queryItems: [URLQueryItem]) throws -> CmuxRunURLRequest {
        switch parse(queryItems) {
        case .success(let request):
            return try #require(request)
        case .failure(let error):
            throw error
        }
    }

    private func parse(
        _ queryItems: [URLQueryItem]
    ) -> Result<CmuxRunURLRequest?, CmuxRunURLParseError> {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "run"
        components.queryItems = queryItems
        guard let url = components.url else {
            return .failure(.unsupportedURLShape)
        }
        return CmuxRunURLRequest.parse(url, supportedSchemes: [scheme])
    }
}
