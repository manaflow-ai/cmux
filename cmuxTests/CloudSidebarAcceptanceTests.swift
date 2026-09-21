import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One isolated app-host invocation for the Cloud sidebar's focused acceptance
/// checks. Reuse their behavioral fixtures and assertions; serialize the groups
/// so temporary magnification settings cannot interfere with another renderer.
@MainActor
@Suite("Cloud sidebar acceptance", .serialized)
struct CloudSidebarAcceptanceTests {
    @Test func compactGeometry() throws {
        let geometry = CloudTreeCompactLayoutTests()
        for width in [220.0, 360.0] {
            for percent in [100, 150] { try geometry.compactRows(width: width, percent: percent) }
        }
        let layout = CloudTreeWorkspaceTitleLayoutTests()
        try layout.disclosureSpacing(style: .compact)
        layout.displayHostUsesVisibleCellWidth()
        layout.containerDocumentFillsScrollViewportAtWideAndNarrowSizes()
    }

    @Test func pinsAndUnreadState() throws {
        let pins = CloudSidebarPinGeometryTests()
        for width in [220.0, 380.0] { try pins.machinePinRepaintsImmediately(width: width) }
        for percent in [75, 100, 150, 200] {
            try pins.noEmptyAttentionGutter(percent: percent)
            for width in [100.0, 320.0] { try pins.leadingPin(width: width, percent: percent) }
        }
        try pins.pinMagnification()
        try pins.compactDisclosure()
        for width in [220.0, 380.0] {
            for hover in [false, true] { try pins.longFolderTitle(width: width, hovered: hover) }
        }
        let attention = CloudSidebarAttentionLayoutTests()
        for width in [140.0, 300.0] {
            for kind in ["workspace", "terminal"] { try attention.attentionPlacement(width: width, kind: kind) }
        }
        for width in [220.0, 380.0] { try attention.outlineAttentionTransitions(width: width) }
        try attention.collapsedFolderAttention()
        try attention.collapsedFolderIsInvalidatedByDescendantReadChanges()
    }

    @Test func deletionAndRollback() async throws {
        let deletion = CloudWorkspaceDeleteOptimismTests()
        try await deletion.deletionIsVisibleBeforeProviderRefresh()
        try await deletion.admissionAndRepeatedCallsShareOneMutation()
        try await deletion.failedDeleteRestoresSnapshotAndPreservesErrorForRetry()
        try await deletion.cancelledDeleteRollsBackBeforeDestruction()
        try deletion.selectionAndExpansionSurviveFailureWithoutOverwritingNewSelection()
        try await deletion.staleNavigationIsCancelledOnlyForDeletedWorkspace()
        try await deletion.concurrentDeletesAndPartialFailurePreserveUnrelatedState()
        try await deletion.confirmedTerminalCloseIsNotResurrectedWhenWorkspaceCloseFails()
        try await deletion.renderedOutlineRemovesDescendantsThenRestoresSelectionOnFailure()
        try await deletion.providerReplacementCancelsDelete()
        try await deletion.sharedTerminalClosesOnce()
        let ledger = CloudWorkspaceDeletionLedgerTests()
        try ledger.successTombstoneSurvivesStaleRefresh()
        try ledger.failureRollsBackAndRepeatedDeleteIsIgnored()
        try ledger.concurrentDeletesHaveIndependentIdentity()
        try ledger.generationChangeRequiresAbsenceBeforeReuse()
    }

    @Test func renameAndAccountScope() async throws {
        let rename = CloudRenameOptimismTests()
        try await rename.workspaceRenameShowsImmediatelyAndRollsBackOnFailure()
        try await rename.tabAndTerminalRenamesProjectOntoTheRightViews()
        try await rename.acceptedReceiptKeepsTheNameUntilTheGraphCatchesUp()
        let menu = CloudTreeMachineMenuTests()
        try menu.catalogMachinePinsRoundTripThroughSidebar()
        try menu.expiredMachineCanBePinned()
        try await menu.sharedPinsInvalidateBothPanels()
        try await menu.scopeRefreshDoesNotRememberPreviousAccountsMachines()
        let availability = CloudTreeAvailabilityTests()
        availability.testCloudTreeSleepingAndBrokenMachinesShowOnePlaceholder()
        availability.testCloudTreeExpansionStoreDefaultsToExpandedAndPersistsMachineCollapse()
    }
}
