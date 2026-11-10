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
//!
//! A remote chain's Claude Code runs in the sandbox, which allows no Unix socket, so it cannot
//! ask over the socket as a local agent does. It asks over its own stdio instead: the
//! `acpmux-github` SDK MCP server its translator serves (`claude_stdio/github_mcp.rs`), whose
//! tool calls reach the hub as [`crate::claude_stdio::GITHUB_ACTION`] requests from the
//! session's own agent ([`Hub::answer_github_action`]). The caller is the session that owns
//! that agent, so no socket or token enters the sandbox. It is answered only:
//! - for a remote chain's Claude Code (`remote_claude`): no other harness speaks for this method;
//! - while no Web client runs the turn (`web_turn`: a Web turn, or between turns after one);
//! - when nothing but the owner's own clients ever acted on the chat (`github_withheld`): a
//!   prompt, steer, answer or edit from a Web client or a paired device (`via: device`), the
//!   requests `vm_boundary::owner` says are not the person's, turns it off for the chat for the
//!   life of this daemon (`Hub::refuse_at_vm_boundary` marks it).
//!
//! Then it is the same action as over the socket: the same `validate`, the same link and the
//! Mac's same `githubBroker` check, the same `github_broker_action` row.

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
    /// Clone from a test's loopback git stand-in and stage in its folder
    /// (`github_clone::CloneOrigin::loopback`), instead of GitHub and the state folder.
    pub fn set_github_clone_origin(&self, origin: crate::github_clone::CloneOrigin) {
        *self.github_clone_origin.lock().unwrap_or_else(|e| e.into_inner()) = origin;
    }

    /// Where `repo clone` clones from and stages.
    pub(crate) fn github_clone_origin(&self) -> crate::github_clone::CloneOrigin {
        self.github_clone_origin.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

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

    /// Whether `meta`'s Claude Code is offered the `acpmux-github` server at this spawn: a remote
    /// chain, on a machine a Mac lends GitHub to now (module docs).
    pub(crate) fn offers_github_broker(&self, meta: &crate::store::SessionMeta) -> bool {
        meta.remote_origin && self.github_owner_link().is_some()
    }

    /// [`crate::claude_stdio::GITHUB_ACTION`] from `session`'s own agent (module docs).
    pub(crate) async fn answer_github_action(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Value,
    ) -> Result<Value, crate::rpc::RpcError> {
        let denied = |why: &str| {
            crate::rpc::RpcError::new(-32040, why.to_owned())
                .with_data(serde_json::json!({"reason": "github.denied"}))
        };
        if !self.remote_claude(session) {
            return Err(denied("this chat asks for GitHub actions with `acpmux gh`"));
        }
        let refusal = if Self::web_turn(session) {
            Some("GitHub actions are not lent to a turn a Web client started")
        } else if session.floor.github_withheld.load(std::sync::atomic::Ordering::SeqCst) {
            Some("GitHub actions are not lent to a chat a Web client or a paired device acted on")
        } else {
            None
        };
        let request: crate::github_broker::GithubActionParams = serde_json::from_value(params)
            .map_err(|e| {
                crate::rpc::RpcError::invalid_params(format!("invalid GitHub action: {e}"))
            })?;
        if let Some(why) = refusal {
            let e = denied(why);
            self.append_github_audit(
                session,
                crate::github_broker::audit_payload(&request, "denied", Some(&e), None),
            );
            return Err(e);
        }
        crate::github_broker::ask_owner(self, session, request).await
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
