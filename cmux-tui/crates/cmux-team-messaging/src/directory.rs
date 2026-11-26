//! RFD 0170 phase 1's three native surfaces as typed views over the phase 0 records: the team
//! navigator, the composer's recipient picker and Session Info's participant and link sections.
//!
//! Each surface is a projection, never a second log. Every view is computed for one viewer: a space
//! the viewer cannot read is never listed, a link never shows a target the viewer cannot reach, and a
//! bridge author (`via Slack`) is never offered as a recipient. Nothing here does I/O or reads a
//! clock; the host passes unread counts, presence and recent activity in.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use cmux_sync::presence::Status;

use crate::backend::{Room, RoomRole};
use crate::delivery::DeliveryMode;
use crate::identity::PrincipalKind;
use crate::model::{Principal, RootKind, Space, SpaceKind, Team, Thread, ThreadState};
use crate::permission::{Capability, effective, wake_allowed};
use crate::presence::Participant;
use crate::refs::{LinkGraph, RefKey, RefKind, RefSource};

/// The records a viewer's surfaces are computed from.
#[derive(Debug, Clone, Default)]
pub struct Directory {
    pub principals: Vec<Principal>,
    pub teams: Vec<Team>,
    pub spaces: Vec<Space>,
    pub threads: Vec<Thread>,
}

/// Where a principal is, as presence reports it. `Offline` is the absence of a lease.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Liveness {
    Active,
    Idle,
    Away,
    Offline,
}

impl Liveness {
    pub fn is_live(self) -> bool {
        matches!(self, Self::Active | Self::Idle)
    }
}

/// A person or agent as every surface shows them. An agent always carries its owner, so the picker,
/// navigator and Session Info never show an agent that looks like a person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrincipalCard {
    pub id: String,
    pub kind: PrincipalKind,
    pub handle: String,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub liveness: Liveness,
    /// Typing (a person) or in a turn (an agent).
    pub working: bool,
}

impl Directory {
    pub fn principal(&self, id: &str) -> Option<&Principal> {
        self.principals.iter().find(|p| p.id == id)
    }

    /// Whether `viewer` may read `space`, by the phase 0 permission intersection.
    pub fn can_read(&self, viewer: &Principal, space: &Space) -> bool {
        Ix::new(self, &[]).can_read(viewer, space)
    }

    pub fn card(&self, p: &Principal, here: &[Participant]) -> PrincipalCard {
        Ix::new(self, here).card(p)
    }
}

/// One call's lookups by id, built once in O(records), so a keystroke in the picker costs the same
/// whether the team has ten members or two thousand.
struct Ix<'a> {
    principals: &'a [Principal],
    teams: &'a [Team],
    spaces: &'a [Space],
    threads: &'a [Thread],
    principal_by: HashMap<&'a str, &'a Principal>,
    team_by: HashMap<&'a str, &'a Team>,
    space_by: HashMap<&'a str, &'a Space>,
    thread_by: HashMap<&'a str, &'a Thread>,
    members: HashMap<&'a str, HashSet<&'a str>>,
    here: HashMap<&'a str, &'a Participant>,
}

impl<'a> Ix<'a> {
    fn new(d: &'a Directory, here: &'a [Participant]) -> Self {
        Self {
            principals: &d.principals,
            teams: &d.teams,
            spaces: &d.spaces,
            threads: &d.threads,
            principal_by: d.principals.iter().map(|p| (p.id.as_str(), p)).collect(),
            team_by: d.teams.iter().map(|t| (t.id.as_str(), t)).collect(),
            space_by: d.spaces.iter().map(|s| (s.id.as_str(), s)).collect(),
            thread_by: d.threads.iter().map(|t| (t.id.as_str(), t)).collect(),
            members: d
                .spaces
                .iter()
                .map(|s| (s.id.as_str(), s.members.iter().map(String::as_str).collect()))
                .collect(),
            here: here.iter().map(|p| (p.principal_id.as_str(), p)).collect(),
        }
    }

