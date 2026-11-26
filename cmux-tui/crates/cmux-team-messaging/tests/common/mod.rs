#![allow(dead_code)]

use std::collections::BTreeMap;

use cmux_team_messaging::model::{AgentGrant, Notify};
use cmux_team_messaging::{
    Bridge, DeliveryMode, Grants, Principal, PrincipalKind, RootKind, Space, SpaceKind, Team,
    Thread, ThreadState,
};

pub const TEAM: &str = "team-a";

pub fn person(id: &str, caps: Grants) -> Principal {
    Principal {
        id: id.to_owned(),
        kind: PrincipalKind::Person,
        handle: id.to_owned(),
        display_name: id.to_owned(),
        team_id: TEAM.to_owned(),
        owner_person_id: None,
        harness: None,
        model: None,
        session_id: None,
        host_id: None,
        capabilities: caps,
        via: None,
    }
}

pub fn agent(id: &str, owner: &str, caps: Grants) -> Principal {
    Principal {
        kind: PrincipalKind::Agent,
        owner_person_id: Some(owner.to_owned()),
        harness: Some("claude".to_owned()),
        ..person(id, caps)
    }
}

pub fn bridged(id: &str, via: Bridge) -> Principal {
    Principal { via: Some(via), ..person(id, Grants::all()) }
}

pub fn team(policy: Grants) -> Team {
    Team {
        id: TEAM.to_owned(),
        name: "Team A".to_owned(),
        members: Vec::new(),
        spaces: vec!["space-1".to_owned()],
        integrations: vec![Bridge::Slack],
        policy,
        customization: BTreeMap::new(),
    }
}

pub fn space(members: &[&str]) -> Space {
    Space {
        id: "space-1".to_owned(),
        team_id: TEAM.to_owned(),
        kind: SpaceKind::Project,
        title: "Project".to_owned(),
        members: members.iter().map(|m| (*m).to_owned()).collect(),
        agent_policy: BTreeMap::new(),
        notification_policy: BTreeMap::new(),
    }
}

pub fn grant_wake(space: &mut Space, agent: &str, by: &str) {
    space.agent_policy.insert(
        agent.to_owned(),
        AgentGrant { granted_by: by.to_owned(), wake: true, default_mode: DeliveryMode::Ask },
    );
}

pub fn set_notify(space: &mut Space, person: &str, n: Notify) {
    space.notification_policy.insert(person.to_owned(), n);
}

pub fn thread(id: &str) -> Thread {
    Thread {
        id: id.to_owned(),
        space_id: "space-1".to_owned(),
        root_kind: RootKind::Ask,
        subject: "Subject".to_owned(),
        participants: Vec::new(),
        linked_rfd_ids: Vec::new(),
        linked_session_ids: Vec::new(),
        revision: 0,
        state: ThreadState::Open,
    }
}
