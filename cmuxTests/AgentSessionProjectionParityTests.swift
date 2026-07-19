import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent session projection parity")
struct AgentSessionProjectionParityTests {
    struct ParityCase: Sendable, CustomTestStringConvertible {
        let name: String
        let record: RecordFixture
        let expected: ExpectedProjection

        var testDescription: String { name }
    }

    struct ExpectedProjection: Sendable {
        let restoreAuthority: Bool
        let runId: String?
        let relationship: String?
        let authorityEvidence: String?
        let endedAt: TimeInterval?
        let identityConflict: Bool?
        let resumeAttemptId: String?
        let runtimeProcessId: Int?
        let runtimeProcessStartSeconds: Int64?
        let runtimeProcessStartMicroseconds: Int64?

        init(
            restoreAuthority: Bool,
            runId: String? = nil,
            relationship: String? = nil,
            authorityEvidence: String? = nil,
            endedAt: TimeInterval? = nil,
            identityConflict: Bool? = nil,
            resumeAttemptId: String? = nil,
            runtimeProcessId: Int? = nil,
            runtimeProcessStartSeconds: Int64? = nil,
            runtimeProcessStartMicroseconds: Int64? = nil
        ) {
            self.restoreAuthority = restoreAuthority
            self.runId = runId
            self.relationship = relationship
            self.authorityEvidence = authorityEvidence
            self.endedAt = endedAt
            self.identityConflict = identityConflict
            self.resumeAttemptId = resumeAttemptId
            self.runtimeProcessId = runtimeProcessId
            self.runtimeProcessStartSeconds = runtimeProcessStartSeconds
            self.runtimeProcessStartMicroseconds = runtimeProcessStartMicroseconds
        }
    }

    struct RecordFixture: Codable, Sendable {
        var sessionId: String
        var workspaceId: String
        var surfaceId: String
        var restoreAuthority: Bool?
        var relationship: String?
        var authorityEvidence: String?
        var completedAt: TimeInterval?
        var startedAt: TimeInterval
        var updatedAt: TimeInterval
        var runs: [RunFixture]?
        var activeRunId: String?
    }

    struct RunFixture: Codable, Equatable, Sendable {
        var runId: String
        var pid: Int?
        var processStartedAt: TimeInterval?
        var cmuxRuntime: RuntimeFixture?
        var parentRunId: String?
        var parentSessionId: String?
        var relationship: String?
        var restoreAuthority: Bool
        var authorityEvidence: String?
        var cmuxHibernationResumeAttemptId: String?
        var startedAt: TimeInterval
        var updatedAt: TimeInterval
        var endedAt: TimeInterval?
        var identityConflict: Bool?
    }

    struct RuntimeFixture: Codable, Equatable, Sendable {
        var id: String
        var socketPath: String?
        var bundleIdentifier: String?
        var processId: Int?
        var processStartSeconds: Int64?
        var processStartMicroseconds: Int64?
    }

    struct ProjectionFixture: Equatable {
        var restoreAuthority: Bool
        var run: RunFixture?
    }