    fn principal(&self, id: &str) -> Option<&'a Principal> {
        self.principal_by.get(id).copied()
    }

    fn team(&self, id: &str) -> Option<&'a Team> {
        self.team_by.get(id).copied()
    }

    fn space(&self, id: &str) -> Option<&'a Space> {
        self.space_by.get(id).copied()
    }

    fn thread(&self, id: &str) -> Option<&'a Thread> {
        self.thread_by.get(id).copied()
    }

    fn owner_of(&self, p: &Principal) -> Option<&'a Principal> {
        match p.kind {
            PrincipalKind::Agent => p.owner_person_id.as_deref().and_then(|o| self.principal(o)),
            PrincipalKind::Person => None,
        }
    }

    fn is_member(&self, space: &Space, id: &str) -> bool {
        self.members.get(space.id.as_str()).is_some_and(|m| m.contains(id))
    }

    fn can_read(&self, viewer: &Principal, space: &Space) -> bool {
        // `effective` needs the viewer, and an agent's owner, to be members: check that in O(1)
        // before running the full intersection.
        if !self.is_member(space, &viewer.id) {
            return false;
        }
        let owner = self.owner_of(viewer);
        if viewer.kind == PrincipalKind::Agent
            && !owner.is_some_and(|o| self.is_member(space, &o.id))
        {
            return false;
        }
        self.team(&space.team_id)
            .is_some_and(|team| effective(viewer, owner, team, space).has(Capability::Read))
    }

    fn can_read_thread(&self, viewer: &Principal, thread_id: &str) -> bool {
        self.thread(thread_id)
            .and_then(|t| self.space(&t.space_id))
            .is_some_and(|s| self.can_read(viewer, s))
    }

    fn card(&self, p: &Principal) -> PrincipalCard {
        let (liveness, working) = match self.here.get(p.id.as_str()) {
            Some(h) => (
                match h.status {
                    Status::Active => Liveness::Active,
                    Status::Idle => Liveness::Idle,
                    Status::Away => Liveness::Away,
                },
                h.working,
            ),
            None => (Liveness::Offline, false),
        };
        let owner = self.owner_of(p);
        PrincipalCard {
            id: p.id.clone(),
            kind: p.kind,
            handle: p.handle.clone(),
            display_name: p.display_name.clone(),
            owner_id: p.owner_person_id.clone(),
            owner_name: owner.map(|o| o.display_name.clone()),
            harness: p.harness.clone(),
            session_id: p.session_id.clone(),
            liveness,
            working,
        }
    }

    /// The team members a viewer can address: in the team, holding cmux rights (no bridge author),
    /// and not the viewer.
    fn addressable<'b>(
        &'b self,
        viewer: &'b Principal,
        team: &'b Team,
    ) -> impl Iterator<Item = &'a Principal> + 'b {
        self.principals
            .iter()
            .filter(move |p| p.team_id == team.id && p.via.is_none() && p.id != viewer.id)
    }
}

