import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Permission pane promotion policy")
struct PermissionPanePromotionPolicyTests {
    private let top = UUID()
    private let middle = UUID()
    private let bottom = UUID()

    private func input(
        enabled: Bool = true,
        kind: FeedDecisionAttentionKind = .permission,
        source: UUID?,
        panes: [UUID],
        layout: PermissionPanePromotionPolicy.LayoutClass = .verticalStack,
        selected: Bool = true,
        remote: Bool = false
    ) -> PermissionPanePromotionPolicy.Input {
        .init(
            enabled: enabled,
            eventKind: kind,
            sourcePaneID: source,
            orderedPaneIDs: panes,
            layout: layout,
            sourceSurfaceIsSelected: selected,
            isRemoteTmuxMirror: remote
        )
    }

    @Test func disabledIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(enabled: false, source: bottom, panes: [top, bottom])) == .noOp(.disabled))
    }

    @Test func nonPermissionIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(kind: .question, source: bottom, panes: [top, bottom])) == .noOp(.notPermission))
    }

    @Test func singlePaneIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: top, panes: [top], layout: .singlePane)) == .noOp(.singlePane))
    }

    @Test func alreadyTopIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: top, panes: [top, middle])) == .noOp(.alreadyTop))
    }

    @Test func middlePlansSwapWithTop() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: middle, panes: [top, middle, bottom])) == .swap(sourcePaneID: middle, targetPaneID: top))
    }

    @Test func bottomPlansSwapWithTop() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: bottom, panes: [top, middle, bottom])) == .swap(sourcePaneID: bottom, targetPaneID: top))
    }

    @Test func horizontalIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: bottom, panes: [top, bottom], layout: .horizontalRow)) == .noOp(.unsupportedLayout))
    }

    @Test func mixedLayoutIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: bottom, panes: [top, bottom], layout: .mixed2D)) == .noOp(.unsupportedLayout))
    }

    @Test func remoteTmuxIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: bottom, panes: [top, bottom], remote: true)) == .noOp(.remoteTmux))
    }

    @Test func nonSelectedSurfaceIsNoOp() {
        #expect(PermissionPanePromotionPolicy().plan(input(source: bottom, panes: [top, bottom], selected: false)) == .noOp(.surfaceNotSelected))
    }
}

@Suite("Pane surface swap rollback")
struct PaneSurfaceSwapRollbackTests {
    @Test func successfulRollbackCleansUpPlaceholders() {
        #expect(
            PaneSurfaceSwapRollbackPlan.afterSourceRollback(succeeded: true)
                == .cleanupPlaceholders
        )
    }

    @Test func failedRollbackPreservesPlaceholders() {
        #expect(
            PaneSurfaceSwapRollbackPlan.afterSourceRollback(succeeded: false)
                == .preservePlaceholders
        )
    }
}
