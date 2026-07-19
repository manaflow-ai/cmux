import AppKit
import CmuxFoundation
import CmuxTerminal
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func directShebangAvailabilityMatchesExecveAndTracksSymlinkRetargeting() throws {
        let root = try makeShortExecutableTestRoot("direct")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let interpreter = bin.appendingPathComponent("runtime", isDirectory: false)
        let agent = bin.appendingPathComponent("agent", isDirectory: false)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeResumeTestExecutable(
            at: agent,
            shebang: "#!\(interpreter.path)"
        )
        let descriptor = AgentCommandExecutionDescriptor(
            executable: agent.path,
            searchPath: bin.path,
            workingDirectory: root.path
        )

        #expect(AgentCommandExecutableResolver().resolve(descriptor) == nil)
        #expect(directExecOutcome(agent, path: bin.path) == .launchError(Int(ENOENT)))

        try FileManager.default.createSymbolicLink(atPath: interpreter.path, withDestinationPath: "/bin/sh")
        let resolution = try #require(AgentCommandExecutableResolver().resolve(descriptor))
        #expect(directExecOutcome(agent, path: bin.path) == .exit(0))
        #expect(resolution.watchDirectories.contains(bin.path))

        try FileManager.default.removeItem(at: interpreter)
        try FileManager.default.createSymbolicLink(atPath: interpreter.path, withDestinationPath: "/bin/zsh")
        let retargeted = try #require(AgentCommandExecutableResolver().resolve(descriptor))
        #expect(directExecOutcome(agent, path: bin.path) == .exit(0))
        #expect(retargeted.cachePart != resolution.cachePart)
        #expect(!AgentCommandExecutableResolver.revalidate(resolution))

        try FileManager.default.removeItem(at: interpreter)
        #expect(AgentCommandExecutableResolver().resolve(descriptor) == nil)
        #expect(!AgentCommandExecutableResolver.revalidate(retargeted))
    }

    @Test func envNodeAndBunShebangsTrackRuntimeAndStopAtBrokenFirstPATHCandidate() throws {
        let root = try makeShortExecutableTestRoot("env")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let laterBin = root.appendingPathComponent("later", isDirectory: true)
        let node = bin.appendingPathComponent("node", isDirectory: false)
        let bun = bin.appendingPathComponent("bun", isDirectory: false)
        let nodeAgent = bin.appendingPathComponent("node-agent", isDirectory: false)
        let bunAgent = bin.appendingPathComponent("bun-agent", isDirectory: false)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: laterBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeResumeTestExecutable(at: nodeAgent, shebang: "#!/usr/bin/env node --plain-tail")
        try writeResumeTestExecutable(at: bunAgent, shebang: "#!/usr/bin/env -S bun --split-tail")

        func descriptor(_ url: URL, path: String? = nil) -> AgentCommandExecutionDescriptor {
            AgentCommandExecutionDescriptor(
                executable: url.path,
                searchPath: path ?? bin.path,
                workingDirectory: root.path
            )
        }

        #expect(AgentCommandExecutableResolver().resolve(descriptor(nodeAgent)) == nil)
        #expect(AgentCommandExecutableResolver().resolve(descriptor(bunAgent)) == nil)
        #expect(directExecOutcome(nodeAgent, path: bin.path) == .exit(127))
        #expect(directExecOutcome(bunAgent, path: bin.path) == .exit(127))

        // /usr/bin/true proves Darwin passes both plain and -S tails as
        // separate argv entries. A Linux-style unsplit command name would fail.
        try FileManager.default.createSymbolicLink(atPath: node.path, withDestinationPath: "/usr/bin/true")
        try FileManager.default.createSymbolicLink(atPath: bun.path, withDestinationPath: "/usr/bin/true")
        let nodeResolution = try #require(AgentCommandExecutableResolver().resolve(descriptor(nodeAgent)))
        let bunResolution = try #require(AgentCommandExecutableResolver().resolve(descriptor(bunAgent)))
        #expect(directExecOutcome(nodeAgent, path: bin.path) == .exit(0))
        #expect(directExecOutcome(bunAgent, path: bin.path) == .exit(0))

        try FileManager.default.removeItem(at: node)
        #expect(!AgentCommandExecutableResolver.revalidate(nodeResolution))
        #expect(AgentCommandExecutableResolver.revalidate(bunResolution))

        let commandName = "earlier-broken"
        let broken = bin.appendingPathComponent(commandName)
        try writeResumeTestExecutable(at: broken, shebang: "#!/usr/bin/env missing-runtime")
        try writeResumeTestExecutable(at: laterBin.appendingPathComponent(commandName))
        let searchPath = "\(bin.path):\(laterBin.path)"
        let lookup = AgentCommandExecutableResolver().lookup(AgentCommandExecutionDescriptor(
            executable: commandName,
            searchPath: searchPath,
            workingDirectory: root.path
        ))
        #expect(lookup.candidateLookupPath == broken.path)
        #expect(lookup.resolution == nil)
        #expect(directExecOutcome(broken, path: searchPath) == .exit(127))

        #expect(nodeResolution.cachePart != bunResolution.cachePart)
    }

    @Test func shebangParsingMatchesExecveBoundariesAndNestedInterpreterRule() throws {
        let root = try makeShortExecutableTestRoot("kernel")
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor: (URL) -> AgentCommandExecutionDescriptor = { url in
            AgentCommandExecutionDescriptor(
                executable: url.path,
                searchPath: "/usr/bin:/bin",
                workingDirectory: root.path
            )
        }

        let crlf = root.appendingPathComponent("crlf")
        try writeResumeTestExecutable(at: crlf, shebang: "#!/bin/sh\r")
        #expect(directExecOutcome(crlf) == .exit(0))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(crlf)) != nil)

        let hashComment = root.appendingPathComponent("hash-comment")
        try writeResumeTestExecutable(at: hashComment, shebang: "#!/bin/sh#not-a-path")
        #expect(directExecOutcome(hashComment) == .exit(0))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(hashComment)) != nil)

        let line512 = root.appendingPathComponent("line-512")
        let line513 = root.appendingPathComponent("line-513")
        try writeResumeTestExecutable(
            at: line512,
            shebang: "#!/bin/sh" + String(repeating: " ", count: 502)
        )
        try writeResumeTestExecutable(
            at: line513,
            shebang: "#!/bin/sh" + String(repeating: " ", count: 503)
        )
        #expect(directExecOutcome(line512) == .exit(0))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(line512)) != nil)
        #expect(directExecOutcome(line513) == .launchError(Int(ENOEXEC)))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(line513)) == nil)

        let relative = root.appendingPathComponent("relative")
        try writeResumeTestExecutable(at: relative, shebang: "#!bin/sh")
        #expect(directExecOutcome(relative) == .launchError(Int(ENOENT)))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(relative)) == nil)

        let scriptInterpreter = root.appendingPathComponent("script-interpreter")
        let nested = root.appendingPathComponent("nested")
        try writeResumeTestExecutable(at: scriptInterpreter)
        try writeResumeTestExecutable(at: nested, shebang: "#!\(scriptInterpreter.path)")
        // XNU's IMGPF_INTERPRET permits one script activation per exec.
        #expect(directExecOutcome(nested) == .launchError(Int(ENOEXEC)))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(nested)) == nil)

        let plainInterpreter = root.appendingPathComponent("plain-interpreter")
        let plainNested = root.appendingPathComponent("plain-nested")
        try "exit 0\n".write(to: plainInterpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: plainInterpreter.path
        )
        try writeResumeTestExecutable(at: plainNested, shebang: "#!\(plainInterpreter.path)")
        #expect(directExecOutcome(plainNested) == .launchError(Int(ENOEXEC)))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(plainNested)) == nil)

        let unreadable = root.appendingPathComponent("unreadable")
        try writeResumeTestExecutable(at: unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o111],
            ofItemAtPath: unreadable.path
        )
        #expect(directExecOutcome(unreadable) == .exit(0))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(unreadable)) == nil)
    }

    @Test func envTargetScriptsCyclesAndDefensiveDepthBoundaryFailClosed() throws {
        let root = try makeShortExecutableTestRoot("cycle")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor: (URL) -> AgentCommandExecutionDescriptor = { url in
            AgentCommandExecutionDescriptor(
                executable: url.path,
                searchPath: bin.path,
                workingDirectory: root.path
            )
        }

        let target = bin.appendingPathComponent("script-target")
        let targetAgent = bin.appendingPathComponent("target-agent")
        try writeResumeTestExecutable(at: target)
        try writeResumeTestExecutable(at: targetAgent, shebang: "#!/usr/bin/env script-target")
        #expect(directExecOutcome(targetAgent, path: bin.path) == .exit(0))
        let targetResolution = try #require(
            AgentCommandExecutableResolver().resolve(descriptor(targetAgent))
        )
        try FileManager.default.removeItem(at: target)
        #expect(!AgentCommandExecutableResolver.revalidate(targetResolution))

        let a = bin.appendingPathComponent("a")
        let b = bin.appendingPathComponent("b")
        try writeResumeTestExecutable(at: a, shebang: "#!/usr/bin/env b")
        try writeResumeTestExecutable(at: b, shebang: "#!/usr/bin/env a")
        #expect(directExecOutcome(a, path: bin.path, timeout: 0.2) == .timedOut)
        #expect(AgentCommandExecutableResolver().resolve(descriptor(a)) == nil)

        let wrappers = (0...17).map { bin.appendingPathComponent("w\($0)") }
        for index in 0..<17 {
            try writeResumeTestExecutable(
                at: wrappers[index],
                shebang: "#!/usr/bin/env w\(index + 1)"
            )
        }
        try writeResumeTestExecutable(at: wrappers[17])
        // Fresh env execs have no Darwin recursion limit. The resolver accepts
        // 16 hops and conservatively rejects the 17th to bound filesystem work.
        #expect(directExecOutcome(wrappers[1], path: bin.path) == .exit(0))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(wrappers[1])) != nil)
        #expect(directExecOutcome(wrappers[0], path: bin.path) == .exit(0))
        #expect(AgentCommandExecutableResolver().resolve(descriptor(wrappers[0])) == nil)
    }

    @MainActor
    @Test func missingPATHResumeExecutableStaysHibernatedUntilPATHRecovers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-path-retry-\(UUID().uuidString)", isDirectory: true)
        let capturedBin = root.appendingPathComponent("captured-bin", isDirectory: true)
        let nonExecutableBin = root.appendingPathComponent("non-executable-bin", isDirectory: true)
        let directoryBin = root.appendingPathComponent("directory-bin", isDirectory: true)
        let brokenLinkBin = root.appendingPathComponent("broken-link-bin", isDirectory: true)
        let availableBin = root.appendingPathComponent("available-bin", isDirectory: true)
        for directory in [capturedBin, nonExecutableBin, directoryBin, brokenLinkBin, availableBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-path-resume-\(UUID().uuidString)"
        try writeResumeTestExecutable(at: capturedBin.appendingPathComponent(executableName))
        let nonExecutable = nonExecutableBin.appendingPathComponent(executableName)
        try "not executable\n".write(to: nonExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: directoryBin.appendingPathComponent(executableName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: brokenLinkBin.appendingPathComponent(executableName),
            withDestinationURL: root.appendingPathComponent("absent-target")
        )
        let unavailablePATH = [nonExecutableBin, directoryBin, brokenLinkBin]
            .map(\.path)
            .joined(separator: ":")
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "path-retry-session",
            executable: executableName,
            workingDirectory: root.path,
            launchEnvironment: ["PATH": capturedBin.path]
        )

        try withResumeExecutableEnvironment(
            root: root,
            registryURL: registryURL,
            path: unavailablePATH
        ) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let resumedWhileMissing = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(!resumedWhileMissing)
            #expect(claimOperations == 0)
            #expect(fixture.panel.isAgentHibernated)
            #expect(!fixture.panel.surface.debugInitialInputMetadata().hasInitialInput)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "hibernated")
            guard !resumedWhileMissing else { return }

            try writeResumeTestExecutable(
                at: availableBin.appendingPathComponent(executableName, isDirectory: false)
            )
            setenv("PATH", availableBin.path, 1)
            let resumedAfterPATHRepair = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(resumedAfterPATHRepair)
            #expect(claimOperations == 1)
            #expect(!fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "restoring")
        }
    }

    @MainActor
    @Test func missingAbsoluteResumeExecutableDoesNotFallBackToMatchingPATHName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-absolute-missing-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-absolute-resume-\(UUID().uuidString)"
        try writeResumeTestExecutable(at: bin.appendingPathComponent(executableName))
        let missingAbsoluteExecutable = root
            .appendingPathComponent("removed", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        try FileManager.default.createDirectory(
            at: missingAbsoluteExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: missingAbsoluteExecutable,
            withDestinationURL: root.appendingPathComponent("absent-absolute-target")
        )
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "absolute-missing-session",
            executable: missingAbsoluteExecutable.path,
            workingDirectory: root.path
        )

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: bin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let didResume = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(!didResume)
            #expect(claimOperations == 0)
            #expect(fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "hibernated")
        }
    }

    @MainActor
    @Test func missingEnvRuntimeStaysHibernatedUntilRuntimeIsInstalled() throws {
        let root = try makeShortExecutableTestRoot("env-retry")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "env-agent"
        let runtimeName = "env-runtime"
        try writeResumeTestExecutable(
            at: bin.appendingPathComponent(executableName),
            shebang: "#!/usr/bin/env \(runtimeName)"
        )
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "env-runtime-retry",
            executable: executableName,
            workingDirectory: root.path,
            launchEnvironment: ["PATH": bin.path]
        )

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: bin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            #expect(!fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            ))
            #expect(claimOperations == 0)
            #expect(fixture.panel.isAgentHibernated)

            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent(runtimeName).path,
                withDestinationPath: "/bin/sh"
            )
            #expect(fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            ))
            #expect(claimOperations == 1)
            #expect(!fixture.panel.isAgentHibernated)
        }
    }

    @MainActor
    @Test func capturedPiPATHIsTheEffectiveResumePATHAndRemainsRetryable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-captured-path-\(UUID().uuidString)", isDirectory: true)
        let capturedBin = root.appendingPathComponent("captured-bin", isDirectory: true)
        let currentBin = root.appendingPathComponent("current-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-pi-resume-\(UUID().uuidString)"
        let capturedExecutable = capturedBin.appendingPathComponent(executableName)
        try "not executable\n".write(to: capturedExecutable, atomically: true, encoding: .utf8)
        try writeResumeTestExecutable(at: currentBin.appendingPathComponent(executableName))
        let agent = resumeExecutableTestAgent(
            kind: .pi,
            sessionID: "captured-path-session",
            executable: executableName,
            workingDirectory: root.path,
            launchEnvironment: ["PATH": capturedBin.path]
        )
        #expect(agent.resumeCommand?.contains("PATH=\(capturedBin.path)") == true)

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: currentBin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let resumedThroughWrongPATH = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(!resumedThroughWrongPATH)
            #expect(claimOperations == 0)
            #expect(fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "hibernated")
            guard !resumedThroughWrongPATH else { return }

            try writeResumeTestExecutable(at: capturedExecutable)
            #expect(fixture.workspace.resumeAgentHibernation(panelId: fixture.panelID, focus: false))
            #expect(!fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "restoring")
        }
    }

    @MainActor
    @Test func missingCustomProviderResumeExecutableKeepsDurableAuthority() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-custom-missing-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-custom-resume-\(UUID().uuidString)"
        let registration = CmuxVaultAgentRegistration(
            id: "resume-preflight-vault",
            name: "Resume Preflight Vault",
            detect: CmuxVaultAgentDetectRule(processName: executableName),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --resume {{sessionId}}"
        )
        let agent = resumeExecutableTestAgent(
            kind: .custom(registration.id),
            sessionID: "custom-missing-session",
            executable: executableName,
            workingDirectory: root.path,
            registration: registration
        )

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: bin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let didResume = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(!didResume)
            #expect(claimOperations == 0)
            #expect(fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: registration.id,
                sessionID: agent.sessionId
            ) == "hibernated")
        }
    }

    @MainActor
    @Test func capturedCustomOmpPATHIsTheEffectiveResumePATH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-custom-omp-path-\(UUID().uuidString)", isDirectory: true)
        let capturedBin = root.appendingPathComponent("captured-bin", isDirectory: true)
        let currentBin = root.appendingPathComponent("current-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: capturedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-omp-resume-\(UUID().uuidString)"
        let capturedExecutable = capturedBin.appendingPathComponent(executableName)
        try "not executable\n".write(to: capturedExecutable, atomically: true, encoding: .utf8)
        try writeResumeTestExecutable(at: currentBin.appendingPathComponent(executableName))
        var registration = CmuxVaultAgentRegistration.builtInOmp
        registration.detect = CmuxVaultAgentDetectRule(processName: executableName)
        let agent = resumeExecutableTestAgent(
            kind: .custom("omp"),
            sessionID: "custom-omp-captured-path-session",
            executable: executableName,
            workingDirectory: root.path,
            registration: registration,
            launchEnvironment: ["PATH": capturedBin.path]
        )
        #expect(agent.resumeCommand?.contains("PATH=\(capturedBin.path)") == true)

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: currentBin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let resumedThroughWrongPATH = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(!resumedThroughWrongPATH)
            #expect(claimOperations == 0)
            #expect(fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "hibernated")
            guard !resumedThroughWrongPATH else { return }

            try writeResumeTestExecutable(at: capturedExecutable)
            #expect(fixture.workspace.resumeAgentHibernation(panelId: fixture.panelID, focus: false))
            #expect(!fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "restoring")
        }
    }

    @MainActor
    @Test func shellResolvedResumeExecutablePassesAvailabilityPreflight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-shell-path-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("shell resolved bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-shell-resume-\(UUID().uuidString)"
        try writeResumeTestExecutable(at: bin.appendingPathComponent(executableName))
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "shell-path-session",
            executable: executableName,
            workingDirectory: root.path
        )

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: bin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let didResume = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(didResume)
            #expect(claimOperations == 1)
            #expect(!fixture.panel.isAgentHibernated)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "restoring")
        }
    }

    @MainActor
    @Test func executableRemovedAfterAuthorityClaimRollsBackToHibernated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-post-claim-removal-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let executableName = "cmux-post-claim-resume-\(UUID().uuidString)"
        let executable = bin.appendingPathComponent(executableName, isDirectory: false)
        try writeResumeTestExecutable(at: executable)
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "post-claim-removal-session",
            executable: executableName,
            workingDirectory: root.path
        )

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: bin.path) {
            let fixture = try makeRestoredResumeExecutableFixture(
                root: root,
                registryURL: registryURL,
                agent: agent
            )
            var claimOperations = 0
            let didResume = fixture.workspace.resumeVisibleAgentHibernationPanels(
                panelIds: [fixture.panelID],
                retryPendingAdoptions: false,
                authorityClaimHandler: { requests in
                    claimOperations += 1
                    try? FileManager.default.removeItem(at: executable)
                    return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
                }
            )

            #expect(!didResume)
            #expect(claimOperations == 1)
            #expect(fixture.panel.isAgentHibernated)
            #expect(!fixture.panel.surface.debugInitialInputMetadata().hasInitialInput)
            #expect(try durableSessionState(
                fixture.registry,
                provider: agent.kind.rawValue,
                sessionID: agent.sessionId
            ) == "hibernated")
            guard !didResume else { return }

            try writeResumeTestExecutable(at: executable)
            #expect(fixture.workspace.resumeAgentHibernation(panelId: fixture.panelID, focus: false))
            #expect(!fixture.panel.isAgentHibernated)
        }
    }

    @MainActor
    @Test func missingExecutableRejectsLiveHibernationBeforeValidationOrAuthorityCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-live-hibernation-missing-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingExecutable = root.appendingPathComponent("missing-agent", isDirectory: false)
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "live-hibernation-missing-executable",
            executable: missingExecutable.path,
            workingDirectory: root.path
        )
        let workspace = Workspace(workingDirectory: root.path)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let runtimeSurface = UnsafeMutableRawPointer(bitPattern: 0x78670001)!
        panel.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let validationCalled = AtomicBooleanGate(false)
        let teardownPreparationCalled = AtomicBooleanGate(false)
        let authorityCommitCalled = AtomicBooleanGate(false)
        let nativeFreeCalled = AtomicBooleanGate(false)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            nativeFreeCalled.storeRelease(true)
        }
        defer {
            if panel.surface.surface == runtimeSurface {
                panel.surface.teardownSurface()
            }
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        let didHibernate = await panel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            finalValidation: {
                validationCalled.storeRelease(true)
                return true
            },
            finalTeardownPreparation: {
                teardownPreparationCalled.storeRelease(true)
                return {}
            },
            finalCommit: {
                authorityCommitCalled.storeRelease(true)
                return true
            }
        )

        #expect(!didHibernate)
        #expect(!panel.isAgentHibernated)
        #expect(panel.surface.surface == runtimeSurface)
        #expect(!validationCalled.loadAcquire())
        #expect(!teardownPreparationCalled.loadAcquire())
        #expect(!authorityCommitCalled.loadAcquire())
        #expect(!nativeFreeCalled.loadAcquire())
    }

    @MainActor
    @Test func shebangInterpreterRemovedDuringValidationRejectsLiveHibernationBeforeFinalTeardown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-live-hibernation-executable-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("agent", isDirectory: false)
        let interpreter = root.appendingPathComponent("runtime", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: interpreter.path, withDestinationPath: "/bin/sh")
        try writeResumeTestExecutable(at: executable, shebang: "#!\(interpreter.path)")
        let agent = resumeExecutableTestAgent(
            kind: .amp,
            sessionID: "live-hibernation-executable-race",
            executable: executable.path,
            workingDirectory: root.path
        )
        let workspace = Workspace(workingDirectory: root.path)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let runtimeSurface = UnsafeMutableRawPointer(bitPattern: 0x78670002)!
        panel.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let validationCalled = AtomicBooleanGate(false)
        let teardownPreparationCalled = AtomicBooleanGate(false)
        let authorityCommitCalled = AtomicBooleanGate(false)
        let nativeFreeCalled = AtomicBooleanGate(false)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            nativeFreeCalled.storeRelease(true)
        }
        defer {
            if panel.surface.surface == runtimeSurface {
                panel.surface.teardownSurface()
            }
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        let didHibernate = await panel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            finalValidation: {
                validationCalled.storeRelease(true)
                try? FileManager.default.removeItem(at: interpreter)
                return true
            },
            finalTeardownPreparation: {
                teardownPreparationCalled.storeRelease(true)
                return {}
            },
            finalCommit: {
                authorityCommitCalled.storeRelease(true)
                return true
            }
        )

        #expect(!didHibernate)
        #expect(!panel.isAgentHibernated)
        #expect(panel.surface.surface == runtimeSurface)
        #expect(validationCalled.loadAcquire())
        #expect(!teardownPreparationCalled.loadAcquire())
        #expect(!authorityCommitCalled.loadAcquire())
        #expect(!nativeFreeCalled.loadAcquire())
    }

    @MainActor
    @Test func missingExecutableOrdinaryAutoRestoreFallsBackToManualResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-auto-restore-missing-executable-\(UUID().uuidString)", isDirectory: true)
        let emptyBin = root.appendingPathComponent("empty-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let defaultsSuite = "cmux-auto-restore-missing-executable-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let executableName = "cmux-auto-restore-\(UUID().uuidString)"
        let agent = resumeExecutableTestAgent(
            kind: .grok,
            sessionID: "ordinary-auto-restore-session",
            executable: executableName,
            workingDirectory: root.path
        )
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminal = try #require(snapshot.panels[panelIndex].terminal)
        terminal.agent = agent
        terminal.resumeBinding = nil
        terminal.hibernation = nil
        terminal.wasAgentRunning = true
        terminal.scrollback = "saved output that must remain visible"
        snapshot.panels[panelIndex].terminal = terminal
        var breadcrumbs: [[StartupBreadcrumbEvent]] = []

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: emptyBin.path) {
            let restored = Workspace(
                agentSessionAutoResumeDefaults: defaults,
                startupBreadcrumbBatchWriter: { breadcrumbs.append($0) }
            )
            let mapping = restored.restoreSessionSnapshot(snapshot)
            let panelID = try #require(mapping[sourcePanelID])
            let panel = try #require(restored.terminalPanel(for: panelID))

            #expect(panel.surface.debugInitialCommand() == nil)
            #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
            #expect(restored.restoredAgentSnapshotForTesting(panelId: panelID)?.sessionId == agent.sessionId)
            #expect(restored.restoredAgentResumeStatesByPanelId[panelID] == .manualResumeAvailable)
            let restoredPanel = try #require(
                restored.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelID }
            )
            #expect(restoredPanel.terminal?.agent?.sessionId == agent.sessionId)
            let event = try #require(breadcrumbs.flatMap { $0 }.first {
                $0.fields["panel"] == String(sourcePanelID.uuidString.lowercased().prefix(8))
            })
            #expect(event.fields["resume"] == "suppressed")
            #expect(event.fields["resumeReason"] == "resume_executable_unavailable")
        }
    }

    @Test func cwdIgnoredCommandsFailClosedWhenExecutableLookupDependsOnUnknownCWD() throws {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let upwardComponents = Array(
            repeating: "..",
            count: max(0, currentDirectory.pathComponents.count - 1)
        )
        let relativeSystemShell = (upwardComponents + ["bin", "sh"]).joined(separator: "/")
        var registration = CmuxVaultAgentRegistration.builtInOmp
        registration.cwd = .ignore
        let relativeExecutableAgent = resumeExecutableTestAgent(
            kind: .custom("omp"),
            sessionID: "cwd-ignore-relative-executable",
            executable: relativeSystemShell,
            workingDirectory: "/tmp/ignored-launch-cwd",
            registration: registration,
            launchEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        let relativeDescriptor = try #require(relativeExecutableAgent.resumeExecutionDescriptor)
        #expect(relativeDescriptor.workingDirectory == nil)
        #expect(AgentCommandExecutableResolver().resolve(relativeDescriptor) == nil)

        let emptyPATHAgent = resumeExecutableTestAgent(
            kind: .custom("omp"),
            sessionID: "cwd-ignore-empty-path-entry",
            executable: "sh",
            workingDirectory: "/tmp/ignored-launch-cwd",
            registration: registration,
            launchEnvironment: ["PATH": ":/usr/bin"]
        )
        let emptyPATHDescriptor = try #require(emptyPATHAgent.resumeExecutionDescriptor)
        #expect(emptyPATHDescriptor.workingDirectory == nil)
        #expect(emptyPATHDescriptor.searchPath == ":/usr/bin")
        #expect(AgentCommandExecutableResolver().resolve(emptyPATHDescriptor) == nil)
    }

    @Test func bindingPreflightMirrorsPortableWrapperFallbackWithoutGeneralAbsoluteFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-binding-wrapper-preflight-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bareCodex = bin.appendingPathComponent("codex", isDirectory: false)
        let bareAmp = bin.appendingPathComponent("amp", isDirectory: false)
        let bareClaude = bin.appendingPathComponent("claude", isDirectory: false)
        try writeResumeTestExecutable(at: bareCodex)
        try writeResumeTestExecutable(at: bareAmp)
        try writeResumeTestExecutable(at: bareClaude)

        let staleCodex = root
            .appendingPathComponent("removed", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        let codexBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(staleCodex.path)' 'resume' 'binding-codex-session'",
            cwd: root.path,
            checkpointId: "binding-codex-session",
            source: "agent-hook",
            environment: ["PATH": bin.path],
            autoResume: true
        )
        let codexDescriptor = try #require(codexBinding.agentHookExecutionDescriptor)
        #expect(codexDescriptor.executable == staleCodex.path)
        #expect(codexDescriptor.fallbackExecutables == ["codex"])
        #expect(AgentCommandExecutableResolver().resolve(codexDescriptor)?.lookupPath == bareCodex.path)

        let staleAmp = root
            .appendingPathComponent("removed", isDirectory: true)
            .appendingPathComponent("amp", isDirectory: false)
        let ampBinding = SurfaceResumeBindingSnapshot(
            kind: "amp",
            command: "'\(staleAmp.path)' 'threads' 'continue' 'binding-amp-session'",
            cwd: root.path,
            checkpointId: "binding-amp-session",
            source: "agent-hook",
            environment: ["PATH": bin.path],
            autoResume: true
        )
        let ampDescriptor = try #require(ampBinding.agentHookExecutionDescriptor)
        #expect(ampDescriptor.executable == staleAmp.path)
        #expect(ampDescriptor.fallbackExecutables.isEmpty)
        #expect(AgentCommandExecutableResolver().resolve(ampDescriptor) == nil)

        let managedClaude = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude", isDirectory: false)
        let claudeBinding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'\(managedClaude.path)' '--resume' 'binding-claude-session'",
            cwd: root.path,
            checkpointId: "binding-claude-session",
            source: "agent-hook",
            environment: ["PATH": bin.path],
            autoResume: true
        )
        let claudeDescriptor = try #require(claudeBinding.agentHookExecutionDescriptor)
        if claudeDescriptor.executable == "claude" {
            #expect(claudeDescriptor.fallbackExecutables.isEmpty)
        } else {
            #expect(claudeDescriptor.fallbackExecutables == ["claude"])
        }
        #expect(AgentCommandExecutableResolver().resolve(claudeDescriptor) != nil)
    }

    @MainActor
    @Test func unavailableWinningAgentHookBindingSuppressesSnapshotAndBindingOnlyAutoResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-binding-executable-unavailable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let availableSnapshotExecutable = root.appendingPathComponent("available-amp", isDirectory: false)
        try writeResumeTestExecutable(at: availableSnapshotExecutable)
        let missingBindingExecutable = root.appendingPathComponent("missing-amp", isDirectory: false)
        let defaultsSuite = "cmux-binding-executable-unavailable-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        for includesSnapshot in [true, false] {
            let sessionID = includesSnapshot
                ? "stale-snapshot-binding-session"
                : "binding-only-missing-session"
            let source = Workspace(agentSessionAutoResumeDefaults: defaults)
            let sourcePanelID = try #require(source.focusedPanelId)
            var snapshot = source.sessionSnapshot(includeScrollback: false)
            let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
            var terminal = try #require(snapshot.panels[panelIndex].terminal)
            if includesSnapshot {
                terminal.agent = resumeExecutableTestAgent(
                    kind: .amp,
                    sessionID: sessionID,
                    executable: availableSnapshotExecutable.path,
                    workingDirectory: root.path
                )
            } else {
                terminal.agent = nil
            }
            terminal.resumeBinding = SurfaceResumeBindingSnapshot(
                name: "Amp",
                kind: "amp",
                command: "'\(missingBindingExecutable.path)' 'threads' 'continue' '\(sessionID)'",
                cwd: root.path,
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 20
            )
            terminal.hibernation = nil
            terminal.wasAgentRunning = true
            terminal.scrollback = "saved binding output"
            snapshot.panels[panelIndex].terminal = terminal
            var breadcrumbs: [[StartupBreadcrumbEvent]] = []

            let restored = Workspace(
                agentSessionAutoResumeDefaults: defaults,
                startupBreadcrumbBatchWriter: { breadcrumbs.append($0) }
            )
            let mapping = restored.restoreSessionSnapshot(snapshot)
            let panelID = try #require(mapping[sourcePanelID])
            let panel = try #require(restored.terminalPanel(for: panelID))
            #expect(panel.surface.debugInitialCommand() == nil, Comment(rawValue: sessionID))
            #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput, Comment(rawValue: sessionID))
            let persistedTerminal = try #require(
                restored.sessionSnapshot(includeScrollback: false)
                    .panels.first { $0.id == panelID }?.terminal
            )
            #expect(
                persistedTerminal.resumeBinding?.command.contains(missingBindingExecutable.path) == true,
                Comment(rawValue: sessionID)
            )
            #expect(
                (restored.restoredAgentSnapshotForTesting(panelId: panelID) != nil) == includesSnapshot,
                Comment(rawValue: sessionID)
            )
            let event = try #require(breadcrumbs.flatMap { $0 }.first {
                $0.fields["panel"] == String(sourcePanelID.uuidString.lowercased().prefix(8))
            })
            #expect(event.fields["resume"] == "suppressed", Comment(rawValue: sessionID))
            #expect(
                event.fields["resumeReason"] == "resume_executable_unavailable",
                Comment(rawValue: sessionID)
            )
        }
    }

    @MainActor
    @Test func registryOwnedCustomProviderBindingsSurviveRoundTripAndClaimExactAuthority() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registry-provider-binding-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let ollama = CmuxVaultAgentRegistration(
            id: "ollama",
            name: "Ollama",
            detect: CmuxVaultAgentDetectRule(processName: "ollama"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            forkCommand: "{{executable}} --fork {{sessionId}}"
        )
        var registrations = [
            CmuxVaultAgentRegistration.builtInPi,
            CmuxVaultAgentRegistration.builtInGrok,
            CmuxVaultAgentRegistration.builtInAntigravity,
            ollama,
        ]

        try withResumeExecutableEnvironment(root: root, registryURL: registryURL, path: bin.path) {
            for index in registrations.indices {
                let provider = registrations[index].id
                let executable = bin.appendingPathComponent("\(provider)-resume", isDirectory: false)
                try writeResumeTestExecutable(at: executable)
                registrations[index].detect = CmuxVaultAgentDetectRule(processName: executable.lastPathComponent)
                let workingDirectory = root.appendingPathComponent("\(provider)-working", isDirectory: true)
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                var agent = resumeExecutableTestAgent(
                    kind: .custom(provider),
                    sessionID: "registry-owned-\(provider)-session",
                    executable: executable.path,
                    workingDirectory: workingDirectory.path,
                    registration: registrations[index]
                )
                if provider == "grok" { agent.launchCommand?.executablePath = nil }
                let fixture = try makeHibernatedRestoreFixture(root: root, agent: agent)
                var snapshot = fixture.snapshot
                let sourcePanelIndex = try #require(
                    snapshot.panels.firstIndex { $0.id == fixture.sourcePanelID }
                )
                var sourceTerminal = try #require(snapshot.panels[sourcePanelIndex].terminal)
                var sourceBinding = try #require(sourceTerminal.resumeBinding)
                sourceBinding.kind = "  \(provider) \n"
                sourceBinding.cwd = nil
                sourceTerminal.resumeBinding = sourceBinding
                snapshot.panels[sourcePanelIndex].terminal = sourceTerminal
                let decoded = try JSONDecoder().decode(
                    SessionWorkspaceSnapshot.self,
                    from: JSONEncoder().encode(snapshot)
                )
                let decodedAgent = try #require(decoded.panels[sourcePanelIndex].terminal?.agent)
                #expect(decodedAgent.kind == .custom(provider), Comment(rawValue: provider))
                _ = try installHibernatedAuthority(
                    root: root,
                    registryURL: registryURL,
                    agent: decodedAgent,
                    workspaceId: fixture.source.id,
                    surfaceId: fixture.sourcePanelID
                )

                let restored = Workspace()
                let mapping = restored.restoreSessionSnapshot(decoded)
                let panelID = try #require(mapping[fixture.sourcePanelID])
                let panel = try #require(restored.terminalPanel(for: panelID))
                #expect(panel.isAgentHibernated, Comment(rawValue: provider))
                let persisted = try #require(
                    restored.sessionSnapshot(includeScrollback: false)
                        .panels.first { $0.id == panelID }?.terminal
                )
                #expect(persisted.agent?.kind == .custom(provider), Comment(rawValue: provider))
                #expect(persisted.resumeBinding?.kind?.trimmingCharacters(in: .whitespacesAndNewlines) == provider)
                #expect(persisted.resumeBinding?.cwd == workingDirectory.path, Comment(rawValue: provider))

                var claimedKinds: [RestorableAgentKind] = []
                let didResume = restored.resumeVisibleAgentHibernationPanels(
                    panelIds: [panelID],
                    retryPendingAdoptions: false,
                    authorityClaimHandler: { requests in
                        claimedKinds.append(contentsOf: requests.map(\.agent.kind))
                        return Dictionary(uniqueKeysWithValues: requests.map {
                            ($0.surfaceId, .unavailable)
                        })
                    }
                )
                #expect(!didResume)
                #expect(claimedKinds == [.custom(provider)], Comment(rawValue: provider))
                #expect(panel.isAgentHibernated)
            }

            var mismatchedAgent = resumeExecutableTestAgent(
                kind: .custom("pi"),
                sessionID: "registry-provider-mismatch",
                executable: bin.appendingPathComponent("pi-resume").path,
                workingDirectory: root.path,
                registration: CmuxVaultAgentRegistration.builtInPi
            )
            mismatchedAgent.registration = CmuxVaultAgentRegistration.builtInPi
            let mismatchFixture = try makeHibernatedRestoreFixture(root: root, agent: mismatchedAgent)
            var mismatchSnapshot = mismatchFixture.snapshot
            let mismatchIndex = try #require(
                mismatchSnapshot.panels.firstIndex { $0.id == mismatchFixture.sourcePanelID }
            )
            var mismatchTerminal = try #require(mismatchSnapshot.panels[mismatchIndex].terminal)
            mismatchTerminal.resumeBinding?.kind = "grok"
            mismatchSnapshot.panels[mismatchIndex].terminal = mismatchTerminal
            let decodedMismatch = try JSONDecoder().decode(
                SessionWorkspaceSnapshot.self,
                from: JSONEncoder().encode(mismatchSnapshot)
            )
            let rejected = Workspace()
            let rejectedMapping = rejected.restoreSessionSnapshot(decodedMismatch)
            let rejectedPanelID = try #require(rejectedMapping[mismatchFixture.sourcePanelID])
            let rejectedPanel = try #require(rejected.terminalPanel(for: rejectedPanelID))
            #expect(!rejectedPanel.isAgentHibernated)
            #expect(rejected.restoredAgentSnapshotForTesting(panelId: rejectedPanelID) == nil)
            let rejectedSnapshot = try #require(
                rejected.sessionSnapshot(includeScrollback: false)
                    .panels.first { $0.id == rejectedPanelID }?.terminal
            )
            #expect(rejectedSnapshot.agent == nil)
        }
    }

    @Test func configuredAntigravityResumeTemplateOwnsRegistrySnapshotSemantics() throws {
        var registration = CmuxVaultAgentRegistration.builtInAntigravity
        registration.name = "Project Antigravity"
        registration.resumeCommand = "{{executable}} --project-resume {{sessionId}}"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("antigravity"),
            sessionId: "configured-antigravity-session",
            workingDirectory: "/tmp/configured-antigravity",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "antigravity",
                executablePath: "/opt/bin/agy",
                arguments: ["/opt/bin/agy", "--model", "configured-model"],
                workingDirectory: "/tmp/configured-antigravity",
                environment: nil,
                capturedAt: 10,
                source: "agent-hook"
            ),
            registration: registration
        )

        #expect(
            snapshot.resumeCommand == TerminalStartupWorkingDirectoryPrefix.prefix(
                "'/opt/bin/agy' '--project-resume' 'configured-antigravity-session'",
                workingDirectory: "/tmp/configured-antigravity"
            )
        )
    }

    @MainActor
    private func makeHibernatedRestoreFixture(
        root: URL,
        sessionID: String
    ) throws -> (
        source: Workspace,
        snapshot: SessionWorkspaceSnapshot,
        sourcePanelID: UUID,
        agent: SessionRestorableAgentSnapshot
    ) {
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 10,
                source: "agent-hook"
            )
        )
        return try makeHibernatedRestoreFixture(root: root, agent: agent)
    }

    @MainActor
    private func makeHibernatedRestoreFixture(
        root: URL,
        agent: SessionRestorableAgentSnapshot
    ) throws -> (
        source: Workspace,
        snapshot: SessionWorkspaceSnapshot,
        sourcePanelID: UUID,
        agent: SessionRestorableAgentSnapshot
    ) {
        let sessionID = agent.sessionId
        let source = Workspace()
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourcePaneID = try #require(source.paneId(forPanelId: sourcePanelID))
        _ = try #require(source.newTerminalSurface(inPane: sourcePaneID, focus: true))
        source.focusPanel(sourcePanelID)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminal = try #require(snapshot.panels[panelIndex].terminal)
        terminal.agent = agent
        terminal.resumeBinding = SurfaceResumeBindingSnapshot(
            kind: agent.kind.rawValue,
            command: try #require(agent.resumeCommand),
            cwd: root.path,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: false,
            updatedAt: 20
        )
        terminal.hibernation = SessionAgentHibernationSnapshot(
            hibernatedAt: 20,
            lastActivityAt: 10
        )
        terminal.wasAgentRunning = true
        snapshot.panels[panelIndex].terminal = terminal
        return (
            source: source,
            snapshot: snapshot,
            sourcePanelID: sourcePanelID,
            agent: agent
        )
    }

    private func installHibernatedAuthority(
        root: URL,
        registryURL: URL,
        agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        surfaceId: UUID,
        runtime: [String: Any]? = nil
    ) throws -> CmuxAgentSessionRegistry {
        let runtime = runtime ?? provablyDeadRuntime(
            id: "retired-\(agent.kind.rawValue)-runtime"
        )
        let activeSlot: [String: Any] = [
            "sessionId": agent.sessionId,
            "updatedAt": 20.0,
        ]
        var record: [String: Any] = [
            "sessionId": agent.sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": surfaceId.uuidString,
            "sessionState": "hibernated",
            "restoreAuthority": true,
            "startedAt": 10.0,
            "updatedAt": 20.0,
        ]
        record["activeRunId"] = "restored-run"
        record["cmuxRuntime"] = runtime
        record["runs"] = [[
            "runId": "restored-run",
            "restoreAuthority": true,
            "cmuxRuntime": runtime,
            "startedAt": 10.0,
            "updatedAt": 20.0,
        ]]
        let stateURL = agent.kind.hookStoreFileURL(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        )
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [agent.sessionId: record],
            "activeSessionsByWorkspace": [workspaceId.uuidString: activeSlot],
            "activeSessionsBySurface": [surfaceId.uuidString: activeSlot],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        _ = try registry.snapshotImportingLegacy(
            provider: agent.kind.rawValue,
            legacyURL: stateURL,
            fileManager: .default
        )
        return registry
    }

    private func resumeExecutableTestAgent(
        kind: RestorableAgentKind,
        sessionID: String,
        executable: String,
        workingDirectory: String,
        registration: CmuxVaultAgentRegistration? = nil,
        launchEnvironment: [String: String]? = nil
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: kind.customAgentID == nil ? kind.rawValue : nil,
                executablePath: executable,
                arguments: [executable],
                workingDirectory: workingDirectory,
                environment: launchEnvironment,
                capturedAt: 10,
                source: "agent-hook"
            ),
            registration: registration
        )
    }

    @MainActor
    private func makeRestoredResumeExecutableFixture(
        root: URL,
        registryURL: URL,
        agent: SessionRestorableAgentSnapshot
    ) throws -> (
        workspace: Workspace,
        panelID: UUID,
        panel: TerminalPanel,
        registry: CmuxAgentSessionRegistry
    ) {
        let source = try makeHibernatedRestoreFixture(root: root, agent: agent)
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: agent,
            workspaceId: source.source.id,
            surfaceId: source.sourcePanelID
        )
        let workspace = Workspace()
        let mapping = workspace.restoreSessionSnapshot(source.snapshot)
        let panelID = try #require(mapping[source.sourcePanelID])
        let panel = try #require(workspace.terminalPanel(for: panelID))
        #expect(panel.isAgentHibernated)
        return (workspace, panelID, panel, registry)
    }

    @MainActor
    private func withResumeExecutableEnvironment<T>(
        root: URL,
        registryURL: URL,
        path: String,
        body: () throws -> T
    ) throws -> T {
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "resume-executable-preflight-runtime",
            "PATH": path,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return try body()
    }

    private enum DirectExecOutcome: Equatable {
        case exit(Int32)
        case launchError(Int)
        case timedOut
    }

    private func makeShortExecutableTestRoot(_ label: String) throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cx-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func directExecOutcome(
        _ executable: URL,
        path: String = "/usr/bin:/bin",
        timeout: TimeInterval = 1
    ) -> DirectExecOutcome {
        let process = Process()
        process.executableURL = executable
        process.environment = ["PATH": path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .launchError((error as NSError).code)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard process.isRunning else { return .exit(process.terminationStatus) }
        process.terminate()
        process.waitUntilExit()
        return .timedOut
    }

    private func writeResumeTestExecutable(
        at url: URL,
        shebang: String = "#!/bin/sh"
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(shebang)\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func durableSessionState(
        _ registry: CmuxAgentSessionRegistry,
        provider: String,
        sessionID: String
    ) throws -> String? {
        let snapshot = try registry.snapshot(provider: provider)
        let record = try #require(snapshot.records.first { $0.sessionID == sessionID })
        let object = try #require(
            JSONSerialization.jsonObject(with: record.json) as? [String: Any]
        )
        return object["sessionState"] as? String
    }

    private func provablyDeadRuntime(id: String) -> [String: Any] {
        [
            "id": id,
            "processId": Int(Int32.max),
            "processStartSeconds": 1,
            "processStartMicroseconds": 1,
        ]
    }

}

