import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Parks resource retirement at an explicit causal boundary, without a clock.
@MainActor
final class MobileHostLifecycleFixture {
    var holdsRetirement = false
    var invalidations = 0
    var onInvalidation: (() -> Void)?
    var retirements = 0
    var activations: [String] = []
    var activationGenerations: [UUID] = []
    private var retirement: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func makeCoordinator() -> MobileHostLifecycleCoordinator<String> {
        MobileHostLifecycleCoordinator(
            invalidate: {
                self.invalidations += 1
                self.onInvalidation?()
            },
            retire: {
                self.retirements += 1
                guard self.holdsRetirement else { return }
                await withCheckedContinuation { continuation in
                    self.retirement = continuation
                    let observers = self.observers
                    self.observers.removeAll()
                    for observer in observers { observer.resume() }
                }
            },
            activate: { scope, generation in
                self.activations.append(scope)
                self.activationGenerations.append(generation)
            }
        )
    }

    func waitForHeldRetirement() async {
        if retirement != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func releaseRetirement() {
        holdsRetirement = false
        let continuation = retirement
        retirement = nil
        continuation?.resume()
    }
}
