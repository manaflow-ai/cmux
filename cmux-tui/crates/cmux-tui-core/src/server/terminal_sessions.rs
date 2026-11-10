//! Which connecting peers run in this session's terminals, as the accept
//! loop decides it (#27698): without waiting on the session state lock and
//! before a connection slot is taken.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crate::mux::Mux;
use crate::panic_free::RecoverPoison;

/// The process sessions of the session's terminals. A terminal's PTY child
/// leads its own process session, so an agent in it and a `cmux` run in the
/// pane share that session (`getsid`), whatever started the shell (login(1) on
/// macOS, an adopted or held child). The set comes from the session's own
/// terminals, the same ones the request-origin rules match
/// (`origin_gate::classify_local_peer`); no other process is read.
///
/// An agent hook's sending child is NOT in that session: the hook helper
/// starts it in a session of its own (`cmux-tui-hook` `detach_session`), so
/// that neither the provider nor a closed terminal ends a report on its way.
/// No kernel fact ties that child to its terminal once the helper has exited,
/// so the accept loop takes it for an outside client, and its first line
/// places it ([`hook_report_terminal`]).
///
/// A peer in the last set read is in a terminal. Any other peer reads the
/// terminals again when the state lock is free, so a new terminal is found at
/// its first connection. While another thread holds the lock (the app closing
/// workspaces), the accept loop never waits for it: it answers from the last
/// set read. A closed terminal's session stays in the set until a miss reads
/// again; a later process reusing that id is only capped, never refused more.
#[derive(Default)]
pub(super) struct TerminalSessions {
    last: Mutex<Arc<HashSet<u32>>>,
}

impl TerminalSessions {
    /// Whether the peer a peer key names runs in one of the session's
    /// terminals (tests; the accept loop asks ``terminal_of_peer``).
    #[cfg(test)]
    pub(super) fn contains_peer(&self, mux: &Mux, peer_key: Option<&str>) -> bool {
        self.terminal_of_peer(mux, peer_key).is_some()
    }

    /// The process session of the terminal the peer runs in (one client of the
    /// terminal lane: its shell, the agent in it, the agent's hooks and a `cmux`
    /// run in it), or nil when the peer runs in none.
    pub(super) fn terminal_of_peer(&self, mux: &Mux, peer_key: Option<&str>) -> Option<u32> {
        let session = peer_key
            .and_then(super::origin_gate::peer_pid)
            .and_then(super::origin_gate::peer_session_id)?;
        // A known terminal answers at once: a burst of agents costs no read.
        // A miss (the app, a new terminal) reads the terminals again.
        if self.last.lock().recover_poison().contains(&session) {
            return Some(session);
        }
        self.current(mux).contains(&session).then_some(session)
    }

    fn current(&self, mux: &Mux) -> Arc<HashSet<u32>> {
        match mux.try_with_state(|state| {
            state
                .surfaces
                .values()
                .chain(state.terminal_catalog.values())
                .filter_map(|surface| surface.process_id())
                .collect::<HashSet<_>>()
        }) {
            Some(read) => {
                let read = Arc::new(read);
                *self.last.lock().recover_poison() = read.clone();
                read
            }
            None => self.last.lock().recover_poison().clone(),
        }
    }
}

/// What an agent hook's report says about its sender, read from a
/// connection's first line: `Some` for a `session.journal.append` of the agent
/// hook producer, with the terminal the report names (nil when it names none).
///
/// This is a claim, not a proof: any local client can send this line. It is
/// used only to count the connection in the terminal lane, the SMALLER pool
/// (`ConnectionPermit::enter_terminal_lane`); it gives no right and changes no
/// request origin (`origin_gate` still knows a terminal by its process
/// session only). A client that does not make the claim keeps what an
/// outside client has.
pub(super) fn hook_report_terminal(line: &str) -> Option<Option<String>> {
    // Most first lines are an `identify` or a `client-hello`: no parse.
    if !line.contains(JOURNAL_APPEND) || !line.contains(crate::AGENT_HOOK_PRODUCER_ID) {
        return None;
    }
    let report: ReportLine = serde_json::from_str(line).ok()?;
    let event = report.params.event;
    if report.operation != JOURNAL_APPEND || event.producer_id != crate::AGENT_HOOK_PRODUCER_ID {
        return None;
    }
    Some(event.subjects.into_iter().find(|subject| subject.kind == "terminal").map(|s| s.id))
}

/// The process session of the session's terminal `terminal` (a public id),
/// the terminal lane's key for a fair share. Nil when the session has no such
/// terminal, when the terminal has no process, and when another thread holds
/// the state lock: the lane then bounds the connection without a share, and
/// nothing waits.
pub(super) fn session_of_terminal(mux: &Mux, terminal: &str) -> Option<u32> {
    // One lookup by key: no walk of the session's terminals for a line a client wrote.
    let terminal = crate::resource::TerminalPublicId::parse(terminal).ok()?;
    mux.try_with_state(|state| state.terminal_catalog.get(&terminal).and_then(|s| s.process_id()))
        .flatten()
}

