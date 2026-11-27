//! Part of `Hub`; see `hub/mod.rs`. RFD 0170 phase 1: the team directory the navigator, the
//! recipient picker and Session Info read (`server/team_directory.rs`), as one published snapshot.
//!
//! The snapshot is built from what the daemon already holds: the hub's address book, read after
//! each heartbeat (`server/mesh_relay.rs` `read_book`), names every live daemon's person and every
//! live session's agent. A read whose book is the same as the last one keeps the snapshot (its
//! fingerprint), so a keystroke in the picker never rebuilds it; a changed book publishes a new one
//! with the next generation. Spaces, threads, links and rooms beyond the team space join through
//! [`Hub::set_team_view`] as their feeds land.

use super::*;
use crate::mesh::AddressBook;
use cmux_sync::presence::Status;
use cmux_team_messaging::backend::Room;
use cmux_team_messaging::directory::Recent;
use cmux_team_messaging::presence::Participant;
use cmux_team_messaging::{
    Directory, Grants, LinkGraph, Principal, PrincipalKind, Space, SpaceKind, Team,
};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::hash::{Hash, Hasher};

/// One published team directory and the live state its views read.
#[derive(Debug, Default)]
pub struct TeamView {
    /// Bumped on every publish, so a client can tell a fresh answer from a cached one.
    pub generation: u64,
    pub team_id: String,
    /// The person this machine is joined as: the viewer of the app's (the person's) connection.
    pub person_id: Option<String>,
    pub directory: Directory,
    pub links: LinkGraph,
    pub rooms: HashMap<String, Room>,
    pub here: Vec<Participant>,
    pub recent: Vec<Recent>,
    pub unread: BTreeMap<String, u32>,
    pub titles: BTreeMap<String, String>,
    /// Principal id by session id, for an agent connection's viewer.
    pub by_session: HashMap<String, usize>,
}

impl TeamView {
    /// Index the agents by session, after a feeder filled `directory`.
    pub fn indexed(mut self) -> Self {
        self.by_session = self
            .directory
            .principals
            .iter()
            .enumerate()
            .filter_map(|(i, p)| p.session_id.clone().map(|s| (s, i)))
            .collect();
        self
    }

    /// The principal a connection speaks as: the joined person for the person's connection, the
    /// agent of its proven session for an agent's.
    pub fn viewer(&self, person: bool, caller: Option<&str>) -> Option<&Principal> {
        if let Some(session) = caller.filter(|_| !person) {
            return self.by_session.get(session).map(|&i| &self.directory.principals[i]);
        }
        let id = self.person_id.as_deref()?;
        self.directory.principal(id)
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

/// Build the team directory the address book describes: a person per daemon owner, an agent per
/// session (owned by its daemon's person), all in one team space.
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
    let people: BTreeSet<&str> = user_of.values().copied().chain(person_id).collect();
    let mut principals: Vec<Principal> = people.iter().map(|p| person(p)).collect();
    let mut here: Vec<Participant> = Vec::new();
    for p in &principals {
        here.push(Participant {
            principal_id: p.id.clone(),
            kind: p.kind,
            name: p.display_name.clone(),
            status: Status::Active,
            working: false,
        });
    }
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
            display_name: name,
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
            name: agent.display_name.clone(),
            status: if working(&s.state) { Status::Active } else { Status::Idle },
            working: working(&s.state),
        });
        principals.push(agent);
    }
    let members: Vec<String> = principals.iter().map(|p| p.id.clone()).collect();
    let space_id = format!("team:{team_id}");
    let team = Team {
        id: team_id.to_owned(),
        name: "Team".to_owned(),
        members: members.clone(),
        spaces: vec![space_id.clone()],
        integrations: Vec::new(),
        policy: Grants::all(),
        customization: BTreeMap::new(),
    };
    let space = Space {
        id: space_id,
        team_id: team_id.to_owned(),
        kind: SpaceKind::Team,
        title: "Team".to_owned(),
        members,
        agent_policy: BTreeMap::new(),
        notification_policy: BTreeMap::new(),
    };
    TeamView {
        team_id: team_id.to_owned(),
        person_id: person_id.map(str::to_owned),
        directory: Directory {
            principals,
            teams: vec![team],
            spaces: vec![space],
            threads: Vec::new(),
        },
        here,
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

    /// Publish `view` with the next generation.
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
