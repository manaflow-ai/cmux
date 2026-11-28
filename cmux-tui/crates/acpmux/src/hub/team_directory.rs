//! Part of `Hub`; see `hub/mod.rs`. RFD 0170 phase 1: the records the team navigator, the
//! recipient picker and Session Info project (`cmux_team_messaging::{navigator, picker,
//! session_info}`), as one published snapshot (`server/team_directory.rs` answers the RPCs).
//!
//! The snapshot is built from what the daemon already holds: the hub's address book, read after
//! each heartbeat (`server/mesh_relay.rs` `read_book`), names every live daemon's person and every
//! live session's agent. A read whose book is the same as the last one keeps the snapshot (its
//! fingerprint), so a keystroke in the picker never rebuilds it; a changed book publishes a new one
//! with the next generation. Spaces, threads, links, rooms and feedback beyond the team space join
//! through [`Hub::set_team_view`] as their feeds land.

use super::*;
use crate::mesh::AddressBook;
use crate::no_panic::LockExt;
use cmux_sync::presence::Status;
use cmux_team_messaging::backend::Room;
use cmux_team_messaging::navigator::{NavContext, SessionEntry};
use cmux_team_messaging::picker::PickerContext;
use cmux_team_messaging::presence::Participant;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::session_info::SessionContext;
use cmux_team_messaging::{
    Grants, LinkGraph, Principal, PrincipalKind, Space, SpaceKind, StoredMessage, Team, Thread,
    VoteBoard,
};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::hash::{Hash, Hasher};

/// Recent threads kept per principal for the picker's last tier, newest first.
pub const RECENT_PER_PRINCIPAL: usize = 50;

/// The records one published team directory holds. A feeder fills the record fields and calls
/// [`TeamView::indexed`]; the index fields are derived from them.
#[derive(Debug, Default)]
pub struct TeamView {
    /// Bumped on every publish, so a client can tell a fresh answer from a cached one.
    pub generation: u64,
    /// The team the views open on when a call names none.
    pub team_id: String,
    /// The person this machine is joined as: the viewer of the app's (the person's) connection.
    pub person_id: Option<String>,
    pub teams: Vec<Team>,
    pub spaces: Vec<Space>,
    pub principals: Vec<Principal>,
    pub threads: Vec<Thread>,
    /// Thread id to the joined person's unread count.
    pub unread: BTreeMap<String, u32>,
    /// Space id to who is here.
    pub here: BTreeMap<String, Vec<Participant>>,
    pub sessions: Vec<SessionEntry>,
    pub rfds: Vec<(RefKey, String)>,
    pub links: LinkGraph,
    /// Session id to its room.
    pub rooms: HashMap<String, Room>,
    pub titles: BTreeMap<RefKey, String>,
    pub messages: Vec<StoredMessage>,
    pub feedback: VoteBoard,
    // Derived by `indexed`.
    by_id: HashMap<String, usize>,
    by_session: HashMap<String, usize>,
    /// Team id to everyone here in any of its spaces, once each.
    team_here: HashMap<String, Vec<Participant>>,
    /// Principal id to the recent threads it takes part in, newest first.
    recent: HashMap<String, Vec<Thread>>,
    /// Session id to the threads linked to it.
    session_threads: HashMap<String, Vec<Thread>>,
}

impl TeamView {
    /// Derive the lookups the views read, after a feeder filled the records. Done once per
    /// publish, so no call pays for it.
    pub fn indexed(mut self) -> Self {
        self.by_id = self.principals.iter().enumerate().map(|(i, p)| (p.id.clone(), i)).collect();
        self.by_session = self
            .principals
            .iter()
            .enumerate()
            .filter_map(|(i, p)| p.session_id.clone().map(|s| (s, i)))
            .collect();
        let team_of: HashMap<&str, &str> =
            self.spaces.iter().map(|s| (s.id.as_str(), s.team_id.as_str())).collect();
        let mut team_here: HashMap<String, Vec<Participant>> = HashMap::new();
        let mut seen: BTreeSet<(&str, &str)> = BTreeSet::new();
        for (space, people) in &self.here {
            let Some(team) = team_of.get(space.as_str()) else { continue };
            for p in people {
                if seen.insert((team, p.principal_id.as_str())) {
                    team_here.entry((*team).to_owned()).or_default().push(p.clone());
                }
            }
        }
        self.team_here = team_here;
        let mut newest: Vec<&Thread> = self.threads.iter().collect();
        newest.sort_by(|a, b| b.revision.cmp(&a.revision).then_with(|| a.id.cmp(&b.id)));
        let mut recent: HashMap<String, Vec<Thread>> = HashMap::new();
        let mut session_threads: HashMap<String, Vec<Thread>> = HashMap::new();
        for t in newest {
            for p in &t.participants {
                let list = recent.entry(p.clone()).or_default();
                if list.len() < RECENT_PER_PRINCIPAL {
                    list.push(t.clone());
                }
            }
            for s in &t.linked_session_ids {
                session_threads.entry(s.clone()).or_default().push(t.clone());
            }
        }
        self.recent = recent;
        self.session_threads = session_threads;
        self
    }

