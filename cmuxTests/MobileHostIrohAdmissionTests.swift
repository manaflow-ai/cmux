import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MobileHostAuthorizationTests {
    @Test func testIrohAdmissionReplacesPerRequestStackAuthorization() async throws {
        let recorder = MobileHostAuthorizationInvocationRecorder()
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: nil
        )
        let admitted = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: try irohAdmissionContext(),
            stackAuthorization: { _ in
                await recorder.record()
                return .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Stack should not run"
                ))
            }
        )
        #expect(admitted == nil)
        #expect(await recorder.count() == 0)

        let tcp = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .stackBearer,
            stackAuthorization: { _ in
                await recorder.record()
                return .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Missing Stack bearer"
                ))
            }
        )
        guard case let .failure(error) = tcp else {
            return #expect(Bool(false), "Tokenless TCP must retain Stack authorization")
        }
        #expect(error.code == "unauthorized")
        #expect(await recorder.count() == 1)
    }
    @Test func testIrohAdmittedStatusIncludesIdentityWhileTCPPublicStatusDoesNot() async throws {
        let request = MobileHostRPCRequest(
            id: "host-status",
            method: "mobile.host.status",
            params: [:],
            auth: nil
        )
        let admitted = await MobileHostService.connectionStatusResult(
            for: request,
            authorization: try irohAdmissionContext(),
            stackStatus: { _ in .ok(["routes": []]) }
        )
        guard case let .ok(admittedPayload as [String: Any]) = admitted else {
            return #expect(Bool(false), "Admitted Iroh status must return an object")
        }
        #expect(admittedPayload["mac_device_id"] is String)

        let tcp = await MobileHostService.connectionStatusResult(
            for: request,
            authorization: .stackBearer,
            stackStatus: { _ in .ok(["routes": []]) }
        )
        guard case let .ok(tcpPayload as [String: Any]) = tcp else {
            return #expect(Bool(false), "TCP status must return an object")
        }
        #expect(tcpPayload["mac_device_id"] == nil)
    }
}
