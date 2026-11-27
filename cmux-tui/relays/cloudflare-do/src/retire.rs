//! When the slot closes a daemon socket that went silent, so a paused Cloud machine stays asleep.
//!
//! A paused Freestyle VM is resumed by any inbound traffic, and a WebSocket close frame is traffic. A daemon
//! registration is silent from the moment its machine pauses; if the cleanup alarm closed it at its 45 s idle
//! deadline (`DAEMON_CONTROL_IDLE_TIMEOUT_MS`), the close frame woke the machine, its daemon registered again
//! (the registration "did not survive a pause"), the platform paused it, and 45 s later the next close woke it
//! again: a paused machine was awake about every 45 s. A standby closed at its ticket's expiry woke it the same way.
//!
//! So a daemon socket past its idle deadline is retired, not closed: it stays open and sends nothing. Retiring
//! keeps what the deadline protected, because none of it ever needed the close:
//!
//! - Routing. A Connect goes only to a registration heard within `DAEMON_LIVENESS_WINDOW_MS` (15 s), and a
//!   standby is taken only before its ticket expires (`crate::daemon::accepts_connects`,
//!   `crate::inline::takeable_standby`), so a retired socket takes no Connect; it parks, as it did when the
//!   registration was closed.
//! - Capacity. Only an open socket before its idle deadline counts toward the slot's socket limits and its
//!   standby limit (`crate::abuse::websocket_counts_toward_capacity`), so a retired socket never refuses the
//!   Register or Standby its machine sends on resume.
//! - Bound. A slot holds one registration (a Register closes every other, `crate::daemon::replaced_by_register`),
//!   and a Register or Standby, sent by a machine that is awake, closes the slot's retired standbys
//!   ([`closed_by_awake_daemon`]), so retired sockets never pile up. One whose machine never comes back is
//!   closed [`RETIRED_DAEMON_HOLD_MS`] after its idle deadline ([`close_deadline_ms`]): at most one wake a day.
//! - Expiry. A Ping on a registration or standby whose ticket expired is still refused and closed: a machine
//!   that pings is awake.
//!
//! A legacy registration (number 0, attached before registration numbers) still closes at its idle deadline:
//! its close is what hands its circuits to the slot's other legacy registrations
//! (`crate::daemon::owed_handover_after_close`).

use cmux_remote_protocol::RelayRole;

use crate::abuse::websocket_is_open;
use crate::attachment::{SlotAttachment, SlotPhase};

/// How long a retired daemon socket stays open past its idle deadline before the cleanup alarm closes it.
pub(crate) const RETIRED_DAEMON_HOLD_MS: u64 = 24 * 60 * 60_000;

/// Whether `attachment` is a daemon socket the slot retires instead of closing past its idle deadline: a
/// numbered registration or a standby.
pub(crate) fn retires_when_silent(attachment: &SlotAttachment) -> bool {
    attachment.relay.role == RelayRole::Daemon
        && match attachment.phase {
            SlotPhase::Registered => attachment.generation > 0,
            SlotPhase::Standby => true,
            _ => false,
        }
}

/// When the cleanup alarm closes the socket with `attachment`: its idle deadline, or for a socket that retires
/// ([`retires_when_silent`]) [`RETIRED_DAEMON_HOLD_MS`] after it.
pub(crate) fn close_deadline_ms(attachment: &SlotAttachment) -> u64 {
    if retires_when_silent(attachment) {
        attachment.idle_deadline_ms.saturating_add(RETIRED_DAEMON_HOLD_MS)
    } else {
        attachment.idle_deadline_ms
    }
}

/// Whether a socket on `slot` in `ready_state` with `attachment` is retired at `now_ms`: open, a daemon socket
/// that retires, and past its idle deadline.
pub(crate) fn retired(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    websocket_is_open(ready_state)
        && retires_when_silent(attachment)
        && attachment.relay.slot == slot
        && attachment.idle_deadline_ms <= now_ms
}

/// Whether a Register or Standby on `slot` at `now_ms`, which shows its machine is awake, closes this other
/// socket: a retired standby. A retired registration is left to the Register's replacement
/// (`crate::daemon::replaced_by_register`), which the awake daemon sends.
pub(crate) fn closed_by_awake_daemon(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    attachment.phase == SlotPhase::Standby && retired(attachment, ready_state, slot, now_ms)
}

#[cfg(test)]
#[path = "retire_tests.rs"]
mod tests;