    /// The principal a connection speaks as: the joined person for the person's connection, the
    /// agent of its proven session for an agent's.
    pub fn viewer(&self, person: bool, caller: Option<&str>) -> Option<&Principal> {
        let at = match caller.filter(|_| !person) {
            Some(session) => self.by_session.get(session),
            None => self.by_id.get(self.person_id.as_deref()?),
        };
        at.map(|&i| &self.principals[i])
    }

    pub fn team(&self, id: &str) -> Option<&Team> {
        self.teams.iter().find(|t| t.id == id)
    }

    /// What the navigator and search read, opened on `team_id`.
    pub fn nav<'a>(&'a self, team_id: &'a str) -> NavContext<'a> {
        NavContext {
            teams: &self.teams,
            current_team_id: team_id,
            spaces: &self.spaces,
            principals: &self.principals,
            threads: &self.threads,
            unread: &self.unread,
            here: &self.here,
            sessions: &self.sessions,
            rfds: &self.rfds,
        }
    }

    /// What the picker reads for `viewer` composing in `team`.
    pub fn picker<'a>(&'a self, viewer: &Principal, team: &'a Team) -> PickerContext<'a> {
        PickerContext {
            team,
            spaces: &self.spaces,
            principals: &self.principals,
            recent: self.recent.get(&viewer.id).map_or(&[], Vec::as_slice),
            here: self.team_here.get(&team.id).map_or(&[], Vec::as_slice),
        }
    }

    /// What Session Info reads for `session_id`, or None when the session's team is unknown.
    pub fn session<'a>(&'a self, session_id: &'a str) -> Option<SessionContext<'a>> {
        let entry = self.sessions.iter().find(|s| s.id == session_id);
        let space = entry.and_then(|e| self.spaces.iter().find(|s| s.id == e.space_id));
        let team = self.team(space.map_or(self.team_id.as_str(), |s| s.team_id.as_str()))?;
        let here = space.and_then(|s| self.here.get(&s.id)).map_or(&[][..], Vec::as_slice);
        Some(SessionContext {
            session_id,
            team,
            space,
            spaces: &self.spaces,
            principals: &self.principals,
            threads: self.session_threads.get(session_id).map_or(&[], Vec::as_slice),
            room: self.rooms.get(session_id),
            here,
            links: &self.links,
            titles: &self.titles,
            messages: &self.messages,
            feedback: &self.feedback,
        })
    }
}

/// The published snapshot and the fingerprint of the book it was built from.
#[derive(Default)]
pub(crate) struct TeamDirectoryCell {
    view: arc_swap::ArcSwapOption<TeamView>,
    book: StdMutex<Option<u64>>,
    generation: std::sync::atomic::AtomicU64,
}

/// A session the book lists as doing work now.
fn working(state: &str) -> bool {
    matches!(state, "working" | "running" | "busy" | "prompting")
}

