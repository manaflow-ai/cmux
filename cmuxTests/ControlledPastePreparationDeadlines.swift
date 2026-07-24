import Foundation

actor ControlledPastePreparationDeadlines {
    private var arrivalCount = 0
    private var arrivalWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var sleepers: [UUID: CheckedContinuation<Void, Never>] = [:]

    func sleep() async throws {
        try Task.checkCancellation()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sleepers[id] = continuation
                arrivalCount += 1
                let readyTargets = arrivalWaiters.keys.filter {
                    $0 <= arrivalCount
                }
                for target in readyTargets {
                    arrivalWaiters.removeValue(forKey: target)?
                        .forEach { $0.resume() }
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        try Task.checkCancellation()
    }

    func waitForArrivalCount(_ target: Int) async {
        guard arrivalCount < target else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters[target, default: []].append(continuation)
        }
    }

    func fireAll() {
        let continuations = sleepers.values
        sleepers.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cancel(id: UUID) {
        sleepers.removeValue(forKey: id)?.resume()
    }
}