    static let parityCases: [ParityCase] = {
        let equalRoot = run(
            relationship: "forked",
            restoreAuthority: true,
            authorityEvidence: "verified_fork_root"
        )
        let equalManagedChild = run(
            parentRunId: "parent-run",
            parentSessionId: "parent-session",
            relationship: "spawned",
            restoreAuthority: false,
            authorityEvidence: "managed_child"
        )
        let olderManagedChild = run(
            parentRunId: "parent-run",
            parentSessionId: "parent-session",
            relationship: "spawned",
            restoreAuthority: false,
            authorityEvidence: "managed_child",
            updatedAt: 200
        )
        let olderProvisionalChild = run(
            parentRunId: "parent-run",
            parentSessionId: "parent-session",
            relationship: "spawned",
            restoreAuthority: false,
            authorityEvidence: "provisional_ambiguous_child",
            updatedAt: 200
        )
        let newerVerifiedRoot = run(
            relationship: "forked",
            restoreAuthority: true,
            authorityEvidence: "verified_fork_root",
            updatedAt: 300
        )
        let newerIncompleteRoot = run(restoreAuthority: true, updatedAt: 300)
        let runtime101 = runtime(processId: 101, seconds: 10, microseconds: 1)
        let runtime202 = runtime(processId: 202, seconds: 20, microseconds: 2)
        let runtimeProcess101 = run(cmuxRuntime: runtime101)
        let runtimeProcess202 = run(cmuxRuntime: runtime202)
        let firstResumeProof = run(resumeAttemptId: "attempt-a")
        let secondResumeProof = run(resumeAttemptId: "attempt-b")
        let complementaryRuntimeFields = [
            run(cmuxRuntime: runtime(processId: 101, seconds: nil, microseconds: 1)),
            run(cmuxRuntime: runtime(processId: nil, seconds: 10, microseconds: nil)),
        ]
        let olderProcessGeneration = run(cmuxRuntime: runtime101, updatedAt: 200)
        let newerProcessGeneration = run(cmuxRuntime: runtime202, updatedAt: 300)
        let olderRun = run("older-run", updatedAt: 200)
        let newerRun = run("newer-run", updatedAt: 300)
        let endedRun = run("ended-run", updatedAt: 200, endedAt: 250)

        return [
            ParityCase(
                name: "equal duplicate keeps durable child evidence",
                record: record(runs: [equalRoot, equalManagedChild], activeRunId: "shared-run"),
                expected: ExpectedProjection(
                    restoreAuthority: false,
                    runId: "shared-run",
                    relationship: "spawned",
                    authorityEvidence: "managed_child"
                )
            ),
            ParityCase(
                name: "equal duplicate keeps durable child evidence in reverse order",
                record: record(runs: [equalManagedChild, equalRoot], activeRunId: "shared-run"),
                expected: ExpectedProjection(
                    restoreAuthority: false,
                    runId: "shared-run",
                    relationship: "spawned",
                    authorityEvidence: "managed_child"
                )
            ),
            ParityCase(
                name: "equal duplicate rejects conflicting runtime process generations",
                record: record(
                    runs: [runtimeProcess101, runtimeProcess202],
                    activeRunId: "shared-run"
                ),
                expected: ExpectedProjection(
                    restoreAuthority: false,
                    runId: "shared-run",
                    identityConflict: true
                )
            ),
            ParityCase(
                name: "equal duplicate merges complementary runtime generation fields",
                record: record(runs: complementaryRuntimeFields, activeRunId: "shared-run"),
                expected: ExpectedProjection(
                    restoreAuthority: true,
                    runId: "shared-run",
                    runtimeProcessId: 101,
                    runtimeProcessStartSeconds: 10,
                    runtimeProcessStartMicroseconds: 1
                )
            ),
            ParityCase(
                name: "equal duplicate rejects conflicting hibernation resume proofs",
                record: record(
                    runs: [firstResumeProof, secondResumeProof],
                    activeRunId: "shared-run"
                ),
                expected: ExpectedProjection(restoreAuthority: false, runId: "shared-run")
            ),
            ParityCase(
                name: "non-equal duplicate cannot revive durable child authority",
                record: record(
                    runs: [olderManagedChild, newerVerifiedRoot],
                    activeRunId: "shared-run"
                ),
                expected: ExpectedProjection(
                    restoreAuthority: false,
                    runId: "shared-run",
                    relationship: "spawned",
                    authorityEvidence: "managed_child"
                )
            ),
            ParityCase(
                name: "non-equal duplicate recovers provisional verified fork root",
                record: record(
                    runs: [olderProvisionalChild, newerVerifiedRoot],
                    activeRunId: "shared-run"
                ),
                expected: ExpectedProjection(
                    restoreAuthority: true,
                    runId: "shared-run",
                    relationship: "forked",
                    authorityEvidence: "verified_fork_root"
                )
            ),
            ParityCase(
                name: "non-equal duplicate keeps provisional child without complete proof",
                record: record(
                    runs: [olderProvisionalChild, newerIncompleteRoot],
                    activeRunId: "shared-run"
                ),
                expected: ExpectedProjection(
                    restoreAuthority: false,
                    runId: "shared-run",
                    relationship: "spawned",
                    authorityEvidence: "provisional_ambiguous_child"
                )
            ),
            ParityCase(
                name: "non-equal duplicate accepts a newer process generation",
                record: record(
                    runs: [olderProcessGeneration, newerProcessGeneration],
                    activeRunId: "shared-run"
                ),
                expected: ExpectedProjection(
                    restoreAuthority: true,
                    runId: "shared-run",
                    runtimeProcessId: 202,
                    runtimeProcessStartSeconds: 20,
                    runtimeProcessStartMicroseconds: 2
                )
            ),
            ParityCase(
                name: "legacy spawned record fails closed without runs",
                record: record(relationship: "spawned", runs: nil),
                expected: ExpectedProjection(restoreAuthority: false)
            ),
            ParityCase(
                name: "legacy child evidence fails closed without runs",
                record: record(authorityEvidence: "managed_child", runs: nil),
                expected: ExpectedProjection(restoreAuthority: false)
            ),
            ParityCase(
                name: "legacy completed record fails closed without runs",
                record: record(completedAt: 250, runs: nil),
                expected: ExpectedProjection(restoreAuthority: false)
            ),
            ParityCase(
                name: "legacy verified fork root retains authority without runs",
                record: record(
                    relationship: "forked",
                    authorityEvidence: "verified_fork_root",
                    runs: nil
                ),
                expected: ExpectedProjection(restoreAuthority: true)
            ),
            ParityCase(
                name: "missing active run id selects the newest run",
                record: record(runs: [newerRun, olderRun], activeRunId: nil),
                expected: ExpectedProjection(restoreAuthority: true, runId: "newer-run")
            ),
            ParityCase(
                name: "unknown active run id selects the newest run",
                record: record(runs: [olderRun, newerRun], activeRunId: "missing-run"),
                expected: ExpectedProjection(restoreAuthority: true, runId: "newer-run")
            ),
            ParityCase(
                name: "active ended run remains authoritative over a newer live run",
                record: record(
                    runs: [newerRun, endedRun],
                    activeRunId: "ended-run"
                ),
                expected: ExpectedProjection(
                    restoreAuthority: false,
                    runId: "ended-run",
                    endedAt: 250
                )
            ),
        ]
    }()

