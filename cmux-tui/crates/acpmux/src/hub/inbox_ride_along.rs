//! A program's FYI rides along with the chat's next notice and never starts a turn of its own
//! (cmuxterm-hq `docs/handbook/notice-flood.md`: "A program's message is an inbox fyi").
//!
//! The lane-gh broker sends a program's message (RFD-IDLE, "co-owner ... started", "UI preview of
//! your push") as an FYI, and each still woke its idle chat at the 60-minute FYI deadline: 14 of
//! 33 program-only notices on one host over 30 hours were those deadline turns. A program is a
//! sender with no session; the broker labels its message with the session that answers for it (a
//! coordinator), so the label is not the session the relay took it from ([`program_notice`]). A
//! FIRE, a page, a message that waited for this machine and one whose sender set `--within` keep
//! their deadline. Expiry still counts from the FYI deadline ([`Item::expiry_due`]), so a chat
//! that never wakes again keeps no program notices past its grace. Leo, 2026-11-28: "us not
//! getting fucking swamped by our own fucking wake-ups, our own tool calls".

use super::*;

impl Item {
    /// Its class's deadline (`prompt_class::due_at`), which the expiry sweep counts from
    /// (`inbox_deadline.rs`) for a message that rides along too.
    pub(super) fn expiry_due(&self) -> u64 {
        crate::prompt_class::due_at(self.class, self.at, self.within)
    }

    /// Whether it goes with the chat's next notice and wakes it at no deadline (module docs,
    /// "Deadlines"): a program's plain FYI ([`program_notice`]), not a FIRE, a page or fold, a
    /// message that waited for this machine, or one whose sender set its own deadline.
    pub(super) fn rides_along(&self) -> bool {
        self.class == PromptClass::Fyi
            && !self.fire
            && !self.waited
            && self.within.is_none()
            && self.verdict.is_none()
            && program_notice(&self.sender)
    }
}

/// The relay that carries a lane VM's sends (cmuxterm-hq `tools/lane-gh-broker`).
const BROKER_RELAY: &str = "lane-gh";

/// Whether `sender` (a [`prompt_provenance`](crate::prompt_provenance) sender record) is a
/// program the lane-gh broker relayed: its label, where answers go, is not the session the
/// relay took the message from. The broker labels an agent's message with the agent's own
/// `VM/LANE` and a program's (args.program, no lane name, or a name on its NOTICE_PROGRAMS list)
/// with the session that answers for it (`send_sender`).
pub(super) fn program_notice(sender: &Value) -> bool {
    let Some(relay) = sender.get("relay").and_then(crate::prompt_provenance::RelaySender::of)
    else {
        return false;
    };
    relay.by == BROKER_RELAY
        && sender.get("label").and_then(Value::as_str).is_some_and(|label| label != relay.name())
}