// ---------------------------------------------------------------------------------------------
// Team switcher and space navigator
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceRow {
    pub id: String,
    pub kind: SpaceKind,
    pub title: String,
    pub unread: u32,
    /// Members of this space who are live now, people first.
    pub live: Vec<PrincipalCard>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamTab {
    pub id: String,
    pub name: String,
    pub unread: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Navigator {
    /// Every team the viewer belongs to, the current one included, for the team switcher.
    pub teams: Vec<TeamTab>,
    pub team_id: String,
    pub spaces: Vec<SpaceRow>,
    /// Live people and agents in the current team, people first.
    pub live: Vec<PrincipalCard>,
}

/// Spaces sort team, pair, project, RFD, session; then unread first; then title.
fn space_rank(kind: SpaceKind) -> u8 {
    match kind {
        SpaceKind::Team => 0,
        SpaceKind::Pair => 1,
        SpaceKind::Project => 2,
        SpaceKind::Rfd => 3,
        SpaceKind::Session => 4,
    }
}

fn people_first(cards: &mut [PrincipalCard]) {
    cards.sort_by(|a, b| {
        (a.kind != PrincipalKind::Person, !a.working, &a.display_name, &a.id).cmp(&(
            b.kind != PrincipalKind::Person,
            !b.working,
            &b.display_name,
            &b.id,
        ))
    });
}

impl Directory {
    /// The sidebar for `viewer` in `team_id`: the viewer's teams, the readable spaces with unread
    /// counts, and who is live. `unread` maps a space id to its unread count for this viewer.
    pub fn navigator(
        &self,
        viewer: &Principal,
        team_id: &str,
        unread: &BTreeMap<String, u32>,
        here: &[Participant],
    ) -> Navigator {
        let ix = Ix::new(self, here);
        let readable = |s: &&Space| ix.can_read(viewer, s);
        let teams = self
            .teams
            .iter()
            .filter(|t| t.id == viewer.team_id || t.members.iter().any(|m| m == &viewer.id))
            .map(|t| TeamTab {
                id: t.id.clone(),
                name: t.name.clone(),
                unread: self
                    .spaces
                    .iter()
                    .filter(|s| s.team_id == t.id)
                    .filter(readable)
                    .map(|s| unread.get(&s.id).copied().unwrap_or(0))
                    .sum(),
            })
            .collect();

        let mut spaces: Vec<SpaceRow> = self
            .spaces
            .iter()
            .filter(|s| s.team_id == team_id)
            .filter(readable)
            .map(|s| {
                let mut live: Vec<PrincipalCard> = s
                    .members
                    .iter()
                    .filter_map(|m| ix.principal(m))
                    .map(|p| ix.card(p))
                    .filter(|c| c.liveness.is_live())
                    .collect();
                people_first(&mut live);
                SpaceRow {
                    id: s.id.clone(),
                    kind: s.kind,
                    title: s.title.clone(),
                    unread: unread.get(&s.id).copied().unwrap_or(0),
                    live,
                }
            })
            .collect();
        spaces.sort_by(|a, b| {
            (space_rank(a.kind), a.unread == 0, &a.title, &a.id).cmp(&(
                space_rank(b.kind),
                b.unread == 0,
                &b.title,
                &b.id,
            ))
        });

        let mut live: Vec<PrincipalCard> = match ix.team(team_id) {
            Some(team) => ix
                .addressable(viewer, team)
                .map(|p| ix.card(p))
                .filter(|c| c.liveness.is_live())
                .collect(),
            None => Vec::new(),
        };
        people_first(&mut live);
        Navigator { teams, team_id: team_id.to_owned(), spaces, live }
    }
}

// ---------------------------------------------------------------------------------------------
// Composer recipient picker
// ---------------------------------------------------------------------------------------------

/// A thread's last activity, as the host knows it, for the picker's "recent threads".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recent {
    pub thread_id: String,
    pub at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Candidate {
    Person {
        card: PrincipalCard,
        /// The pair space the viewer already shares with this person, if any.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pair_space_id: Option<String>,
    },
    Agent {
        card: PrincipalCard,
        /// What the composer will suggest for this agent: its owner's default in the agent's pair or
        /// team space, else `ask`. Never `wake` unless the owner granted wake there.
        default_mode: DeliveryMode,
        /// Whether a `wake` sent now can start a turn anywhere the viewer could post to it.
        can_wake: bool,
    },
    Space {
        id: String,
        space_kind: SpaceKind,
        title: String,
        members: usize,
    },
    Thread {
        id: String,
        space_id: String,
        space_title: String,
        subject: String,
        root_kind: RootKind,
        at_ms: u64,
    },
}

impl Candidate {
    pub fn id(&self) -> &str {
        match self {
            Self::Person { card, .. } | Self::Agent { card, .. } => &card.id,
            Self::Space { id, .. } | Self::Thread { id, .. } => id,
        }
    }

    /// The picker's group order with no query: people and pair spaces, then recent threads, then
    /// agents, then the other spaces (RFD 0170, "Person-to-person ergonomics").
    fn group(&self) -> u8 {
        match self {
            Self::Person { .. } => 0,
            Self::Space { space_kind: SpaceKind::Pair, .. } => 0,
            Self::Thread { .. } => 1,
            Self::Agent { .. } => 2,
            Self::Space { .. } => 3,
        }
    }

    fn texts(&self) -> Vec<&str> {
        match self {
            Self::Person { card, .. } | Self::Agent { card, .. } => {
                let mut t = vec![card.handle.as_str(), card.display_name.as_str()];
                if let Some(o) = &card.owner_name {
                    t.push(o.as_str());
                }
                t
            }
            Self::Space { title, .. } => vec![title.as_str()],
            Self::Thread { subject, space_title, .. } => {
                vec![subject.as_str(), space_title.as_str()]
            }
        }
    }
}

/// How well `query` matches `text`: 0 handle-exact, 1 prefix, 2 word prefix, 3 substring.
fn match_tier(text: &str, query: &str) -> Option<u8> {
    let t = text.to_lowercase();
    if t == query {
        Some(0)
    } else if t.starts_with(query) {
        Some(1)
    } else if t.split(|c: char| !c.is_alphanumeric()).any(|w| !w.is_empty() && w.starts_with(query))
    {
        Some(2)
    } else if t.contains(query) {
        Some(3)
    } else {
        None
    }
}

impl Directory {
    /// The recipient picker for `viewer` composing in `team_id`. With an empty query it lists people
    /// and pair spaces, then recent threads, then agents, then team spaces. With a query (`@`
    /// optional) it ranks by match quality, then that group order. A query that starts with `@`
    /// matches only people and agents. At most `limit` candidates.
    pub fn pick(
        &self,
        viewer: &Principal,
        team_id: &str,
        query: &str,
        recent: &[Recent],
        here: &[Participant],
        limit: usize,
    ) -> Vec<Candidate> {
        let ix = Ix::new(self, here);
        let Some(team) = ix.team(team_id) else { return Vec::new() };
        let raw = query.trim();
        let principals_only = raw.starts_with('@');
        let q = raw.trim_start_matches('@').to_lowercase();

        let readable: Vec<&Space> =
            self.spaces.iter().filter(|s| s.team_id == team.id && ix.can_read(viewer, s)).collect();
        let readable_by: HashMap<&str, &Space> =
            readable.iter().map(|s| (s.id.as_str(), *s)).collect();
        let pair_with = |id: &str| {
            readable
                .iter()
                .find(|s| s.kind == SpaceKind::Pair && ix.is_member(s, id))
                .map(|s| s.id.clone())
        };

        let mut out: Vec<(Candidate, u64)> = Vec::new();
        for p in ix.addressable(viewer, team) {
            let card = ix.card(p);
            match p.kind {
                PrincipalKind::Person => {
                    out.push((Candidate::Person { card, pair_space_id: pair_with(&p.id) }, 0));
                }
                PrincipalKind::Agent => {
                    // The spaces where the viewer could post to this agent and it could read.
                    let reach: Vec<&&Space> =
                        readable.iter().filter(|s| ix.can_read(p, s)).collect();
                    let can_wake = reach.iter().any(|s| wake_allowed(s, p));
                    let owner = p.owner_person_id.as_deref();
                    let default_mode = reach
                        .iter()
                        .filter(|s| matches!(s.kind, SpaceKind::Pair | SpaceKind::Team))
                        .find_map(|s| s.agent_policy.get(&p.id))
                        .filter(|g| Some(g.granted_by.as_str()) == owner)
                        .map(|g| match g.default_mode {
                            DeliveryMode::Wake if !g.wake => DeliveryMode::Ask,
                            m => m,
                        })
                        .unwrap_or(DeliveryMode::Ask);
                    out.push((Candidate::Agent { card, default_mode, can_wake }, 0));
                }
            }
        }
        if !principals_only {
            for s in &readable {
                // A pair space is reached through its person; listing both would be a duplicate.
                if s.kind == SpaceKind::Pair {
                    continue;
                }
                out.push((
                    Candidate::Space {
                        id: s.id.clone(),
                        space_kind: s.kind,
                        title: s.title.clone(),
                        members: s.members.len(),
                    },
                    0,
                ));
            }
            let mut seen = BTreeSet::new();
            let mut recent: Vec<&Recent> = recent.iter().collect();
            recent
                .sort_by(|a, b| b.at_ms.cmp(&a.at_ms).then_with(|| a.thread_id.cmp(&b.thread_id)));
            for r in recent {
                if !seen.insert(r.thread_id.as_str()) {
                    continue;
                }
                let Some(t) = ix.thread(&r.thread_id) else { continue };
                let Some(s) = readable_by.get(t.space_id.as_str()) else { continue };
                if t.state == ThreadState::Closed {
                    continue;
                }
                out.push((
                    Candidate::Thread {
                        id: t.id.clone(),
                        space_id: s.id.clone(),
                        space_title: s.title.clone(),
                        subject: t.subject.clone(),
                        root_kind: t.root_kind,
                        at_ms: r.at_ms,
                    },
                    r.at_ms,
                ));
            }
        }

        let mut scored: Vec<(u8, u8, u8, u64, Candidate)> = out
            .into_iter()
            .filter_map(|(c, at)| {
                let tier = if q.is_empty() {
                    0
                } else {
                    c.texts().into_iter().filter_map(|t| match_tier(t, &q)).min()?
                };
                let live = match &c {
                    Candidate::Person { card, .. } | Candidate::Agent { card, .. } => {
                        u8::from(!card.liveness.is_live())
                    }
                    _ => 0,
                };
                Some((tier, c.group(), live, u64::MAX - at, c))
            })
            .collect();
        scored.sort_by(|a, b| {
            (a.0, a.1, a.2, a.3, label(&a.4), a.4.id()).cmp(&(
                b.0,
                b.1,
                b.2,
                b.3,
                label(&b.4),
                b.4.id(),
            ))
        });
        scored.into_iter().take(limit).map(|t| t.4).collect()
    }
}

fn label(c: &Candidate) -> String {
    match c {
        Candidate::Person { card, .. } | Candidate::Agent { card, .. } => {
            card.display_name.to_lowercase()
        }
        Candidate::Space { title, .. } => title.to_lowercase(),
        Candidate::Thread { subject, .. } => subject.to_lowercase(),
    }
}

// ---------------------------------------------------------------------------------------------
// Session Info: participants and links
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkRow {
    pub key: RefKey,
    /// `kind:source/id`, what `Copy link` and the opener take.
    pub canonical: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionParticipant {
    pub card: PrincipalCard,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<RoomRole>,
    pub owner: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum SessionAction {
    OpenThread { target: String },
    OpenRfd { target: String },
    JoinRoom { session_id: String },
    CopyLink { link: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub session: LinkRow,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub space: Option<LinkRow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<PrincipalCard>,
    /// The viewer's role in the live room; `None` when not admitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewer_role: Option<RoomRole>,
    /// People first, then agents; the owner leads its group.
    pub participants: Vec<SessionParticipant>,
    /// The session's linked forum thread the viewer can read (the most recently revised).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread: Option<LinkRow>,
    pub rfds: Vec<LinkRow>,
    /// The newest open `ask` thread linked to the session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_ask: Option<LinkRow>,
    /// Links the viewer cannot read, counted and never named.
    pub hidden_links: usize,
    pub actions: Vec<SessionAction>,
}

fn row(key: RefKey, title: impl Into<String>) -> LinkRow {
    LinkRow { canonical: key.canonical(), key, title: title.into() }
}

impl Directory {
    /// Session Info's participant and link sections for `viewer`. `titles` maps a ref's canonical
    /// string to its display title (an RFD's title, say); a link without one shows its id.
    pub fn session_info(
        &self,
        viewer: &Principal,
        session_id: &str,
        links: &LinkGraph,
        room: Option<&Room>,
        here: &[Participant],
        titles: &BTreeMap<String, String>,
    ) -> SessionInfo {
        let ix = Ix::new(self, here);
        let session_key =
            RefKey { kind: RefKind::Session, source: RefSource::Cmux, id: session_id.to_owned() };
        let title_of =
            |k: &RefKey| titles.get(&k.canonical()).cloned().unwrap_or_else(|| k.id.clone());
        let can_read = |k: &RefKey| match k.kind {
            RefKind::Thread => ix.can_read_thread(viewer, &k.id),
            RefKind::Space => ix.space(&k.id).is_some_and(|s| ix.can_read(viewer, s)),
            // RFDs, PRs and issues carry their own access; Session Info only links them.
            _ => true,
        };
        let all = links.links(&session_key);
        let visible: Vec<RefKey> = all.iter().filter(|k| can_read(k)).cloned().collect();
        let hidden_links = all.len() - visible.len();

        let mut threads: Vec<&Thread> = visible
            .iter()
            .filter(|k| k.kind == RefKind::Thread)
            .filter_map(|k| ix.thread(&k.id))
            .collect();
        // Also a thread whose record names this session, linked or not in the graph.
        for t in ix.threads {
            if t.linked_session_ids.iter().any(|s| s == session_id)
                && !threads.iter().any(|x| x.id == t.id)
                && ix.can_read_thread(viewer, &t.id)
            {
                threads.push(t);
            }
        }
        threads.sort_by(|a, b| b.revision.cmp(&a.revision).then_with(|| a.id.cmp(&b.id)));
        let thread_row = |t: &Thread| {
            row(
                RefKey { kind: RefKind::Thread, source: RefSource::Cmux, id: t.id.clone() },
                t.subject.clone(),
            )
        };
        let thread = threads.first().map(|t| thread_row(t));
        let current_ask = threads
            .iter()
            .find(|t| t.root_kind == RootKind::Ask && t.state == ThreadState::Open)
            .map(|t| thread_row(t));

        let mut rfd_keys: Vec<RefKey> =
            visible.iter().filter(|k| k.kind == RefKind::Rfd).cloned().collect();
        for t in &threads {
            for id in &t.linked_rfd_ids {
                if let Ok(k) = RefKey::new(RefKind::Rfd, RefSource::Hq, id) {
                    if !rfd_keys.contains(&k) {
                        rfd_keys.push(k);
                    }
                }
            }
        }
        rfd_keys.sort();
        let rfds: Vec<LinkRow> = rfd_keys
            .into_iter()
            .map(|k| {
                let t = title_of(&k);
                row(k, t)
            })
            .collect();

        let space = threads.first().and_then(|t| ix.space(&t.space_id));
        let team = space.and_then(|s| ix.team(&s.team_id));

        let owner_id = room.map(|r| r.owner_id.as_str());
        let mut participants: Vec<SessionParticipant> = Vec::new();
        let mut add = |id: &str, role: Option<RoomRole>| {
            if participants.iter().any(|p| p.card.id == id) {
                return;
            }
            if let Some(p) = ix.principal(id) {
                participants.push(SessionParticipant {
                    card: ix.card(p),
                    role,
                    owner: Some(id) == owner_id,
                });
            }
        };
        if let Some(r) = room {
            add(&r.owner_id, Some(RoomRole::Talk));
            for (id, role) in &r.members {
                add(id, Some(*role));
            }
        }
        for p in here {
            add(&p.principal_id, None);
        }
        // An agent whose reported session is this one is a participant even before it beats.
        for p in ix.principals.iter().filter(|p| p.session_id.as_deref() == Some(session_id)) {
            add(&p.id, None);
        }
        participants.sort_by(|a, b| {
            (a.card.kind != PrincipalKind::Person, !a.owner, &a.card.display_name, &a.card.id).cmp(
                &(b.card.kind != PrincipalKind::Person, !b.owner, &b.card.display_name, &b.card.id),
            )
        });

        let viewer_role = room.and_then(|r| {
            if r.owner_id == viewer.id {
                Some(RoomRole::Talk)
            } else {
                r.members.iter().find(|(id, _)| id == &viewer.id).map(|(_, role)| *role)
            }
        });
        let owner = owner_id.and_then(|o| ix.principal(o)).map(|p| ix.card(p));

        let mut actions = Vec::new();
        if let Some(t) = &thread {
            actions.push(SessionAction::OpenThread { target: t.canonical.clone() });
        }
        if let Some(r) = rfds.first() {
            actions.push(SessionAction::OpenRfd { target: r.canonical.clone() });
        }
        if viewer_role.is_some() {
            actions.push(SessionAction::JoinRoom { session_id: session_id.to_owned() });
        }
        actions.push(SessionAction::CopyLink { link: session_key.canonical() });

        SessionInfo {
            session: row(session_key.clone(), title_of(&session_key)),
            team_id: team.map(|t| t.id.clone()),
            team_name: team.map(|t| t.name.clone()),
            space: space.map(|s| {
                row(
                    RefKey { kind: RefKind::Space, source: RefSource::Cmux, id: s.id.clone() },
                    s.title.clone(),
                )
            }),
            owner,
            viewer_role,
            participants,
            thread,
            rfds,
            current_ask,
            hidden_links,
            actions,
        }
    }
}
