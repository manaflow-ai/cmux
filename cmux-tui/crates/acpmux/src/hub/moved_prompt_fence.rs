//! Part of `Hub`; see `hub/mod.rs`. A turn runs once across hosts (Leo, 2026-11-25: "cuz the
//! startup speed like we can assist in the startup locally too"; "any whatever best order of
//! operations/potentially multiple orders at once deduplicated").
//!
//! A Mac-first turn (the hybrid start, `cmux-cloud-start-core::hybrid`) runs a chat's first
//! prompts on the Mac while its Cloud machine boots, then the session move carries the chat to the
//! machine. The prompt id is the one dedupe key across both hosts: the moved log carries every
//! `user_message` the Mac ran, but the prompt ledger that answers a repeated id is in memory and
//! stays behind. So a moved chat (its ownership epoch above zero: every move bumps it,
//! `session.rs`) reads its log for each client prompt id, as a `resend` does: an id the Mac
//! already ran is answered from that run (`duplicate: true`) and never reaches the model again.
//! A chat that never moved pays nothing.
//!
//! On by default. `ACPMUX_MOVED_PROMPT_FENCE=0` turns it off (the kill switch); the cost is one
//! keyed read of the chat's `user_message` index per prompt, off the workers (`turns.rs`).

use super::Session;

/// The kill switch: `0`, `false`, `off` or `no` turn the fence off.
pub(crate) const ENV: &str = "ACPMUX_MOVED_PROMPT_FENCE";

/// Whether a prompt to `session` reads its log for its id: the chat moved here at least once and
/// the kill switch is not thrown.
pub(super) fn reads_log(session: &Session) -> bool {
    session.ownership_epoch() > 0 && on(std::env::var(ENV).ok().as_deref())
}

fn on(value: Option<&str>) -> bool {
    !matches!(value.map(str::trim), Some("0" | "false" | "off" | "no"))
}

#[cfg(test)]
mod tests {
    use super::on;

    #[test]
    fn the_fence_is_on_unless_the_kill_switch_says_off() {
        for value in [None, Some(""), Some("1"), Some("on"), Some("junk")] {
            assert!(on(value), "{value:?}");
        }
        for value in ["0", "false", "off", "no", " 0 "] {
            assert!(!on(Some(value)), "{value}");
        }
    }
}
