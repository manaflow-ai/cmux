import CMUXAuthCore
import CmuxAuthRuntime
import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWebContentProcessTests {
    private let recoveryURL = URL(string: "data:text/html,cmux-recovery")!

    @Test
    func authCallbackNavigationPolicyIsPureAndFailClosed() {
        let policy = BrowserAuthCallbackNavigationPolicy(
            trustedSourcePageOrigin: URL(string: "https://cmux.test")!,
            callbackScheme: "cmux-dev-test"
        )
        let callbackURL = URL(string: "cmux-dev-test://auth-callback?refresh_token=secret")!

        switch policy.disposition(
            for: callbackURL,
            targetFrameIsMainFrame: true,
            isLinkActivated: true,
            sourceOriginMatches: true
        ) {
        case .deliverInApp:
            break
        case .block, .passThrough:
            Issue.record("Trusted user-activated callback should be delivered in-process")
        }

        for rejectedContext in [
            (false, true, true),
            (true, false, true),
            (true, true, false),
        ] {
            switch policy.disposition(
                for: callbackURL,
                targetFrameIsMainFrame: rejectedContext.0,
                isLinkActivated: rejectedContext.1,
                sourceOriginMatches: rejectedContext.2
            ) {
            case .block:
                break
            case .deliverInApp, .passThrough:
                Issue.record("Auth callbacks that fail a trust check must be blocked")
            }
        }

        switch policy.disposition(
            for: URL(string: "https://cmux.test/app-pricing")!,
            targetFrameIsMainFrame: true,
            isLinkActivated: true,
            sourceOriginMatches: true
        ) {
        case .passThrough:
            break
        case .block, .deliverInApp:
            Issue.record("Ordinary web navigation should pass through")
        }

        #expect(BrowserAuthCallbackNavigationPolicy.shouldBlockExternalNavigation(callbackURL))
        #expect(
            !BrowserAuthCallbackNavigationPolicy.shouldBlockExternalNavigation(
                URL(string: "https://cmux.test/app-pricing")!
            )
        )
    }

    @Test
    func authCallbackConsumptionTerminatesNavigationAndSurfacesDeliveryFailure() async {
        let policy = BrowserAuthCallbackNavigationPolicy(
            trustedSourcePageOrigin: URL(string: "https://cmux.test")!,
            callbackScheme: "cmux-dev-test"
        )
        let callbackURL = URL(string: "cmux-dev-test://auth-callback?refresh_token=secret")!
        let sourcePageURL = URL(
            string: "https://cmux.test/handler/after-sign-in?web_return_to=%2Fapp-pricing%3Fcmux_app%3D1"
        )!
        var cancellationCount = 0
        var terminalCancellationReportCount = 0

        let completion = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Bool, URL?), Never>) in
            let consumed = policy.consume(
                disposition: .deliverInApp,
                callbackURL: callbackURL,
                sourcePageURL: sourcePageURL,
                cancelNavigation: { cancellationCount += 1 },
                reportTerminalCancellation: { terminalCancellationReportCount += 1 },
                deliver: { _ in false },
                completion: { delivered, returnURL in
                    continuation.resume(returning: (delivered, returnURL))
                }
            )
            #expect(consumed)
            #expect(cancellationCount == 1)
            #expect(terminalCancellationReportCount == 1)
        }

        #expect(!completion.0)
        #expect(completion.1?.absoluteString == "https://cmux.test/app-pricing?cmux_app=1")

        let webView = WKWebView()
        var presentedFailure = false
        var preparedReturnURL: URL?
        var loadedReturnURL: URL?
        BrowserAuthCallbackNavigationPolicy.finishDelivery(
            delivered: completion.0,
            returnURL: completion.1,
            in: webView,
            prepareReturnRequest: { preparedReturnURL = $0.url },
            presentAlert: { _, _, completion, _ in
                presentedFailure = true
                completion(.alertFirstButtonReturn)
            },
            loadRequest: { request, _ in loadedReturnURL = request.url }
        )

        #expect(presentedFailure)
        #expect(preparedReturnURL == completion.1)
        #expect(loadedReturnURL == completion.1)
    }

    @Test
    func blockedAuthCallbackConsumptionStillTerminatesNavigation() {
        let policy = BrowserAuthCallbackNavigationPolicy(
            trustedSourcePageOrigin: URL(string: "https://cmux.test")!,
            callbackScheme: "cmux-dev-test"
        )
        let callbackURL = URL(string: "cmux-nightly://auth-callback?refresh_token=secret")!
        var cancellationCount = 0
        var terminalCancellationReportCount = 0

        let consumed = policy.consume(
            disposition: .block,
            callbackURL: callbackURL,
            sourcePageURL: nil,
            cancelNavigation: { cancellationCount += 1 },
            reportTerminalCancellation: { terminalCancellationReportCount += 1 },
            deliver: { _ in
                Issue.record("Blocked callbacks must never be delivered")
                return false
            },
            completion: { _, _ in
                Issue.record("Blocked callbacks must not complete delivery")
            }
        )

        #expect(consumed)
        #expect(cancellationCount == 1)
        #expect(terminalCancellationReportCount == 1)
    }

    @Test
    func browserPanelsShareDefaultWebsiteDataStore() {
        let first = BrowserPanel(workspaceId: UUID())
        let second = BrowserPanel(workspaceId: UUID())
        defer {
            first.close()
            second.close()
        }

        #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
    }

    @Test
    func configureWebViewConfigurationAppliesWebsiteDataStore() {
        let configuration = WKWebViewConfiguration()
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: websiteDataStore
        )

        #expect(configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func browserPanelUsesExplicitWebsiteDataStoreForAuthenticatedHandoffs() {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            websiteDataStore: websiteDataStore
        )
        defer { panel.close() }

        #expect(panel.websiteDataStore === websiteDataStore)
        #expect(panel.webView.configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func authenticatedHandoffNavigationPinsTheNativeAuthGeneration() {
        let navigation = BrowserAppSessionNavigation(
            request: URLRequest(url: URL(string: "https://cmux.test/dashboard")!),
            websiteDataStore: .nonPersistent(),
            generation: 7,
            authSessionGeneration: 11
        )

        #expect(navigation.generation == 7)
        #expect(navigation.authSessionGeneration == 11)
    }

    @Test
    func browserAppSessionAdmissionClosesAcrossAccountTransitions() {
        let first = BrowserAppSessionAuthOwner(
            userID: "account-a",
            authSessionGeneration: 7
        )
        let second = BrowserAppSessionAuthOwner(
            userID: "account-b",
            authSessionGeneration: 9
        )
        var admission = BrowserAppSessionAdmission()

        #expect(!admission.allows(first))
        admission.resume(for: first)
        #expect(admission.allows(first))

        admission.beginTransition()
        #expect(!admission.allows(first))
        #expect(!admission.allows(second))

        admission.resume(for: second)
        #expect(!admission.allows(first))
        #expect(admission.allows(second))
    }

    @Test
    func browserAppSessionRequestAdmitsRestoredSessionWithoutPostSignInHook() async throws {
        let suiteName = "BrowserAppSessionRestoredSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = makeRestoredSessionCoordinator(defaults: defaults)
        coordinator.start()
        let controller = BrowserAppSessionController(
            coordinator: coordinator,
            webOrigin: URL(string: "http://127.0.0.1:1")!,
            projectID: "project-a",
            defaults: defaults
        )

        let outcome = await controller.request(
            destinationURL: URL(string: "http://127.0.0.1:1/dashboard")!
        )

        #expect(outcome.shouldRetry)
    }

    @Test
    func browserAppSessionCleanupFailureRetainsOwnershipAndBoundsRetries() async throws {
        let suiteName = "BrowserAppSessionFailedCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = makeRestoredSessionCoordinator(defaults: defaults)
        coordinator.start()
        let environment = BrowserAppSessionEnvironment(
            webOrigin: URL(string: "http://127.0.0.1:1")!,
            projectID: "project-a"
        )
        let registry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "failed-cleanup-stores",
            environment: environment
        )
        var websiteDataStore: WKWebsiteDataStore? = .nonPersistent()
        registry.register(try #require(websiteDataStore))
        var cleanupAttemptCount = 0
        let controller = BrowserAppSessionController(
            coordinator: coordinator,
            webOrigin: environment.webOrigin,
            projectID: environment.projectID,
            defaults: defaults,
            storeRegistry: registry,
            clearWebsiteDataStore: { _ in
                cleanupAttemptCount += 1
                return .timedOut
            }
        )

        for _ in 0..<3 {
            let outcome = await controller.request(
                destinationURL: URL(string: "http://127.0.0.1:1/dashboard")!
            )
            #expect(outcome.shouldRetry)
        }

        #expect(cleanupAttemptCount == 2)
        #expect(registry.hasOwnership)

        websiteDataStore = nil
        #expect(!registry.hasOwnership)
        _ = await controller.request(
            destinationURL: URL(string: "http://127.0.0.1:1/dashboard")!
        )
        let nextWebsiteDataStore = WKWebsiteDataStore.nonPersistent()
        registry.register(nextWebsiteDataStore)

        await controller.clearCmuxWebSession()

        #expect(cleanupAttemptCount == 3)
        #expect(registry.hasOwnership)
    }

    @Test
    func authenticatedHandoffStoreSurvivesWorkspaceReattachment() {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            websiteDataStore: websiteDataStore
        )
        defer { panel.close() }

        panel.reattachToWorkspace(
            UUID(),
            isRemoteWorkspace: false,
            proxyEndpoint: nil,
            remoteStatus: nil
        )

        #expect(panel.websiteDataStore === websiteDataStore)
        #expect(panel.webView.configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func authenticatedHandoffStoreCannotSwitchIntoAPersistentProfile() throws {
        let profile = try #require(
            BrowserProfileStore.shared.createProfile(
                named: "Handoff isolation \(UUID().uuidString)"
            )
        )
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: profile.id) }
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            websiteDataStore: websiteDataStore
        )
        defer { panel.close() }

        #expect(!panel.switchToProfile(profile.id))
        #expect(panel.websiteDataStore === websiteDataStore)
        #expect(panel.webView.configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func browserAppSessionRegistryTracksPanelsUsingOwnedStores() throws {
        let suiteName = "BrowserAppSessionOwnedPanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            websiteDataStore: websiteDataStore
        )
        defer { panel.close() }
        let registry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "owned-stores",
            environment: BrowserAppSessionEnvironment(
                webOrigin: URL(string: "https://cmux.test")!,
                projectID: "project-a"
            )
        )

        registry.register(websiteDataStore)
        registry.register(panel)

        #expect(registry.panelsForCleanup().contains { $0 === panel })
    }

    @Test
    func browserAppSessionRegistryDoesNotResetAClosingPanel() throws {
        let suiteName = "BrowserAppSessionClosingPanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            websiteDataStore: websiteDataStore
        )
        let registry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "closing-panel-stores",
            environment: BrowserAppSessionEnvironment(
                webOrigin: URL(string: "https://cmux.test")!,
                projectID: "project-a"
            )
        )
        registry.register(websiteDataStore)
        registry.register(panel)

        panel.close()

        #expect(!registry.panelsForCleanup().contains { $0 === panel })
        #expect(registry.storesForCleanup().contains { $0 === websiteDataStore })
    }

    @Test
    func browserAppSessionRegistryRetainsAClosingPanelAssociation() throws {
        let suiteName = "BrowserAppSessionClosingPanelAssociationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            websiteDataStore: websiteDataStore
        )
        defer { panel.close() }
        let registry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "closing-panel-association-stores",
            environment: BrowserAppSessionEnvironment(
                webOrigin: URL(string: "https://cmux.test")!,
                projectID: "project-a"
            )
        )
        registry.register(websiteDataStore)
        registry.register(panel)

        panel.isClosingWebViewLifecycle = true
        #expect(!registry.panelsForCleanup().contains { $0 === panel })
        panel.isClosingWebViewLifecycle = false

        #expect(registry.panelsForCleanup().contains { $0 === panel })
    }

    @Test
    func browserAppSessionCleanupCoversEveryWebsiteDataType() {
        #expect(
            BrowserAppSessionController.appSessionWebsiteDataTypes ==
                WKWebsiteDataStore.allWebsiteDataTypes()
        )
    }

    @Test
    func browserAppSessionSignOutRevokesTheLivePanelStoreBeforeAsyncCleanup() {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            websiteDataStore: websiteDataStore
        )
        defer { panel.close() }

        panel.resetForAppSessionSignOut()

        #expect(panel.websiteDataStore !== websiteDataStore)
        #expect(!panel.websiteDataStore.isPersistent)
        #expect(
            panel.webView.configuration.websiteDataStore ===
                panel.websiteDataStore
        )
    }

    @Test
    func browserAppSessionCallbackWaitTimesOutWhenWebKitDropsCompletion() async {
        let outcome = await awaitBrowserAppSessionCallback(
            timeout: .milliseconds(20)
        ) { _ in
            // Reproduce a WebKit API that never invokes its completion handler.
        }

        #expect(outcome == .timedOut)
    }

    @Test
    func browserAppSessionCallbackWaitCompletesWhenItsTaskIsCancelled() async {
        let task = Task { @MainActor in
            await awaitBrowserAppSessionCallback(timeout: .seconds(30)) { _ in
                // Keep the callback parked until cancellation wins the race.
            }
        }
        await Task.yield()

        task.cancel()

        #expect(await task.value == .cancelled)
    }

    @Test
    func appLinkHandoffRegistryCoalescesDuplicateSourceDestinations() async throws {
        let registry = BrowserAppLinkHandoffRegistry()
        let sourcePanelID = UUID()
        let destinationURL = try #require(
            URL(string: "https://cmux.test/dashboard/testflight")
        )
        let operationStarted = AsyncStream<Void>.makeStream()
        let operationRelease = AsyncStream<Void>.makeStream()
        var operationStartedIterator = operationStarted.stream.makeAsyncIterator()
        var startCount = 0

        #expect(registry.start(
            sourcePanelID: sourcePanelID,
            destinationURL: destinationURL
        ) {
            startCount += 1
            operationStarted.continuation.yield()
            for await _ in operationRelease.stream {}
        })
        #expect(!registry.start(
            sourcePanelID: sourcePanelID,
            destinationURL: destinationURL
        ) {
            startCount += 1
        })
        _ = await operationStartedIterator.next()

        #expect(startCount == 1)
        #expect(registry.activeCount == 1)

        registry.cancel(sourcePanelID: sourcePanelID)
        operationRelease.continuation.finish()
        #expect(registry.activeCount == 0)
    }

    @Test
    func appLinkPlacementUsesOnePreferredPaneThenSplitThenSourcePolicy() {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let navigation = BrowserAppSessionNavigation(
            request: URLRequest(url: URL(string: "https://cmux.test/dashboard")!),
            websiteDataStore: websiteDataStore,
            generation: 1,
            authSessionGeneration: 1
        )
        var placements: [String] = []

        let opened = BrowserAppLinkPlacementPolicy().openNavigation(
            navigation,
            openInPreferredPane: { _, store in
                placements.append("preferred")
                #expect(store === websiteDataStore)
                return false
            },
            openHorizontalSplit: { _, store in
                placements.append("split")
                #expect(store === websiteDataStore)
                return true
            },
            openInSourcePane: { _, _ in
                placements.append("source")
                return true
            },
            isBrowserAvailable: { true }
        )

        #expect(opened)
        #expect(placements == ["preferred", "split"])
    }

    @Test
    func appLinkRecoveryUsesOneNonPersistentPlacementPolicyBeforeSystemBrowser() {
        let destinationURL = URL(string: "https://cmux.test/dashboard/testflight")!
        var placements: [String] = []
        var openedSystemBrowser = false

        let opened = BrowserAppLinkPlacementPolicy(
            openInSystemBrowser: { _ in
                openedSystemBrowser = true
                return true
            }
        ).recover(
            destinationURL,
            openInPreferredPane: { _, store in
                placements.append("preferred")
                #expect(!store.isPersistent)
                return false
            },
            openHorizontalSplit: { _, store in
                placements.append("split")
                #expect(!store.isPersistent)
                return false
            },
            openInSourcePane: { _, store in
                placements.append("source")
                #expect(!store.isPersistent)
                return true
            },
            isBrowserAvailable: { true }
        )

        #expect(opened)
        #expect(placements == ["preferred", "split", "source"])
        #expect(!openedSystemBrowser)
    }

    @Test
    func appLinkRecoveryStopsPlacementWhenBrowserAvailabilityIsRevoked() {
        var browserAvailable = true
        let destinationURL = URL(
            string: "https://cmux.test/dashboard/testflight"
        )!
        var placements: [String] = []
        var systemBrowserOpenCount = 0

        let opened = BrowserAppLinkPlacementPolicy(
            openInSystemBrowser: { _ in
                systemBrowserOpenCount += 1
                return true
            }
        ).recover(
            destinationURL,
            openInPreferredPane: { _, _ in
                placements.append("preferred")
                browserAvailable = false
                return false
            },
            openHorizontalSplit: { _, _ in
                placements.append("split")
                return false
            },
            openInSourcePane: { _, _ in
                placements.append("source")
                return false
            },
            isBrowserAvailable: { browserAvailable }
        )

        #expect(opened)
        #expect(placements == ["preferred"])
        #expect(systemBrowserOpenCount == 1)
    }

    @Test
    func browserAppSessionOutcomesSeparateMissingAuthFromTransientFailure() {
        let notAuthenticated = BrowserAppSessionRequestOutcome.notAuthenticated
        let transientFailure = BrowserAppSessionRequestOutcome.transientFailure
        let failed = BrowserAppSessionRequestOutcome.failed

        #expect(notAuthenticated.shouldBeginSignIn)
        #expect(!notAuthenticated.shouldRetry)
        #expect(!failed.shouldBeginSignIn)
        #expect(!failed.shouldRetry)
        #expect(transientFailure.shouldRetry)
        #expect(BrowserAppSessionRequestOutcome.exchangeFailure(statusCode: 401).shouldBeginSignIn)
        #expect(!BrowserAppSessionRequestOutcome.exchangeFailure(statusCode: 429).shouldRetry)
        #expect(BrowserAppSessionRequestOutcome.exchangeFailure(statusCode: 503).shouldRetry)
    }

    @Test
    func browserAppSessionClassifiesDefinitiveUnauthorizedTokenReads() {
        let unauthorized = BrowserAppSessionRequestOutcome.tokenFailure(
            AuthError.unauthorized
        )
        let transient = BrowserAppSessionRequestOutcome.tokenFailure(
            AuthError.networkError
        )

        #expect(unauthorized.shouldBeginSignIn)
        #expect(!unauthorized.shouldRetry)
        #expect(!transient.shouldBeginSignIn)
        #expect(transient.shouldRetry)
    }

    @Test
    func failedBrowserAppSessionHandoffUsesIsolatedRecovery() {
        #expect(
            BrowserAppSessionRequestOutcome.failed.recoveryAction == .isolatedBrowser
        )
        #expect(
            BrowserAppSessionRequestOutcome.transientFailure.recoveryAction == .isolatedBrowser
        )
        #expect(
            BrowserAppSessionRequestOutcome.notAuthenticated.recoveryAction == .beginSignIn
        )
        #expect(
            BrowserAppSessionRequestOutcome.cancelled.recoveryAction == .isolatedBrowser
        )
    }

    @Test
    func browserAppSessionStoreOwnershipDoesNotClaimPersistentProfiles() throws {
        let suiteName = "BrowserAppSessionStoreOwnershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultsKey = "owned-stores"
        let persistentStoreID = UUID()
        let environment = BrowserAppSessionEnvironment(
            webOrigin: URL(string: "https://cmux.test")!,
            projectID: "project-a"
        )

        let firstLaunch = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: defaultsKey,
            environment: environment
        )
        firstLaunch.register(
            WKWebsiteDataStore(forIdentifier: persistentStoreID)
        )

        let relaunched = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: defaultsKey,
            environment: environment
        )
        #expect(relaunched.storesForCleanup().isEmpty)
    }

    @Test
    func browserAppSessionDoesNotReopenASharedPersistentProfileForCleanup() throws {
        let suiteName = "BrowserAppSessionSharedProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let environment = BrowserAppSessionEnvironment(
            webOrigin: URL(string: "https://cmux.test")!,
            projectID: "project-a"
        )

        let firstLaunch = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "owned-stores",
            environment: environment
        )
        firstLaunch.register(WKWebsiteDataStore(forIdentifier: UUID()))

        let relaunched = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "owned-stores",
            environment: environment
        )
        #expect(relaunched.storesForCleanup().isEmpty)
    }

    @Test
    func browserAppSessionStoreRegistryRetiresPersistedOwnershipMarkers() throws {
        let suiteName = "BrowserAppSessionStoreEnvironmentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultsKey = "owned-stores"
        let persistentStoreID = UUID()
        let oldEnvironment = BrowserAppSessionEnvironment(
            webOrigin: URL(string: "https://old.cmux.test")!,
            projectID: "project-a"
        )
        let newEnvironment = BrowserAppSessionEnvironment(
            webOrigin: URL(string: "https://new.cmux.test")!,
            projectID: "project-b"
        )

        let encodedOwnership = try JSONSerialization.data(withJSONObject: [[
            "identity": "persistent:\(persistentStoreID.uuidString.lowercased())",
            "webOrigin": oldEnvironment.webOrigin.absoluteString,
            "projectID": oldEnvironment.projectID,
        ]])
        defaults.set(encodedOwnership, forKey: defaultsKey)

        let switched = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: defaultsKey,
            environment: newEnvironment
        )
        #expect(defaults.object(forKey: defaultsKey) == nil)
        #expect(switched.storesForCleanup().isEmpty)
    }

    @Test
    func browserAppSessionStoreOwnershipMigratesProjectScopedRecords() throws {
        let suiteName = "BrowserAppSessionStoreMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPrefix = "cmux.auth.browserAppSessionStores."
        let legacyKey = "\(legacyPrefix)project-a"
        let persistentStoreID = UUID()
        defaults.set(
            ["persistent:\(persistentStoreID.uuidString.lowercased())"],
            forKey: legacyKey
        )

        let registry = BrowserAppSessionStoreRegistry(
            defaults: defaults,
            defaultsKey: "owned-stores-v2",
            environment: BrowserAppSessionEnvironment(
                webOrigin: URL(string: "https://cmux.test")!,
                projectID: "project-b"
            ),
            legacyDefaultsKeyPrefix: legacyPrefix
        )

        #expect(defaults.object(forKey: "owned-stores-v2") == nil)
        #expect(defaults.object(forKey: legacyKey) == nil)
        #expect(registry.storesForCleanup().isEmpty)
    }

    @Test
    func browserAppSessionWeakStoreReferencesDoNotRetainOwners() throws {
        var reference: BrowserAppSessionWeakReference<StoreLifetimeProbe>?
        weak var retainedOwner: StoreLifetimeProbe?

        autoreleasepool {
            let owner = StoreLifetimeProbe()
            retainedOwner = owner
            reference = BrowserAppSessionWeakReference(owner)
        }

        #expect(retainedOwner == nil)
        #expect(reference?.value == nil)
    }

    @Test
    func browserAppSessionSignInRelayClosesAndReopensAdmissionAcrossTransitions() async {
        let relay = BrowserAppSessionSignInRelay()
        var transitionCount = 0
        var resumeCount = 0

        relay.sessionWillTransition()
        await relay.signedIn()
        #expect(transitionCount == 0)
        #expect(resumeCount == 0)

        relay.bind(
            beginTransition: {
                transitionCount += 1
            },
            resume: {
                resumeCount += 1
            }
        )
        relay.sessionWillTransition()
        await relay.signedIn()

        #expect(transitionCount == 1)
        #expect(resumeCount == 1)
    }

    @Test
    func browserAppSessionHTTPClientRejectsRedirects() async throws {
        let delegate = BrowserAppSessionRedirectRejectingDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let sourceURL = try #require(URL(string: "https://cmux.test/handoff"))
        let targetURL = try #require(URL(string: "https://evil.test/steal"))
        let task = session.dataTask(with: sourceURL)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": targetURL.absoluteString]
        ))

        let redirectedRequest = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: targetURL)
            ) { request in
                continuation.resume(returning: request)
            }
        }

        #expect(redirectedRequest == nil)
    }

    @Test
    func configuredBrowserPageInstallsWebAuthnBridge() async throws {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        let webAuthnScript = try #require(
            configuration.userContentController.userScripts.first {
                $0.source == BrowserWebAuthnBridgeContract.scriptSource
            }
        )
        let webAuthnRelayScript = try #require(
            configuration.userContentController.userScripts.first {
                $0.source == BrowserWebAuthnBridgeContract.relayScriptSource
            }
        )
        #expect(webAuthnScript.injectionTime == .atDocumentStart)
        #expect(webAuthnScript.isForMainFrameOnly)
        #expect(webAuthnRelayScript.injectionTime == .atDocumentStart)
        #expect(webAuthnRelayScript.isForMainFrameOnly)
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey bridge probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let installed = try await webView.evaluateJavaScript(
            "window.__cmuxWebAuthnBridgeInstalled === true"
        ) as? Bool
        #expect(installed == true)
    }

    @Test
    func browserPanelInstallsWebAuthnBridgeWithoutExposingNativeHandler() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let webView = panel.webView
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey native handler probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        let result = try await webView.evaluateJavaScript(
            """
            ({
              bridge: window.__cmuxWebAuthnBridgeInstalled === true,
              handler: !!(
                window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers.cmuxWebAuthn &&
                typeof window.webkit.messageHandlers.cmuxWebAuthn.postMessage === "function"
              )
            })
            """
        ) as? [String: Bool]
        #expect(result?["bridge"] == true)
        #expect(result?["handler"] == false)
    }

    @Test
    func webAuthnPageBridgeRelaysCredentialGetThroughContentWorldHandler() async throws {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .nonPersistent()
        )
        let probe = BrowserWebAuthnReplyProbe()
        configuration.userContentController.addScriptMessageHandler(
            probe,
            contentWorld: BrowserWebAuthnBridgeContract.contentWorld,
            name: BrowserWebAuthnBridgeContract.handlerName
        )
        defer {
            configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserWebAuthnBridgeContract.handlerName,
                contentWorld: BrowserWebAuthnBridgeContract.contentWorld
            )
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loadDelegate = BrowserWebContentProcessLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html><body>passkey relay probe</body></html>
            """,
            in: webView,
            baseURL: URL(string: "https://example.com/")!
        )

        // The bridge's navigator.credentials.get returns a promise, and
        // evaluateJavaScript cannot serialize a promise (WKError 5). Call the body
        // as an async function instead, in the page world that holds the override.
        let result = try await webView.callAsyncJavaScript(
            """
            const handlerVisible = !!(
              window.webkit &&
              window.webkit.messageHandlers &&
              window.webkit.messageHandlers.cmuxWebAuthn &&
              typeof window.webkit.messageHandlers.cmuxWebAuthn.postMessage === "function"
            );
            const credential = await navigator.credentials.get({
              publicKey: {
                challenge: new Uint8Array([1, 2, 3, 4]).buffer,
                rpId: "example.com",
                userVerification: "preferred"
              }
            });
            return {
              handlerVisible,
              credentialId: credential && credential.id,
              rawIDLength: credential && credential.rawId && credential.rawId.byteLength,
              signatureLength:
                credential &&
                credential.response &&
                credential.response.signature &&
                credential.response.signature.byteLength
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Any]

        #expect(result?["handlerVisible"] as? Bool == false)
        #expect(result?["credentialId"] as? String == "AQID")
        #expect((result?["rawIDLength"] as? NSNumber)?.intValue == 3)
        #expect((result?["signatureLength"] as? NSNumber)?.intValue == 2)
        #expect(probe.receivedKinds == ["getCredential"])
    }

    @Test
    func webAuthnNativeBridgeScopesParentDomainRelyingPartyIDs() throws {
        let googleOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://accounts.google.com")!)
        )
        #expect(googleOrigin.isWithinRelyingPartyScope("google.com"))
        #expect(googleOrigin.permits(relyingPartyIdentifier: "google.com"))

        let exampleOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://login.example.com")!)
        )
        #expect(exampleOrigin.isWithinRelyingPartyScope("example.com"))
        #expect(!exampleOrigin.permits(relyingPartyIdentifier: "example.com"))
        #expect(!exampleOrigin.permits(relyingPartyIdentifier: "com"))

        let githubPagesOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://tenant.github.io")!)
        )
        #expect(githubPagesOrigin.isWithinRelyingPartyScope("github.io"))
        #expect(githubPagesOrigin.permits(relyingPartyIdentifier: "tenant.github.io"))
        #expect(!githubPagesOrigin.permits(relyingPartyIdentifier: "github.io"))

        let appspotOrigin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "https://foo.appspot.com")!)
        )
        #expect(appspotOrigin.isWithinRelyingPartyScope("appspot.com"))
        #expect(appspotOrigin.permits(relyingPartyIdentifier: "foo.appspot.com"))
        #expect(!appspotOrigin.permits(relyingPartyIdentifier: "appspot.com"))
    }

    @Test
    func webAuthnSecurityOriginSerializesIPv6LoopbackOrigins() throws {
        let origin = try #require(
            BrowserWebAuthnSecurityOrigin(url: URL(string: "http://[::1]:3000")!)
        )

        #expect(origin.serializedString == "http://[::1]:3000")
        #expect(origin.isPotentiallyTrustworthyWebAuthnOrigin)
    }

    @Test
    func webViewReplacementAfterProcessTerminationUpdatesInstanceIdentity() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let viewportHost = panel.viewportHostView
        let oldInstanceID = panel.webViewInstanceID

        #expect(oldWebView.superview == nil)
        #expect(oldWebView.cmuxBrowserViewportHostView === viewportHost)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webViewInstanceID != oldInstanceID)
        #expect(panel.hasRecoverableWebContentTermination)
        #expect(panel.webView.navigationDelegate != nil)
        #expect(panel.webView.uiDelegate != nil)
        #expect(panel.webView.superview == nil)
        #expect(panel.webView.cmuxBrowserViewportHostView === viewportHost)
        #expect(oldWebView.cmuxBrowserViewportHostView == nil)
    }

    @Test
    func webViewReplacementPreservesActiveEmulatedViewportHost() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }
        let oldWebView = panel.webView
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 610))
        container.addSubview(oldWebView)
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        _ = try panel.setAutomationViewport(viewport).get()

        #expect(oldWebView.superview === panel.viewportHostView)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!(panel.webView === oldWebView))
        #expect(panel.webView.superview === panel.viewportHostView)
        #expect(panel.webView.cmuxBrowserViewportPresentationView === panel.viewportHostView)
        #expect(panel.webView.cmuxBrowserViewportHostView === panel.viewportHostView)
        #expect(oldWebView.cmuxBrowserViewportHostView == nil)
    }

    @Test
    func remoteWorkspaceWebsiteDataStoreSurvivesWebViewReplacement() {
        let storeIdentifier = UUID()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: storeIdentifier
        )
        defer { panel.close() }
        let originalStore = panel.webView.configuration.websiteDataStore

        panel.debugSimulateWebContentProcessTermination()

        #expect(panel.webView.configuration.websiteDataStore === originalStore)
    }

    @Test
    func reloadRecoversTerminatedWebView() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        panel.reload()

        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(panel.shouldRenderWebView)
    }

    @Test
    func workspaceContextResetClearsTerminatedWebViewRecovery() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: recoveryURL
        )
        defer { panel.close() }

        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        panel.resetForWorkspaceContextChange(reason: "test")

        #expect(!panel.hasRecoverableWebContentTermination)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.preferredURLStringForOmnibar() == nil)
    }

    @Test
    func profileSwitchClearsTerminatedWebViewRecovery() throws {
        let profile = try #require(
            BrowserProfileStore.shared.createProfile(
                named: "WebContent Recovery \(UUID().uuidString)"
            )
        )
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            initialURL: recoveryURL
        )
        defer { panel.close() }

        panel.debugSimulateWebContentProcessTermination()
        #expect(panel.hasRecoverableWebContentTermination)

        #expect(panel.switchToProfile(profile.id))

        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func webViewReplacementPreservesEmptyNewTabRenderState() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        #expect(!panel.shouldRenderWebView)

        panel.debugSimulateWebContentProcessTermination()

        #expect(!panel.shouldRenderWebView)
        #expect(!panel.hasRecoverableWebContentTermination)
    }

    @Test
    func floatingPopupInheritsOpenerWebsiteDataStore() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
    }

    @Test
    func floatingPopupInheritsRemoteWorkspaceWebsiteDataStore() throws {
        let remoteWorkspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: remoteWorkspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: remoteWorkspaceId
        )
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
        #expect(!(popupWebView.configuration.websiteDataStore === WKWebsiteDataStore.default()))
    }

    @Test
    func appSessionSignOutClosesFloatingPopupsBeforeReplacingStore() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let authenticatedStore = panel.webView.configuration.websiteDataStore
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        let popupWindow = try #require(popupWebView.window)
        defer { popupWebView.window?.close() }

        #expect(popupWebView.configuration.websiteDataStore === authenticatedStore)

        panel.resetForAppSessionSignOut()

        #expect(!(panel.webView.configuration.websiteDataStore === authenticatedStore))
        #expect(popupWebView.navigationDelegate == nil)
        #expect(popupWebView.uiDelegate == nil)
        #expect(!popupWindow.isVisible)
    }

    @Test
    func floatingPopupClosesWhenWebContentProcessTerminates() throws {
        let panel = BrowserPanel(workspaceId: UUID(), isRemoteWorkspace: false)
        defer { panel.close() }
        let popupWebView = try #require(
            panel.createFloatingPopup(
                configuration: WKWebViewConfiguration(),
                windowFeatures: WKWindowFeatures()
            )
        )
        let popupWindow = try #require(popupWebView.window)

        popupWebView.navigationDelegate?.webViewWebContentProcessDidTerminate?(popupWebView)

        #expect(popupWebView.navigationDelegate == nil)
        #expect(popupWebView.uiDelegate == nil)
        #expect(!popupWindow.isVisible)
        // Teardown closes the panel and unregisters the popup from its opener, but
        // it never detaches the web view, and this test holds the panel alive
        // (isReleasedWhenClosed is false), so popupWebView.window still points at
        // the closed panel.
        #expect(!panel.hiddenWebViewDiscardSnapshot.hasPopups)
    }

    private func makeRestoredSessionCoordinator(
        defaults: UserDefaults
    ) -> AuthCoordinator {
        AuthCoordinator(
            client: BrowserAppSessionRestoredSessionAuthClient(),
            sessionCache: CMUXAuthSessionCache(
                keyValueStore: defaults,
                key: "auth-session"
            ),
            userCache: CMUXAuthIdentityStore(
                keyValueStore: defaults,
                key: "auth-user"
            ),
            teamSelection: CMUXAuthTeamSelectionStore(
                keyValueStore: defaults,
                key: "auth-team"
            ),
            anchor: AuthPresentationContextProvider(),
            config: AuthConfig(
                stack: CMUXAuthConfig(
                    projectId: "project-a",
                    publishableClientKey: "publishable-a"
                ),
                magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback",
                apiBaseURL: "http://127.0.0.1:1"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_AUTH_FIXTURE": "1",
                    "CMUX_UITEST_AUTH_USER_ID": "restored-account",
                ],
                includesDevAuth: true
            )
        )
    }
}

