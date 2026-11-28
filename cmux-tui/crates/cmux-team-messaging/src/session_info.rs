//! Session Info: one compact projection of a session's team, people, agents, permissions, linked
//! thread, RFDs, current ask and open feedback (RFD 0170, "Native surfaces" 3, phase 1).
//!
//! It is a projection of the session, room, presence and forum records, never a second log: it
//! reads them and writes nothing. Every link goes through the viewer's own permission, so a thread
//! the viewer cannot read is not shown, and neither are the RFDs only that thread links: linking a
//! pair thread to a session never widens who can see it. `Open thread`, `Open RFD`, `Join room` and
//! `Copy link` are direct actions carrying their target, so each is one click.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use cmux_sync::presence::Status;

use crate::backend::{Room, RoomRole, StoredMessage};
use crate::delivery::DeliveryMode;
use crate::feedback::{VoteBoard, VoteSummary};
use crate::identity::{self, PrincipalKind};
use crate::model::{Principal, Space, SpaceKind, Team, Thread, ThreadState};
use crate::permission::{Capability, Grants, effective};
use crate::presence::Participant;
use crate::refs::{LinkGraph, RefKey, RefKind, RefSource};

/// Longest current-ask excerpt, in characters.
pub const ASK_EXCERPT_CHARS: usize = 140;

/// What Session Info reads. The host gathers it; nothing here does I/O.
#[derive(Debug, Clone, Copy)]
pub struct SessionContext<'a> {
    pub session_id: &'a str,
    pub team: &'a Team,
    /// The session's own space, if it has one.
    pub space: Option<&'a Space>,
    /// Every space a linked thread may live in (the session's included or not).
    pub spaces: &'a [Space],
    pub principals: &'a [Principal],
    /// Threads linked to the session, from either end.
    pub threads: &'a [Thread],
    pub room: Option<&'a Room>,
    /// Presence in the session's scope. A lease: read, never stored.
    pub here: &'a [Participant],
    pub links: &'a LinkGraph,
    /// Display titles for refs; a missing title falls back to the ref's id.
    pub titles: &'a BTreeMap<RefKey, String>,
    /// Messages of the linked threads, any order.
    pub messages: &'a [StoredMessage],
    pub feedback: &'a VoteBoard,
}

