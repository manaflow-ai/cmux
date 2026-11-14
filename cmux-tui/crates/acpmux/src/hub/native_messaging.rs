//! Part of `Hub`; see `hub/mod.rs`. Claude Code's own cross-session messaging in the agents
//! acpmux starts (W7-A, bench round 6: agent-to-agent A5 went 3 -> 1).
//!
//! Claude Code 2.1.322 gives every session `ListAgents` and a `SendMessage` that reaches any other
//! Claude Code of the same user on the machine (code.claude.com/docs/en/cross-session-messaging):
//! each session writes a registry entry and binds an inbox socket, so the peer list is the
//! machine's, whichever acpmux daemon (or none) started a session. In the bench an acpmux agent
//! asked to message another agent used that route, not acpmux: the receiver, in another
//! permission class, held the message (Claude Code's default inbound rule), ran no turn and said
//! nothing, `acpmux pending` showed nothing, and `ListAgents` listed a session of another acpmux
//! daemon. Measured on a fleet Mac (Claude Code 2.1.322 through `sr2 claude`, two headless
//! sessions): the receiver's stream had `system/peer_message_hold` `held` (cause
//! `mode-mismatch`), later `dropped`.
//!
//! What acpmux does, in three layers:
//! - Off at the source: every Claude Code the daemon starts gets [`SWITCH_ENV`]`=0`: an agent
//!   (`agent/command.rs`) and the model probe that reads a Claude harness's models
//!   (`live_models/mod.rs`, its own spawn path). Claude Code's switch for cross-session
//!   messaging; measured on 2.1.322:
//!   no `ListAgents` tool, no inbox socket and no peer address, so the agent lists no session of
//!   any daemon and no other session lists or messages it; a `SendMessage` to another session
//!   answers "No agent named 'X' is reachable". `SendMessage` to the agent's own subagents and
//!   teammates still works. The switch is an undocumented Claude Code setting (found in its
//!   binary, not in its docs), so the next two layers do not depend on it. If a later Claude Code
//!   renames or drops it, its messaging is on again in acpmux agents: `ListAgents` lists every
//!   Claude Code of the machine (acpmux agents of other daemons too), and other sessions can
//!   message an acpmux agent, which may hold the message. The gate below still refuses every
//!   native send to an acpmux session (tested with a Claude Code that ignores the switch,
//!   `tests/claude_native_messaging.rs`), and a hold still shows in `pending`; only the
//!   cross-daemon peer list comes back. A profile or preset that sets the variable itself keeps
//!   its value (the person's choice to take part in Claude Code's peer list).
//! - Refused with the way that works: acpmux's PreToolUse gate (`claude_stdio/policy_gate.rs`,
//!   every mode, every tool) refuses a `SendMessage` whose target is a session of this daemon or
//!   any cross-session address (a `NAME [ref]` row of `ListAgents`, a `uds:` or `bridge:`
//!   address) before Claude Code runs it ([`Hub::native_message_refusal`]), with the acpmux
//!   command that delivers it and waits for the reply. A target that is one of the session's own
//!   agents (`main`, a subagent's name or agent id) passes.
//! - Shown when held: a message Claude Code holds anyway (a profile that turned messaging back
//!   on, a Claude Code that ignores the switch) is in the session's `heldMessages` (summary and
//!   info) and in `acpmux pending` until Claude Code says it was released or dropped
//!   ([`Hub::note_peer_message_hold`]). The frame is information only: Claude Code has no host
//!   approval for it, so acpmux shows it and cannot release it. Kept in memory only (no log
//!   record): a daemon restart forgets the holds of the agents it adopts, and `pending` then
//!   shows them no more although Claude Code may still hold them.

use super::*;

/// Claude Code's switch for its cross-session messaging (`0`: off, both ways).
pub const SWITCH_ENV: &str = "CLAUDE_CODE_HARBOR_KITE";

/// The ACP `sessionUpdate` the Claude Code backend sends for a `system/peer_message_hold` line.
pub const HOLD_UPDATE: &str = "peer_message_hold";

/// The most holds one session keeps (Claude Code itself holds at most 100).
const MAX_HELD: usize = 100;

/// A target of `SendMessage` that is the session's own agent: `main` (a subagent's parent), or a
/// subagent of the session by name or agent id.
fn own_agent(session: &Session, to: &str) -> bool {
    to == "main" || session.subagents.lock().unwrap_or_else(|e| e.into_inner()).answers_to(to)
}

/// The name a `SendMessage` target gives, without the ` [ref]` a `ListAgents` row adds, and
/// whether it is written as a cross-session address (that ref, or a `uds:` / `bridge:` scheme).
fn target(to: &str) -> (&str, bool) {
    let to = to.trim();
    if to.starts_with("uds:") || to.starts_with("bridge:") {
        return (to, true);
    }
    match to.strip_suffix(']').and_then(|t| t.rsplit_once(" [")) {
        Some((name, reference))
            if !reference.is_empty() && reference.bytes().all(|b| b.is_ascii_hexdigit()) =>
        {
            (name.trim_end(), true)
        }
        _ => (to, false),
    }
}

