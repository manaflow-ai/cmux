import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual == expected, Comment(rawValue: message))
}

private func checkTrue(_ condition: @autoclosure () -> Bool, _ message: String = "") {
    #expect(condition(), Comment(rawValue: message))
}

@Suite
struct AppIconAppearanceObserverTests {
    private final class ObservationToken: EffectiveAppearanceObservation {
        private(set) var invalidateCallCount = 0

        func invalidate() {
            invalidateCallCount += 1
        }
    }

    private final class Harness {
        var isFinishedLaunching = false
        var isDark = false
        var startObservationCallCount = 0
        var currentAppearanceIsDarkCallCount = 0
        var imageRequests: [String] = []
        var appliedIconCount = 0
        var didFinishLaunchingObserverCount = 0
        private(set) var didFinishLaunchingHandler: (() -> Void)?
        private(set) var appearanceHandler: (() -> Void)?
        let observation = ObservationToken()

        lazy var environment = AppIconAppearanceObserver.Environment(
            isApplicationFinishedLaunching: { [unowned self] in
                self.isFinishedLaunching
            },
            startEffectiveAppearanceObservation: { [unowned self] handler in
                self.startObservationCallCount += 1
                self.appearanceHandler = handler
                return self.observation
            },
            addDidFinishLaunchingObserver: { [unowned self] handler in
                self.didFinishLaunchingObserverCount += 1
                self.didFinishLaunchingHandler = handler
                return NSObject()
            },
            removeObserver: { _ in },
            currentAppearanceIsDark: { [unowned self] in
                self.currentAppearanceIsDarkCallCount += 1
                return self.isDark
            },
            imageForName: { [unowned self] imageName in
                self.imageRequests.append(imageName)
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            setApplicationIconImage: { [unowned self] _ in
                self.appliedIconCount += 1
            }
        )

        func fireDidFinishLaunching() {
            didFinishLaunchingHandler?()
        }

        func fireAppearanceChanged() {
            appearanceHandler?()
        }
    }

    @Test
    func testStartObservingDefersInitialApplyUntilLaunch() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()

        checkEqual(harness.didFinishLaunchingObserverCount, 1)
        checkEqual(harness.startObservationCallCount, 0)
        checkEqual(harness.currentAppearanceIsDarkCallCount, 0)
        checkTrue(harness.imageRequests.isEmpty)

        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        checkEqual(harness.startObservationCallCount, 1)
        checkEqual(harness.currentAppearanceIsDarkCallCount, 1)
        checkEqual(harness.imageRequests, ["AppIconLight"])
        checkEqual(harness.appliedIconCount, 1)
    }

    @Test
    func testStopObservingCancelsDeferredLaunchApply() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()
        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        checkEqual(harness.startObservationCallCount, 0)
        checkEqual(harness.currentAppearanceIsDarkCallCount, 0)
        checkTrue(harness.imageRequests.isEmpty)
        checkEqual(harness.appliedIconCount, 0)
    }

    @Test
    func testStopObservingInvalidatesActiveObservation() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()

        checkEqual(harness.startObservationCallCount, 1)
        checkEqual(harness.observation.invalidateCallCount, 1)
    }

    @Test
    func testUnchangedAutomaticAppearanceDoesNotReapplyIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.fireAppearanceChanged()

        checkEqual(harness.currentAppearanceIsDarkCallCount, 2)
        checkEqual(harness.imageRequests, ["AppIconLight"])
        checkEqual(harness.appliedIconCount, 1)
    }

    @Test
    func testAutomaticAppearanceChangeAppliesNewIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.isDark = true
        harness.fireAppearanceChanged()

        checkEqual(harness.imageRequests, ["AppIconLight", "AppIconDark"])
        checkEqual(harness.appliedIconCount, 2)
    }
}
