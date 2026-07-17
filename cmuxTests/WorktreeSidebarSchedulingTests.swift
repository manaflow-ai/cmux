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
        let enqueuedC = queue.enqueue(path: "/c", eligibleAt: now)
        let removedB = queue.remove(path: "/b")
        let firstPath = queue.popFirst()
        let secondPath = queue.popFirst()
        let reenqueuedB = queue.enqueue(path: "/b", eligibleAt: now)
        let thirdPath = queue.popFirst()

        #expect(enqueuedA)
        #expect(!duplicatedA)
        #expect(enqueuedB)
        #expect(enqueuedC)
        #expect(removedB)
        #expect(firstPath == "/a")
        #expect(secondPath == "/c")
        #expect(reenqueuedB)
        #expect(thirdPath == "/b")
        #expect(queue.isEmpty)
    }

    @MainActor
    @Test("removed rows stay blocked until a listing omits the removed path")
    func removedRowsStayBlockedUntilListingOmitsRemovedPath() async throws {
        let projectRoot = "/tmp/worktree-sidebar-review-project"
        let worktreePath = projectRoot + "/linked"
        let manager = TabManager(
            initialWorkingDirectory: projectRoot,
            autoWelcomeIfNeeded: false
        )
        let git = WorktreeSidebarReviewRegressionGit(
            projectRootPath: projectRoot,
            worktreePath: worktreePath
        )
        let model = WorktreeSidebarModel(
            projectRootPath: projectRoot,
            git: git,
            dialogs: WorktreeSidebarReviewRegressionDialogs(),
            workspaces: WorktreeSidebarWorkspaceController(tabManager: manager)
        )
        let waiter = WorktreeSidebarModelWaiter()
        model.start()
        defer { model.stop() }
        await waiter.wait(for: model) { !$0.rows.isEmpty }
        let row = try #require(model.rows.first)

        model.refreshAll()
        await git.waitUntilListingCall(2)

        model.requestDeletion(for: row)
        await waiter.wait(for: model) { $0.operationPhase == .idle }
        let workspaceCount = manager.tabs.count

        await git.resumeListingCall(2)
        await git.waitUntilListingCall(3)
        model.openTerminal(for: row)

        #expect(manager.tabs.count == workspaceCount)

        await git.resumeListingCall(3)
        await waiter.wait(for: model) { $0.listingPhase == .loaded }
        model.openTerminal(for: row)

        #expect(manager.tabs.count == workspaceCount)

        model.refreshAll()
        await git.waitUntilListingCall(4)
        model.openTerminal(for: row)

        #expect(manager.tabs.count == workspaceCount)

        await git.resumeListingCall(4)
        await waiter.wait(for: model) { $0.rows.isEmpty }
    }

    @Test("keep-unmerged disposition preserves a branch already merged into HEAD")
    func keepUnmergedDispositionPreservesBranchMergedIntoHEAD() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-keep-unmerged-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let repo = container.appendingPathComponent("repo", isDirectory: true)
        let worktree = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: repo)
        try runGit(["config", "user.name", "cmux Test"], in: repo)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repo)
        try runGit(["remote", "add", "origin", "https://example.invalid/cmux-test.git"], in: repo)
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("tracked"))
        try runGit(["add", "tracked"], in: repo)
        try runGit(["commit", "-m", "base"], in: repo)
        try runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        try runGit(["worktree", "add", "-b", "feature", worktree.path, "HEAD"], in: repo)
        try runGit(["branch", "--set-upstream-to=origin/main", "feature"], in: repo)
        try Data("feature\n".utf8).write(to: worktree.appendingPathComponent("feature"))
        try runGit(["add", "feature"], in: worktree)
        try runGit(["commit", "-m", "feature"], in: worktree)
        try runGit(["merge", "--no-ff", "--no-edit", "feature"], in: repo)

        let service = WorktreeSidebarGitService(commandTimeout: 10)
        let inspection = try await service.inspectDeletion(
            projectRootPath: repo.path,
            worktreePath: worktree.path
        )
        #expect(inspection.branchDisposition == .keepUnmerged("feature"))
        let result = try await service.removeWorktree(
            projectRootPath: repo.path,
            expected: inspection,
            force: false
        )

        guard case .preserved(let branchName, _) = result.branch else {
            Issue.record("Expected the confirmed keep disposition to preserve the branch")
            return
        }
        #expect(branchName == "feature")
        #expect(try runGit(["branch", "--list", "feature"], in: repo).contains("feature"))
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

    @Test("resolver coalesces matching in-flight requests")
    @MainActor
    func resolverCoalescesMatchingInFlightRequests() async {
        let git = WorktreeSidebarResolverTestGit(projectRootPath: "/repo")
        let resolver = WorktreeSidebarProjectRootResolver(git: git)
        async let first = resolver.projectRoot(onDiskFor: "/repo/first")
        await git.waitForFirstListRequest()
        let requesterID = UUID()
        let coalescedRoot: String? = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await resolver.projectRoot(
                        onDiskFor: "/repo/first",
                        requesterID: requesterID
                    )
                }
            }
            guard case .some(.none) = await group.next() else {
                Issue.record("Expected one same-requester request to be superseded")
                group.cancelAll()
                await git.resolveFirstListRequest()
                return nil
            }
            await git.resolveFirstListRequest()
            guard case .some(.some(let projectRoot)) = await group.next() else {
                Issue.record("Expected the remaining request to share the in-flight result")
                return nil
            }
            return projectRoot
        }

        #expect(await first == "/repo")
        #expect(coalescedRoot == "/repo")
        #expect(await git.listRequestCount == 1)
    }

    @Test("TabManager injects one resolver without a static default")
    @MainActor
    func tabManagerInjectsResolverWithoutStaticDefault() {
        let resolver = WorktreeSidebarProjectRootResolver()
        let rootManager = TabManager(
            autoWelcomeIfNeeded: false,
            extensionSidebarProjectRootResolver: resolver
        )
        let windowManager = TabManager(
            autoWelcomeIfNeeded: false,
            extensionSidebarProjectRootResolver:
                rootManager.extensionSidebarProjectRootResolver
        )
        let isolatedManager = TabManager(autoWelcomeIfNeeded: false)

        #expect(rootManager.extensionSidebarProjectRootResolver === resolver)
        #expect(windowManager.extensionSidebarProjectRootResolver === resolver)
        #expect(isolatedManager.extensionSidebarProjectRootResolver !== resolver)
    }

    @Test("live panel directory replaces the terminal startup directory")
    @MainActor
    func livePanelDirectoryReplacesTerminalStartupDirectory() throws {
        let startupDirectory = "/tmp/cmux-worktree-startup-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-worktree-live-\(UUID().uuidString)"
        let workspace = Workspace(workingDirectory: startupDirectory)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        #expect(workspace.currentDirectory == startupDirectory)
        #expect(panel.requestedWorkingDirectory == startupDirectory)
        workspace.panelDirectories[panel.id] = liveDirectory

        let candidates = workspace.worktreeSidebarCandidateDirectories()

        #expect(candidates.contains(liveDirectory))
        #expect(!candidates.contains(startupDirectory))
    }

    @Test("listing watch plan stays shallow and includes exact linked metadata")
    func listingWatchPlanStaysShallow() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-listing-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let worktrees = container.appendingPathComponent("worktrees", isDirectory: true)
        let linked = worktrees.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)

        let plan = WorktreeSidebarListingWatchPathResolver().makePlan(
            commonDirectory: container.path
        )

        #expect(plan.shallowPaths.contains(container.appendingPathComponent("HEAD").path))
        #expect(plan.shallowPaths.contains(worktrees.path))
        #expect(plan.shallowPaths.contains(linked.appendingPathComponent("HEAD").path))
        #expect(plan.shallowPaths.contains(linked.appendingPathComponent("locked").path))
        #expect(plan.shallowPaths.contains(linked.appendingPathComponent("gitdir").path))
        #expect(!plan.shallowPaths.contains(container.path))
    }

    @Test("listing snapshot ignores unrelated admin churn")
    func listingSnapshotIgnoresUnrelatedAdminChurn() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-listing-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let worktrees = container.appendingPathComponent("worktrees", isDirectory: true)
        let linked = worktrees.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let head = linked.appendingPathComponent("HEAD")
        let locked = linked.appendingPathComponent("locked")
        try Data("ref: refs/heads/main\n".utf8).write(to: head)
        try Data("/tmp/linked/.git\n".utf8).write(
            to: linked.appendingPathComponent("gitdir")
        )
        let plan = WorktreeSidebarListingWatchPathResolver().makePlan(
            commonDirectory: container.path
        )
        let loader = WorktreeSidebarListingMetadataSnapshotLoader()
        let initial = await loader.load(plan: plan)

        try Data().write(to: linked.appendingPathComponent("index.lock"))
        #expect(await loader.load(plan: plan) == initial)

        try Data("ref: refs/heads/next\n".utf8).write(to: head)
        let changedHead = await loader.load(plan: plan)
        #expect(changedHead != initial)

        try Data("editor\n".utf8).write(to: locked)
        let changedLock = await loader.load(plan: plan)
        #expect(changedLock != changedHead)

        try FileManager.default.createDirectory(
            at: worktrees.appendingPathComponent("other", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(await loader.load(plan: plan) != changedLock)
    }

    @Test("requester queue drains in FIFO order")
    func requesterQueueDrainsInFIFOOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var queue = WorktreeSidebarRequesterQueue()
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)

        #expect(queue.dequeue() == first)
        #expect(queue.dequeue() == second)
        #expect(queue.dequeue() == third)
        #expect(queue.dequeue() == nil)
    }

    @Test("Git child environment removes ambient repository selectors")
    func gitChildEnvironmentRemovesRepositorySelectors() throws {
        let removedVariables = [
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
            "GIT_CONFIG_COUNT",
            "GIT_CONFIG_PARAMETERS",
            "GIT_DIR",
            "GIT_INDEX_FILE",
            "GIT_NAMESPACE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_OPTIONAL_LOCKS",
            "GIT_PREFIX",
            "GIT_QUARANTINE_PATH",
            "GIT_WORK_TREE",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = WorktreeSidebarGitEnvironment().launchArguments(
            executable: "/usr/bin/env",
            arguments: [],
            optionalLocks: true
        )
        process.environment = Dictionary(uniqueKeysWithValues: removedVariables.map {
            ($0, "/ambient/\($0.lowercased())")
        }).merging(["CMUX_TEST_PRESERVED": "yes"]) { _, value in value }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let childEnvironment = Set(output.split(whereSeparator: \.isNewline).map(String.init))

        #expect(process.terminationStatus == 0)
        #expect(childEnvironment.contains("CMUX_TEST_PRESERVED=yes"))
        #expect(childEnvironment.contains("GIT_OPTIONAL_LOCKS=0"))
        for variable in removedVariables where variable != "GIT_OPTIONAL_LOCKS" {
            #expect(!childEnvironment.contains { $0.hasPrefix(variable + "=") })
        }
    }

    @Test("workspace close plan preserves symlink matches across removal")
    @MainActor
    func workspaceClosePlanPreservesSymlinkMatchesAcrossRemoval() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-close-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let worktree = container.appendingPathComponent("worktree", isDirectory: true)
        let nested = worktree.appendingPathComponent("Sources", isDirectory: true)
        let alias = container.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: worktree)
        let manager = TabManager(
            initialWorkingDirectory: alias.appendingPathComponent("Sources").path,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.tabs.first)
        let controller = WorktreeSidebarWorkspaceController(tabManager: manager)

        let plan = await controller.closePlan(
            worktreePath: worktree.path,
            fallbackDirectory: container.path
        )
        try FileManager.default.removeItem(at: worktree)
        let latePlan = await controller.closePlan(
            worktreePath: worktree.path,
            fallbackDirectory: container.path
        )

        #expect(plan.entries.contains { $0.workspaceIDs.contains(workspace.id) })
        #expect(!latePlan.entries.contains { $0.workspaceIDs.contains(workspace.id) })
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeSidebarSchedulingTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum WorktreeSidebarSchedulingTestError: Error {
    case descendantDeletionWasAllowed
}
