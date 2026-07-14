import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct WorktreeSidebarSchedulingTests {
    @Test("status queue is FIFO and deduplicated")
    func statusQueueIsFIFOAndDeduplicated() {
        var queue = WorktreeSidebarStatusQueue()
        let now = ContinuousClock().now
        let enqueuedA = queue.enqueue(path: "/a", eligibleAt: now)
        let duplicatedA = queue.enqueue(path: "/a", eligibleAt: now)
        let enqueuedB = queue.enqueue(path: "/b", eligibleAt: now)
        let firstPath = queue.popFirst()
        let removedB = queue.remove(path: "/b")

        #expect(enqueuedA)
        #expect(!duplicatedA)
        #expect(enqueuedB)
        #expect(firstPath == "/a")
        #expect(removedB)
        #expect(queue.isEmpty)
    }

    @Test("status watch plan excludes shell-created descendant worktrees")
    func statusWatchPlanExcludesDescendantWorktrees() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-watch-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("root", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let parent = root.appendingPathComponent("manual", isDirectory: true)
        let nestedWorktree = parent.appendingPathComponent("child", isDirectory: true)
        let sibling = parent.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedWorktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let head = gitDirectory.appendingPathComponent("HEAD")
        let index = gitDirectory.appendingPathComponent("index")
        let branchRef = gitDirectory.appendingPathComponent("refs/heads/main")
        try FileManager.default.createDirectory(
            at: branchRef.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/main\n".utf8).write(to: head)
        try Data().write(to: index)
        try Data().write(to: branchRef)

        let plan = WorktreeSidebarStatusWatchPlanner().makePlan(
            worktreePath: root.path,
            gitDirectory: gitDirectory.path,
            metadataPaths: [root.path, head.path, index.path],
            excludedWorktreePaths: [nestedWorktree.path]
        )

        #expect(plan.shallowPaths.contains(root.path))
        #expect(plan.shallowPaths.contains(parent.path))
        #expect(plan.recursivePaths.contains(sibling.path))
        #expect(plan.recursivePaths.contains(head.path))
        #expect(plan.recursivePaths.contains(index.path))
        #expect(plan.shallowPaths.contains(branchRef.path))
        #expect(!plan.recursivePaths.contains { path in
            path == nestedWorktree.path || path.hasPrefix(nestedWorktree.path + "/")
        })
    }

    @Test("deletion inspection refuses a Git-registered descendant worktree")
    func deletionInspectionRefusesRegisteredDescendantWorktree() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-nested-worktree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let parent = container.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: repository)
        try runGit(["config", "user.name", "cmux Test"], in: repository)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repository)
        try Data("root\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try runGit(["add", "README.md"], in: repository)
        try runGit(["commit", "-m", "initial"], in: repository)
        try runGit(["worktree", "add", "-b", "parent", parent.path, "HEAD"], in: repository)
        try runGit(["worktree", "add", "-b", "child", child.path, "HEAD"], in: repository)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        do {
            _ = try await service.inspectDeletion(
                projectRootPath: repository.path,
                worktreePath: parent.path
            )
        } catch WorktreeSidebarGitError.containsRegisteredWorktrees {
            #expect(FileManager.default.fileExists(atPath: child.path))
            return
        }
        throw WorktreeSidebarSchedulingTestError.descendantDeletionWasAllowed
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "WorktreeSidebarSchedulingTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }
}

private enum WorktreeSidebarSchedulingTestError: Error {
    case descendantDeletionWasAllowed
}
