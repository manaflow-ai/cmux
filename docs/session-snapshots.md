# Session snapshots

cmux writes the open windows, workspaces, and panels to the session file so a quit, an update, or a relaunch can restore them. A snapshot is a bounded copy, not a complete export of everything that was open.

## Panel limit

Each workspace, and each Dock, keeps at most **512 panels** in a snapshot. Panels are the terminals, browsers, and other surfaces in that workspace or Dock, in sidebar order. Anything past the first 512 is left out.

The snapshot records that drop as `omittedPanelCount` on the workspace, and the same field on a Dock snapshot. The field is absent when every panel fit, and on snapshots written before it existed; those older files still open. Restore cannot recreate the omitted panels. It adds a warning to the workspace log naming how many were left out, for the workspace itself and for a workspace Dock or a window Dock.

The saved split layout and the focused panel refer only to panels the snapshot kept, so restore does not point at a surface that was dropped.

The limit is fixed. It keeps a session file from growing without a bound. Closing panels you no longer need, or moving some into another workspace, brings the workspace back under the limit so the next snapshot can keep all of them.
