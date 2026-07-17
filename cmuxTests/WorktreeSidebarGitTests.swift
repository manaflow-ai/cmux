import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct WorktreeSidebarGitTests {
    @Test("porcelain parser preserves lock and prune reasons")
    func parsesPorcelainAnnotations() throws {
        let output = [
            "worktree /repo", "HEAD 1111111111111111111111111111111111111111", "branch refs/heads/main", "",
            "worktree /repo worktree\nnewline", "HEAD 2222222222222222222222222222222222222222",
            "branch refs/heads/feature/manual", "locked editor is using it", "",
            "worktree /missing worktree", "HEAD 3333333333333333333333333333333333333333",
            "detached", "prunable gitdir file points to non-existent location", "",
        ].joined(separator: "\0")

        let parsed = WorktreeSidebarPorcelainParser().parse(output)
        #expect(parsed.count == 3)
        #expect(parsed[0].isMain)
        #expect(parsed[1].branchName == "feature/manual")
        #expect(parsed[1].path.hasSuffix("/repo worktree\nnewline"))
        #expect(parsed[1].isLocked)
        #expect(parsed[1].lockReason == "editor is using it")
        #expect(parsed[2].isPrunable)
        #expect(parsed[2].prunableReason == "gitdir file points to non-existent location")
    }

    @Test(arguments: [
        (" feature / 日本語  ", "feature-日本語"),
        ("foo..bar", "foo.bar"),
        ("foo._ / bar", "foo-bar"),
        ("re\u{301}sume\u{301}", "résumé"),
        ("---résumé___42---", "résumé-42"),
    ])
    func sanitizesBranchNames(input: String, expected: String) throws {
        #expect(try #require(WorktreeSidebarBranchName(userInput: input)).value == expected)
    }

    @Test("manual worktrees appear without import state")
    func listsShellCreatedWorktreesAndVisibleDirtyState() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let manual = fixture.container.appendingPathComponent("manual\n$(touch PWNED)", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "manual", manual.path, "HEAD"], in: fixture.repo)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let listed = try await service.listWorktrees(projectRootPath: fixture.repo.path)
        #expect(listed.map(\.path) == [canonical(fixture.repo), canonical(manual)])
        #expect(listed.first?.isMain == true)
        #expect(listed.last?.branchName == "manual")

        try Data("scratch\n".utf8).write(to: manual.appendingPathComponent("scratch.txt"))
        #expect(try await service.isDirty(
            projectRootPath: fixture.repo.path,
            worktreePath: manual.path
        ))
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: manual.path
        )
        #expect(inspection.hasUncommittedChanges)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.repo.appendingPathComponent("PWNED").path
        ))
    }

    @Test("create sanitizes the ref, ignores .cmux, and initializes the worktree")
    func createsNamedWorktree() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try Data().write(to: fixture.repo.appendingPathComponent(".gitmodules"))
        _ = try runGit(["add", ".gitmodules"], in: fixture.repo)
        _ = try runGit(["commit", "-m", "add empty gitmodules"], in: fixture.repo)
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".gitmodules"))

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let created = try await service.createWorktree(
            projectRootPath: fixture.repo.path,
            userInput: " Föö / bug..name "
        )

        #expect(created.branchName == "Föö-bug.name")
        #expect(created.worktreePath.hasSuffix("/.cmux/worktrees/Föö-bug.name"))
        #expect(FileManager.default.fileExists(atPath: created.worktreePath))
        #expect(FileManager.default.fileExists(atPath: created.worktreePath + "/.gitmodules"))
        try Data().write(to: fixture.repo.appendingPathComponent(".gitmodules"))
        #expect(try runGit(["status", "--porcelain", "--untracked-files=all"], in: fixture.repo).isEmpty)
    }

    @Test("create validates the sanitized name with Git")
    func rejectsGitInvalidSanitizedName() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = WorktreeSidebarGitService(commandTimeout: 10)

        var rejected = false
        do {
            _ = try await service.createWorktree(
                projectRootPath: fixture.repo.path,
                userInput: "reserved.lock"
            )
        } catch WorktreeSidebarGitError.invalidBranchName(let name) {
            rejected = name == "reserved.lock"
        }
        #expect(rejected)
        #expect(try await service.listWorktrees(projectRootPath: fixture.repo.path).count == 1)
    }

    @Test("clean removal safely deletes a merged branch")
    func removesCleanWorktreeAndMergedBranch() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("merged", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "merged", worktree.path, "HEAD"], in: fixture.repo)
        try Data(".ignored\n".utf8).write(
            to: fixture.repo.appendingPathComponent(".git/info/exclude")
        )
        try Data("at risk\n".utf8).write(to: worktree.appendingPathComponent(".ignored"))

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        #expect(!inspection.hasUncommittedChanges)
        #expect(inspection.hasIgnoredFiles)
        #expect(!inspection.requiresForceRemoval)
        #expect(inspection.unpushedCommitCount == 0)
        #expect(inspection.branchDisposition == .deleteMerged("merged"))

        let result = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: inspection,
            force: false
        )
        #expect(result == WorktreeSidebarDeletionResult(
            removal: .removed,
            branch: .deleted("merged")
        ))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try runGit(["branch", "--list", "merged"], in: fixture.repo).isEmpty)
    }

    @Test("unmerged branch is preserved when branch -d refuses")
    func preservesUnmergedBranch() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("unmerged", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "unmerged", worktree.path, "HEAD"], in: fixture.repo)
        try Data("commit\n".utf8).write(to: worktree.appendingPathComponent("commit.txt"))
        _ = try runGit(["add", "commit.txt"], in: worktree)
        _ = try runGit(["commit", "-m", "unmerged work"], in: worktree)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        #expect(inspection.unpushedCommitCount == 1)
        #expect(inspection.branchDisposition == .keepUnmerged("unmerged"))
        let result = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: inspection,
            force: false
        )
        guard case .preserved(let name, _) = result.branch else {
            Issue.record("Expected the unmerged branch to be preserved")
            return
        }
        #expect(name == "unmerged")
        #expect(try runGit(["branch", "--list", "unmerged"], in: fixture.repo)
            .contains("unmerged"))
    }

    @Test("detached worktree inspection reports commits that would lose reachability")
    func detachedWorktreeReportsUniqueCommits() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("detached", isDirectory: true)
        _ = try runGit(["worktree", "add", "--detach", worktree.path, "HEAD"], in: fixture.repo)
        try Data("detached\n".utf8).write(to: worktree.appendingPathComponent("detached.txt"))
        _ = try runGit(["add", "detached.txt"], in: worktree)
        _ = try runGit(["commit", "-m", "detached work"], in: worktree)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        #expect(inspection.unpushedCommitCount == 1)
        #expect(inspection.branchDisposition == .noLocalBranch)
        let result = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: inspection,
            force: false
        )
        #expect(result.branch == .notApplicable)
    }

    @Test("dirty removal refuses by default and requires the confirmed force path")
    func dirtyRemovalRequiresForce() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("dirty", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "dirty", worktree.path, "HEAD"], in: fixture.repo)
        try Data("*.ignored\n".utf8).write(to: fixture.repo.appendingPathComponent(".git/info/exclude"))
        try Data("uncommitted\n".utf8).write(to: worktree.appendingPathComponent("uncommitted.txt"))
        try Data("ignored\n".utf8).write(to: worktree.appendingPathComponent("first.ignored"))

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        #expect(inspection.hasUncommittedChanges)
        var rejected = false
        do {
            _ = try await service.removeWorktree(
                projectRootPath: fixture.repo.path,
                expected: inspection,
                force: false
            )
        } catch WorktreeSidebarGitError.forceRequired {
            rejected = true
        }
        #expect(rejected)
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try Data("new\n".utf8).write(to: worktree.appendingPathComponent("second.txt"))
        try Data("ignored\n".utf8).write(to: worktree.appendingPathComponent("second.ignored"))
        rejected = false
        do {
            _ = try await service.removeWorktree(
                projectRootPath: fixture.repo.path,
                expected: inspection,
                force: true
            )
        } catch WorktreeSidebarGitError.worktreeChanged {
            rejected = true
        }
        #expect(rejected)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        let refreshed = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        _ = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: refreshed,
            force: true
        )
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test("clean initialized submodules require an explicit force removal")
    func initializedSubmodulesRequireForce() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let submodule = fixture.container.appendingPathComponent("Submodule", isDirectory: true)
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        _ = try runGit(["init", "-b", "main"], in: submodule)
        _ = try runGit(["config", "user.name", "cmux Test"], in: submodule)
        _ = try runGit(["config", "user.email", "cmux@example.invalid"], in: submodule)
        try Data("submodule\n".utf8).write(to: submodule.appendingPathComponent("README.md"))
        _ = try runGit(["add", "README.md"], in: submodule)
        _ = try runGit(["commit", "-m", "initial"], in: submodule)
        _ = try runGit([
            "-c", "protocol.file.allow=always", "submodule", "add",
            submodule.path, "Dependencies/Submodule",
        ], in: fixture.repo)
        _ = try runGit(["commit", "-m", "add submodule"], in: fixture.repo)

        let worktree = fixture.container.appendingPathComponent("with-submodule", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "with-submodule", worktree.path, "HEAD"], in: fixture.repo)
        _ = try runGit([
            "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive",
        ], in: worktree)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        #expect(!inspection.hasUncommittedChanges)
        #expect(inspection.hasInitializedSubmodules)
        #expect(inspection.requiresForceRemoval)
        var refused = false
        do {
            _ = try await service.removeWorktree(
                projectRootPath: fixture.repo.path,
                expected: inspection,
                force: false
            )
        } catch WorktreeSidebarGitError.forceRequired {
            refused = true
        }
        #expect(refused)

        _ = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: inspection,
            force: true
        )
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test("safe branch deletion follows its configured upstream")
    func safeDeletionUsesBranchUpstream() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let remote = fixture.container.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGit(["init", "--bare"], in: remote)
        _ = try runGit(["remote", "add", "origin", remote.path], in: fixture.repo)
        _ = try runGit(["push", "-u", "origin", "main"], in: fixture.repo)

        let worktree = fixture.container.appendingPathComponent("published", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "published", worktree.path, "HEAD"], in: fixture.repo)
        try Data("published\n".utf8).write(to: worktree.appendingPathComponent("published.txt"))
        _ = try runGit(["add", "published.txt"], in: worktree)
        _ = try runGit(["commit", "-m", "published work"], in: worktree)
        _ = try runGit(["push", "-u", "origin", "published"], in: worktree)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        #expect(inspection.unpushedCommitCount == 0)
        #expect(inspection.branchDisposition == .deleteMerged("published"))
        let result = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: inspection,
            force: false
        )
        #expect(result.branch == .deleted("published"))
    }

    @Test("locked state is refreshed and blocks deletion")
    func lockedWorktreeIsRefused() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("locked", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "locked", worktree.path, "HEAD"], in: fixture.repo)
        _ = try runGit(["worktree", "lock", "--reason", "editor", worktree.path], in: fixture.repo)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let listed = try await service.listWorktrees(projectRootPath: fixture.repo.path)
        #expect(listed.last?.isLocked == true)
        #expect(listed.last?.lockReason == "editor")
        var refused = false
        do {
            _ = try await service.inspectDeletion(
                projectRootPath: fixture.repo.path,
                worktreePath: worktree.path
            )
        } catch WorktreeSidebarGitError.locked(let reason) {
            refused = reason == "editor"
        }
        #expect(refused)
    }

    @Test("missing working directory is pruned instead of hard-failing")
    func prunesOrphanedGitdir() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("orphan", isDirectory: true)
        let other = fixture.container.appendingPathComponent("other-orphan", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "orphan", worktree.path, "HEAD"], in: fixture.repo)
        _ = try runGit(["worktree", "add", "-b", "other-orphan", other.path, "HEAD"], in: fixture.repo)
        try FileManager.default.removeItem(at: worktree)
        try FileManager.default.removeItem(at: other)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let listed = try await service.listWorktrees(projectRootPath: fixture.repo.path)
        #expect(listed.last?.isPrunable == true)
        let inspection = try await service.inspectDeletion(
            projectRootPath: fixture.repo.path,
            worktreePath: worktree.path
        )
        let result = try await service.removeWorktree(
            projectRootPath: fixture.repo.path,
            expected: inspection,
            force: false
        )
        #expect(result.removal == .pruned)
        let refreshed = try await service.listWorktrees(projectRootPath: fixture.repo.path)
        #expect(refreshed.count == 2)
        #expect(refreshed.contains { $0.normalizedPath == canonical(other) && $0.isPrunable })
    }

    @Test("linked worktree grouping resolves to the main checkout")
    func linkedProjectRootResolvesToMainCheckout() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let worktree = fixture.container.appendingPathComponent("linked", isDirectory: true)
        _ = try runGit(["worktree", "add", "-b", "linked", worktree.path, "HEAD"], in: fixture.repo)

        let resolved = await WorktreeSidebarProjectRootResolver()
            .projectRoot(onDiskFor: worktree.path)
        #expect(resolved == canonical(fixture.repo))

        let separate = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-separate-git-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: separate) }
        let checkout = separate.appendingPathComponent("checkout", isDirectory: true)
        let admin = separate.appendingPathComponent("admin.git", isDirectory: true)
        let linked = separate.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        _ = try runGit(["init", "--separate-git-dir", admin.path, "-b", "main"], in: checkout)
        _ = try runGit(["config", "user.name", "cmux Test"], in: checkout)
        _ = try runGit(["config", "user.email", "cmux@example.invalid"], in: checkout)
        try Data("hello\n".utf8).write(to: checkout.appendingPathComponent("README.md"))
        _ = try runGit(["add", "README.md"], in: checkout)
        _ = try runGit(["commit", "-m", "initial"], in: checkout)
        _ = try runGit(["worktree", "add", "-b", "linked", linked.path, "HEAD"], in: checkout)
        let separateResolved = await WorktreeSidebarProjectRootResolver()
            .projectRoot(onDiskFor: linked.path)
        #expect(separateResolved == canonical(admin))
    }

    @Test("open-terminal request is interactive, eager, and focus-false by construction")
    func openTerminalRequestDoesNotStealFocus() {
        let request = WorktreeSidebarWorkspaceRequest(
            worktreePath: "/tmp/project/manual worktree"
        )
        #expect(request.workingDirectory == "/tmp/project/manual worktree")
        #expect(!request.inheritWorkingDirectory)
        #expect(!request.select)
        #expect(request.eagerLoadTerminal)
        // The request has no primary-command field, so the terminal's main
        // process remains cmux's interactive login shell (issue #5032).
    }

    @Test("workspace close matching uses path boundaries")
    func workspaceCloseMatchingUsesPathBoundaries() {
        let worktree = "/repo/worktrees/task"
        let atRoot = UUID()
        let nested = UUID()
        let siblingPrefix = UUID()
        let ids = WorktreeSidebarWorkspaceController.workspaceIDsRooted(
            in: worktree,
            snapshots: [
                (atRoot, [worktree]),
                (nested, [worktree + "/Sources"]),
                (siblingPrefix, [worktree + "-backup"]),
            ]
        )
        #expect(ids == [atRoot, nested])
    }

    private func makeRepository() throws -> (container: URL, repo: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-sidebar-\(UUID().uuidString)", isDirectory: true)
        let repo = container.appendingPathComponent("Repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try runGit(["init", "-b", "main"], in: repo)
        _ = try runGit(["config", "user.name", "cmux Test"], in: repo)
        _ = try runGit(["config", "user.email", "cmux@example.invalid"], in: repo)
        try Data("hello\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        _ = try runGit(["add", "README.md"], in: repo)
        _ = try runGit(["commit", "-m", "initial"], in: repo)
        return (container, repo)
    }

    private func canonical(_ url: URL) -> String {
        WorktreeSidebarWorktree.normalizedPath(url.path)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GitFailure(arguments: arguments, output: output)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct GitFailure: Error {
        let arguments: [String]
        let output: String
    }
}
