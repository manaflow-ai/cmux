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