private final class StoreLifetimeProbe {}

private actor BrowserAppSessionRestoredSessionAuthClient: AuthClient {
    func accessToken() async -> String? { "access-token" }
    func refreshToken() async -> String? { "refresh-token" }
    func forceRefreshAccessToken() async -> String? { "access-token" }
    func currentUser(
        throwOnMissing: Bool
    ) async throws -> CMUXAuthCore.CMUXAuthUser? {
        CMUXAuthCore.CMUXAuthUser(
            id: "restored-account",
            primaryEmail: "restored@cmux.test",
            displayName: "Restored Account"
        )
    }
    func listTeams() async throws -> [CMUXAuthCore.CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        "nonce"
    }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(
        provider: String,
        anchor: any AuthPresentationAnchoring
    ) async throws {}
    func storedAccessToken() async -> String? { "access-token" }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(
        accessToken: String?,
        refreshToken: String
    ) async -> String? {
        accessToken
    }
}

private final class BrowserWebContentProcessLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class BrowserWebAuthnReplyProbe: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var receivedKinds: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else {
            replyHandler(
                [
                    "ok": false,
                    "error": [
                        "name": "TypeError",
                        "message": "Malformed browser passkey request.",
                    ],
                ],
                nil
            )
            return
        }

        receivedKinds.append(kind)
        switch kind {
        case "getCredential":
            replyHandler(
                [
                    "ok": true,
                    "credential": [
                        "type": "public-key",
                        "id": "AQID",
                        "rawId": "AQID",
                        "authenticatorAttachment": "platform",
                        "responseKind": "assertion",
                        "response": [
                            "clientDataJSON": "BAU",
                            "authenticatorData": "Bgc",
                            "signature": "CAk",
                            "userHandle": "Cg",
                        ],
                        "clientExtensionResults": [:],
                    ],
                ],
                nil
            )
        default:
            replyHandler(
                [
                    "ok": false,
                    "error": [
                        "name": "NotSupportedError",
                        "message": "Native passkey support is unavailable.",
                    ],
                ],
                nil
            )
        }
    }
}