const JOURNAL_APPEND: &str = "session.journal.append";

/// The fields of a request line that say an agent hook sent it. Every other
/// field is skipped, so a large report costs one pass and no copy.
#[derive(serde::Deserialize)]
struct ReportLine {
    #[serde(default)]
    operation: String,
    #[serde(default)]
    params: ReportParams,
}

#[derive(Default, serde::Deserialize)]
struct ReportParams {
    #[serde(default)]
    event: ReportEvent,
}

#[derive(Default, serde::Deserialize)]
struct ReportEvent {
    #[serde(default)]
    producer_id: String,
    #[serde(default)]
    subjects: Vec<ReportSubject>,
}

#[derive(serde::Deserialize)]
struct ReportSubject {
    #[serde(default)]
    kind: String,
    #[serde(default)]
    id: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(operation: &str, event: serde_json::Value) -> String {
        serde_json::json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": "request_1",
            "operation": operation,
            "params": {"machine": "current", "session": "current", "event": event},
        })
        .to_string()
    }

    #[test]
    fn an_agent_hook_report_names_its_terminal() {
        let terminal = "term_0123456789abcdef0123456789abcdef";
        let event = |terminal| {
            let event =
                crate::agent_hook_journal_ingress("codex", "Stop", terminal, serde_json::json!({}));
            serde_json::to_value(event.unwrap()).unwrap()
        };
        let named = request(JOURNAL_APPEND, event(Some(terminal)));
        assert_eq!(hook_report_terminal(&named), Some(Some(terminal.to_string())));
        let unnamed = request(JOURNAL_APPEND, event(None));
        assert_eq!(hook_report_terminal(&unnamed), Some(None));
    }

    #[test]
    fn other_first_lines_are_not_an_agent_hook_report() {
        let mut other_producer = serde_json::to_value(
            crate::agent_hook_journal_ingress("codex", "Stop", None, serde_json::json!({}))
                .unwrap(),
        )
        .unwrap();
        other_producer["producer_id"] = "a_plugin".into();
        // The producer's name in a payload is not the producer.
        other_producer["payload"]["note"] = crate::AGENT_HOOK_PRODUCER_ID.into();
        let hook_event = serde_json::json!({"producer_id": crate::AGENT_HOOK_PRODUCER_ID});
        for line in [
            r#"{"id":1,"cmd":"identify"}"#.to_string(),
            r#"{"cmd":"client-hello","role":"main"}"#.to_string(),
            request(JOURNAL_APPEND, other_producer),
            request("session.journal.read", hook_event),
            format!("not json {JOURNAL_APPEND} {}", crate::AGENT_HOOK_PRODUCER_ID),
        ] {
            assert_eq!(hook_report_terminal(&line), None, "{line}");
        }
    }

    #[test]
    fn a_peer_with_no_terminal_session_is_not_in_one() {
        let mux = super::super::tests::test_mux();
        let sessions = TerminalSessions::default();
        for key in [None, Some(""), Some("token:"), Some("token:0.1"), Some("pid:1.2")] {
            assert!(!sessions.contains_peer(&mux, key), "{key:?}");
        }
    }

    /// The accept loop never waits on the state lock: while another thread
    /// holds it, the last terminals read answer, and a free lock reads them
    /// again on a miss.
    #[cfg(unix)]
    #[test]
    fn a_held_state_lock_answers_from_the_last_read() {
        use crate::platform::transport::Stream;
        let mux = super::super::tests::test_mux();
        let (ours, _theirs) = std::os::unix::net::UnixStream::pair().unwrap();
        let key = Stream::peer_process_key(&ours).expect("peer key");
        let session = super::super::origin_gate::peer_pid(&key)
            .and_then(super::super::origin_gate::peer_session_id)
            .expect("our session");
        let sessions = TerminalSessions::default();
        let set = |ids: &[u32]| {
            *sessions.last.lock().unwrap() = Arc::new(ids.iter().copied().collect());
        };

        let held = mux.state.lock().unwrap();
        set(&[]);
        assert!(!sessions.contains_peer(&mux, Some(&key)), "a held lock is not waited for");
        set(&[session]);
        assert!(sessions.contains_peer(&mux, Some(&key)), "answered from the last read");
        drop(held);

        // A miss with the lock free reads the terminals again: the test
        // session has none, so the stale id is gone.
        set(&[u32::MAX]);
        assert!(!sessions.contains_peer(&mux, Some(&key)));
        assert!(sessions.last.lock().unwrap().is_empty(), "read again once the lock is free");
    }
}