extension WorkspaceForkConversationContextMenuTests {
    @Test
    func localForkAvailabilityTracksMissingAndRepairedExecutableForEveryCommandShape() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fork-executable-availability-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let customRegistration = CmuxVaultAgentRegistration(
            id: "fork-executable-vault",
            name: "Fork Executable Vault",
            detect: CmuxVaultAgentDetectRule(processName: "vault-fork"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            forkCommand: "{{executable}} --fork {{sessionId}}"
        )
        let grokExecutable = bin.appendingPathComponent("grok-fork", isDirectory: false)
        let vaultExecutable = bin.appendingPathComponent("vault-fork", isDirectory: false)
        let cases: [(name: String, snapshot: SessionRestorableAgentSnapshot, executable: URL)] = [
            (
                "native-grok",
                SessionRestorableAgentSnapshot(
                    kind: .grok,
                    sessionId: "missing-grok-fork",
                    workingDirectory: root.path,
                    launchCommand: AgentLaunchCommandSnapshot(
                        launcher: "grok",
                        executablePath: grokExecutable.path,
                        arguments: [grokExecutable.path],
                        workingDirectory: root.path,
                        environment: nil,
                        capturedAt: 123,
                        source: "process"
                    )
                ),
                grokExecutable
            ),
            (
                "custom-vault",
                SessionRestorableAgentSnapshot(
                    kind: .custom(customRegistration.id),
                    sessionId: "missing-custom-fork",
                    workingDirectory: root.path,
                    launchCommand: AgentLaunchCommandSnapshot(
                        launcher: customRegistration.id,
                        executablePath: vaultExecutable.path,
                        arguments: [vaultExecutable.path],
                        workingDirectory: root.path,
                        environment: nil,
                        capturedAt: 123,
                        source: "process"
                    ),
                    registration: customRegistration
                ),
                vaultExecutable
            ),
        ]

        for testCase in cases {
            #expect(
                !(await AgentForkSupport.supportsFork(snapshot: testCase.snapshot)),
                Comment(rawValue: testCase.name)
            )
            #expect(
                AgentForkSupport.forkValidationExecutableIdentity(snapshot: testCase.snapshot) == nil,
                Comment(rawValue: testCase.name)
            )
            #expect(
                await AgentForkSupport.supportsFork(
                    snapshot: testCase.snapshot,
                    isRemoteContext: true
                ),
                "Explicit remote contexts must not be rejected by local filesystem availability: \(testCase.name)"
            )

            let runtimeName = "\(testCase.name)-runtime"
            let runtime = bin.appendingPathComponent(runtimeName)
            try writeAgentAvailabilityTestExecutable(
                at: testCase.executable,
                shebang: "#!/usr/bin/env \(runtimeName)"
            )

            #expect(
                !(await AgentForkSupport.supportsFork(snapshot: testCase.snapshot)),
                "The wrapper alone must not hide its missing runtime: \(testCase.name)"
            )
            try fileManager.createSymbolicLink(atPath: runtime.path, withDestinationPath: "/bin/sh")

            #expect(
                await AgentForkSupport.supportsFork(snapshot: testCase.snapshot),
                Comment(rawValue: testCase.name)
            )
            #expect(
                AgentForkSupport.forkValidationExecutableIdentity(snapshot: testCase.snapshot) != nil,
                "Installing the executable must change the validation identity immediately: \(testCase.name)"
            )
            try fileManager.removeItem(at: runtime)
            #expect(
                !(await AgentForkSupport.supportsFork(snapshot: testCase.snapshot)),
                "Removing only the shebang runtime must disable fork: \(testCase.name)"
            )
        }
    }

}

private func writeAgentAvailabilityTestExecutable(
    at url: URL,
    shebang: String = "#!/bin/sh"
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "\(shebang)\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}
