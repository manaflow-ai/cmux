import CmuxCloud
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// "Open Repository in Cloud…": the repository field's rules (the ones `cmux vm clone`
/// applies), the command typed into the terminal, the `cmux://cloud/clone` link, and
/// the sheet model's validation, git-auth offer and Run.
@Suite("Open Repository in Cloud")
struct CloudOpenRepositoryTests {
    // MARK: Repository field

    struct FormCase: CustomTestStringConvertible, Sendable {
        let input: String
        let url: String
        let name: String
        let owner: String?
        let branch: String?
        let project: String
        let argument: String
        var testDescription: String { input }
    }

    @Test(arguments: [
        FormCase(input: "manaflow-ai/cmux", url: "https://github.com/manaflow-ai/cmux.git", name: "cmux", owner: "manaflow-ai", branch: nil, project: "github.com/manaflow-ai/cmux", argument: "manaflow-ai/cmux"),
        FormCase(input: "Acme/Api.git", url: "https://github.com/Acme/Api.git", name: "Api", owner: "Acme", branch: nil, project: "github.com/acme/api", argument: "Acme/Api"),
        FormCase(input: "  https://github.com/vercel/next.js/  ", url: "https://github.com/vercel/next.js.git", name: "next.js", owner: "vercel", branch: nil, project: "github.com/vercel/next.js", argument: "vercel/next.js"),
        FormCase(input: "https://github.com/vercel/next.js/tree/canary", url: "https://github.com/vercel/next.js.git", name: "next.js", owner: "vercel", branch: "canary", project: "github.com/vercel/next.js", argument: "vercel/next.js"),
        FormCase(input: "https://www.github.com/o/r/tree/feat/deep-branch", url: "https://github.com/o/r.git", name: "r", owner: "o", branch: "feat/deep-branch", project: "github.com/o/r", argument: "o/r"),
        FormCase(input: "git@github.com:acme/api.git", url: "https://github.com/acme/api.git", name: "api", owner: "acme", branch: nil, project: "github.com/acme/api", argument: "acme/api"),
        FormCase(input: "ssh://git@github.com/acme/api.git", url: "https://github.com/acme/api.git", name: "api", owner: "acme", branch: nil, project: "github.com/acme/api", argument: "acme/api"),
        FormCase(input: "https://gitlab.com/group/sub/proj.git", url: "https://gitlab.com/group/sub/proj.git", name: "proj", owner: "group/sub", branch: nil, project: "gitlab.com/group/sub/proj", argument: "https://gitlab.com/group/sub/proj.git"),
        FormCase(input: "git@git.example.com:team/svc.git", url: "git@git.example.com:team/svc.git", name: "svc", owner: "team", branch: nil, project: "git.example.com/team/svc", argument: "git@git.example.com:team/svc.git"),
    ])
    func parsesEveryFormTheCLIAccepts(_ form: FormCase) throws {
        let reference = try CloudOpenRepositoryReference.parse(form.input).get()
        #expect(reference.cloneURL == form.url)
        #expect(reference.name == form.name)
        #expect(reference.owner == form.owner)
        #expect(reference.branch == form.branch)
        #expect(reference.projectKey == form.project)
        #expect(reference.cloneArgument == form.argument)
        #expect(reference.isGitHub == form.project.hasPrefix("github.com/"))
    }

    @Test("Refusals name the reason and never carry the text")
    func refusals() {
        let cases: [(String, CloudOpenRepositoryReferenceError)] = [
            ("", .empty),
            ("   ", .empty),
            ("not a repo", .unrecognized),
            (".", .unrecognized),
            ("ftp://example.com/r.git", .unrecognized),
            ("https://github.com/onlyowner", .unrecognized),
            ("https://github.com/o/r?tab=readme", .unrecognized),
            ("https://ghp_secret@github.com/o/r", .credentialsInURL),
            ("https://user:pass@gitlab.com/o/r.git", .credentialsInURL),
            ("https://github.com/o/r/tree/bad..branch", .invalidBranch),
        ]
        for (input, expected) in cases {
            #expect(CloudOpenRepositoryReference.parse(input) == .failure(expected), "\(input)")
        }
        #expect(CloudOpenRepositoryReference.parse("o/r", branchOverride: "a b") == .failure(.invalidBranch))
    }

