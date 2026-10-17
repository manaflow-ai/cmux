import CmuxFoundation
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The sheet validates with ``CloudOpenRepositoryReference`` and then runs the bundled
/// CLI's `vm clone`, which still has its own parser. These run the real CLI's
/// `--dry-run --json` (no socket) over one corpus and fail when the two disagree, and
/// check that the exact argv the sheet types plans the same repository.
extension CLINotifyProcessIntegrationRegressionTests {
    private func openRepositoryDryRun(_ arguments: [String], home: URL) throws -> (status: Int32, plan: [String: Any]?, stderr: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("orp")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment.removeValue(forKey: "CMUX_DEBUG")
        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: arguments + ["--dry-run", "--json"],
            environment: environment,
            timeout: 60
        )
        XCTAssertFalse(result.timedOut, "\(arguments) timed out")
        let plan = result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return (result.status, plan, result.stderr)
    }

    func testOpenRepositoryFieldRulesMatchVMClone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-open-repo-parity-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cmuxterm"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let corpus = [
            "manaflow-ai/cmux", "Acme/Api.git", "https://github.com/vercel/next.js/",
            "https://github.com/vercel/next.js/tree/canary", "https://www.github.com/o/r/tree/feat/deep-branch",
            "git@github.com:acme/api.git", "ssh://git@github.com/acme/api.git",
            "https://gitlab.com/group/sub/proj.git", "git@git.example.com:team/svc.git", "http://example.org/r.git",
            // Refused by both.
            "not a repo", "ftp://example.com/r.git", "https://github.com/onlyowner", "https://github.com/o/r?tab=x",
            "https://ghp_secret@github.com/o/r", "https://user:pass@gitlab.com/o/r.git",
            "https://github.com/o/r/tree/bad..branch", "-o/r", "o/.r",
        ]
        for input in corpus {
            let cli = try openRepositoryDryRun(["vm", "clone", input], home: home)
            switch CloudOpenRepositoryReference.parse(input) {
            case .success(let reference):
                XCTAssertEqual(cli.status, 0, "\(input): the app accepts it, the CLI refused: \(cli.stderr)")
                let repo = try XCTUnwrap(cli.plan?["repo"] as? [String: Any], input)
                XCTAssertEqual(repo["url"] as? String, reference.cloneURL, input)
                XCTAssertEqual(repo["name"] as? String, reference.name, input)
                XCTAssertEqual(repo["owner"] as? String, reference.owner, input)
                XCTAssertEqual(repo["project"] as? String, reference.projectKey, input)
                XCTAssertEqual(repo["branch"] as? String, reference.branch, input)

                // The argv the sheet types plans the same repository and branch.
                let command = CloudOpenRepositoryCommand(reference: reference, agent: .claude, prompt: nil)
                let typed = try openRepositoryDryRun(command.cliArguments, home: home)
                XCTAssertEqual(typed.status, 0, "\(command.cliArguments): \(typed.stderr)")
                let typedRepo = try XCTUnwrap(typed.plan?["repo"] as? [String: Any], input)
                XCTAssertEqual(typedRepo["project"] as? String, reference.projectKey, input)
                XCTAssertEqual(typedRepo["branch"] as? String, reference.branch, input)
                XCTAssertEqual(typed.plan?["agent"] as? String, "claude", input)
            case .failure:
                XCTAssertNotEqual(cli.status, 0, "\(input): the app refuses it, the CLI accepted it")
            }
        }
    }
}