/// The team directory the address book describes: a person per daemon owner, an agent per
/// session (owned by its daemon's person) with its room, all in one team space.
pub fn view_of_book(team_id: &str, person_id: Option<&str>, book: &AddressBook) -> TeamView {
    let user_of: HashMap<&str, &str> = book
        .daemons
        .iter()
        .filter(|d| !d.user.is_empty())
        .map(|d| (d.daemon_id.as_str(), d.user.as_str()))
        .collect();
    let person = |id: &str| Principal {
        id: id.to_owned(),
        kind: PrincipalKind::Person,
        handle: id.to_owned(),
        display_name: id.to_owned(),
        team_id: team_id.to_owned(),
        owner_person_id: None,
        harness: None,
        model: None,
        session_id: None,
        host_id: None,
        capabilities: Grants::all(),
        via: None,
    };
    let space_id = format!("team:{team_id}");
    let people: BTreeSet<&str> = user_of.values().copied().chain(person_id).collect();
    let mut principals: Vec<Principal> = people.iter().map(|p| person(p)).collect();
    let mut here: Vec<Participant> = principals
        .iter()
        .map(|p| Participant {
            principal_id: p.id.clone(),
            kind: p.kind,
            name: p.display_name.clone(),
            status: Status::Active,
            working: false,
        })
        .collect();
    let mut sessions = Vec::new();
    let mut rooms = HashMap::new();
    let mut seen = BTreeSet::new();
    for s in &book.sessions {
        let Some(owner) = user_of.get(s.daemon_id.as_str()) else { continue };
        if s.session_id.is_empty() || !seen.insert(s.session_id.as_str()) {
            continue;
        }
        let name = s.title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| s.name.clone());
        let agent = Principal {
            id: format!("agent:{}", s.session_id),
            kind: PrincipalKind::Agent,
            handle: s.handle.clone().unwrap_or_else(|| s.name.clone()),
            display_name: name.clone(),
            owner_person_id: Some((*owner).to_owned()),
            harness: (!s.harness.is_empty()).then(|| s.harness.clone()),
            model: s.model.clone(),
            session_id: Some(s.session_id.clone()),
            host_id: (!s.host.is_empty()).then(|| s.host.clone()),
            ..person(&s.session_id)
        };
        here.push(Participant {
            principal_id: agent.id.clone(),
            kind: agent.kind,
            name: name.clone(),
            status: if working(&s.state) { Status::Active } else { Status::Idle },
            working: working(&s.state),
        });
        sessions.push(SessionEntry {
            id: s.session_id.clone(),
            title: name,
            space_id: space_id.clone(),
        });
        rooms.insert(
            s.session_id.clone(),
            Room {
                session_id: s.session_id.clone(),
                owner_id: (*owner).to_owned(),
                members: Vec::new(),
            },
        );
        principals.push(agent);
    }
    let members: Vec<String> = principals.iter().map(|p| p.id.clone()).collect();
    TeamView {
        team_id: team_id.to_owned(),
        person_id: person_id.map(str::to_owned),
        teams: vec![Team {
            id: team_id.to_owned(),
            name: "Team".to_owned(),
            members: members.clone(),
            spaces: vec![space_id.clone()],
            integrations: Vec::new(),
            policy: Grants::all(),
            customization: BTreeMap::new(),
        }],
        spaces: vec![Space {
            id: space_id.clone(),
            team_id: team_id.to_owned(),
            kind: SpaceKind::Team,
            title: "Team".to_owned(),
            members,
            agent_policy: BTreeMap::new(),
            notification_policy: BTreeMap::new(),
        }],
        principals,
        here: BTreeMap::from([(space_id, here)]),
        sessions,
        rooms,
        ..TeamView::default()
    }
    .indexed()
}

fn fingerprint(team_id: &str, person_id: Option<&str>, book: &AddressBook) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    team_id.hash(&mut h);
    person_id.hash(&mut h);
    for d in &book.daemons {
        (&d.daemon_id, &d.user).hash(&mut h);
    }
    for s in &book.sessions {
        (&s.session_id, &s.daemon_id, &s.name, &s.title, &s.handle, &s.harness, &s.model, &s.state)
            .hash(&mut h);
        s.host.hash(&mut h);
    }
    h.finish()
}

impl Hub {
    /// The team directory now, if one was published.
    pub fn team_view(&self) -> Option<Arc<TeamView>> {
        self.team_directory.view.load_full()
    }

    /// Publish `view` (already [`TeamView::indexed`]) with the next generation.
    pub fn set_team_view(&self, mut view: TeamView) -> Arc<TeamView> {
        view.generation =
            self.team_directory.generation.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let view = Arc::new(view);
        self.team_directory.view.store(Some(view.clone()));
        view
    }

    /// Read the address book into the team directory; true when it changed and was republished.
    /// The same book as the last read keeps the snapshot as it is.
    pub(crate) fn apply_team_book(
        &self,
        team_id: &str,
        person_id: Option<&str>,
        book: &AddressBook,
    ) -> bool {
        let print = fingerprint(team_id, person_id, book);
        {
            let mut last = self.team_directory.book.lock_or_recover();
            if *last == Some(print) {
                return false;
            }
            *last = Some(print);
        }
        self.set_team_view(view_of_book(team_id, person_id, book));
        true
    }
}
