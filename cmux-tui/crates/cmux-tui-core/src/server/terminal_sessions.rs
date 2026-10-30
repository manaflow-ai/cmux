//! Which connecting peers run in this session's terminals, as the accept
//! loop decides it (#27698): without waiting on the session state lock and
//! before a connection slot is taken.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crate::mux::Mux;
use crate::panic_free::RecoverPoison;

/// The process sessions of the session's terminals. A terminal's PTY child
/// leads its own process session, so an agent in it, the agent's hooks and a
/// `cmux` run in the pane all share that session (`getsid`), whatever started
/// the shell (login(1) on macOS, an adopted or held child). The set comes from
/// the session's own terminals, the same ones the request-origin rules match
/// (`origin_gate::classify_local_peer`); no other process is read.
///
/// Each lookup reads the terminals again when the state lock is free, so it
/// is exact then. While another thread holds the lock (the app closing
/// workspaces), the accept loop never waits for it: it answers from the last
/// set read, which holds every terminal that existed then.
#[derive(Default)]
pub(super) struct TerminalSessions {
    last: Mutex<Arc<HashSet<u32>>>,
}

impl TerminalSessions {
    /// Whether the peer a peer key names runs in one of the session's
    /// terminals.
    pub(super) fn contains_peer(&self, mux: &Mux, peer_key: Option<&str>) -> bool {
        let Some(session) = peer_key
            .and_then(super::origin_gate::peer_pid)
            .and_then(super::origin_gate::peer_session_id)
        else {
            return false;
        };
        self.current(mux).contains(&session)
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

#[cfg(test)]
mod tests {
    use super::*;

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
    /// again.
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
        *sessions.last.lock().unwrap() = Arc::new(HashSet::from([session]));

        let held = mux.state.lock().unwrap();
        assert!(sessions.contains_peer(&mux, Some(&key)), "answered from the last read");
        drop(held);
        // The test session has no terminals: a fresh read does not hold ours.
        assert!(!sessions.contains_peer(&mux, Some(&key)), "read again once the lock is free");
    }
}
