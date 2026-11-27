//! The composer's recipient picker (RFD 0170, "Native surfaces" 2, phase 1).
//!
//! One picker covers person, agent, team and space recipients, then recent threads. It starts with
//! people and pair spaces in the current team; an agent row shows its owner, harness, session and
//! status. `@name` resolves a person and `@agent-handle` the agent, through
//! [`identity::resolve_handle`]. Each candidate carries where the message would be stored, the
//! viewer's effective grants there and the wake mode the composer would suggest, so the preview is
//! known before send. A space the viewer cannot read is never listed, and a bridge author is never a
//! recipient. Nothing here does I/O; the host passes the records in.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use cmux_sync::presence::Status;

use crate::delivery::DeliveryMode;
use crate::identity::{self, PrincipalKind, Resolved};
use crate::model::{Principal, Space, SpaceKind, Team, Thread};
use crate::permission::{Capability, Grants, effective, wake_allowed};
use crate::presence::Participant;

/// What the picker reads.
#[derive(Debug, Clone, Copy)]
pub struct PickerContext<'a> {
    pub team: &'a Team,
    pub spaces: &'a [Space],
    pub principals: &'a [Principal],
    /// The viewer's recent threads, newest first.
    pub recent: &'a [Thread],
    /// Presence in the team's scope. A lease: read, never stored.
    pub here: &'a [Participant],
}

/// The picker's tiers, in the order they are shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CandidateKind {
    Person,
    PairSpace,
    Agent,
    Team,
    Space,
    Thread,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub kind: CandidateKind,
    /// A principal, space or thread id, by kind.
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    /// Where the message is stored: the pair space for a person, the shared space for an agent, the
    /// space itself, or the thread's space. `None` for a person with no pair space yet (the composer
    /// creates one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub space_id: Option<String>,
    /// The viewer's effective grants in `space_id` (none when there is no space yet).
    pub grants: Grants,
    /// What the composer suggests. A person is never woken; an agent's `wake` holds only with its
    /// owner's grant in that space.
    pub mode: DeliveryMode,
    pub wake_allowed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<Status>,
    pub working: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Picked {
    /// For an `@handle` query: the resolved principal id, or every id when it is ambiguous (the
    /// composer asks, never guesses).
    pub resolved: Vec<String>,
    pub candidates: Vec<Candidate>,
}

/// How well `query` matches one of `fields`: 0 is an exact match, 1 a prefix, 2 a word prefix, 3 a
/// substring. An empty query matches everything at 3.
pub(crate) fn score(query: &str, fields: &[&str]) -> Option<u8> {
    let q = query.trim().trim_start_matches('@').to_lowercase();
    if q.is_empty() {
        return Some(3);
    }
    fields
        .iter()
        .filter_map(|f| {
            let f = f.to_lowercase();
            if f == q {
                Some(0)
            } else if f.starts_with(&q) {
                Some(1)
            } else if f.split(|c: char| !c.is_alphanumeric()).any(|w| w.starts_with(&q)) {
                Some(2)
            } else if f.contains(&q) {
                Some(3)
            } else {
                None
            }
        })
        .min()
}

/// The viewer's grants in `space`, the agent bounded by its owner.
pub(crate) fn grants_for(
    viewer: &Principal,
    team: &Team,
    space: &Space,
    principals: &[Principal],
) -> Grants {
    if space.team_id != team.id {
        return Grants::none();
    }
    let owner = match viewer.kind {
        PrincipalKind::Agent => {
            viewer.owner_person_id.as_deref().and_then(|o| principals.iter().find(|p| p.id == o))
        }
        PrincipalKind::Person => None,
    };
    effective(viewer, owner, team, space)
}

/// Whether `viewer` may act at all: a rights-holding, well-formed principal.
pub(crate) fn has_rights(viewer: &Principal) -> bool {
    identity::require_rights(viewer).is_ok() && identity::validate(viewer).is_ok()
}

