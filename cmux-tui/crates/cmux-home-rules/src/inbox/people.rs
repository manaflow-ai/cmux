//! Who New Message and a group offers (`HomeContact`, `HomeChiefRoster+Members`), the Chief
//! defaults (`HomeChiefDefault`, `HomeChiefPlace`) and the group sheet's members
//! (`HomeGroupMember`, `HomeGroupInfo`).

use super::model::{
    Contact, ContactSource, Membership, Participant, ParticipantKind, Role, Row, RowKind,
    standard_compare,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// `HomeContact.connections(in:me:)`: each DM's active human peer, once.
pub fn connections(rows: &[Row], me: &str) -> Vec<Contact> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for row in rows.iter().filter(|row| row.kind == RowKind::Direct) {
        let Some(peer) = row.participants.iter().find(|p| p.id != me) else {
            continue;
        };
        if peer.kind != ParticipantKind::Human
            || peer.membership != Membership::Active
            || peer.display_name.is_empty()
            || !seen.insert(peer.id.clone())
        {
            continue;
        }
        out.push(Contact {
            id: peer.id.clone(),
            name: peer.display_name.clone(),
            source: ContactSource::Connection,
        });
    }
    out
}

/// `HomeContact.withoutDM`: how many contacts have no DM yet.
pub fn without_dm(contacts: &[Contact], rows: &[Row]) -> usize {
    let peers: HashSet<&str> = rows
        .iter()
        .filter(|row| row.kind == RowKind::Direct)
        .flat_map(|row| row.participants.iter().map(|p| p.id.as_str()))
        .collect();
    contacts.iter().filter(|c| !peers.contains(c.id.as_str())).count()
}

/// `HomeContact.merged`: the team by name, then connections, then agents, each id once.
pub fn merged(team: &[Contact], connections: &[Contact], agents: &[Contact]) -> Vec<Contact> {
    let mut members = team.to_vec();
    members.sort_by(|a, b| standard_compare(&a.name, &b.name));
    let mut ids: HashSet<String> = members.iter().map(|c| c.id.clone()).collect();
    for contact in connections.iter().chain(agents) {
        if ids.insert(contact.id.clone()) {
            members.push(contact.clone());
        }
    }
    members
}

/// `HomeContact.agents(in:me:)`: every agent in a Chief row, once.
pub fn agents(rows: &[Row], me: &str) -> Vec<Contact> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for row in rows.iter().filter(|row| row.kind == RowKind::Chief) {
        for peer in &row.participants {
            if peer.id == me || peer.kind != ParticipantKind::Agent {
                continue;
            }
            let name = peer.visible_name();
            if name.is_empty() || !seen.insert(peer.id.clone()) {
                continue;
            }
            out.push(Contact { id: peer.id.clone(), name, source: ContactSource::Agent });
        }
    }
    out
}

/// `HomeChiefRoster.mainFirst`: the main Chief's members lead.
pub fn main_first(contacts: &[Contact], rows: &[Row], main: Option<&str>) -> Vec<Contact> {
    let Some(row) = main.and_then(|main| rows.iter().find(|row| row.id == main)) else {
        return contacts.to_vec();
    };
    let is_main = |c: &Contact| row.participants.iter().any(|p| p.id == c.id);
    contacts
        .iter()
        .filter(|c| is_main(c))
        .chain(contacts.iter().filter(|c| !is_main(c)))
        .cloned()
        .collect()
}

/// `HomeChiefRoster.groupMembers`: agents, then the team, then connections; never me.
pub fn group_members(
    contacts: &[Contact],
    rows: &[Row],
    main: Option<&str>,
    me: Option<&str>,
) -> Vec<Contact> {
    let ordered: Vec<Contact> = main_first(contacts, rows, main)
        .into_iter()
        .filter(|c| Some(c.id.as_str()) != me)
        .collect();
    [ContactSource::Agent, ContactSource::Team, ContactSource::Connection]
        .iter()
        .flat_map(|source| ordered.iter().filter(move |c| c.source == *source).cloned())
        .collect()
}

/// `HomeChiefDefault`: where a new Chief runs by default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChiefDefault {
    Auto,
    Local,
    Hosted,
}

impl ChiefDefault {
    /// `HomeChiefDefault(setting:)`: an unknown or missing setting is `auto`.
    pub fn from_setting(setting: Option<&str>) -> Self {
        match setting {
            Some("local") => Self::Local,
            Some("hosted") => Self::Hosted,
            _ => Self::Auto,
        }
    }

    /// `prefersLocal(localRunning:)`.
    pub fn prefers_local(self, local_running: bool) -> bool {
        match self {
            Self::Auto => local_running,
            Self::Local => true,
            Self::Hosted => false,
        }
    }
}

/// `HomeGroupMember.roleTag`'s kind (Swift words it).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RoleTag {
    Owner,
    Admin,
    ReadOnly,
}

/// `HomeGroupMember` built from a participant.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupMember {
    pub id: String,
    pub name: String,
    pub initials: String,
    pub is_me: bool,
    pub is_agent: bool,
    pub is_invited: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role_tag: Option<RoleTag>,
}

/// `HomeGroupMember.roleTag`.
pub fn role_tag(role: Option<Role>) -> Option<RoleTag> {
    match role {
        Some(Role::Owner) => Some(RoleTag::Owner),
        Some(Role::Admin) => Some(RoleTag::Admin),
        Some(Role::ReadOnly) => Some(RoleTag::ReadOnly),
        Some(Role::Member) | None => None,
    }
}

/// `HomeGroupMember(_:me:)`.
pub fn group_member(participant: &Participant, me: Option<&str>) -> GroupMember {
    GroupMember {
        id: participant.id.clone(),
        name: participant.visible_name(),
        initials: participant.initials(),
        is_me: Some(participant.id.as_str()) == me,
        is_agent: participant.kind == ParticipantKind::Agent,
        is_invited: participant.membership == Membership::Invited,
        role: participant.role,
        role_tag: role_tag(participant.role),
    }
}
