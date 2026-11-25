//! The lane's half of the GitHub broker (`github_broker.rs`): which connected Macs lend this
//! machine their GitHub login, and the session row each decision leaves.
//!
//! A Mac says so in its `initialize` (`_meta.acpmux.githubBroker`), and only over a link that
//! proved this machine's peer token (`peer_auth.rs`: read over ssh); a Web, app or paired-device
//! connection saying it counts for nothing (`server/requests.rs`). The link counts once this
//! machine's answer to its `_acpmux/watch` is queued (`server/mod.rs`): the Mac opens its side
//! when it reads that answer, and every action goes out after it (`Conn::send_request_in_order`
//! refuses one while that answer still waits for room), so none reaches a Mac that would still
//! refuse it. The newest such link still open is the one
//! asked.

use super::{Hub, Session};
use crate::server::Conn;
use serde_json::Value;
use std::sync::{Arc, Mutex, Weak};

#[derive(Default)]
pub(crate) struct Owners(Mutex<Vec<Weak<Conn>>>);

/// How many lending links are kept; past that the oldest goes.
const OWNERS_MAX: usize = 16;

/// `new` becomes the newest of `list`, once: closed links and an earlier entry for it go.
fn register<T>(list: &mut Vec<Weak<T>>, new: &Arc<T>, open: impl Fn(&T) -> bool) {
    list.retain(|o| o.upgrade().is_some_and(|c| open(&c) && !Arc::ptr_eq(&c, new)));
    if list.len() >= OWNERS_MAX {
        list.remove(0);
    }
    list.push(Arc::downgrade(new));
}

impl Hub {
    /// `conn` lends this machine its GitHub login (module docs).
    pub(crate) fn add_github_owner(&self, conn: &Arc<Conn>) {
        let mut owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        register(&mut owners, conn, Conn::is_open);
    }

    /// The newest open link that lends its GitHub login, if any.
    pub(crate) fn github_owner_link(&self) -> Option<Arc<Conn>> {
        let owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        owners.iter().rev().filter_map(Weak::upgrade).find(|c| c.is_open())
    }

    /// One redacted broker decision, in the session's own event stream, so the app shows it
    /// beside the work that caused it.
    pub(crate) fn append_github_audit(&self, session: &Session, payload: Value) {
        self.append(session, "mux", "github_broker_action", payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// The review of the lane part at 1ea8bb6: each `initialize` on one link added it again.
    #[test]
    fn a_link_is_listed_once_and_the_list_stays_bounded() {
        let open = |c: &AtomicBool| c.load(Ordering::SeqCst);
        let mut list = Vec::new();
        let link = Arc::new(AtomicBool::new(true));
        for _ in 0..100 {
            register(&mut list, &link, open);
        }
        assert_eq!(list.len(), 1);
        let others: Vec<_> = (0..40).map(|_| Arc::new(AtomicBool::new(true))).collect();
        for o in &others {
            register(&mut list, o, open);
        }
        assert_eq!(list.len(), OWNERS_MAX);
        others.last().unwrap().store(false, Ordering::SeqCst);
        register(&mut list, &link, open);
        assert!(Arc::ptr_eq(&list.last().unwrap().upgrade().unwrap(), &link));
        assert!(list.iter().all(|o| o.upgrade().is_some_and(|c| open(&c))));
    }
}
