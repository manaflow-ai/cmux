import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatFallbackTranscriptResolutionCoordinatorTests {
    @MainActor
    @Test func authoritativeTranscriptBindingCancelsFallbackResolution() async throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(path: nil, waitForCancellation: true)
        let service = makeService(fixture: fixture, probe: probe)

        let historyTask = Task {
            await service.history(sessionID: fixture.sessionID, beforeSeq: nil, limit: 50)
        }
        await probe.waitUntilStarted()
        service.registry.update(sessionID: fixture.sessionID) {
            $0.transcriptPath = fixture.transcript.path
        }

        #expect(await historyTask.value != nil)
        #expect(await probe.wasCancelled())
        #expect(await probe.callCount() == 1)
    }

    @MainActor
    @Test func endedSessionCancelsFallbackResolution() async throws {
        let fixture = try makeCodexFixture(createTranscript: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(path: nil, waitForCancellation: true)
        let service = makeService(fixture: fixture, probe: probe)

        let historyTask = Task {
            await service.history(sessionID: fixture.sessionID, beforeSeq: nil, limit: 50)
        }
        await probe.waitUntilStarted()
        service.noteHookEvent(fixture.hookEvent(.sessionEnd))

        #expect(await historyTask.value == nil)
        #expect(await probe.wasCancelled())
        #expect(await probe.callCount() == 1)
    }

    @MainActor
    @Test func cancelledResolutionDoesNotPublishLateResolverResult() async throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(
            path: fixture.transcript.path,
            waitForCancellation: true,
            returnPathAfterCancellation: true
        )
        let registry = AgentChatSessionRegistry()
        let record = registry.noteHookEvent(fixture.hookEvent(.sessionStart))
        let coordinator = AgentChatFallbackTranscriptResolutionCoordinator(
            transcriptResolver: AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:]),
            resolver: { record, deadline in
                await probe.resolve(record: record, deadline: deadline)
            },
            timeout: .milliseconds(250)
        )

        let resolutionTask = Task {
            await coordinator.resolve(for: record)
        }
        await probe.waitUntilStarted()
        let coalescedResolutionTask = Task {
            await coordinator.resolve(for: record)
        }
        await Task.yield()
        coordinator.cancel(sessionID: fixture.sessionID)

        #expect(await resolutionTask.value == nil)
        #expect(await coalescedResolutionTask.value == nil)
        #expect(await probe.wasCancelled())
        #expect(await probe.callCount() == 1)
    }

    @Test func deadlineReturnsWhileResolverRemainsSuspendedAndCoalesced() async throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let probe = AgentChatFallbackResolutionProbe(
            path: fixture.transcript.path,
            returnPathAfterCancellation: true,
            suspendUntilReleased: true
        )
        let (record, coordinator) = await MainActor.run {
            let registry = AgentChatSessionRegistry()
            let record = registry.noteHookEvent(fixture.hookEvent(.sessionStart))
            let coordinator = AgentChatFallbackTranscriptResolutionCoordinator(
                transcriptResolver: AgentChatTranscriptResolver(
                    homeDirectory: fixture.home,
                    environment: [:]
                ),
                resolver: { record, deadline in
                    await probe.resolve(record: record, deadline: deadline)
                },
                timeout: .milliseconds(50)
            )
            return (record, coordinator)
        }

        let (firstCompletions, firstCompletionContinuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let firstResolution = Task { @MainActor in
            let path = await coordinator.resolve(for: record)
            firstCompletionContinuation.yield(true)
            firstCompletionContinuation.finish()
            return path
        }
        let firstDeadline = Task {
            try? await ContinuousClock().sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            firstCompletionContinuation.yield(false)
            firstCompletionContinuation.finish()
        }
        await probe.waitUntilStarted()
        let firstCompletedBeforeDeadline = await firstCompletions.first { _ in true } ?? false
        firstDeadline.cancel()
        #expect(
            firstCompletedBeforeDeadline,
            "the advertised deadline must return while non-cooperative resolver I/O remains suspended"
        )
        if !firstCompletedBeforeDeadline {
            await probe.releaseSuspendedResolution()
            await probe.waitUntilFinished()
        }
        #expect(await firstResolution.value == nil)

        let (secondCompletions, secondCompletionContinuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let secondResolution = Task { @MainActor in
            let path = await coordinator.resolve(for: record)
            secondCompletionContinuation.yield(true)
            secondCompletionContinuation.finish()
            return path
        }
        let secondDeadline = Task {
            try? await ContinuousClock().sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            secondCompletionContinuation.yield(false)
            secondCompletionContinuation.finish()
        }
        let secondCompletedBeforeDeadline = await secondCompletions.first { _ in true } ?? false
        secondDeadline.cancel()
        #expect(
            secondCompletedBeforeDeadline,
            "an expired lookup must reject coalesced callers without spawning more stuck resolver work"
        )
        #expect(await secondResolution.value == nil)
        #expect(await probe.callCount() == 1)

        await probe.releaseSuspendedResolution()
        await probe.waitUntilFinished()
        #expect(await probe.wasCancelled())
    }

    @MainActor
    @Test func distinctSessionFallbackResolutionHasGlobalAdmissionBound() async {
        let registry = AgentChatSessionRegistry()
        let records = (0..<5).map { index in
            registry.noteHookEvent(
                WorkstreamEvent(
                    sessionId: "fallback-global-admission-\(index)",
                    hookEventName: .sessionStart,
                    source: "codex"
                )
            )
        }
        let probes = Dictionary(uniqueKeysWithValues: records.map { record in
            (
                record.sessionID,
                AgentChatFallbackResolutionProbe(
                    path: nil,
                    returnPathAfterCancellation: true,
                    suspendUntilReleased: true
                )
            )
        })
        let coordinator = AgentChatFallbackTranscriptResolutionCoordinator(
            transcriptResolver: AgentChatTranscriptResolver(),
            resolver: { record, deadline in
                guard let probe = probes[record.sessionID] else { return nil }
                return await probe.resolve(record: record, deadline: deadline)
            },
            timeout: .milliseconds(50)
        )

        let admittedTasks = records.prefix(4).map { record in
            Task { @MainActor in
                await coordinator.resolve(for: record)
            }
        }
        for record in records.prefix(4) {
            await probes[record.sessionID]?.waitUntilStarted()
        }

        let overflowRecord = records[4]
        #expect(await coordinator.resolve(for: overflowRecord) == nil)
        #expect(
            await probes[overflowRecord.sessionID]?.callCount() == 0,
            "fallback scans for distinct sessions must have a global admission bound"
        )

        for probe in probes.values {
            if await probe.callCount() > 0 {
                await probe.releaseSuspendedResolution()
                await probe.waitUntilFinished()
            }
        }
        for task in admittedTasks {
            #expect(await task.value == nil)
        }
    }

    @MainActor
    @Test func expiredDeadlineSkipsCodexFallbackEnumeration() throws {
        let fixture = try makeCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let resolver = AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:])
        let registry = AgentChatSessionRegistry()
        let record = registry.noteHookEvent(fixture.hookEvent(.sessionStart))

        #expect(resolver.transcriptPath(for: record, deadline: .now) == nil)
    }

    @MainActor
    @Test func ompRecordedTranscriptWinsAndMissingRecordedPathFailsClosed() throws {
        let home = try makeTemporaryDirectory(prefix: "cmux-omp-recorded")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "019f0000-0000-7000-8000-000000000301"
        let cwd = home.appendingPathComponent("project", isDirectory: true).path
        let sessionsRoot = home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        _ = try writeOmpTranscript(
            sessionsRoot: sessionsRoot,
            bucket: "-project",
            sessionID: sessionID,
            cwd: cwd
        )
        let recorded = home.appendingPathComponent("authoritative/\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: recorded.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ompHeader(sessionID: sessionID, cwd: cwd)
            .write(to: recorded, atomically: true, encoding: .utf8)
        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let authoritativeRecord = ompRecord(
            sessionID: sessionID,
            cwd: cwd,
            transcriptPath: recorded.path
        )

        #expect(resolver.transcriptPath(for: authoritativeRecord, deadline: deadline) == recorded.path)

        let missingRecordedPath = home.appendingPathComponent("missing/\(sessionID).jsonl").path
        let missingRecord = ompRecord(
            sessionID: sessionID,
            cwd: cwd,
            transcriptPath: missingRecordedPath
        )
        #expect(
            resolver.transcriptPath(for: missingRecord, deadline: deadline) == nil,
            "an authoritative OMP hook path that disappeared must not select a different transcript"
        )
    }

    @MainActor
    @Test func ompDefaultFallbackFindsCurrentAndLegacyCwdBucketsWithinDeadline() throws {
        let home = try makeTemporaryDirectory(prefix: "cmux-omp-default-buckets")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsRoot = home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        let homeProject = home
            .appendingPathComponent("Projects/mobile", isDirectory: true)
            .path
        let temporaryProjectName = "cmux-omp-temp-\(UUID().uuidString)"
        let temporaryProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryProjectName)/repo", isDirectory: true)
            .path
        let outsideProject = "/opt/anonymized-omp-project"
        let legacyPath = String(homeProject.dropFirst()).replacingOccurrences(of: "/", with: "-")
        let legacyHomeBucket = "--\(legacyPath)--"
        let cases = [
            (
                sessionID: "019f0000-0000-7000-8000-000000000311",
                cwd: home.path,
                bucket: "-"
            ),
            (
                sessionID: "019f0000-0000-7000-8000-000000000312",
                cwd: homeProject,
                bucket: "-Projects-mobile"
            ),
            (
                sessionID: "019f0000-0000-7000-8000-000000000313",
                cwd: temporaryProject,
                bucket: "-tmp-\(temporaryProjectName)-repo"
            ),
            (
                sessionID: "019f0000-0000-7000-8000-000000000314",
                cwd: outsideProject,
                bucket: "--opt-anonymized-omp-project--"
            ),
            (
                sessionID: "019f0000-0000-7000-8000-000000000315",
                cwd: homeProject,
                bucket: legacyHomeBucket
            ),
        ]
        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])

        for item in cases {
            let transcript = try writeOmpTranscript(
                sessionsRoot: sessionsRoot,
                bucket: item.bucket,
                sessionID: item.sessionID,
                cwd: item.cwd
            )
            let record = ompRecord(sessionID: item.sessionID, cwd: item.cwd)
            #expect(
                canonicalPath(resolver.transcriptPath(
                    for: record,
                    deadline: ContinuousClock.now.advanced(by: .seconds(1))
                )) == canonicalPath(transcript.path)
            )
        }

        let expired = ompRecord(sessionID: cases[0].sessionID, cwd: cases[0].cwd)
        #expect(resolver.transcriptPath(for: expired, deadline: .now) == nil)
    }

    @MainActor
    @Test func ompNamedProfileFallbackUsesProfileRootAndIgnoresAgentDirOverride() throws {
        let home = try makeTemporaryDirectory(prefix: "cmux-omp-named-profile")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "019f0000-0000-7000-8000-000000000321"
        let cwd = home.appendingPathComponent("project", isDirectory: true).path
        let profileRoot = home
            .appendingPathComponent(".omp/profiles/work/agent/sessions", isDirectory: true)
        let transcript = try writeOmpTranscript(
            sessionsRoot: profileRoot,
            bucket: "-project",
            sessionID: sessionID,
            cwd: cwd
        )
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: [
                "OMP_PROFILE": "work",
                "PI_CODING_AGENT_DIR": home.appendingPathComponent("wrong-agent-root").path,
            ]
        )

        #expect(
            canonicalPath(resolver.transcriptPath(
                for: ompRecord(sessionID: sessionID, cwd: cwd),
                deadline: ContinuousClock.now.advanced(by: .seconds(1))
            )) == canonicalPath(transcript.path)
        )
    }

    @MainActor
    @Test func ompXdgFallbackUsesFlattenedDefaultAndNamedProfileDataRoots() throws {
        let home = try makeTemporaryDirectory(prefix: "cmux-omp-xdg")
        defer { try? FileManager.default.removeItem(at: home) }
        let xdgData = home.appendingPathComponent("xdg-data", isDirectory: true)
        let cwd = home.appendingPathComponent("project", isDirectory: true).path

        let defaultAppRoot = xdgData.appendingPathComponent("omp", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultAppRoot, withIntermediateDirectories: true)
        let defaultSessionID = "019f0000-0000-7000-8000-000000000331"
        let defaultTranscript = try writeOmpTranscript(
            sessionsRoot: defaultAppRoot.appendingPathComponent("sessions", isDirectory: true),
            bucket: "-project",
            sessionID: defaultSessionID,
            cwd: cwd
        )
        let defaultResolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: ["XDG_DATA_HOME": xdgData.path]
        )
        #expect(
            canonicalPath(defaultResolver.transcriptPath(
                for: ompRecord(sessionID: defaultSessionID, cwd: cwd),
                deadline: ContinuousClock.now.advanced(by: .seconds(1))
            )) == canonicalPath(defaultTranscript.path)
        )

        let namedAppRoot = defaultAppRoot
            .appendingPathComponent("profiles/team", isDirectory: true)
        try FileManager.default.createDirectory(at: namedAppRoot, withIntermediateDirectories: true)
        let namedSessionID = "019f0000-0000-7000-8000-000000000332"
        let namedTranscript = try writeOmpTranscript(
            sessionsRoot: namedAppRoot.appendingPathComponent("sessions", isDirectory: true),
            bucket: "-project",
            sessionID: namedSessionID,
            cwd: cwd
        )
        let namedResolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: [
                "XDG_DATA_HOME": xdgData.path,
                "OMP_PROFILE": "team",
                "PI_CODING_AGENT_DIR": home.appendingPathComponent("ignored-agent-root").path,
            ]
        )
        #expect(
            canonicalPath(namedResolver.transcriptPath(
                for: ompRecord(sessionID: namedSessionID, cwd: cwd),
                deadline: ContinuousClock.now.advanced(by: .seconds(1))
            )) == canonicalPath(namedTranscript.path)
        )
    }

    @MainActor
    @Test func ompFallbackFindsLegacyNamedProfilesWithoutActiveProfileAndRejectsInvalidNames() throws {
        let home = try makeTemporaryDirectory(prefix: "cmux-omp-legacy-profiles")
        defer { try? FileManager.default.removeItem(at: home) }
        let xdgData = home.appendingPathComponent("xdg-data", isDirectory: true)
        let cwd = home.appendingPathComponent("project", isDirectory: true).path
        let configSessionID = "019f0000-0000-7000-8000-000000000341"
        let xdgSessionID = "019f0000-0000-7000-8000-000000000342"
        let invalidSessionID = "019f0000-0000-7000-8000-000000000343"
        let configTranscript = try writeOmpTranscript(
            sessionsRoot: home
                .appendingPathComponent(".omp/profiles/work/agent/sessions", isDirectory: true),
            bucket: "-project",
            sessionID: configSessionID,
            cwd: cwd
        )
        let xdgProfileRoot = xdgData
            .appendingPathComponent("omp/profiles/team", isDirectory: true)
        let xdgTranscript = try writeOmpTranscript(
            sessionsRoot: xdgProfileRoot.appendingPathComponent("sessions", isDirectory: true),
            bucket: "-project",
            sessionID: xdgSessionID,
            cwd: cwd
        )
        _ = try writeOmpTranscript(
            sessionsRoot: home
                .appendingPathComponent(
                    ".omp/profiles/INVALID PROFILE/agent/sessions",
                    isDirectory: true
                ),
            bucket: "-project",
            sessionID: invalidSessionID,
            cwd: cwd
        )
        _ = try writeOmpTranscript(
            sessionsRoot: xdgData
                .appendingPathComponent(
                    "omp/profiles/INVALID PROFILE/sessions",
                    isDirectory: true
                ),
            bucket: "-project",
            sessionID: invalidSessionID,
            cwd: cwd
        )
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: ["XDG_DATA_HOME": xdgData.path]
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))

        #expect(
            canonicalPath(resolver.transcriptPath(
                for: ompRecord(sessionID: configSessionID, cwd: cwd),
                deadline: deadline
            )) == canonicalPath(configTranscript.path)
        )
        #expect(
            canonicalPath(resolver.transcriptPath(
                for: ompRecord(sessionID: xdgSessionID, cwd: cwd),
                deadline: deadline
            )) == canonicalPath(xdgTranscript.path)
        )
        #expect(
            resolver.transcriptPath(
                for: ompRecord(sessionID: invalidSessionID, cwd: cwd),
                deadline: deadline
            ) == nil
        )
        #expect(
            resolver.transcriptPath(
                for: ompRecord(sessionID: configSessionID, cwd: cwd),
                deadline: .now
            ) == nil
        )
    }

    @MainActor
    private func makeService(
        fixture: AgentChatFallbackResolutionFixture,
        probe: AgentChatFallbackResolutionProbe
    ) -> AgentChatTranscriptService {
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            fallbackTranscriptPathResolver: { record, deadline in
                await probe.resolve(record: record, deadline: deadline)
            },
            fallbackResolutionTimeout: .milliseconds(250)
        )
        service.noteHookEvent(fixture.hookEvent(.sessionStart))
        return service
    }

    private func makeCodexFixture(
        createTranscript: Bool = true
    ) throws -> AgentChatFallbackResolutionFixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        let sessionID = UUID().uuidString.lowercased()
        let transcript = home
            .appendingPathComponent(".codex/sessions/2026/07/24", isDirectory: true)
            .appendingPathComponent("rollout-2026-07-24T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if createTranscript {
            try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
        }
        return AgentChatFallbackResolutionFixture(
            home: home,
            transcript: transcript,
            sessionID: sessionID,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString
        )
    }
    private func canonicalPath(_ path: String?) -> String? {
        path.map {
            URL(fileURLWithPath: $0)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeOmpTranscript(
        sessionsRoot: URL,
        bucket: String,
        sessionID: String,
        cwd: String
    ) throws -> URL {
        let transcript = sessionsRoot
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent("2026-02-16T10-20-30_\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ompHeader(sessionID: sessionID, cwd: cwd)
            .write(to: transcript, atomically: true, encoding: .utf8)
        return transcript
    }

    private func ompHeader(sessionID: String, cwd: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "type": "session",
                "version": 3,
                "id": sessionID,
                "timestamp": "2026-02-16T10:20:30.000Z",
                "cwd": cwd,
            ],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func ompRecord(
        sessionID: String,
        cwd: String,
        transcriptPath: String? = nil
    ) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .omp,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: cwd,
            transcriptPath: transcriptPath,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 200),
            title: nil,
            pid: nil
        )
    }

}

