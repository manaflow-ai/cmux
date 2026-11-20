# Owner notes, 2026-11-11: fixes for a red feat-cmux-next

The pre-push guardrail names owners for the files below. Their sessions (cmux-4f, cmux-b6) were
not live, so `acpmux send` could not reach them and the notes are here. No action is needed
unless you disagree with a change.

## PL-acpmux (acpmux, session cmux-4f)

- `514107dfeb3` `cmux-tui/crates/acpmux/src/hub/watch_events.rs`: `page["pageThrough"].as_u64()`
  is `page.get("pageThrough").and_then(Value::as_u64)`. Same value; no panic site
  (clippy::indexing_slicing).
- `514107dfeb3` `cmux-tui/crates/cmux-tui/src/cli/agents/events.rs`: `cursor["live"] = json!(live)`
  is `as_object_mut()` and `insert("live", ...)`.
- The two `machine_tunnel` rekey tests that failed with `key_held` and `holderPid: null`
  (cmux-tui spec inventory run 42960856401, 2 of 3 attempts) were not wrong, and
  `machine_tunnel.rs` is unchanged. The cause was in `cmux-link`'s `KeyHolder` (below).

## PL-daemon (cmux-tui-core, session cmux-b6)

- `514107dfeb3` `mux/presentation/decoration_walks.rs`: two `lock().unwrap()` are
  `lock().unwrap_or_else(PoisonError::into_inner)`, as the other walks in that file.
- `514107dfeb3` `mux/resource_topology/batch_close.rs`: `state.workspaces[index]` is
  `state.workspaces.get(index).context("close target disappeared")?`.
- `514107dfeb3` `mux/resource_topology/close_effects.rs`: `&state.workspaces[index]` is
  `if let Some(closed) = state.workspaces.get(index)`. An index that names no workspace keeps the
  full split-index rebuild (`split_index_changed` stays true) instead of a panic.

These came from PR #41024 (it could not merge) and removed the panic-ratchet red
(`cmux-tui-core: clippy::indexing_slicing 855 > baseline 853`). No baseline changed.

## cmux-link key lock (whoever owns `cmux-link/src/key_holder.rs`)

`flock` belongs to the open file description. A child forked while the lock was held shares it
until it execs or exits, so a holder's drop did not always free the lock at once, and the next
`KeyHolder::acquire` or `holder()` read `KeyHeld` with no pid. acpmux forks for every agent, so
this was also a real, short refusal of a rekey, not only a test failure.

A holder writes its pid record right after it locks and removes it before it lets go. A held lock
with no record is therefore a leftover descriptor (or a holder about to write its record), and
`acquire` and `holder()` now look again every 5 ms, for at most 2 s, until the lock is free or a
record appears. A lock with a record is refused at once, as before. `acquire` can now block its
thread for up to 2 s in that one state.

Test: `a_descriptor_a_forked_child_still_holds_after_the_drop_is_waited_out`. On cmux-lawrence-2
it failed without the fix (and made `a_second_holder_in_this_process_is_refused_until_the_first_drops`
fail too, through the same leaked descriptor) and passed 3 of 3 with it.
