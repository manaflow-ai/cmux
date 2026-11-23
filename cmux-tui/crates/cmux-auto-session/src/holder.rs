//! One Auto chat on one machine, as an explicit state machine: a [`Chat`] whose [`State`] carries
//! its own data, and one pure [`step`] from `(Chat, Event, now)` to the next chat and the
//! [`Effect`]s the daemon runs. Every (state, event) pair is written out in `laptop.rs` and
//! `machine.rs`: no arm falls through to a default, so a new state or event does not compile
//! until each pair is decided. The table ([`table`]) is committed as
//! `schemas/auto-session-holder/table.json`.
//!
//! The daemon keeps one `Chat` per Auto chat. It sends each thing that happens as an [`Event`]
//! with the wall clock in milliseconds, replaces the chat with the one `step` returns and runs
//! the effects in order. Nothing here reads a clock or sends a request.
//!
//! What it encodes, from `plans/cmux-next/auto-mode/DESIGN.md`:
//!
//! - **Renewals.** The holder renews every [`RENEW_MS`](crate::consts::RENEW_MS), a laptop that
//!   is not the holder renews as standby, and a change of `needsRun` is told at once. Only the
//!   answer to the newest request counts; any other is ignored.
//! - **The store's answer is a role.** "holder" to a renewal that is not a standby's: go on,
//!   at the answer's epoch. "holder" to a standby's renewal: the chat is this laptop's now,
//!   import first. "lost": what runs here is not the chat any more.
//! - **A laptop that cannot reach the Cloud stops by itself.** No renewal answered for
//!   [`SELF_STOP_MS`](crate::consts::SELF_STOP_MS), counted from when the last answered one was
//!   sent: `StopTree`. The next answered renewal decides: still the holder (or holder again of
//!   its own chat the store had parked, at the new epoch): `ContinueTree`. Lost: `KillTree`,
//!   `WriteLeftoverPatch`, then standby.
//! - **Laptop wake.** A wake notice, or a clock that jumped past
//!   [`LEASE_MS`](crate::consts::LEASE_MS): `StopTree` first, then `Renew`, then the same
//!   decision.
//! - **Handback.** A standby laptop the store answers "holder": `Import(handback)`, and it
//!   holds once the import is done. Nothing runs before that. A standby's renewal takes a
//!   parked chat the same way.
//! - **A Cloud machine.** An assignment (`takeover`, `create`, `deliver`) is imported, its
//!   messages are taken, it is acked, then the machine renews as holder. The handback is the
//!   store's move, at the machine's renewal that says nothing is left to run. So the machine
//!   says that only once the store has its last copy, and the answer "lost" ends its hold. It
//!   never stops itself: the store takes no chat from a machine at work, however quiet.
//! - **Auto switched off.** `Close` asks the store; the chat stays an Auto chat until the store
//!   confirms ([`Event::Closed`]), so a stopped chat is not continued on the person's word
//!   alone.
//! - **Copies.** While this machine runs the chat, a turn end, a tool end and a queue change
//!   send the events and a snapshot, and a streaming turn at most every
//!   [`STREAM_COPY_MS`](crate::consts::STREAM_COPY_MS).

mod chat;
mod effect;
mod event;
mod laptop;
mod machine;
mod out;
mod reason;
mod step;
mod table;

pub use chat::{Chat, CopyState, Sent, Side, State, Stop};
pub use effect::Effect;
pub use event::{Answer, Change, Event, Verdict};
pub use reason::ImportReason;
pub use step::{CLOCK_SLACK_MS, step};
pub use table::{
    SAMPLE_AT, SAMPLE_COPY, SAMPLE_EPOCH, SAMPLE_REQUEST, SAMPLE_SNAPSHOT, sample_chats,
    sample_events, table,
};

#[cfg(test)]
mod tests;
