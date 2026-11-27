//! The team switcher, space navigator and search (RFD 0170, "Native surfaces" 1, phase 1).
//!
//! The sidebar lists the viewer's teams, the current team's spaces with unread counts and who is
//! live in each, and a search that opens a person, agent, thread, RFD or session without knowing
//! which backend stores it. Every space, thread and session goes through the viewer's own read
//! permission. Spaces follow the team's own order (`team.spaces`, its customization), then title.
//! Nothing here does I/O; the host passes the records in.

use std::collections::{BTreeMap, HashMap, HashSet};

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
    /// The first [`LIVE_PREVIEW`] live people by name; `people_live` counts all of them.
    pub people: Vec<LiveRow>,
    /// The first [`LIVE_PREVIEW`] live agents by name; `agents_live` counts all of them.
    pub agents: Vec<LiveRow>,
    pub people_live: u32,
    pub agents_live: u32,
}

/// Live rows a space row carries per kind. The sidebar shows a few faces and a count, so the
/// answer stays the same size however many are live: at 1000 people and 1000 agents in 200
/// spaces, every live row made a 1.56 MB answer. The whole list is the picker's and Session
/// Info's.
pub const LIVE_PREVIEW: usize = 8;

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

/// Per space id: the viewer's unread count and open threads, from one pass over the threads.
fn thread_counts<'a>(cx: &NavContext<'a>) -> HashMap<&'a str, (u32, u32)> {
    let mut counts: HashMap<&str, (u32, u32)> = HashMap::new();
    for t in cx.threads {
        let c = counts.entry(t.space_id.as_str()).or_default();
        c.0 += cx.unread.get(&t.id).copied().unwrap_or(0);
        if t.state == ThreadState::Open {
            c.1 += 1;
        }
    }
    counts
}

/// The sidebar as `viewer` may see it, or `None` for a bridge author, a malformed principal or a
/// viewer outside the current team.
pub fn navigator(viewer: &Principal, cx: &NavContext<'_>) -> Option<Navigator> {
    if !has_rights(viewer) {
        return None;
    }
    let teams = teams_of(viewer, cx);
    let current = teams.iter().find(|t| t.id == cx.current_team_id).copied()?;
    let counts = thread_counts(cx);
    let count = |s: &Space| counts.get(s.id.as_str()).copied().unwrap_or_default();
    let team_rows = teams
        .iter()
        .map(|t| TeamRow {
            id: t.id.clone(),
            name: t.name.clone(),
            current: t.id == current.id,
            unread: readable(viewer, t, cx).iter().map(|(s, _)| count(s).0).sum(),
        })
        .collect();

    let position: HashMap<&str, usize> =
        current.spaces.iter().enumerate().rev().map(|(i, id)| (id.as_str(), i)).collect();
    let mut spaces: Vec<((usize, String), &Space, Grants)> = readable(viewer, current, cx)
        .into_iter()
        .map(|(s, g)| {
            let order = position.get(s.id.as_str()).copied().unwrap_or(usize::MAX);
            ((order, s.title.to_lowercase()), s, g)
        })
        .collect();
    spaces.sort_by(|(ka, a, _), (kb, b, _)| (ka, &a.id).cmp(&(kb, &b.id)));
    let bridged: HashSet<&str> =
        cx.principals.iter().filter(|p| p.via.is_some()).map(|p| p.id.as_str()).collect();
    let space_rows = spaces
        .into_iter()
        .map(|(_, s, grants)| {
            let live = cx.here.get(&s.id).map_or(&[][..], Vec::as_slice);
            // Member sets pay off only past a few lookups; a small space scans its list.
            let members: Option<HashSet<&str>> = (live.len() > 4 && s.members.len() > 8)
                .then(|| s.members.iter().map(String::as_str).collect());
            let is_member = |id: &str| match &members {
                Some(m) => m.contains(id),
                None => s.is_member(id),
            };
            let (mut people, mut agents) = (Vec::new(), Vec::new());
            for h in live {
                if !is_member(&h.principal_id) || bridged.contains(h.principal_id.as_str()) {
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
            let (people_live, agents_live) = (people.len() as u32, agents.len() as u32);
            first_by_name(&mut people, LIVE_PREVIEW);
            first_by_name(&mut agents, LIVE_PREVIEW);
            let (unread, open) = count(s);
            SpaceRow {
                id: s.id.clone(),
                title: s.title.clone(),
                kind: s.kind,
                unread,
                open,
                grants,
                people,
                agents,
                people_live,
                agents_live,
            }
        })
        .collect();
    Some(Navigator { teams: team_rows, spaces: space_rows })
}

/// Keep the first `n` live rows by lowercased name, then id, in that order; each key built once,
/// and only the kept rows sorted.
fn first_by_name(rows: &mut Vec<LiveRow>, n: usize) {
    let mut keyed: Vec<(String, LiveRow)> =
        rows.drain(..).map(|r| (r.name.to_lowercase(), r)).collect();
    let by = |(ka, a): &(String, LiveRow), (kb, b): &(String, LiveRow)| {
        (ka, &a.principal_id).cmp(&(kb, &b.principal_id))
    };
    if keyed.len() > n {
        keyed.select_nth_unstable_by(n, by);
        keyed.truncate(n);
    }
    keyed.sort_by(by);
    rows.extend(keyed.into_iter().map(|(_, r)| r));
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
    let by_space: HashMap<&str, &Space> = spaces.iter().map(|(s, _)| (s.id.as_str(), *s)).collect();
    let space_of = |id: &str| by_space.get(id).copied();
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

    let mut keyed: Vec<((u8, HitKind, String), Hit)> =
        hits.into_iter().map(|(sc, h)| ((sc, h.kind, h.label.to_lowercase()), h)).collect();
    keyed.sort_by(|(ka, a), (kb, b)| (ka, &a.id).cmp(&(kb, &b.id)));
    keyed.truncate(SEARCH_LIMIT);
    keyed.into_iter().map(|(_, h)| h).collect()
}
