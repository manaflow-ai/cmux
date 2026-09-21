import CmuxControlSocket
import CmuxFoundation
@testable import CmuxComputerUse
import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use onboarding admission")
struct ComputerUseOnboardingAdmissionTests {
    @Test(arguments: ComputerUseDaemonProfile.allCases) @MainActor
    func grantRecheckUsesTheControlProtocolForBothProfiles(profile: ComputerUseDaemonProfile) async throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let socket = ComputerUseRuntimeService.socketURL(for: profile, paths: fixture.paths)
        let responder = try UnixSocketResponder(
            path: socket.path,
            response: #"{"ok":true,"result":{"accessibility":true,"screen_recording":true,"source":{"attribution":"driver-daemon"}}}"#
        )
        defer { responder.stop() }
        let service = ComputerUseDaemonAdmissionService(paths: fixture.paths, transport: SocketTransport())
        let peer = try #require(AgentPIDProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier))
        let status = try #require(await service.permissionStatus(at: socket, peer: peer))
        #expect(status.accessibility && status.screenRecording && status.helperOwnsPermissions)
        let received = try #require(responder.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(
            with: Data(received.utf8)
        ) as? [String: Any])
        let request = try #require(envelope["request"] as? [String: Any])
        #expect(request["method"] as? String == "permissions_status")
        #expect(envelope["host_auth_token"] as? String == "synthetic-host-capability")
    }

    @Test func completionAfterDisableCannotAuthorizeTheNextEnable() {
        var phase = ComputerUseRuntimePermissionPhase.disabled(onboardingComplete: false)
        phase = phase.applying(.setEnabled(true))
        phase = phase.applying(.onboardingPresented)
        phase = phase.applying(.setEnabled(false))

        // A capture response can arrive after the user disables Computer Use.
        // That obsolete response must not become consent for a later launch.
        phase = phase.applying(.onboardingCompleted)
        #expect(phase == .disabled(onboardingComplete: false))
        #expect(phase.applying(.setEnabled(true)) == .onboardingRequired)
    }

    @Test @MainActor func grantedPermissionsAndEmptyStateNeedVerifiedHostAdmission() async throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper")
        try FileManager.default.createDirectory(at: fixture.paths.stateDirectoryURL, withIntermediateDirectories: true)
        let peer = try #require(AgentPIDProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier))
        let replies = [
            #"{"ok":true,"result":{"external_permission_ready":false}}"#,
            #"{"ok":true,"result":{"capturable":true}}"#,
            #"{"ok":true,"result":{"external_permission_ready":true}}"#,
        ]
        let granted = #"{"ok":true,"result":{"structuredContent":{"accessibility":true,"screen_recording":true,"source":{"attribution":"driver-daemon"}}}}"#
        let native = try UnixSocketResponder(path: fixture.paths.daemonSocketURL.path, responses: [granted] + replies)
        let codex = try UnixSocketResponder(path: fixture.paths.codexDaemonSocketURL.path, responses: replies)
        defer { native.stop(); codex.stop() }
        let admission = ComputerUseDaemonAdmissionService(paths: fixture.paths, transport: SocketTransport())
        let sockets = [fixture.paths.daemonSocketURL, fixture.paths.codexDaemonSocketURL]
        let status = try #require(await ComputerUseRuntimeService.queryPermissionStatus(
            paths: fixture.paths, transport: SocketTransport(), expectedPeerIdentity: peer
        ))
        #expect(status.helperOwnsPermissions)
        #expect(ComputerUseSetupStatus(
            enabled: true, helperAvailable: status.isKnown, accessibilityGranted: status.accessibility,
            screenRecordingGranted: status.screenRecording, captureVerified: store.phase.isReady
        ) == .captureConfirmationRequired)
        for socket in sockets {
            #expect(await admission.publish(phase: store.phase, enabled: true, to: socket, peer: peer))
        }

        let attempt = try #require(store.beginVerification())
        let verification = await ComputerUseRuntimeService.verifyDirectScreenCaptureOutcomes(
            paths: fixture.paths,
            expectedPeerIdentities: [.native: peer, .codexCompatibility: peer]
        )
        #expect(store.finishVerification(verification, attempt: attempt) == .ready)
        for socket in sockets {
            #expect(await admission.publish(phase: store.phase, enabled: true, to: socket, peer: peer))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.stateDirectoryURL.path).isEmpty)
        for responder in [native, codex] {
            let envelopes = try responder.receivedRequests.suffix(3).map { line in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
            #expect(envelopes.count == 3)
            for envelope in envelopes {
                #expect(envelope["auth_token"] as? String == "synthetic-agent-capability")
                #expect(envelope["host_auth_token"] as? String == "synthetic-host-capability")
            }
            let before = try #require(envelopes.first?["request"] as? [String: Any])
            let after = try #require(envelopes.last?["request"] as? [String: Any])
            #expect((before["args"] as? [String: Any])?["ready"] as? Bool == false)
            #expect((after["args"] as? [String: Any])?["ready"] as? Bool == true)
        }
    }

    @Test @MainActor func unavailableDaemonDoesNotBecomeAnOnboardingDenial() async throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let peer = try #require(AgentPIDProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier))
        let result = await ComputerUseRuntimeService.verifyDirectScreenCaptureOutcomes(
            paths: fixture.paths,
            expectedPeerIdentities: [.native: peer, .codexCompatibility: peer]
        )
        #expect(result == .unavailable)
        #expect(ComputerUseSetupStatus(
            enabled: true, helperAvailable: false, accessibilityGranted: true,
            screenRecordingGranted: true, captureVerified: true
        ) == .unavailable)
        let admission = ComputerUseDaemonAdmissionService(paths: fixture.paths, transport: SocketTransport())
        #expect(!(await admission.publish(phase: .ready, enabled: true, to: fixture.paths.daemonSocketURL, peer: peer)))
    }

    @Test @MainActor func disabledHostPublishesFalseEvenWithPriorCompletion() async throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let peer = try #require(AgentPIDProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier))
        let responder = try UnixSocketResponder(
            path: fixture.paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"external_permission_ready":false}}"#
        )
        defer { responder.stop() }
        let admission = ComputerUseDaemonAdmissionService(paths: fixture.paths, transport: SocketTransport())
        #expect(await admission.publish(
            phase: .disabled(onboardingComplete: true), enabled: false,
            to: fixture.paths.daemonSocketURL, peer: peer
        ))
        let received = try #require(responder.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(
            with: Data(received.utf8)
        ) as? [String: Any])
        let request = try #require(envelope["request"] as? [String: Any])
        #expect((request["args"] as? [String: Any])?["ready"] as? Bool == false)
    }

    @Test(arguments: [true, false]) @MainActor
    func partialPublicationWithdrawsBothProfilesOrStopsThem(acknowledgesWithdrawal: Bool) async throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper")
        let peer = try #require(AgentPIDProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier))
        let admitted = #"{"ok":true,"result":{"external_permission_ready":true}}"#
        let withdrawn = #"{"ok":true,"result":{"external_permission_ready":false}}"#
        let rejected = #"{"ok":false,"error":"synthetic failure"}"#
        let native = try UnixSocketResponder(path: fixture.paths.daemonSocketURL.path, responses: [admitted, withdrawn])
        let codex = try UnixSocketResponder(
            path: fixture.paths.codexDaemonSocketURL.path,
            responses: [rejected, acknowledgesWithdrawal ? withdrawn : rejected]
        )
        defer { native.stop(); codex.stop() }
        let service = ComputerUseDaemonAdmissionService(paths: fixture.paths, transport: SocketTransport())
        var stopped = false
        let admission = ComputerUseOnboardingAdmissionCoordinator(
            store: store,
            publish: { profile in
                await service.publish(
                    phase: store.phase, enabled: true,
                    to: ComputerUseRuntimeService.socketURL(for: profile, paths: fixture.paths), peer: peer
                )
            },
            stop: { stopped = true }
        )
        let result = await admission.finish(.ready, attempt: try #require(store.beginVerification()))
        #expect(result == .unavailable)
        #expect(store.phase == .onboardingRequired)
        #expect(stopped == !acknowledgesWithdrawal)
        #expect(fixture.defaults.data(forKey: fixture.completionKey) == nil)
        for responder in [native, codex] {
            #expect(responder.receivedRequests.count == 2)
            let received = try #require(responder.receivedRequests.last)
            let envelope = try #require(JSONSerialization.jsonObject(
                with: Data(received.utf8)
            ) as? [String: Any])
            let request = try #require(envelope["request"] as? [String: Any])
            #expect((request["args"] as? [String: Any])?["ready"] as? Bool == false)
        }
    }
}
