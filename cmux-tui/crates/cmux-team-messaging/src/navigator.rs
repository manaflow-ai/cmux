//! The team switcher, space navigator and search (RFD 0170, "Native surfaces" 1, phase 1).
//!
//! The sidebar lists the viewer's teams, the current team's spaces with unread counts and who is
//! live in each, and a search that opens a person, agent, thread, RFD or session without knowing
//! which backend stores it. Every space, thread and session goes through the viewer's own read
//! permission. Spaces follow the team's own order (`team.spaces`, its customization), then title.
//! Nothing here does I/O; the host passes the records in.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use cmux_sync::presence::Status;

use crate::identity::{self, PrincipalKind};
use crate::model::{Principal, Space, SpaceKind, Team, Thread, ThreadState};
use crate::permission::{Capability, Grants};
use crate::picker::{grants_for, has_rights, score};
use crate::presence::Participant;
use crate::refs::{RefKey, RefKind, RefSource};

/// A session the host knows, with the space it lives in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEntry {
    pub id: String,
    pub title: String,
    pub space_id: String,
}

/// What the navigator reads.
#[derive(Debug, Clone, Copy)]
pub struct NavContext<'a> {
    pub teams: &'a [Team],
    pub current_team_id: &'a str,
    pub spaces: &'a [Space],
    pub principals: &'a [Principal],
    pub threads: &'a [Thread],
    /// Thread id to the viewer's unread count.
    pub unread: &'a BTreeMap<String, u32>,
    /// Space id to who is here. A lease: read, never stored.
    pub here: &'a BTreeMap<String, Vec<Participant>>,
    pub sessions: &'a [SessionEntry],
    /// RFDs the host may show this viewer, with titles.
    pub rfds: &'a [(RefKey, String)],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamRow {
    pub id: String,
    pub name: String,
    pub current: bool,
    pub unread: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveRow {
    pub principal_id: String,
    pub name: String,
    pub status: Status,
    pub working: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceRow {
    pub id: String,
    pub title: String,
    pub kind: SpaceKind,
    pub unread: u32,
    /// Open threads.
    pub open: u32,
    pub grants: Grants,
    pub people: Vec<LiveRow>,
    pub agents: Vec<LiveRow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Navigator {
    pub teams: Vec<TeamRow>,
    pub spaces: Vec<SpaceRow>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HitKind {
    Person,
    Agent,
    Thread,
    Rfd,
    Session,
    Space,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub kind: HitKind,
    pub label: String,
    /// A principal id for a person or agent; else the ref's id.
    pub id: String,
    /// What opening the hit navigates to; `None` for a principal (the host opens its profile).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open: Option<RefKey>,
    /// A space title, an agent's owner, or an RFD's label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Longest search result list.
pub const SEARCH_LIMIT: usize = 50;

fn teams_of<'a>(viewer: &Principal, cx: &NavContext<'a>) -> Vec<&'a Team> {
    cx.teams.iter().filter(|t| t.id == viewer.team_id || t.members.contains(&viewer.id)).collect()
}

fn readable<'a>(viewer: &Principal, team: &Team, cx: &NavContext<'a>) -> Vec<(&'a Space, Grants)> {
    cx.spaces
        .iter()
        .filter(|s| s.team_id == team.id)
        .map(|s| (s, grants_for(viewer, team, s, cx.principals)))
        .filter(|(_, g)| g.has(Capability::Read))
        .collect()
}

fn unread_in(space: &Space, cx: &NavContext<'_>) -> u32 {
    cx.threads.iter().filter(|t| t.space_id == space.id).filter_map(|t| cx.unread.get(&t.id)).sum()
}

/// The sidebar as `viewer` may see it, or `None` for a bridge author, a malformed principal or a
/// viewer outside the current team.
pub fn navigator(viewer: &Principal, cx: &NavContext<'_>) -> Option<Navigator> {
    if !has_rights(viewer) {
        return None;
    }
    let teams = teams_of(viewer, cx);
    let current = teams.iter().find(|t| t.id == cx.current_team_id).copied()?;
    let team_rows = teams
        .iter()
        .map(|t| TeamRow {
            id: t.id.clone(),
            name: t.name.clone(),
            current: t.id == current.id,
            unread: readable(viewer, t, cx).iter().map(|(s, _)| unread_in(s, cx)).sum(),
        })
        .collect();

    let mut spaces = readable(viewer, current, cx);
    let order = |s: &Space| current.spaces.iter().position(|id| *id == s.id).unwrap_or(usize::MAX);
    spaces.sort_by(|(a, _), (b, _)| {
        (order(a), a.title.to_lowercase(), &a.id).cmp(&(order(b), b.title.to_lowercase(), &b.id))
    });
    let bridged: Vec<&str> =
        cx.principals.iter().filter(|p| p.via.is_some()).map(|p| p.id.as_str()).collect();
    let space_rows = spaces
        .into_iter()
        .map(|(s, grants)| {
            let (mut people, mut agents) = (Vec::new(), Vec::new());
            for h in cx.here.get(&s.id).into_iter().flatten() {
                if !s.is_member(&h.principal_id) || bridged.contains(&h.principal_id.as_str()) {
                    continue;
                }
                let row = LiveRow {
                    principal_id: h.principal_id.clone(),
                    name: h.name.clone(),
                    status: h.status,
                    working: h.working,
                };
                match h.kind {
                    PrincipalKind::Person => people.push(row),
                    PrincipalKind::Agent => agents.push(row),
                }
            }
            let by_name = |r: &LiveRow| (r.name.to_lowercase(), r.principal_id.clone());
            people.sort_by_key(by_name);
            agents.sort_by_key(by_name);
            SpaceRow {
                id: s.id.clone(),
                title: s.title.clone(),
                kind: s.kind,
                unread: unread_in(s, cx),
                open: cx
                    .threads
                    .iter()
                    .filter(|t| t.space_id == s.id && t.state == ThreadState::Open)
                    .count() as u32,
                grants,
                people,
                agents,
            }
        })
        .collect();
    Some(Navigator { teams: team_rows, spaces: space_rows })
}

/// Search the current team for `query`: people, agents, threads, RFDs, sessions and spaces, each
/// through the viewer's read permission; best match first, at most [`SEARCH_LIMIT`].
pub fn search(viewer: &Principal, query: &str, cx: &NavContext<'_>) -> Vec<Hit> {
    if !has_rights(viewer) || query.trim().trim_start_matches('@').is_empty() {
        return Vec::new();
    }
    let Some(team) = teams_of(viewer, cx).into_iter().find(|t| t.id == cx.current_team_id) else {
        return Vec::new();
    };
    let spaces = readable(viewer, team, cx);
    let space_of = |id: &str| spaces.iter().find(|(s, _)| s.id == id).map(|(s, _)| *s);
    let by_id: BTreeMap<&str, &Principal> =
        cx.principals.iter().map(|p| (p.id.as_str(), p)).collect();
    let mut hits: Vec<(u8, Hit)> = Vec::new();

    for p in cx.principals {
        if p.team_id != team.id || p.via.is_some() || identity::validate(p).is_err() {
            continue;
        }
        let Some(sc) = score(query, &[&p.handle, &p.display_name]) else { continue };
        let (kind, detail) = match p.kind {
            PrincipalKind::Person => (HitKind::Person, None),
            PrincipalKind::Agent => (
                HitKind::Agent,
                p.owner_person_id.as_deref().map(|o| {
                    by_id.get(o).map_or_else(|| o.to_owned(), |op| op.display_name.clone())
                }),
            ),
        };
        hits.push((
            sc,
            Hit { kind, label: p.display_name.clone(), id: p.id.clone(), open: None, detail },
        ));
    }
    for t in cx.threads {
        let Some(s) = space_of(&t.space_id) else { continue };
        let Some(sc) = score(query, &[&t.subject]) else { continue };
        let Ok(key) = RefKey::new(RefKind::Thread, RefSource::Cmux, &t.id) else { continue };
        hits.push((
            sc,
            Hit {
                kind: HitKind::Thread,
                label: t.subject.clone(),
                id: key.id.clone(),
                open: Some(key),
                detail: Some(s.title.clone()),
            },
        ));
    }
    for (key, title) in cx.rfds.iter().filter(|(k, _)| k.kind == RefKind::Rfd) {
        let label = format!("RFD {}", key.id);
        let Some(sc) = score(query, &[title, &label, &key.id]) else { continue };
        hits.push((
            sc,
            Hit {
                kind: HitKind::Rfd,
                label: title.clone(),
                id: key.id.clone(),
                open: Some(key.clone()),
                detail: Some(label),
            },
        ));
    }
    for e in cx.sessions {
        let Some(s) = space_of(&e.space_id) else { continue };
        let Some(sc) = score(query, &[&e.title, &e.id]) else { continue };
        let Ok(key) = RefKey::new(RefKind::Session, RefSource::Cmux, &e.id) else { continue };
        hits.push((
            sc,
            Hit {
                kind: HitKind::Session,
                label: e.title.clone(),
                id: key.id.clone(),
                open: Some(key),
                detail: Some(s.title.clone()),
            },
        ));
    }
    for (s, _) in &spaces {
        let Some(sc) = score(query, &[&s.title]) else { continue };
        let Ok(key) = RefKey::new(RefKind::Space, RefSource::Cmux, &s.id) else { continue };
        hits.push((
            sc,
            Hit {
                kind: HitKind::Space,
                label: s.title.clone(),
                id: key.id.clone(),
                open: Some(key),
                detail: None,
            },
        ));
    }

    hits.sort_by(|(sa, a), (sb, b)| {
        (*sa, a.kind, a.label.to_lowercase(), &a.id).cmp(&(
            *sb,
            b.kind,
            b.label.to_lowercase(),
            &b.id,
        ))
    });
    hits.truncate(SEARCH_LIMIT);
    hits.into_iter().map(|(_, h)| h).collect()
}
