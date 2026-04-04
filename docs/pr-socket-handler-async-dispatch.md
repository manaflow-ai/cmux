## Summary

Reduce `reportPorts` handler blocking by applying the port mutation on
`DispatchQueue.main.async` instead of holding `main.sync` through the full update.
Tab/panel resolution and validation still run in a **short** `main.sync` so
invalid targets return synchronous `ERROR:` lines on the socket (same contract as
before `schedulePanelMetadataMutation`, which would have returned `OK` on
silent async failures).

## Problem

`reportPorts` (the `report_ports` socket command) used `DispatchQueue.main.sync`
to resolve the target tab/panel and apply the port mutation in one block. When
the main thread is stalled — for example during a heavy SwiftUI render pass —
the handler thread blocks at `dispatch_sync_f_slow`, consuming memory and
contributing to thread pile-up.

In a real incident, many socket handler threads accumulated via this pattern,
making the app unresponsive.

The project's CLAUDE.md documents a "Socket command threading policy" that
discourages `DispatchQueue.main.sync` on high-frequency telemetry paths. The
narrower fix is to avoid a **long** sync that includes the mutation, not to
drop correct `ERROR:` responses for bad `--tab` / `--panel`.

## Fix

1. Parse ports off-main (unchanged).
2. **`DispatchQueue.main.sync`:** resolve tab, resolve surface id, membership
   checks — return the same `ERROR: ...` strings as the original implementation.
3. **`DispatchQueue.main.async`:** `tabForSidebarMutation`, `pruneSurfaceMetadata`,
   then `surfaceListeningPorts` + `recomputeListeningPorts`.
4. Return `"OK"` only after validation succeeds (errors never become `OK`).

Added `tests_v2/test_report_ports_v1_error_contract.py` to assert invalid
`--tab` / `--panel` still produce `ERROR:` on the wire.

## Scope and follow-up

There are additional `DispatchQueue.main.sync` call sites in
`TerminalController.swift` that could use similar split patterns where clients
rely on synchronous error strings.

## Test plan

- [ ] Verify `report_ports` still updates sidebar port indicators correctly
- [ ] Verify `report_ports` with explicit `--tab` and `--panel` arguments
- [ ] Verify `report_ports` with invalid arguments still returns errors
- [ ] Run `tests_v2/test_report_ports_v1_error_contract.py` and full `tests_v2/` against a tagged debug build
- [ ] Simulate main thread stall and confirm `report_ports` callers do not hang for the full mutation duration
