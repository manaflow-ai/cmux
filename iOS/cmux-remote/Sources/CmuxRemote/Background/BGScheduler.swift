import Foundation
import BackgroundTasks
import CmuxKit
import UserNotifications
import Logging

@MainActor
final class BGScheduler {
    static let shared = BGScheduler()

    private let log = CmuxLog.make("bg.scheduler")
    private let refreshIdentifier = "com.cmuxterm.remote.refresh"

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier,
            using: nil
        ) { task in
            self.handleAppRefresh(task as! BGAppRefreshTask)
        }
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.warning("could not schedule app refresh: \(error.localizedDescription)")
        }
    }

    func scheduleAll() {
        scheduleAppRefresh()
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        // Re-arm for the next opportunity immediately.
        scheduleAppRefresh()

        let operation = BackgroundEventDrain()
        task.expirationHandler = { operation.cancel() }

        Task {
            let success = await operation.run(maxDuration: .seconds(25))
            task.setTaskCompleted(success: success)
        }
    }

}
