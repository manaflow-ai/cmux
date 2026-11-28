//! How a dial's refusal is worded (split out of `hub_carrier.rs`).

use std::time::Duration;

/// What a dial says when the far machine's hub carrier is not serving, whatever told it so (the
/// hub's 404 `machine.not_found` on the connect ticket, the relay's `slot-offline`, or a far
/// machine that never joined the circuit): the machine's own fix, with a reason the CLI ends on
/// ([`cmux_remote::provider::TERMINAL_REFUSALS`]), where a redial only waits out its timeout.
pub(crate) fn carrier_off(how: &str) -> String {
    format!(
        "that machine's hub carrier is off ({how}): its acpmux is stopped or not joined to this \
         account, or it runs a build from before the carrier served beside the cmux link (its \
         app's link holds the node key and the older carrier stays off there). Update cmux on \
         that machine and restart its acpmux; `acpmux machine status --json` there shows the \
         carrier. (carrier.not_serving)"
    )
}

/// The far machine never joined the circuit within `waited`.
pub(crate) fn carrier_not_serving(waited: Duration) -> String {
    carrier_off(&format!("it did not answer on the relay within {}s", waited.as_secs().max(1)))
}

/// A refused connect ticket, as the dialer words it: the hub's `machine.not_found` is
/// [`not_a_teammate_machine`], named for the machine `daemon`; any other refusal keeps its text.
pub(crate) fn ticket_refusal(daemon: &str, text: String) -> String {
    if text.contains("machine.not_found") { not_a_teammate_machine(daemon) } else { text }
}

/// The hub's connect ticket answers `machine.not_found` for any key that is not one of the
/// caller's person's live machines joined in the caller's own team (cmux-platform
/// `server/mesh/MeshCarrier.ts`: rows of `caller.team` minted by `caller.user`). Whether the far
/// carrier serves does not enter into it: a machine joined in another team of the same person
/// registers and serves on its own slot and still answers this, so the words name the machine
/// and the team. The fix is on that machine (join it, in this team), and the reason
/// (`machine.not_joined`) is one the CLI ends on at once
/// ([`cmux_remote::provider::TERMINAL_REFUSALS`]) instead of redialing into its timeout.
pub(crate) fn not_a_teammate_machine(daemon: &str) -> String {
    format!(
        "{daemon} is not joined to your hub in this machine's team: it never joined, its join \
         was revoked or expired, or it is joined in another of your teams (the hub carrier only \
         connects machines joined in the same team). On that machine, join it (`cmux machine add \
         --cloud-token-stdin` / sign in to the cmux app), then retry. Compare teamId in `acpmux \
         machine join --status --json` on both machines; `acpmux machine doctor --here` names \
         the team and how to move a join. (machine.not_joined)"
    )
}

/// A relay's refusal of a dial, as the dialer words it: the relay's `slot-offline` (no daemon
/// registered for the machine's slot, or its registration lease ran out) is the far carrier not
/// serving ([`carrier_not_serving`]); any other refusal keeps its own text.
pub(crate) fn relay_refusal(text: String, waited: Duration) -> String {
    let offline = text.contains("slot-offline")
        || text.contains("no daemon is registered")
        || text.contains("registration lease has expired");
    if offline { carrier_not_serving(waited) } else { text }
}
