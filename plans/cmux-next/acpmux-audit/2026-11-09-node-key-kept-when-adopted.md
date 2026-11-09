# Notice to PL-acpmux: an adopted or held node key is never deleted or replaced (2026-11-09)

PR #39120 (lane/link-key-adoption). The cmux link now serves `node.wg.key` as its only key
(`cmux-tui/src/link/key_adoption.rs`, marker `key-adopted.json` in the link state dir), so every
paired peer knows the link by that key alone.

- `cli/mesh_node_key.rs`: new `lock_to_remove(home)` takes the WireGuard key lock in the acpmux
  home and, under it, checks `link_adopted(link_dir_for(home))`. It answers `Free(holder)`,
  `Adopted` or `Held` (another process, a running link or transport, holds the lock).
- `cli/cloud_join/leave.rs` `remove_local`: deletes the node key only on `Free`, holding the lock
  until the removal is synced. Otherwise the key stays and `machine leave` says so (`nodeKeyKept`).
  The names `link_adopted` and `link_dir_for` match sibling PR #38319, which adds the
  `NODE_KEY_MADE` rule on top; both rules hold together.
- `mesh_node_key::replace_at` (a copied home's fresh key, from `settle_clone_at`): refuses with
  `node_key.adopted` or `node_key.held` and leaves the key. The daemon then keeps the copy off
  WireGuard for that run, as for any failed clone check, and the record stays unmarked.
- Tests: `a_leave_never_deletes_an_adopted_or_held_node_key`,
  `replacing_never_touches_an_adopted_or_held_key`.

## Follow-up: archived adoptions and the tunnel rekey (review at c1898fca, F1 and F2)

- `mesh_node_key::link_adopted` now reads every adoption record in the link state dir: the
  current `key-adopted.json` and each `key-adopted.<install>.json` a sign-out or install switch
  archived (`LinkState::move_install`). A record naming this home, unreadable, or naming no
  `key_dir` keeps the key; a link dir that cannot be listed keeps it too.
- One guard, `mesh_node_key::adoption_depends(home)` (and `adoption_depends_held` with the key
  lock), is asked before every change of `node.wg.key`: `lock_to_remove` (`machine leave`'s
  delete, `replace_at` for a copied home) and `promote_pending_held` plus the start of
  `machine_tunnel::rekey` (`_acpmux/machine.tunnel.rekey`, and the pending rekey an attach
  finishes). The rekey is refused with `reason`/`code` `node_key.adopted` before a candidate is
  written or sent, until the link can rekey its paired peers itself.
- Tests: `an_archived_adoption_keeps_the_key_from_every_change`,
  `a_leave_keeps_a_node_key_an_archived_adoption_names`,
  `a_rekey_is_refused_while_an_adoption_depends_on_the_key` and, end to end with the real
  binary, `an_archived_adoption_keeps_its_node_key_through_a_leave_and_serves_it_restored`
  (`cmux-tui/tests/wg_keys_per_mac.rs`).