    @Test(arguments: parityCases)
    func foundationAndCLIProjectIdenticalJSON(testCase: ParityCase) throws {
        let recordJSON = try JSONEncoder().encode(testCase.record)
        let foundationProjection = try foundationProjection(recordJSON: recordJSON)
        let cliProjection = try cliProjection(recordJSON: recordJSON)
        let comment = Comment(rawValue: testCase.name)

        #expect(foundationProjection == cliProjection, comment)
        #expect(foundationProjection.restoreAuthority == testCase.expected.restoreAuthority, comment)
        #expect(foundationProjection.run?.runId == testCase.expected.runId, comment)
        #expect(foundationProjection.run?.relationship == testCase.expected.relationship, comment)
        #expect(
            foundationProjection.run?.authorityEvidence == testCase.expected.authorityEvidence,
            comment
        )
        #expect(foundationProjection.run?.endedAt == testCase.expected.endedAt, comment)
        #expect(
            foundationProjection.run?.identityConflict == testCase.expected.identityConflict,
            comment
        )
        #expect(
            foundationProjection.run?.cmuxHibernationResumeAttemptId
                == testCase.expected.resumeAttemptId,
            comment
        )
        #expect(
            foundationProjection.run?.cmuxRuntime?.processId
                == testCase.expected.runtimeProcessId,
            comment
        )
        #expect(
            foundationProjection.run?.cmuxRuntime?.processStartSeconds
                == testCase.expected.runtimeProcessStartSeconds,
            comment
        )
        #expect(
            foundationProjection.run?.cmuxRuntime?.processStartMicroseconds
                == testCase.expected.runtimeProcessStartMicroseconds,
            comment
        )
    }

    private func foundationProjection(recordJSON: Data) throws -> ProjectionFixture {
        let projection = try #require(
            CmuxAgentSessionRunAuthorityProjection().projection(recordJSON: recordJSON)
        )
        let run = try projection.run.map { try runFixture($0) }
        return ProjectionFixture(restoreAuthority: projection.restoreAuthority, run: run)
    }

    private func cliProjection(recordJSON: Data) throws -> ProjectionFixture {
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordJSON)
        let projectedRun = AgentSessionRunCanonicalizer().projectedRun(
            record: record,
            provider: "parity-agent"
        )
        let run: RunFixture?
        if record.runs?.isEmpty == false {
            run = try runFixture(projectedRun)
        } else {
            // Foundation intentionally returns no canonical run for compatibility
            // records, so legacy parity compares the authority projection only.
            run = nil
        }
        return ProjectionFixture(restoreAuthority: projectedRun.restoreAuthority, run: run)
    }

    private func runFixture<Value: Encodable>(_ value: Value) throws -> RunFixture {
        try JSONDecoder().decode(RunFixture.self, from: JSONEncoder().encode(value))
    }

    private static func record(
        restoreAuthority: Bool? = true,
        relationship: String? = nil,
        authorityEvidence: String? = nil,
        completedAt: TimeInterval? = nil,
        runs: [RunFixture]?,
        activeRunId: String? = nil
    ) -> RecordFixture {
        RecordFixture(
            sessionId: "parity-session",
            workspaceId: "parity-workspace",
            surfaceId: "parity-surface",
            restoreAuthority: restoreAuthority,
            relationship: relationship,
            authorityEvidence: authorityEvidence,
            completedAt: completedAt,
            startedAt: 100,
            updatedAt: 400,
            runs: runs,
            activeRunId: activeRunId
        )
    }

    private static func run(
        _ runId: String = "shared-run",
        pid: Int? = 42,
        processStartedAt: TimeInterval? = 100,
        cmuxRuntime: RuntimeFixture? = nil,
        parentRunId: String? = nil,
        parentSessionId: String? = nil,
        relationship: String? = nil,
        restoreAuthority: Bool = true,
        authorityEvidence: String? = nil,
        resumeAttemptId: String? = nil,
        startedAt: TimeInterval = 100,
        updatedAt: TimeInterval = 200,
        endedAt: TimeInterval? = nil,
        identityConflict: Bool? = nil
    ) -> RunFixture {
        RunFixture(
            runId: runId,
            pid: pid,
            processStartedAt: processStartedAt,
            cmuxRuntime: cmuxRuntime,
            parentRunId: parentRunId,
            parentSessionId: parentSessionId,
            relationship: relationship,
            restoreAuthority: restoreAuthority,
            authorityEvidence: authorityEvidence,
            cmuxHibernationResumeAttemptId: resumeAttemptId,
            startedAt: startedAt,
            updatedAt: updatedAt,
            endedAt: endedAt,
            identityConflict: identityConflict
        )
    }

    private static func runtime(
        processId: Int?,
        seconds: Int64?,
        microseconds: Int64?
    ) -> RuntimeFixture {
        RuntimeFixture(
            id: "parity-runtime",
            socketPath: "/tmp/parity-runtime.sock",
            bundleIdentifier: "com.cmux.parity",
            processId: processId,
            processStartSeconds: seconds,
            processStartMicroseconds: microseconds
        )
    }
}