/// `word` as one shell word: as it is when only safe characters, else single-quoted.
fn shell_word(word: &str) -> String {
    if !word.is_empty() && word.chars().all(|c| c.is_ascii_alphanumeric() || "-_./".contains(c)) {
        return word.to_owned();
    }
    crate::run_elsewhere::shell_quote(word)
}

/// What the agent reads when its `SendMessage` to `name` is refused.
fn refusal_text(name: &str, session_here: bool) -> String {
    let quoted = shell_word(name);
    let whom = if session_here {
        format!(
            "{name} is an acpmux session; Claude Code's SendMessage does not reach acpmux sessions"
        )
    } else {
        format!(
            "{name} is not an agent of this session, and Claude Code's own cross-session messaging is off in acpmux agents"
        )
    };
    format!(
        "acpmux refused this SendMessage: {whom}. Nothing was sent. Message it with acpmux: in \
         Bash run \"$ACPMUX_BIN\" send {quoted} --wait \"<your message>\" to get its reply in this \
         turn, or use the acpmux send tool to send without waiting (the reply then comes to your \
         inbox). \"$ACPMUX_BIN\" ls (or the acpmux ls tool) lists the sessions you can message. \
         SendMessage still reaches your own subagents."
    )
}

impl Hub {
    /// The PreToolUse gate's refusal of one tool call (`request`, shaped as a
    /// `session/request_permission`) of `session`'s agent, when it is a Claude Code `SendMessage`
    /// to another session (module docs); `None` for every other call.
    pub(super) fn native_message_refusal(
        &self,
        session: &Session,
        request: &Value,
    ) -> Option<String> {
        if request.pointer("/toolCall/_meta/claude/tool").and_then(Value::as_str)
            != Some("SendMessage")
        {
            return None;
        }
        let to = request.pointer("/toolCall/rawInput/to").and_then(Value::as_str)?;
        let (name, cross_session) = target(to);
        if name.is_empty() || own_agent(session, to) || own_agent(session, name) {
            return None;
        }
        let here = self.native_target_here(name);
        (here || cross_session).then(|| refusal_text(name, here))
    }

    /// Whether `name` is the exact name or id of a session of this daemon.
    fn native_target_here(&self, name: &str) -> bool {
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        sessions.contains_key(name)
            || sessions.values().any(|s| s.read_meta(|m| m.name == name || m.id == name))
    }

    /// A [`HOLD_UPDATE`] from `session`'s agent: a `held` message joins its holds, a `released`
    /// or `dropped` one leaves them (module docs).
    pub(super) fn note_peer_message_hold(&self, session: &Session, update: &Value) {
        let text = |key: &str| update.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
        let id = text("messageUuid");
        let same = |h: &Value| h.get("messageUuid").and_then(Value::as_str) == Some(id.as_str());
        let changed = {
            let mut held = session.held_messages.lock().unwrap_or_else(|e| e.into_inner());
            let before = held.len();
            match text("state").as_str() {
                "held" => {
                    held.retain(|h| id.is_empty() || !same(h));
                    if held.len() >= MAX_HELD {
                        held.pop_front();
                    }
                    held.push_back(json!({
                        "messageUuid": update.get("messageUuid"),
                        "from": update.get("from"),
                        "fromName": update.get("fromName"),
                        "cause": update.get("cause"),
                        "lane": update.get("lane"),
                        "heldAt": crate::store::now_ms(),
                    }));
                    true
                }
                "released" | "dropped" if !id.is_empty() => {
                    held.retain(|h| !same(h));
                    held.len() != before
                }
                _ => false,
            }
        };
        if changed {
            // Its row changed: the next list is built anew (`list_guard.rs`).
            session.state_seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.events.row_changed(session);
        }
    }
}

/// The messages `session`'s agent holds now, oldest first (summary `heldMessages`).
pub(super) fn held_messages(session: &Session) -> Value {
    Value::Array(
        session.held_messages.lock().unwrap_or_else(|e| e.into_inner()).iter().cloned().collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_listing_row_and_an_address_read_as_cross_session_targets() {
        assert_eq!(target("beta"), ("beta", false));
        assert_eq!(target("beta [3fa9c1]"), ("beta", true));
        assert_eq!(target("  beta [3fa9c1] "), ("beta", true));
        assert_eq!(target("uds:/tmp/cc-socks/1.sock"), ("uds:/tmp/cc-socks/1.sock", true));
        assert_eq!(target("bridge:abc"), ("bridge:abc", true));
        // Not a ref: brackets around words a name may hold.
        assert_eq!(target("notes [draft]"), ("notes [draft]", false));
    }

    #[test]
    fn the_refusal_names_the_acpmux_command_quoted() {
        let text = refusal_text("beta", true);
        assert!(text.contains("\"$ACPMUX_BIN\" send beta --wait"), "{text}");
        assert!(text.contains("Nothing was sent"), "{text}");
        let text = refusal_text("it's", false);
        assert!(text.contains("send 'it'\\''s' --wait"), "{text}");
    }
}
