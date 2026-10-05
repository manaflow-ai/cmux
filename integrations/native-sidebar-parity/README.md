# Native sidebar parity integration

This integration reuses CMUX's existing AppKit workspace and group menus. The
extension can request native menu presentation, but cannot choose a menu item,
submit a shell command, or supply a path or notification target. Native actions,
shortcuts, palettes, confirmations, group config commands, and SSH availability
remain in the shared CMUX handlers.

The dependent source payload is intentionally outside compiled source roots:
the current main branch predates the paired Sidebar API 2.3 work. The patch names
exact immutable owner commits in `pair-source-receipt.json`; it includes native
menu transport wiring, revision guarded manual tags from the canonical taxonomy,
and separate activity, attention, and confirmed execution mode.

The typed menu request contract, target capture helper, and targeted tests are usable independently.
CMUX's target capture helper freezes relative close membership at menu open and
narrows to surviving UUIDs before the existing confirmation. Manual tags never
set workspace priority or accept automatic classification proposals.

## Validation and integration boundary

Foundation contract, target capture, status, and catalog tests have passed. The
private source pair was assembled without foreign worktree edits. Full tagged
build, live extension grants, native right click/actions, and actual appex resource
lookup remain mandatory before declaring the paired integration complete.
Offscreen renders alone do not prove those runtime boundaries.

The source owner's active missions retain the existing integration scopes.
Apply this patch only after serialized handback, then run the paired dogfood
build and native UI canaries. Never quit, replace, or relaunch running production
CMUX. Production activation is deferred to its normal user initiated relaunch.
