# Groups on mobile (P1: display + collapse/expand)

Desktop organizes workspaces into collapsible named GROUPS. An anchor workspace
owns each group; the anchor renders as the group header (no separate row);
collapsed groups hide members but keep the header. iOS currently flattens and
ignores groups. P1 = render groups on iOS + expand/collapse from the phone.
Phone-side group create/edit/rename/delete/reorder is DEFERRED.

Canonical desktop semantics (mirror these): `Sources/SidebarWorkspaceRenderItem.swift`
- Items follow `tabs` order. A group header is emitted at the first member's position.
- The anchor workspace is NEVER a separate row (header represents it).
- Header label = `group.name`. Collapsed => members skipped, header kept.
- Ungrouped workspaces interleave inline by `tabs` position.

## Payload did NOT carry group info before this change
`mobileWorkspacePayload` emitted only id/title/current_directory/is_selected/
is_pinned/terminals. No group id, no groups array. So step 1 was to surface it.

## Phase 1 — Mac host (surface group structure)
1. `mobileWorkspacePayload` (TerminalController.swift): add `group_id` (nullable).
2. `v2MobileWorkspaceList`: add top-level `groups` array. Scoped branch uses the
   resolved TabManager's `workspaceGroups`; all-windows branch aggregates each
   window's groups in window-iteration order (groups are per-TabManager). Each
   group entry: id, name, is_collapsed, is_pinned, anchor_workspace_id,
   member_workspace_ids (subset of v2WorkspaceGroupPayload shape).
3. `MobileWorkspaceListObserver`: subscribe to `$workspaceGroups` and fold group
   order + id + name + is_collapsed + is_pinned + anchor + member set into
   `summaryHash`. Without this, a phone collapse toggles `isCollapsed` on the Mac
   but the observer never emits `workspace.updated`, so the disclosure looks
   frozen. (Memory: "observer must hash the @Published it pushes".)
4. Expose `workspace.group.collapse`/`workspace.group.expand` to mobile: add cases
   to BOTH `mobileHostHandleRPC` (the real mobile gate) and the ticket-auth switch
   in `MobileHostService.swift`. Display-only state behind the same-account Stack
   gate, so authorized (return nil) like `mobile.workspace.list`. Route by
   `group_id` (v2ResolveTabManager already locates the owning window's TabManager
   across all windows by group_id; group ids are globally unique).
5. Advertise `workspace.groups.v1` capability so iOS feature-detects.

## Phase 2 — iOS (decode + render + collapse)
6. `MobileSyncWorkspaceListResponse`: add optional `groupId` per workspace +
   optional `groups: [Group]` (all optional => backward compatible).
7. New `MobileWorkspaceGroupPreview` value model. Add `groupId` to
   `MobileWorkspacePreview`.
8. Store: parallel `workspaceGroups: [MobileWorkspaceGroupPreview]`, populated in
   `applyRemoteWorkspaceList`. `supportsWorkspaceGroups` capability flag (mirror
   `supportsWorkspaceActions`). `setWorkspaceGroupCollapsed(groupId:_)` RPC
   (fire-and-forget, authoritative re-fetch via observer; no local optimistic
   state, per the optimistic-UI rule).
9. Render-item builder mirroring SidebarWorkspaceRenderItem (anchor-as-header,
   collapsed hides members). `WorkspaceListView` renders collapsible sections.
   Snapshot boundary: pass value models + a `collapseGroup: (id, Bool) -> Void`
   closure into the List, no store ref below the List boundary.

## Ordering caveat
Existing `filteredWorkspaces` does pinned-first sort which scatters group members.
The grouped render path must preserve Mac member contiguity. P1 keeps Mac order
(render items already encode order); the flat pinned-first sort applies only when
there are no groups, to avoid breaking contiguity.

## Localize
New strings via L10n.string/String(localized:) keys in
`ios/cmux/Resources/Localizable.xcstrings` (en + ja).

## Verify
Build-only on iOS simulator with tagged derivedDataPath. No xcodebuild test
locally. No stray cmux DEV launch.
