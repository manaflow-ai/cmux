import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserImportMappingTests: XCTestCase {
    @MainActor
    func testDefaultExecutionPlanUsesSeparateModeForMultipleSourceProfiles() {
        let defaultProfile = BrowserProfileDefinition(
            id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
            displayName: "Default",
            createdAt: .distantPast,
            isBuiltInDefault: true
        )
        let sourceProfiles = [
            makeSourceProfile(displayName: "You", path: "/tmp/browser-import-you", isDefault: true),
            makeSourceProfile(displayName: "austin", path: "/tmp/browser-import-austin", isDefault: false),
        ]

        let plan = BrowserImportPlanResolver.defaultPlan(
            selectedSourceProfiles: sourceProfiles,
            destinationProfiles: [defaultProfile],
            preferredSingleDestinationProfileID: defaultProfile.id
        )

        XCTAssertEqual(plan.mode, .separateProfiles)
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries.map { $0.sourceProfiles.map(\.displayName) }, [["You"], ["austin"]])
    }

    @MainActor
    func testDefaultExecutionPlanUsesSingleDestinationForSingleSourceProfile() {
        let defaultProfileID = UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!
        let sourceProfile = makeSourceProfile(
            displayName: "You",
            path: "/tmp/browser-import-single",
            isDefault: true
        )

        let plan = BrowserImportPlanResolver.defaultPlan(
            selectedSourceProfiles: [sourceProfile],
            destinationProfiles: [],
            preferredSingleDestinationProfileID: defaultProfileID
        )

        XCTAssertEqual(plan.mode, .singleDestination)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].sourceProfiles.map(\.displayName), ["You"])
    }

    @MainActor
    func testSeparatePlanReusesExistingSameNamedDestinationProfiles() {
        let workID = UUID()
        let destinationProfiles = [
            BrowserProfileDefinition(
                id: workID,
                displayName: "You",
                createdAt: .distantPast,
                isBuiltInDefault: false
            )
        ]
        let sourceProfiles = [
            makeSourceProfile(displayName: " you ", path: "/tmp/browser-import-match", isDefault: true)
        ]

        let plan = BrowserImportPlanResolver.separateProfilesPlan(
            selectedSourceProfiles: sourceProfiles,
            destinationProfiles: destinationProfiles
        )

        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].destination, .existing(workID))
    }

    @MainActor
    func testSeparatePlanUsesStableCreateNamesWhenTwoSourceProfilesShareDisplayName() {
        let sourceProfiles = [
            makeSourceProfile(displayName: "Work", path: "/tmp/browser-import-work-1", isDefault: true),
            makeSourceProfile(displayName: "Work", path: "/tmp/browser-import-work-2", isDefault: false),
        ]

        let plan = BrowserImportPlanResolver.separateProfilesPlan(
            selectedSourceProfiles: sourceProfiles,
            destinationProfiles: []
        )

        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries[0].destination, .createNamed("Work"))
        XCTAssertEqual(plan.entries[1].destination, .createNamed("Work (2)"))
    }

    func testStep3PresentationShowsPerProfileRowsWhenPlanUsesSeparateMode() {
        let presentation = BrowserImportStep3Presentation(
            plan: BrowserImportExecutionPlan(
                mode: .separateProfiles,
                entries: [
                    BrowserImportExecutionEntry(
                        sourceProfiles: [
                            makeSourceProfile(
                                displayName: "You",
                                path: "/tmp/browser-import-presentation-separate",
                                isDefault: true
                            )
                        ],
                        destination: .createNamed("You")
                    )
                ]
            )
        )

        XCTAssertTrue(presentation.showsSeparateRows)
        XCTAssertFalse(presentation.showsSingleDestinationPicker)
    }

    func testStep3PresentationShowsSingleDestinationPickerWhenPlanUsesMergeMode() {
        let presentation = BrowserImportStep3Presentation(
            plan: BrowserImportExecutionPlan(
                mode: .mergeIntoOne,
                entries: []
            )
        )

        XCTAssertFalse(presentation.showsSeparateRows)
        XCTAssertTrue(presentation.showsSingleDestinationPicker)
    }

    @MainActor
    func testRealizePlanCreatesMissingDestinationProfilesOnlyWhenRequested() throws {
        let suiteName = "BrowserImportMappingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserProfileStore(defaults: defaults)
        let plan = BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: [
                BrowserImportExecutionEntry(
                    sourceProfiles: [
                        makeSourceProfile(
                            displayName: "You",
                            path: "/tmp/browser-import-realize-create",
                            isDefault: true
                        )
                    ],
                    destination: .createNamed("You")
                )
            ]
        )

        let realized = try BrowserImportPlanResolver.realize(plan: plan, profileStore: store)

        XCTAssertEqual(realized.createdProfiles.map(\.displayName), ["You"])
        XCTAssertEqual(store.profiles.map(\.displayName), ["Default", "You"])
    }

    @MainActor
    func testRealizePlanReusesExistingProfileInsteadOfCreatingDuplicate() throws {
        let suiteName = "BrowserImportMappingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserProfileStore(defaults: defaults)
        let existing = try XCTUnwrap(store.createProfile(named: "You"))
        let plan = BrowserImportExecutionPlan(
            mode: .separateProfiles,
            entries: [
                BrowserImportExecutionEntry(
                    sourceProfiles: [
                        makeSourceProfile(
                            displayName: "You",
                            path: "/tmp/browser-import-realize-existing",
                            isDefault: true
                        )
                    ],
                    destination: .existing(existing.id)
                )
            ]
        )

        let realized = try BrowserImportPlanResolver.realize(plan: plan, profileStore: store)

        XCTAssertTrue(realized.createdProfiles.isEmpty)
        XCTAssertEqual(realized.entries[0].destinationProfileID, existing.id)
    }

    func testAggregateOutcomeIncludesOneMappingLinePerDestination() {
        let outcome = BrowserImportOutcome(
            browserName: "Helium",
            scope: .cookiesAndHistory,
            domainFilters: [],
            createdDestinationProfileNames: ["You", "austin"],
            entries: [
                BrowserImportOutcomeEntry(
                    sourceProfileNames: ["You"],
                    destinationProfileName: "You",
                    importedCookies: 10,
                    skippedCookies: 0,
                    importedHistoryEntries: 20,
                    warnings: []
                ),
                BrowserImportOutcomeEntry(
                    sourceProfileNames: ["austin"],
                    destinationProfileName: "austin",
                    importedCookies: 5,
                    skippedCookies: 1,
                    importedHistoryEntries: 9,
                    warnings: []
                ),
            ],
            warnings: []
        )

        let lines = BrowserImportOutcomeFormatter.lines(for: outcome)

        XCTAssertTrue(lines.contains("You -> You"))
        XCTAssertTrue(lines.contains("austin -> austin"))
        XCTAssertTrue(lines.contains("Created cmux profiles: You, austin"))
    }

    private func makeSourceProfile(displayName: String, path: String, isDefault: Bool) -> InstalledBrowserProfile {
        InstalledBrowserProfile(
            displayName: displayName,
            rootURL: URL(fileURLWithPath: path, isDirectory: true),
            isDefault: isDefault
        )
    }
}
