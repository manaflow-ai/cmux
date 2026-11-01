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
