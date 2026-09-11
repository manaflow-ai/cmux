import Foundation

actor ControlledPastePreparationDeadlines {
    private struct Sleeper {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var arrivalCount = 0
    private var arrivalWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var sleepers: [Sleeper] = []

    func sleep() async throws {
        try Task.checkCancellation()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sleepers.append(Sleeper(id: id, continuation: continuation))
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

    func currentArrivalCount() -> Int {
        arrivalCount
    }

    func fireAll() {
        let continuations = sleepers.map(\.continuation)
        sleepers.removeAll()
        continuations.forEach { $0.resume() }
    }

    @discardableResult
    func fireNext() -> Bool {
        guard !sleepers.isEmpty else { return false }
        sleepers.removeFirst().continuation.resume()
        return true
    }

    @discardableResult
    func fireLast() -> Bool {
        guard let sleeper = sleepers.popLast() else { return false }
        sleeper.continuation.resume()
        return true
    }

    private func cancel(id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            return
        }
        sleepers.remove(at: index).continuation.resume()
    }
}
