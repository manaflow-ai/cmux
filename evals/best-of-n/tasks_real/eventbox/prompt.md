Implement `Mailbox` in `eventbox.py`: one subscriber's bounded queue of daemon events, which coalesces chatty events
instead of overflowing.

Background (from cmux commit 43375208c90, "coalesce bell events in subscriber mailboxes"): a shell loop printing
`\a` sent one bell event per bell, filled a slow subscriber's mailbox, and closed its connection with an overflow.
Bells, like titles, scrolls and output, must be coalesced per surface. The module only has a stub.

Events are tuples whose first item is the kind. The class:

- `Mailbox(capacity)`; attributes `closed` and `overflowed`, both False at first. `push(event) -> bool` and
  `pop() -> event | None` (the oldest event by the order below, or None when empty).
- Every push of an event that gets queued or replaces one takes the next sequence number; `pop` returns the event with
  the lowest sequence among everything held, plain and coalesced.
- A closed mailbox rejects every push (returns False, holds nothing new).
- Slot rule: an event that needs a new slot is refused when `plain count + coalesced count >= capacity`; then set
  `closed` and `overflowed` and return False (what is held stays poppable).
- Coalesced kinds: `"title"`, `"scroll"`, `"bell"`, `"output"`, `"agent"`, `"status"` (key: kind and `event[1]`, the
  surface) and `"config_reload"` (one key for all). If an event with the same key is held, the new event replaces it,
  takes the new sequence (so it now pops after everything older) and returns True with no slot needed; else it needs a
  slot.
- `("exited", surface)`: first discard every coalesced event of that surface (any coalesced kind with that
  `event[1]`), then queue it as a plain event, which needs a slot.
- `("empty",)`: keep only the held plain `"exited"` and `"workspace_closed"` events (the newest `capacity - 1` of
  them, by sequence, if more), drop everything else, including all coalesced events, then append the empty event. It
  always returns True (even when the slot rule would refuse it) and keeps `closed` as it was; on a closed mailbox it
  is refused like any push.
- `("tree_changed",)`: dropped (returns True, nothing queued, no sequence used) when the newest held plain event is a
  `tree_changed` and no coalesced event is newer than it; otherwise it is a plain event that needs a slot.
- Any other kind is a plain event that needs a slot.
