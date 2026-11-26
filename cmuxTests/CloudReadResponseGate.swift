import CmuxCloud
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#else
@testable import CloudReadFixture
#endif

actor CloudReadResponseGate {
    private(set) var requests = 0
    private var released = false
    private var waiting: [(CloudReadRequestCoordinator.Response, CheckedContinuation<CloudReadRequestCoordinator.Response, Never>)] = []

    func read(_ response: CloudReadRequestCoordinator.Response) async -> CloudReadRequestCoordinator.Response {
        requests += 1
        if released { return response }
        return await withCheckedContinuation { waiting.append((response, $0)) }
    }

    func release() {
        released = true
        let pending = waiting
        waiting.removeAll()
        for (response, continuation) in pending { continuation.resume(returning: response) }
    }
}