private struct AgentChatFallbackResolutionFixture {
    let home: URL
    let transcript: URL
    let sessionID: String
    let workspaceID: String
    let surfaceID: String

    func hookEvent(_ name: WorkstreamEvent.HookEventName) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: name,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: name == .sessionEnd ? nil : 123,
            receivedAt: Date(timeIntervalSince1970: name == .sessionEnd ? 302 : 301)
        )
    }
}

private actor AgentChatFallbackResolutionProbe {
    private let path: String?
    private let waitForCancellation: Bool
    private let returnPathAfterCancellation: Bool
    private let suspendUntilReleased: Bool
    private var calls = 0
    private var cancelled = false
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseRequested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        path: String?,
        waitForCancellation: Bool = false,
        returnPathAfterCancellation: Bool = false,
        suspendUntilReleased: Bool = false
    ) {
        self.path = path
        self.waitForCancellation = waitForCancellation
        self.returnPathAfterCancellation = returnPathAfterCancellation
        self.suspendUntilReleased = suspendUntilReleased
    }

    func resolve(
        record _: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        calls += 1
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if suspendUntilReleased {
            await withCheckedContinuation { continuation in
                if releaseRequested {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
            cancelled = Task.isCancelled
            finish()
            return returnPathAfterCancellation ? path : nil
        }
        if waitForCancellation {
            while !Task.isCancelled, ContinuousClock.now < deadline {
                await Task.yield()
            }
            cancelled = Task.isCancelled
            finish()
            return returnPathAfterCancellation ? path : nil
        }
        finish()
        return path
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls
    }

    func wasCancelled() -> Bool {
        cancelled
    }

    func releaseSuspendedResolution() {
        releaseRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            finishedWaiters.append(continuation)
        }
    }

    private func finish() {
        finished = true
        let waiters = finishedWaiters
        finishedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
