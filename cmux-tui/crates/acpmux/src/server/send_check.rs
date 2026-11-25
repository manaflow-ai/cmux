//! The submit-time check of a send's name (plans/cmux-next/message-delivery-successors.md; Leo,
//! 2026-11-24: "well clearly we need to have better listeners/scheduling to make sure those
//! messages are recievable"). A send to a session on a peer that is down used to be queued with
//! no look at the name, relayed to the mesh hub later, refused there as unknown, and failed with
//! nobody told. Now, before it is queued:
//!
//! - a successor or role claim here or on a connected peer takes it (`Hub::successor_for`);
//! - else the hub's address book is read (bounded): a live session there that took the name over
//!   (`formerNames`) or claimed the role takes it; a host the hub lists live with no such session
//!   is no session, refused in the call;
//! - a host the hub lists no daemon for may come back (a laptop asleep): the send is queued, the
//!   reply says the name was not checked, and a failure at the end bounces to its sender
//!   (`hub/dead_letters.rs`). A book that does not answer queues it the same way.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use crate::hub::Hub;

use crate::mesh::{AddressBook, BookSession, MeshHub, valid_role};
use crate::rpc::RpcError;

/// How long the send waits for the hub's address book before it queues the message unchecked.
const BOOK_WAIT: Duration = Duration::from_secs(3);

/// What the check found for a send's target.
#[derive(Debug, PartialEq)]
pub(crate) enum Check {
    /// Send it to this key (`HOST/NAME`, or a session id here) instead.
    Successor(String),
    /// Refused in the call.
    Refuse(String),
    /// Queued as before; `Some` says why the name could not be checked.
    Queue(Option<String>),
}

/// Where a send to `target` goes: the target it keeps, or the successor it goes to instead
/// (written into `request.sessionId`), and why its name was not checked when it could not be.
/// A name the check finds no live session for is refused here.
pub(crate) async fn route(
    hub: &Arc<Hub>,
    request: &mut Value,
    mut target: String,
) -> Result<(String, Option<String>), RpcError> {
    if let Some(found) = hub.successor_for(&target) {
        target = found?;
        request["sessionId"] = json!(target);
    }
    let mut unchecked = None;
    if hub.peer_down_for(&target).is_some()
        && hub.resolve(&target).is_err()
        && let Some(mesh) = hub.mesh.get()
    {
        match check(&mesh, &target).await {
            Check::Successor(key) => {
                target = key;
                request["sessionId"] = json!(target);
            }
            Check::Refuse(text) => return Err(refusal(&target, text)),
            Check::Queue(why) => unchecked = why,
        }
    }
    Ok((target, unchecked))
}

/// The send's answer says which session it went to when that is not the one asked for, and
/// that its name was not checked when it was not.
pub(crate) fn note(status: &mut Value, asked: &str, sent_to: &str, unchecked: Option<String>) {
    let Some(row) = status.as_object_mut() else { return };
    if asked != sent_to {
        row.insert("redirectedFrom".into(), json!(asked));
    }
    if let Some(why) = unchecked {
        row.insert("recipientChecked".into(), json!(false));
        row.insert("recipientNote".into(), json!(why));
    }
}

/// The check for `target`, a session on a peer that is down (`Hub::peer_down_for`) or a role
/// address, with the mesh relay on.
pub(crate) async fn check(mesh: &Arc<dyn MeshHub>, target: &str) -> Check {
    let book = match tokio::time::timeout(BOOK_WAIT, mesh.sessions()).await {
        Ok(Ok(book)) => book,
        Ok(Err(e)) => {
            return Check::Queue(Some(format!("not checked: the mesh hub's address book: {e}")));
        }
        Err(_) => {
            return Check::Queue(Some(format!(
                "not checked: the mesh hub's address book did not answer within {} s",
                BOOK_WAIT.as_secs()
            )));
        }
    };
    in_book(&book, target)
}

/// [`check`] against one read of the book.
pub(crate) fn in_book(book: &AddressBook, target: &str) -> Check {
    if valid_role(target) {
        return book
            .sessions
            .iter()
            .filter_map(|s| s.roles.iter().find(|r| r.address == target).map(|r| (r.claimed_at, s)))
            .max_by_key(|(at, _)| *at)
            .map(|(_, s)| Check::Successor(key_of(s)))
            .unwrap_or_else(|| {
                Check::Refuse(format!(
                    "no session: {target} (no live session here or on the mesh hub holds that role)"
                ))
            });
    }
    let (host, name) = target.split_once('/').unwrap_or(("", target));
    let live = |s: &&BookSession| {
        (host.is_empty() || s.host == host)
            && (s.name == name || s.session_id == name || s.handle.as_deref() == Some(name))
    };
    if book.sessions.iter().any(|s| live(&s)) {
        return Check::Queue(None);
    }
    let heirs: Vec<&BookSession> = book
        .sessions
        .iter()
        .filter(|s| {
            s.former_names
                .iter()
                .any(|n| n == target || (!host.is_empty() && s.host == host && n == name))
        })
        .collect();
    match heirs.as_slice() {
        [one] => return Check::Successor(key_of(one)),
        [] => {}
        many => {
            let mut names: Vec<String> = many.iter().map(|s| key_of(s)).collect();
            names.sort();
            return Check::Refuse(format!(
                "no single session: {target} (several live sessions took it over: {}; send to one)",
                names.join(", ")
            ));
        }
    }
    if !host.is_empty() && book.daemons.iter().any(|d| d.host == host) {
        return Check::Refuse(format!(
            "no session: {target} (its host is up on the mesh hub and lists no such session, and \
             no live session took it over)"
        ));
    }
    Check::Queue(Some(format!(
        "not checked: {target}'s host is down and the mesh hub lists no session that took it over; \
         it is kept and tried again, and its sender is told if it fails"
    )))
}

fn key_of(s: &BookSession) -> String {
    format!("{}/{}", s.host, s.name)
}

/// The refusal a [`Check::Refuse`] answers the send with.
pub(crate) fn refusal(target: &str, text: String) -> RpcError {
    RpcError::invalid_params(text)
        .with_data(json!({"reason": "send.no_session", "target": target, "checked": "mesh"}))
}

#[cfg(test)]
#[path = "send_check_tests.rs"]
mod tests;