    @Test("Only a GitHub link on the clipboard prefills the field, trimmed to the repository")
    func clipboardPrefill() {
        let field = CloudOpenRepositoryReference.gitHubFieldText(fromPasteboardText:)
        #expect(field("https://github.com/manaflow-ai/cmux") == "https://github.com/manaflow-ai/cmux")
        #expect(field("  https://github.com/o/r/pull/12#discussion  \n") == "https://github.com/o/r")
        #expect(field("https://github.com/o/r/blob/main/README.md?plain=1") == "https://github.com/o/r")
        #expect(field("https://github.com/o/r/tree/feat/x") == "https://github.com/o/r/tree/feat/x")
        #expect(field("http://github.com/o/r") == "https://github.com/o/r")
        #expect(field("github.com/o/r") == "https://github.com/o/r")
        #expect(field("git@github.com:o/r.git") == "git@github.com:o/r.git")
        #expect(field("o/r") == nil)
        #expect(field("https://github.com/settings/tokens") == nil)
        #expect(field("https://github.com/o") == nil)
        #expect(field("https://gitlab.com/o/r") == nil)
        #expect(field("see https://github.com/o/r") == nil)
        #expect(field("https://ghp_x@github.com/o/r") == nil)
    }

    // MARK: Command

    @Test("The command is vm clone with options before the prompt")
    func commandArguments() throws {
        let reference = try CloudOpenRepositoryReference.parse("https://github.com/o/r/tree/canary").get()
        let plain = CloudOpenRepositoryCommand(reference: reference, agent: nil, prompt: "ignored without an agent")
        #expect(plain.cliArguments == ["vm", "clone", "o/r", "--branch", "canary"])
        #expect(plain.prompt == nil)
        let agent = CloudOpenRepositoryCommand(reference: reference, agent: .claude, prompt: "  fix\nthe\ttests  ")
        #expect(agent.cliArguments == ["vm", "clone", "o/r", "--branch", "canary", "--agent", "claude", "--", "fix the tests"])
        #expect(agent.displayLine == "cmux vm clone o/r --branch canary --agent claude -- 'fix the tests'")
        let empty = CloudOpenRepositoryCommand(reference: reference, agent: .codex, prompt: " \n ")
        #expect(empty.cliArguments.last == "codex")
    }

    @Test("Control characters never reach the terminal's line editor")
    func promptSanitizing() {
        #expect(CloudOpenRepositoryCommand.sanitizedPrompt("a\u{1B}[31mb\u{03}c\u{7F}") == "a[31mbc")
        #expect(CloudOpenRepositoryCommand.sanitizedPrompt("\u{1B}\u{07}") == nil)
        #expect(CloudOpenRepositoryCommand.sanitizedPrompt(String(repeating: "x", count: 5_000))?.count == CloudOpenRepositoryCommand.maxPromptLength)
        #expect(CloudOpenRepositoryCommand.containsControlCharacters("o/r\u{1B}"))
        #expect(!CloudOpenRepositoryCommand.containsControlCharacters("o/r"))
    }

    @Test("Shell words read back unchanged in sh, including quotes and backslashes")
    func shellWordsRoundTrip() throws {
        let values = ["plain", "two words", "it's", "back\\slash \\\\ and \\'", "$HOME `x` \"q\" !", "", "-- --agent"]
        for value in values {
            let word = CloudOpenRepositoryCommand.shellWord(value)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(word)"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let echoed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(echoed == value, "\(value) -> \(word)")
        }
        #expect(CloudOpenRepositoryCommand.shellWord("o/r") == "o/r")
        #expect(!CloudOpenRepositoryCommand.shellWord("a\\b").contains("'a\\b'"), "a backslash never sits inside single quotes")
    }

    // MARK: cmux://cloud/clone