fn space_rank(kind: SpaceKind) -> u8 {
    match kind {
        SpaceKind::Pair => 0,
        SpaceKind::Session => 1,
        SpaceKind::Project => 2,
        SpaceKind::Rfd => 3,
        SpaceKind::Team => 4,
    }
}

/// Ranked recipients for `query` as `viewer` may address them.
pub fn pick(viewer: &Principal, query: &str, cx: &PickerContext<'_>) -> Picked {
    let mut out = Picked { resolved: Vec::new(), candidates: Vec::new() };
    if !has_rights(viewer) {
        return out;
    }
    let team = cx.team;
    let readable: Vec<(&Space, Grants)> = cx
        .spaces
        .iter()
        .filter(|s| s.team_id == team.id)
        .map(|s| (s, grants_for(viewer, team, s, cx.principals)))
        .filter(|(_, g)| g.has(Capability::Read))
        .collect();
    // Every per-principal and per-thread lookup below is a hash probe, built once per call, so a
    // keystroke costs O(principals + spaces x members + recent) rather than O(principals x spaces x
    // members).
    let by_id: HashMap<&str, &Principal> =
        cx.principals.iter().map(|p| (p.id.as_str(), p)).collect();
    let here: HashMap<&str, &Participant> =
        cx.here.iter().map(|h| (h.principal_id.as_str(), h)).collect();
    // Score principals first, so the space index below covers only the agents that matched.
    let matched: Vec<(&Principal, u8)> = cx
        .principals
        .iter()
        .filter(|p| {
            p.id != viewer.id
                && p.team_id == team.id
                && p.via.is_none()
                && identity::validate(p).is_ok()
        })
        .filter_map(|p| Some((p, score(query, &[&p.handle, &p.display_name])?)))
        .collect();
    let agents: HashSet<&str> = matched
        .iter()
        .filter(|(p, _)| p.kind == PrincipalKind::Agent)
        .map(|(p, _)| p.id.as_str())
        .collect();
    // The viewer's pair space with each other member (lowest id wins), and each matched agent's
    // best readable space: a pair first, then session, project, RFD, team; lowest id within a rank.
    let mut pair_of: HashMap<&str, &(&Space, Grants)> = HashMap::new();
    let mut best_of: HashMap<&str, &(&Space, Grants)> = HashMap::new();
    for entry in &readable {
        let s = entry.0;
        if s.kind == SpaceKind::Pair && s.members.len() == 2 && s.is_member(&viewer.id) {
            for m in &s.members {
                let slot = pair_of.entry(m.as_str()).or_insert(entry);
                if s.id < slot.0.id {
                    *slot = entry;
                }
            }
        }
        if agents.is_empty() {
            continue;
        }
        let rank = space_rank(s.kind);
        for m in &s.members {
            if !agents.contains(m.as_str()) {
                continue;
            }
            let slot = best_of.entry(m.as_str()).or_insert(entry);
            if (rank, &s.id) < (space_rank(slot.0.kind), &slot.0.id) {
                *slot = entry;
            }
        }
    }
    let readable_by: HashMap<&str, &(&Space, Grants)> =
        readable.iter().fold(HashMap::new(), |mut m, e| {
            m.entry(e.0.id.as_str()).or_insert(e);
            m
        });

    if query.trim().starts_with('@') {
        out.resolved = match identity::resolve_handle(query, &team.id, cx.principals) {
            Resolved::One(p) if p.id != viewer.id => vec![p.id.clone()],
            Resolved::Ambiguous(ps) => ps.into_iter().map(|p| p.id).collect(),
            _ => Vec::new(),
        };
    }

    let pair_with = |other: &str| pair_of.get(other).copied();
    let mut scored: Vec<(u8, Candidate)> = Vec::new();
    let mut paired: HashSet<&str> = HashSet::new();
    for &(p, s) in &matched {
        let h = here.get(p.id.as_str()).copied();
        let base = Candidate {
            kind: CandidateKind::Person,
            id: p.id.clone(),
            label: p.display_name.clone(),
            handle: Some(p.handle.clone()),
            space_id: None,
            grants: Grants::none(),
            mode: DeliveryMode::Ask,
            wake_allowed: false,
            owner: None,
            harness: p.harness.clone(),
            session_id: p.session_id.clone(),
            status: h.map(|h| h.status),
            working: h.is_some_and(|h| h.working),
        };
        let c = match p.kind {
            PrincipalKind::Person => {
                let pair = pair_with(&p.id);
                if let Some((s, _)) = pair {
                    paired.insert(s.id.as_str());
                }
                Candidate {
                    space_id: pair.map(|(s, _)| s.id.clone()),
                    grants: pair.map(|(_, g)| g.clone()).unwrap_or_default(),
                    ..base
                }
            }
            PrincipalKind::Agent => {
                // The agent's space with the viewer: a pair first, then session, project, RFD, team.
                let Some((s, g)) = best_of.get(p.id.as_str()).copied() else {
                    continue;
                };
                let wake = wake_allowed(s, p);
                let suggested = s
                    .agent_policy
                    .get(&p.id)
                    .filter(|a| Some(a.granted_by.as_str()) == p.owner_person_id.as_deref())
                    .map_or(DeliveryMode::Ask, |a| a.default_mode);
                let mode = match suggested {
                    DeliveryMode::Wake if !wake => DeliveryMode::Ask,
                    m => m,
                };
                Candidate {
                    kind: CandidateKind::Agent,
                    space_id: Some(s.id.clone()),
                    grants: g.clone(),
                    mode,
                    wake_allowed: wake,
                    owner: p.owner_person_id.as_deref().map(|o| {
                        by_id.get(o).map_or_else(|| o.to_owned(), |op| op.display_name.clone())
                    }),
                    ..base
                }
            }
        };
        scored.push((s, c));
    }

    let space_candidate = |kind: CandidateKind, s: &Space, g: &Grants| Candidate {
        kind,
        id: s.id.clone(),
        label: s.title.clone(),
        handle: None,
        space_id: Some(s.id.clone()),
        grants: g.clone(),
        mode: DeliveryMode::Ask,
        wake_allowed: false,
        owner: None,
        harness: None,
        session_id: None,
        status: None,
        working: false,
    };
    for (s, g) in &readable {
        if paired.contains(s.id.as_str()) {
            continue;
        }
        let Some(sc) = score(query, &[&s.title, &s.id]) else { continue };
        let kind = match s.kind {
            SpaceKind::Pair => CandidateKind::PairSpace,
            SpaceKind::Team => CandidateKind::Team,
            _ => CandidateKind::Space,
        };
        scored.push((sc, space_candidate(kind, s, g)));
    }

    for t in cx.recent {
        let Some((s, g)) = readable_by.get(t.space_id.as_str()).copied() else { continue };
        let Some(sc) = score(query, &[&t.subject]) else { continue };
        scored.push((
            sc,
            Candidate {
                kind: CandidateKind::Thread,
                id: t.id.clone(),
                label: t.subject.clone(),
                ..space_candidate(CandidateKind::Thread, s, g)
            },
        ));
    }

    // Recent threads keep their recency order within a score; everything else sorts by name. Keys
    // are built once per candidate, not per comparison.
    let recency: HashMap<&str, usize> =
        cx.recent.iter().enumerate().map(|(i, t)| (t.id.as_str(), i)).collect();
    let resolved: HashSet<&str> = out.resolved.iter().map(String::as_str).collect();
    let mut keyed: Vec<_> = scored
        .into_iter()
        .map(|(sc, c)| {
            let unresolved = !resolved.contains(c.id.as_str());
            let at =
                recency.get(c.id.as_str()).copied().filter(|_| c.kind == CandidateKind::Thread);
            ((unresolved, c.kind, sc, at, c.label.to_lowercase()), c)
        })
        .collect();
    keyed.sort_by(|(ka, a), (kb, b)| ka.cmp(kb).then_with(|| a.id.cmp(&b.id)));
    out.candidates = keyed.into_iter().map(|(_, c)| c).collect();
    out
}

#[cfg(test)]
#[path = "picker_tests.rs"]
mod tests;
