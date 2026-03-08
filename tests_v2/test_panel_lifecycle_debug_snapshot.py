#!/usr/bin/env python3
"""Smoke test for the DEBUG panel lifecycle shadow snapshot.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll

This is intentionally narrow. It validates the transport and basic invariants
of the shadow snapshot without depending on a fragile workspace topology.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        snapshot = c.panel_lifecycle()
        counts = dict(snapshot.get("counts") or {})
        desired = dict(snapshot.get("desired") or {})
        desired_counts = dict(desired.get("counts") or {})
        divergence = dict(desired.get("divergence") or {})
        terminal_plan = dict(desired.get("terminalExecutorPlan") or {})
        terminal_plan_counts = dict(terminal_plan.get("counts") or {})
        terminal_binding_counts = dict(terminal_plan.get("bindingCounts") or {})
        terminal_bindings = list(terminal_plan.get("bindings") or [])
        terminal_plan_records = list(terminal_plan.get("records") or [])
        audit = dict(snapshot.get("audit") or {})
        records = list(snapshot.get("records") or [])
        desired_records = list(desired.get("records") or [])
        _must(records, f"panel_lifecycle returned no records: {snapshot}")
        _must(desired_records, f"panel_lifecycle returned no desired records: {snapshot}")

        _must(
            counts.get("panelCount") == len(records),
            f"panelCount mismatch: counts={counts} records={len(records)}",
        )
        _must(
            desired_counts.get("panelCount") == len(desired_records),
            f"desired panelCount mismatch: counts={desired_counts} records={len(desired_records)}",
        )
        _must(
            len(records) == len(desired_records),
            f"record count mismatch between current and desired snapshots: current={len(records)} desired={len(desired_records)}",
        )

        visible_count = sum(1 for row in records if row.get("activeWindowMembership"))
        responder_count = sum(1 for row in records if row.get("responderEligible"))
        accessibility_count = sum(1 for row in records if row.get("accessibilityParticipation"))
        anchored_count = sum(1 for row in records if row.get("anchor"))
        non_visible_anchored_count = sum(
            1 for row in records if row.get("anchor") and not row.get("desiredVisible")
        )
        inactive_tab_anchored_count = sum(
            1
            for row in records
            if row.get("anchor")
            and row.get("mountedWorkspace")
            and not row.get("selectedInPane")
            and not row.get("desiredVisible")
        )
        desired_visible_count = sum(1 for row in desired_records if row.get("targetVisible"))
        desired_active_count = sum(1 for row in desired_records if row.get("targetActive"))
        desired_awaiting_anchor_count = sum(
            1 for row in desired_records if row.get("targetState") == "awaitingAnchor"
        )
        desired_visible_residency_count = sum(
            1 for row in desired_records if row.get("targetResidency") == "visibleInActiveWindow"
        )
        desired_parked_count = sum(
            1 for row in desired_records if row.get("targetResidency") == "parkedOffscreen"
        )
        desired_detached_count = sum(
            1 for row in desired_records if row.get("targetResidency") == "detachedRetained"
        )
        desired_destroyed_count = sum(
            1 for row in desired_records if row.get("targetResidency") == "destroyed"
        )
        terminal_record_count = sum(1 for row in records if row.get("panelType") == "terminal")
        terminal_binding_record_count = len(terminal_bindings)
        terminal_binding_visible_count = sum(1 for row in terminal_bindings if row.get("visibleInUI"))
        terminal_binding_hidden_count = sum(1 for row in terminal_bindings if row.get("hostedHidden"))
        terminal_binding_attached_count = sum(
            1 for row in terminal_bindings if row.get("attachedToPortalHost")
        )
        terminal_binding_generation_count = sum(
            1 for row in terminal_bindings if row.get("guardGeneration") is not None
        )
        terminal_noop_count = sum(1 for row in terminal_plan_records if row.get("action") == "noop")
        terminal_wait_count = sum(
            1 for row in terminal_plan_records if row.get("action") == "waitForAnchor"
        )
        terminal_bind_count = sum(
            1 for row in terminal_plan_records if row.get("action") == "bindVisible"
        )
        terminal_detach_count = sum(
            1 for row in terminal_plan_records if row.get("action") == "moveToDetachedRetained"
        )
        terminal_park_count = sum(
            1 for row in terminal_plan_records if row.get("action") == "moveToParkedOffscreen"
        )
        terminal_destroy_count = sum(
            1 for row in terminal_plan_records if row.get("action") == "destroy"
        )

        _must(
            counts.get("visibleInActiveWindowCount") == visible_count,
            f"visibleInActiveWindowCount mismatch: counts={counts} visible={visible_count}",
        )
        _must(
            counts.get("anchoredPanelCount") == anchored_count,
            f"anchoredPanelCount mismatch: counts={counts} anchored={anchored_count}",
        )
        _must(
            counts.get("nonVisibleAnchoredPanelCount") == non_visible_anchored_count,
            f"nonVisibleAnchoredPanelCount mismatch: counts={counts} nonVisibleAnchored={non_visible_anchored_count}",
        )
        _must(
            counts.get("inactiveTabAnchoredPanelCount") == inactive_tab_anchored_count,
            f"inactiveTabAnchoredPanelCount mismatch: counts={counts} inactiveTabAnchored={inactive_tab_anchored_count}",
        )
        _must(
            counts.get("responderEligibleCount") == responder_count,
            f"responderEligibleCount mismatch: counts={counts} responder={responder_count}",
        )
        _must(
            counts.get("accessibilityParticipationCount") == accessibility_count,
            f"accessibilityParticipationCount mismatch: counts={counts} accessibility={accessibility_count}",
        )
        _must(
            desired_counts.get("visibleTargetCount") == desired_visible_count,
            f"visibleTargetCount mismatch: counts={desired_counts} visible={desired_visible_count}",
        )
        _must(
            desired_counts.get("activeTargetCount") == desired_active_count,
            f"activeTargetCount mismatch: counts={desired_counts} active={desired_active_count}",
        )
        _must(
            desired_counts.get("awaitingAnchorCount") == desired_awaiting_anchor_count,
            f"awaitingAnchorCount mismatch: counts={desired_counts} awaiting={desired_awaiting_anchor_count}",
        )
        _must(
            desired_counts.get("visibleInActiveWindowCount") == desired_visible_residency_count,
            f"desired visible residency mismatch: counts={desired_counts} visibleResidency={desired_visible_residency_count}",
        )
        _must(
            desired_counts.get("parkedOffscreenCount") == desired_parked_count,
            f"parkedOffscreenCount mismatch: counts={desired_counts} parked={desired_parked_count}",
        )
        _must(
            desired_counts.get("detachedRetainedCount") == desired_detached_count,
            f"detachedRetainedCount mismatch: counts={desired_counts} detached={desired_detached_count}",
        )
        _must(
            desired_counts.get("destroyedCount") == desired_destroyed_count,
            f"destroyedCount mismatch: counts={desired_counts} destroyed={desired_destroyed_count}",
        )
        _must(
            divergence.get("panelCount") == len(records),
            f"divergence panelCount mismatch: divergence={divergence} current={len(records)}",
        )
        _must(
            terminal_plan_counts.get("panelCount") == terminal_record_count,
            f"terminal plan panelCount mismatch: counts={terminal_plan_counts} terminalRecords={terminal_record_count}",
        )
        _must(
            terminal_plan_counts.get("noopCount") == terminal_noop_count,
            f"terminal noopCount mismatch: counts={terminal_plan_counts} actual={terminal_noop_count}",
        )
        _must(
            terminal_plan_counts.get("waitForAnchorCount") == terminal_wait_count,
            f"terminal waitForAnchorCount mismatch: counts={terminal_plan_counts} actual={terminal_wait_count}",
        )
        _must(
            terminal_plan_counts.get("bindVisibleCount") == terminal_bind_count,
            f"terminal bindVisibleCount mismatch: counts={terminal_plan_counts} actual={terminal_bind_count}",
        )
        _must(
            terminal_plan_counts.get("moveToDetachedRetainedCount") == terminal_detach_count,
            f"terminal moveToDetachedRetainedCount mismatch: counts={terminal_plan_counts} actual={terminal_detach_count}",
        )
        _must(
            terminal_plan_counts.get("moveToParkedOffscreenCount") == terminal_park_count,
            f"terminal moveToParkedOffscreenCount mismatch: counts={terminal_plan_counts} actual={terminal_park_count}",
        )
        _must(
            terminal_plan_counts.get("destroyCount") == terminal_destroy_count,
            f"terminal destroyCount mismatch: counts={terminal_plan_counts} actual={terminal_destroy_count}",
        )
        _must(
            terminal_binding_counts.get("panelCount") == terminal_binding_record_count,
            f"terminal binding panelCount mismatch: counts={terminal_binding_counts} actual={terminal_binding_record_count}",
        )
        _must(
            terminal_binding_counts.get("visibleEntryCount") == terminal_binding_visible_count,
            f"terminal binding visibleEntryCount mismatch: counts={terminal_binding_counts} actual={terminal_binding_visible_count}",
        )
        _must(
            terminal_binding_counts.get("hiddenEntryCount") == terminal_binding_hidden_count,
            f"terminal binding hiddenEntryCount mismatch: counts={terminal_binding_counts} actual={terminal_binding_hidden_count}",
        )
        _must(
            terminal_binding_counts.get("attachedEntryCount") == terminal_binding_attached_count,
            f"terminal binding attachedEntryCount mismatch: counts={terminal_binding_counts} actual={terminal_binding_attached_count}",
        )
        _must(
            terminal_binding_counts.get("currentGenerationCount") == terminal_binding_generation_count,
            f"terminal binding currentGenerationCount mismatch: counts={terminal_binding_counts} actual={terminal_binding_generation_count}",
        )

        selected_workspace_id = snapshot.get("selectedWorkspaceId")
        _must(bool(selected_workspace_id), f"selectedWorkspaceId missing: {snapshot}")
        _must(
            any(row.get("workspaceId") == selected_workspace_id for row in records),
            f"selectedWorkspaceId not present in records: {selected_workspace_id}",
        )

        for executor_name in ("terminal", "browser"):
            executor = dict(audit.get(executor_name) or {})
            totals = dict(executor.get("totals") or {})
            portals = list(executor.get("portals") or [])
            _must(executor, f"missing audit executor payload for {executor_name}: {audit}")
            _must(
                int(executor.get("portalCount") or 0) == len(portals),
                f"{executor_name} portalCount mismatch: {executor}",
            )
            _must(
                int(executor.get("mappingCount") or 0) >= int(totals.get("mappedObjectCount") or 0),
                f"{executor_name} mappingCount invariant failed: {executor}",
            )
            for portal in portals:
                _must(
                    int(portal.get("mappedHostedSubviewCount") or 0) <= int(portal.get("hostedSubviewCount") or 0),
                    f"{executor_name} mappedHostedSubviewCount invariant failed: {portal}",
                )
                _must(
                    int(portal.get("orphanHostedSubviewCount") or 0) <= int(portal.get("hostedSubviewCount") or 0),
                    f"{executor_name} orphanHostedSubviewCount invariant failed: {portal}",
                )

        for row in records:
            if row.get("activeWindowMembership"):
                _must(
                    row.get("desiredVisible"),
                    f"activeWindowMembership without desiredVisible: {row}",
                )
            if row.get("responderEligible"):
                _must(
                    row.get("activeWindowMembership") and row.get("desiredActive"),
                    f"responderEligible invariant failed: {row}",
                )
            if row.get("accessibilityParticipation"):
                _must(
                    row.get("activeWindowMembership"),
                    f"accessibilityParticipation invariant failed: {row}",
                )

        desired_by_panel_id = {row.get("panelId"): row for row in desired_records}
        state_mismatch_count = 0
        residency_mismatch_count = 0
        active_window_mismatch_count = 0
        responder_mismatch_count = 0
        accessibility_mismatch_count = 0
        anchor_required_but_missing_count = 0

        for row in records:
            desired_row = desired_by_panel_id.get(row.get("panelId"))
            _must(desired_row is not None, f"missing desired record for panel: {row}")

            if row.get("state") != desired_row.get("targetState"):
                state_mismatch_count += 1
            if row.get("residency") != desired_row.get("targetResidency"):
                residency_mismatch_count += 1
            if row.get("activeWindowMembership") != desired_row.get("targetVisible"):
                active_window_mismatch_count += 1
            if row.get("responderEligible") != desired_row.get("targetResponderEligible"):
                responder_mismatch_count += 1
            if row.get("accessibilityParticipation") != desired_row.get("targetAccessibilityParticipation"):
                accessibility_mismatch_count += 1
            if desired_row.get("requiresCurrentGenerationAnchor") and not desired_row.get("anchorReadyForVisibility"):
                anchor_required_but_missing_count += 1

            if desired_row.get("anchorReadyForVisibility"):
                _must(
                    desired_row.get("requiresCurrentGenerationAnchor"),
                    f"anchorReadyForVisibility without requiresCurrentGenerationAnchor: {desired_row}",
                )
            _must(
                desired_row.get("panelType") == row.get("panelType"),
                f"desired panelType mismatch: current={row} desired={desired_row}",
            )
            if desired_row.get("targetResponderEligible"):
                _must(
                    desired_row.get("targetVisible") and desired_row.get("targetActive"),
                    f"targetResponderEligible invariant failed: {desired_row}",
                )
            if desired_row.get("targetAccessibilityParticipation"):
                _must(
                    desired_row.get("targetVisible"),
                    f"targetAccessibilityParticipation invariant failed: {desired_row}",
                )

        _must(
            divergence.get("stateMismatchCount") == state_mismatch_count,
            f"stateMismatchCount mismatch: divergence={divergence} actual={state_mismatch_count}",
        )
        _must(
            divergence.get("residencyMismatchCount") == residency_mismatch_count,
            f"residencyMismatchCount mismatch: divergence={divergence} actual={residency_mismatch_count}",
        )
        _must(
            divergence.get("activeWindowMismatchCount") == active_window_mismatch_count,
            f"activeWindowMismatchCount mismatch: divergence={divergence} actual={active_window_mismatch_count}",
        )
        _must(
            divergence.get("responderMismatchCount") == responder_mismatch_count,
            f"responderMismatchCount mismatch: divergence={divergence} actual={responder_mismatch_count}",
        )
        _must(
            divergence.get("accessibilityMismatchCount") == accessibility_mismatch_count,
            f"accessibilityMismatchCount mismatch: divergence={divergence} actual={accessibility_mismatch_count}",
        )
        _must(
            divergence.get("anchorRequiredButMissingCount") == anchor_required_but_missing_count,
            f"anchorRequiredButMissingCount mismatch: divergence={divergence} actual={anchor_required_but_missing_count}",
        )

        for row in terminal_plan_records:
            _must(
                row.get("targetResidency") != "parkedOffscreen",
                f"terminal plan should not park terminals in current capability model: {row}",
            )
            if row.get("action") == "waitForAnchor":
                _must(
                    row.get("requiresCurrentGenerationAnchor") and not row.get("anchorReadyForVisibility"),
                    f"waitForAnchor invariant failed: {row}",
                )
            if row.get("action") == "bindVisible":
                _must(
                    row.get("targetVisible") and row.get("anchorReadyForVisibility"),
                    f"bindVisible invariant failed: {row}",
                )
                _must(
                    not row.get("bindingSatisfied"),
                    f"bindVisible should represent unsatisfied executor state: {row}",
                )
            if row.get("action") == "noop" and row.get("targetVisible"):
                _must(
                    row.get("bindingSatisfied"),
                    f"visible noop should require satisfied binding state: {row}",
                )

    print(
        "PASS: panel lifecycle snapshot transport works and aggregate invariants hold "
        f"(records={len(records)} visible={visible_count} responder={responder_count} "
        f"desiredVisible={desired_visible_count})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