    @Test("The link opens the sheet prefilled and never carries control characters")
    func urlRequest() throws {
        let schemes: Set<String> = ["cmux"]
        let full = try #require(URL(string: "cmux://cloud/clone?repo=owner/repo&agent=Claude&prompt=run%20tests%0Anow"))
        #expect(CloudOpenRepositoryURLRequest.parse(full, supportedSchemes: schemes)
            == CloudOpenRepositoryURLRequest(repository: "owner/repo", agent: .claude, prompt: "run tests now"))
        let noAgent = try #require(URL(string: "cmux://cloud/clone?repo=https://github.com/o/r&prompt=dropped"))
        #expect(CloudOpenRepositoryURLRequest.parse(noAgent, supportedSchemes: schemes)
            == CloudOpenRepositoryURLRequest(repository: "https://github.com/o/r", agent: nil, prompt: nil))
        let escape = try #require(URL(string: "cmux://cloud/clone?repo=o/r%1B&agent=vim"))
        #expect(CloudOpenRepositoryURLRequest.parse(escape, supportedSchemes: schemes)
            == CloudOpenRepositoryURLRequest(repository: "", agent: nil, prompt: nil))
        for other in ["cmux://workspace/123", "cmux://cloud/other?repo=o/r", "https://cloud/clone?repo=o/r", "cmux://cloud/clone/extra"] {
            #expect(CloudOpenRepositoryURLRequest.parse(try #require(URL(string: other)), supportedSchemes: schemes) == nil, "\(other)")
        }
        let link = try #require(CloudOpenRepositoryURLRequest.link(repository: "o/r", agent: .pi, scheme: "cmux"))
        #expect(CloudOpenRepositoryURLRequest.parse(link, supportedSchemes: schemes)
            == CloudOpenRepositoryURLRequest(repository: "o/r", agent: .pi, prompt: nil))
    }

    // MARK: Sheet model

    @MainActor
    final class BackendLog {
        var coverage = CloudOpenRepositorySheetModel.GitTokenCoverage()
        var ghToken: String? = "gho_abc123"
        var stored: [String] = []
        var storeError: (any Error)?
        var openedSecrets = 0

        var backend: CloudOpenRepositorySheetModel.Backend {
            let token = ghToken
            return CloudOpenRepositorySheetModel.Backend(
                loadGitTokenCoverage: { self.coverage },
                readGitHubCLIToken: { token },
                storeGitHubToken: { value in
                    if let error = self.storeError { throw error }
                    self.stored.append(value)
                },
                openSecrets: { self.openedSecrets += 1 }
            )
        }
    }

    @MainActor
    @Test("Validation follows the field; Run needs a valid repository")
    func modelValidation() {
        let log = BackendLog()
        let model = CloudOpenRepositorySheetModel(backend: log.backend)
        #expect(model.validationMessage == nil)
        #expect(!model.canRun)
        model.repositoryText = "not a repo"
        #expect(model.validationMessage != nil)
        #expect(!model.canRun)
        model.repositoryText = "https://ghp_secret@github.com/o/r"
        #expect(model.validation == .failure(.credentialsInURL))
        #expect(model.validationMessage?.contains("ghp_secret") == false)
        model.repositoryText = "o/r\u{1B}"
        #expect(model.validation == .failure(.unrecognized))
        model.repositoryText = "o/r"
        #expect(model.validationMessage == nil)
        #expect(model.canRun)
        #expect(model.command?.cliArguments == ["vm", "clone", "o/r"])
    }

    @MainActor
    @Test("The GitHub token offer shows only for GitHub repositories no token covers")
    func tokenOffer() async {
        let log = BackendLog()
        let model = CloudOpenRepositorySheetModel(repository: "o/r", backend: log.backend)
        #expect(!model.showsGitHubTokenOffer, "no offer before the vault is read")
        await model.load()
        #expect(model.showsGitHubTokenOffer)
        model.repositoryText = "https://gitlab.com/o/r.git"
        #expect(!model.showsGitHubTokenOffer, "GH_TOKEN only answers for github.com")

        log.coverage = .init(projectKeys: ["github.com/o/r"])
        let scoped = CloudOpenRepositorySheetModel(repository: "O/R", backend: log.backend)
        await scoped.load()
        #expect(!scoped.showsGitHubTokenOffer, "a project token covers its own repository")
        scoped.repositoryText = "o/other"
        #expect(scoped.showsGitHubTokenOffer)

        log.coverage = .init(everyMachine: true)
        let covered = CloudOpenRepositorySheetModel(repository: "o/r", backend: log.backend)
        await covered.load()
        #expect(!covered.showsGitHubTokenOffer)
    }

    @MainActor
    @Test("Use my GitHub CLI login stores GH_TOKEN once and confirms it")
    func useGitHubCLILogin() async {
        let log = BackendLog()
        let model = CloudOpenRepositorySheetModel(repository: "o/r", backend: log.backend)
        await model.load()
        await model.useGitHubCLILogin()
        #expect(log.stored == ["gho_abc123"])
        #expect(model.tokenState == .stored)
        #expect(model.showsGitHubTokenOffer, "the confirmation stays visible")
        model.openSecrets()
        #expect(log.openedSecrets == 1)
    }

    @MainActor
    @Test("A missing gh login or a failed save says what to do and stores nothing")
    func gitHubCLIFailures() async {
        let missing = BackendLog()
        missing.ghToken = nil
        let model = CloudOpenRepositorySheetModel(repository: "o/r", backend: missing.backend)
        await model.load()
        await model.useGitHubCLILogin()
        #expect(missing.stored.isEmpty)
        guard case .failed(let message) = model.tokenState else {
            Issue.record("expected a failure, got \(model.tokenState)")
            return
        }
        #expect(message.contains("gh auth login"))

        let garbage = BackendLog()
        garbage.ghToken = "line one\nline two"
        let garbled = CloudOpenRepositorySheetModel(repository: "o/r", backend: garbage.backend)
        await garbled.useGitHubCLILogin()
        #expect(garbage.stored.isEmpty)

        struct Refused: Error {}
        let refusing = BackendLog()
        refusing.storeError = Refused()
        let unsaved = CloudOpenRepositorySheetModel(repository: "o/r", backend: refusing.backend)
        await unsaved.useGitHubCLILogin()
        if case .failed = unsaved.tokenState {} else { Issue.record("expected a failure, got \(unsaved.tokenState)") }
    }

    @MainActor
    @Test("Run hands over the command and closes; a failed launch keeps the sheet open")
    func run() throws {
        let log = BackendLog()
        let model = CloudOpenRepositorySheetModel(repository: "o/r", agent: .codex, prompt: "add a test", backend: log.backend)
        var launched: [CloudOpenRepositoryCommand] = []
        var finished = 0
        model.onRun = { launched.append($0); return true }
        model.onFinished = { finished += 1 }
        model.run()
        #expect(launched.map(\.cliArguments) == [["vm", "clone", "o/r", "--agent", "codex", "--", "add a test"]])
        #expect(finished == 1)

        model.onRun = { _ in false }
        model.run()
        #expect(finished == 1)
        #expect(model.runError != nil)

        let invalid = CloudOpenRepositorySheetModel(repository: "nope nope", backend: log.backend)
        invalid.onRun = { _ in Issue.record("an invalid field must not run"); return true }
        invalid.run()
    }

    @Test("Coverage reads names and scopes only")
    func coverageFromRecords() {
        func record(_ name: String, _ scope: CloudSecretScope) -> CloudSecretRecord {
            CloudSecretRecord(name: name, scope: scope, fingerprint: "00000000", createdAt: .distantPast, updatedAt: .distantPast, source: .manual)
        }
        let coverage = CloudOpenRepositorySheetModel.GitTokenCoverage(records: [
            record("GITHUB_TOKEN", .project("github.com/o/r")),
            record("GH_TOKEN", .machine("vm-1")),
            record("OPENAI_API_KEY", .all),
        ])
        #expect(!coverage.everyMachine)
        #expect(coverage.covers(projectKey: "github.com/o/r"))
        #expect(!coverage.covers(projectKey: "github.com/o/x"))
        #expect(CloudOpenRepositorySheetModel.GitTokenCoverage(records: [record("GH_TOKEN", .all)]).everyMachine)
    }
}
