import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class UpdateDriverTests: XCTestCase {
    func testSlowCheckStaysCheckingUntilSparkleReturnsRealResult() {
        let viewModel = UpdateViewModel()
        let driver = UpdateDriver(
            viewModel: viewModel,
            hostBundle: .main,
            timing: .init(
                minimumCheckDisplayDuration: 0,
                noUpdateDisplayDuration: 0,
                checkTimeoutDuration: 0.05
            )
        )

        driver.showUserInitiatedUpdateCheck(cancellation: {})
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

        guard case .checking = viewModel.state else {
            XCTFail("Expected slow check to remain in checking, got \(viewModel.state)")
            return
        }
    }
}
