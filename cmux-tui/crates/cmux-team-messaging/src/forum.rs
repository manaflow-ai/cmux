//! The hosted forum's wire types (`cmux-forum-hosted`) read as this crate's model.
//!
//! The forum already tells people from agents and carries an agent's `on_behalf_of`, reported session
//! and host. A bridge write carries `origin` on its feed event. These functions map those onto
//! [`Principal`], [`Thread`] and [`Message`] without widening anything: an anonymous or unknown
//! author maps to no principal, a bridge author gets no grants, and a comment reads as `fyi`, which
//! wakes nobody.

use cmux_forum_hosted::model as wire;

use crate::delivery::DeliveryMode;
use crate::identity::{Bridge, PrincipalKind};
use crate::model::{Message, Principal, RootKind, Thread, ThreadState};
use crate::permission::Grants;
use crate::refs::{RefKey, RefKind, RefSource};

/// A forum thread's id in this model: `space/number`.
pub fn thread_id(space: &str, number: u64) -> String {
    format!("{space}/{number}")
}

pub fn thread_key(space: &str, number: u64) -> RefKey {
    RefKey { kind: RefKind::Thread, source: RefSource::Cmux, id: thread_id(space, number) }
}

/// A forum author as a principal of `team_id`, holding `grants` (the caller's home-team grants for
/// it, which the forum does not send). `via` marks a bridge write, which gets no grants.
/// Anonymous and unknown authors map to `None`.
pub fn principal(
    author: &wire::Author,
    team_id: &str,
    grants: Grants,
    via: Option<Bridge>,
) -> Option<Principal> {
    let kind = match author.kind {
        wire::AuthorKind::Person => PrincipalKind::Person,
        wire::AuthorKind::Agent => PrincipalKind::Agent,
        wire::AuthorKind::Anonymous | wire::AuthorKind::Unknown => return None,
    };
    if author.id.trim().is_empty() {
        return None;
    }
    let owner = match kind {
        PrincipalKind::Agent => author.on_behalf_of.clone().filter(|o| !o.trim().is_empty()),
        PrincipalKind::Person => None,
    };
    Some(Principal {
        id: author.id.clone(),
        kind,
        handle: author.name.clone(),
        display_name: author.name.clone(),
        team_id: author.org.clone().unwrap_or_else(|| team_id.to_owned()),
        owner_person_id: owner,
        harness: None,
        model: None,
        session_id: author.session.clone(),
        host_id: author.host.clone(),
        capabilities: if via.is_some() { Grants::none() } else { grants },
        via,
    })
}

/// The thread's root kind from its labels: the first label naming one wins, else `message`.
pub fn root_kind(labels: &[wire::Label]) -> RootKind {
    labels.iter().find_map(|l| RootKind::parse(&l.name)).unwrap_or(RootKind::Message)
}

pub fn thread(t: &wire::Thread) -> Thread {
    let mut participants = vec![t.author.id.clone()];
    participants.retain(|p| !p.is_empty());
    Thread {
        id: thread_id(&t.space, t.number),
        space_id: t.space.clone(),
        root_kind: root_kind(&t.labels),
        subject: t.title.clone(),
        participants,
        linked_rfd_ids: Vec::new(),
        linked_session_ids: Vec::new(),
        revision: 0,
        state: match t.state {
            wire::ThreadState::Closed => ThreadState::Closed,
            wire::ThreadState::Open | wire::ThreadState::Unknown => ThreadState::Open,
        },
    }
}

/// A forum comment as a message. The forum stores no audience or delivery mode yet, so the message
/// is addressed to nobody and reads as `fyi`: it is history, and wakes nobody.
pub fn message(c: &wire::Comment, space: &str, author: Principal) -> Message {
    Message {
        id: format!("{}/{}#{}", space, c.thread, c.id),
        thread_id: thread_id(space, c.thread),
        author,
        audience: Vec::new(),
        body: c.body.clone(),
        refs: Vec::new(),
        delivery: DeliveryMode::Fyi,
        created_at: 0,
        reply_to: None,
        revision: 0,
    }
}

/// The bridge a feed event came through, if any.
pub fn event_bridge(e: &wire::FeedEvent) -> Option<Bridge> {
    e.origin.as_deref().and_then(Bridge::from_origin)
}