/// The viewer's standing in the room.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Standing {
    Owner,
    Talk,
    View,
    /// Not admitted to the room (may still read the session's space).
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParticipantRow {
    pub principal_id: String,
    pub kind: PrincipalKind,
    pub name: String,
    pub standing: Standing,
    /// From presence; `None` when not here right now.
    pub status: Option<Status>,
    /// Typing (a person) or in a turn (an agent).
    pub working: bool,
    /// An agent's owner, by display name when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadLink {
    pub key: RefKey,
    pub subject: String,
    pub space_title: String,
    pub state: ThreadState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RfdLink {
    pub key: RefKey,
    /// `RFD 0170`.
    pub label: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskLine {
    pub message_id: String,
    pub thread: RefKey,
    pub author: String,
    pub author_kind: PrincipalKind,
    pub excerpt: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedbackLine {
    pub target: RefKey,
    pub comments: u32,
    /// Vote value to people count.
    pub people: BTreeMap<i8, u32>,
    /// Agent votes, advisory.
    pub advisory: BTreeMap<i8, u32>,
}

/// A direct action; each carries its target.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum Action {
    OpenThread {
        target: RefKey,
    },
    OpenRfd {
        target: RefKey,
    },
    JoinRoom {
        session_id: String,
    },
    /// The session's canonical ref (`session:cmux/ID`).
    CopyLink {
        link: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub session: RefKey,
    pub team_id: String,
    pub team_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub space_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub space_kind: Option<SpaceKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_id: Option<String>,
    pub standing: Standing,
    /// The viewer's effective grants in the session's space.
    pub grants: Grants,
    /// Owner first, then who is here, then by name.
    pub people: Vec<ParticipantRow>,
    pub agents: Vec<ParticipantRow>,
    /// The first is the primary thread: open before handled or closed, then latest revision.
    pub threads: Vec<ThreadLink>,
    /// By number.
    pub rfds: Vec<RfdLink>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_ask: Option<AskLine>,
    /// The session's, then each RFD's, only where there is any.
    pub feedback: Vec<FeedbackLine>,
    /// Open the primary thread, open each RFD, join the room, copy the link.
    pub actions: Vec<Action>,
}

fn session_key(id: &str) -> Option<RefKey> {
    RefKey::new(RefKind::Session, RefSource::Cmux, id).ok()
}

fn thread_key(id: &str) -> Option<RefKey> {
    RefKey::new(RefKind::Thread, RefSource::Cmux, id).ok()
}

fn excerpt(body: &str) -> String {
    let flat: String = body.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= ASK_EXCERPT_CHARS {
        return flat;
    }
    let mut out: String = flat.chars().take(ASK_EXCERPT_CHARS - 1).collect();
    out.push('…');
    out
}

/// Session Info as `viewer` may see it, or `None` when the viewer may see nothing of the session:
/// a bridge author, a malformed principal, or someone neither admitted to the room nor able to
/// read the session's space.
pub fn session_info(viewer: &Principal, cx: &SessionContext<'_>) -> Option<SessionInfo> {
    if identity::require_rights(viewer).is_err() || identity::validate(viewer).is_err() {
        return None;
    }
    let session = session_key(cx.session_id)?;
    let by_id: BTreeMap<&str, &Principal> =
        cx.principals.iter().map(|p| (p.id.as_str(), p)).collect();
    let owner_of = |p: &Principal| match p.kind {
        PrincipalKind::Agent => p.owner_person_id.as_deref().and_then(|o| by_id.get(o).copied()),
        PrincipalKind::Person => None,
    };
    let grants_in = |space: &Space| -> Grants {
        if space.team_id != cx.team.id {
            return Grants::none();
        }
        effective(viewer, owner_of(viewer), cx.team, space)
    };

    let room = cx.room.filter(|r| r.session_id == cx.session_id);
    let standing_of = |id: &str| -> Standing {
        match room {
            Some(r) if r.owner_id == id => Standing::Owner,
            Some(r) => match r.members.iter().find(|(m, _)| m == id).map(|(_, role)| *role) {
                Some(RoomRole::Talk) => Standing::Talk,
                Some(RoomRole::View) => Standing::View,
                None => Standing::None,
            },
            None => Standing::None,
        }
    };
    let standing = standing_of(&viewer.id);
    let space = cx.space.filter(|s| s.team_id == cx.team.id);
    let grants = space.map(grants_in).unwrap_or_default();
    if standing == Standing::None && !grants.has(Capability::Read) {
        return None;
    }

    // People and agents: everyone admitted to the room, plus everyone here.
    let here: BTreeMap<&str, &Participant> =
        cx.here.iter().map(|h| (h.principal_id.as_str(), h)).collect();
    let mut ids: BTreeSet<&str> = here.keys().copied().collect();
    if let Some(r) = room {
        ids.insert(r.owner_id.as_str());
        ids.extend(r.members.iter().map(|(m, _)| m.as_str()));
    }
    let (mut people, mut agents) = (Vec::new(), Vec::new());
    for id in ids {
        let p = by_id.get(id).copied();
        let h = here.get(id).copied();
        if p.is_some_and(|p| p.via.is_some()) {
            continue;
        }
        let Some(kind) = p.map(|p| p.kind).or(h.map(|h| h.kind)) else { continue };
        let row = ParticipantRow {
            principal_id: id.to_owned(),
            kind,
            name: p
                .map(|p| p.display_name.clone())
                .or(h.map(|h| h.name.clone()))
                .unwrap_or_else(|| id.to_owned()),
            standing: standing_of(id),
            status: h.map(|h| h.status),
            working: h.is_some_and(|h| h.working),
            owner: p
                .and_then(|p| p.owner_person_id.as_deref())
                .map(|o| by_id.get(o).map_or_else(|| o.to_owned(), |op| op.display_name.clone())),
            harness: p.and_then(|p| p.harness.clone()),
        };
        match kind {
            PrincipalKind::Person => people.push(row),
            PrincipalKind::Agent => agents.push(row),
        }
    }
    let order = |r: &ParticipantRow| {
        (r.standing != Standing::Owner, r.status.is_none(), r.name.clone(), r.principal_id.clone())
    };
    people.sort_by_key(order);
    agents.sort_by_key(order);

    // Threads linked from either end, each through the viewer's own read permission.
    let spaces: BTreeMap<&str, &Space> = cx.spaces.iter().map(|s| (s.id.as_str(), s)).collect();
    let linked_from_graph: BTreeSet<String> =
        cx.links.links_of_kind(&session, RefKind::Thread).into_iter().map(|k| k.id).collect();
    let mut visible: Vec<&Thread> = cx
        .threads
        .iter()
        .filter(|t| {
            linked_from_graph.contains(&t.id)
                || t.linked_session_ids.iter().any(|s| s == cx.session_id)
        })
        .filter(|t| {
            spaces.get(t.space_id.as_str()).is_some_and(|s| grants_in(s).has(Capability::Read))
        })
        .collect();
    visible.sort_by(|a, b| {
        (a.state != ThreadState::Open, std::cmp::Reverse(a.revision), &a.id).cmp(&(
            b.state != ThreadState::Open,
            std::cmp::Reverse(b.revision),
            &b.id,
        ))
    });
    visible.dedup_by(|a, b| a.id == b.id);
    let threads: Vec<ThreadLink> = visible
        .iter()
        .filter_map(|t| {
            Some(ThreadLink {
                key: thread_key(&t.id)?,
                subject: t.subject.clone(),
                space_title: spaces
                    .get(t.space_id.as_str())
                    .map_or_else(String::new, |s| s.title.clone()),
                state: t.state,
            })
        })
        .collect();

    // RFDs: the session's own links, plus those the visible threads link. Never a hidden thread's.
    let mut rfd_keys: BTreeSet<RefKey> =
        cx.links.links_of_kind(&session, RefKind::Rfd).into_iter().collect();
    for t in &visible {
        rfd_keys.extend(
            t.linked_rfd_ids
                .iter()
                .filter_map(|n| RefKey::new(RefKind::Rfd, RefSource::Hq, n).ok()),
        );
        if let Some(k) = thread_key(&t.id) {
            rfd_keys.extend(cx.links.links_of_kind(&k, RefKind::Rfd));
        }
    }
    let rfds: Vec<RfdLink> = rfd_keys
        .into_iter()
        .map(|k| RfdLink {
            label: format!("RFD {}", k.id),
            title: cx.titles.get(&k).cloned().unwrap_or_default(),
            key: k,
        })
        .collect();

    // The current ask: the latest ask or wake in an open visible thread.
    let open: BTreeSet<&str> =
        visible.iter().filter(|t| t.state == ThreadState::Open).map(|t| t.id.as_str()).collect();
    let current_ask = cx
        .messages
        .iter()
        .filter(|m| open.contains(m.message.thread_id.as_str()))
        .filter(|m| matches!(m.message.delivery, DeliveryMode::Ask | DeliveryMode::Wake))
        .max_by(|a, b| {
            (a.message.created_at, a.seq, &a.message.id).cmp(&(
                b.message.created_at,
                b.seq,
                &b.message.id,
            ))
        })
        .and_then(|m| {
            Some(AskLine {
                message_id: m.message.id.clone(),
                thread: thread_key(&m.message.thread_id)?,
                author: m.message.author.display_name.clone(),
                author_kind: m.message.author.kind,
                excerpt: excerpt(&m.message.body),
            })
        });

    let mut feedback = Vec::new();
    for target in std::iter::once(&session).chain(rfds.iter().map(|r| &r.key)) {
        let VoteSummary { people: p, advisory, comments } = cx.feedback.summary(target);
        if comments > 0 || !p.is_empty() || !advisory.is_empty() {
            feedback.push(FeedbackLine { target: target.clone(), comments, people: p, advisory });
        }
    }

    let mut actions = Vec::new();
    if let Some(t) = threads.first() {
        actions.push(Action::OpenThread { target: t.key.clone() });
    }
    actions.extend(rfds.iter().map(|r| Action::OpenRfd { target: r.key.clone() }));
    if room.is_some() && standing != Standing::None {
        actions.push(Action::JoinRoom { session_id: cx.session_id.to_owned() });
    }
    actions.push(Action::CopyLink { link: session.canonical() });

    Some(SessionInfo {
        team_id: cx.team.id.clone(),
        team_name: cx.team.name.clone(),
        space_title: space.map(|s| s.title.clone()),
        space_kind: space.map(|s| s.kind),
        owner_id: room.map(|r| r.owner_id.clone()),
        standing,
        grants,
        people,
        agents,
        threads,
        rfds,
        current_ask,
        feedback,
        actions,
        session,
    })
}

#[cfg(test)]
#[path = "session_info_tests.rs"]
mod tests;
