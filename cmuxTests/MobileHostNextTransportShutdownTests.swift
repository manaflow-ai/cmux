#if DEBUG
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Next-transport endpoint shutdown")
struct MobileHostNextTransportShutdownTests {
    @Test("startup retries the retained endpoint after a transient close failure")
    func failedCloseCanRecover() async {
        let runtime = MobileHostNextTransportRuntime()
        var attempts = 0
        runtime.beginEndpointClose {
            attempts += 1
            return attempts > 1
        }
        #expect(await runtime.endpointCloseTask?.value == false)
        #expect(runtime.state == "shutdown-failed")
        #expect(await runtime.awaitEndpointClose(generation: runtime.generation))
        #expect(attempts == 2)
        #expect(runtime.endpointCloseTask == nil)
        #expect(runtime.endpointCloseOperation == nil)
    }

    @Test("persistent failure stays fail-closed and retries only on a new start")
    func persistentFailureRemainsVisibleAndOwned() async {
        let runtime = MobileHostNextTransportRuntime()
        var attempts = 0
        runtime.beginEndpointClose {
            attempts += 1
            return false
        }
        #expect(await runtime.endpointCloseTask?.value == false)
        let firstStartAllowed = await runtime.awaitEndpointClose(generation: runtime.generation)
        #expect(!firstStartAllowed)
        #expect(attempts == 2)
        #expect(runtime.state == "shutdown-failed")
        #expect(runtime.endpointCloseOperation != nil)
        let secondStartAllowed = await runtime.awaitEndpointClose(generation: runtime.generation)
        #expect(!secondStartAllowed)
        #expect(attempts == 3)
    }

    @Test("a superseded startup cannot retry or discard a failed close")
    func staleGenerationPreservesTheBarrier() async {
        let runtime = MobileHostNextTransportRuntime()
        var attempts = 0
        runtime.beginEndpointClose {
            attempts += 1
            return false
        }
        #expect(await runtime.endpointCloseTask?.value == false)
        let staleStartAllowed = await runtime.awaitEndpointClose(generation: runtime.generation &+ 1)
        #expect(!staleStartAllowed)
        #expect(attempts == 1)
        #expect(runtime.endpointCloseTask != nil)
        #expect(runtime.endpointCloseOperation != nil)
    }
}
#endif
