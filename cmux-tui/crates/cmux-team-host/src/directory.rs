//! The team directory the reconciler compiles (input contract with `TeamDO`).
//!
//! `TeamDO` is the only writer of members, Linux names, UID blocks, the node tree and the role
//! grants (plans/cmux-next/team-vm-plan.md S4). The reconciler only reads this snapshot; anything
//! invalid in it is refused and reported, never guessed.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// First UID of member blocks (`TeamDO` allocates blocks of [`UID_BLOCK`] from here, never reused).
pub const FIRST_UID: u32 = 20_000;
/// UIDs stay below this bound (65534 is `nobody`).
pub const MAX_UID: u32 = 60_000;
/// Per member: +0 the person, +1 their mux, +2 their ordinary agents, +3 spare.
pub const UID_BLOCK: u32 = 4;
/// Node groups use GID blocks of three (`r`, `w`, `a`) from here.
pub const FIRST_NODE_GID: u32 = 200_000;
/// Upper bound for node GIDs (below the range some tools treat as special).
pub const MAX_NODE_GID: u32 = 2_000_000_000;
/// The `muxes` group: every member's mux user.
pub const MUXES_GID: u32 = 199_999;
/// Linux group and user names longer than this are refused by the shadow tools.
pub const MAX_NAME: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Read,
    Write,
    Admin,
}

impl Role {
    pub fn suffix(self) -> &'static str {
        match self {
            Role::Read => "r",
            Role::Write => "w",
            Role::Admin => "a",
        }
    }

    /// `admin` implies `write` implies `read`.
    pub fn implied(self) -> &'static [Role] {
        match self {
            Role::Read => &[Role::Read],
            Role::Write => &[Role::Read, Role::Write],
            Role::Admin => &[Role::Read, Role::Write, Role::Admin],
        }
    }

    pub const ALL: [Role; 3] = [Role::Read, Role::Write, Role::Admin];
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NodeKind {
    Team,
    Project,
    Person,
}

/// One node of the permission tree. `id` is dotted (`acme`, `acme.web`, `acme.web.checkout`); the
/// parent is the id without its last segment.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Node {
    pub id: String,
    pub kind: NodeKind,
    /// First GID of the node's block: `gid` = r, `gid + 1` = w, `gid + 2` = a. Never reused.
    pub gid: u32,
    /// Person nodes: the member (Linux name) the node belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Grant {
    pub node: String,
    pub role: Role,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Member {
    /// The Linux name `TeamDO` allocated (`vm_accounts`).
    pub name: String,
    /// First UID of the member's block.
    pub uid: u32,
    #[serde(default)]
    pub roles: Vec<Grant>,
    /// Narrower roles for the member's ordinary agents (`<name>-agents`); absent = the member's roles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_roles: Option<Vec<Grant>>,
}

/// One snapshot of `team:<team>/directory`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Directory {
    /// The team node id (first segment of every node id).
    pub team: String,
    /// The directory revision this snapshot reflects (for reports).
    #[serde(default)]
    pub revision: u64,
    pub nodes: Vec<Node>,
    pub members: Vec<Member>,
}

/// Something the reconciler will not do, and why. Reported, never silently skipped.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Refusal {
    pub subject: String,
    pub reason: String,
}

impl Refusal {
    pub fn new(subject: impl Into<String>, reason: impl Into<String>) -> Self {
        Self { subject: subject.into(), reason: reason.into() }
    }
}

/// A directory with every invalid part removed (each removal is a [`Refusal`]).
#[derive(Clone, Debug, Default)]
pub struct Valid {
    pub team: String,
    pub nodes: BTreeMap<String, Node>,
    pub members: BTreeMap<String, Member>,
}

impl Valid {
    pub fn parent(id: &str) -> Option<&str> {
        id.rsplit_once('.').map(|(p, _)| p)
    }

    /// `id` and every node below it, except other people's person nodes (a person node is private:
    /// roles on its ancestors never reach it).
    pub fn subtree(&self, id: &str) -> Vec<&str> {
        let prefix = format!("{id}.");
        self.nodes
            .values()
            .filter(|n| n.id == id || (n.id.starts_with(&prefix) && n.kind != NodeKind::Person))
            .map(|n| n.id.as_str())
            .collect()
    }

    pub fn group(id: &str, role: Role) -> String {
        format!("n-{id}-{}", role.suffix())
    }

    pub fn gid(&self, id: &str, role: Role) -> Option<u32> {
        let off = match role {
            Role::Read => 0,
            Role::Write => 1,
            Role::Admin => 2,
        };
        self.nodes.get(id).map(|n| n.gid + off)
    }

    pub fn person_node_of(&self, member: &str) -> Option<&Node> {
        self.nodes
            .values()
            .find(|n| n.kind == NodeKind::Person && n.person.as_deref() == Some(member))
    }
}

fn segments_valid(id: &str) -> bool {
    id.split('.').all(|s| {
        let b = s.as_bytes();
        !b.is_empty()
            && b.len() <= 31
            && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
            && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
    })
}

/// A member name as `TeamDO` allocates it: a lowercase letter, then letters and digits, at most 24.
pub fn valid_member_name(name: &str) -> bool {
    let b = name.as_bytes();
    !b.is_empty()
        && b.len() <= 24
        && b[0].is_ascii_lowercase()
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
}

/// Checks the snapshot. Invalid nodes (and every node below them), members and grants are dropped
/// with a refusal each; the rest is reconciled.
pub fn validate(d: &Directory) -> (Valid, Vec<Refusal>) {
    let mut refusals = Vec::new();
    let mut v = Valid { team: d.team.clone(), ..Valid::default() };
    if !segments_valid(&d.team) || d.team.contains('.') {
        refusals.push(Refusal::new(format!("team {}", d.team), "invalid team id"));
        return (v, refusals);
    }
    let names: BTreeSet<&str> = d.members.iter().map(|m| m.name.as_str()).collect();
    // Parents before children: sort by depth, then id.
    let mut nodes: Vec<&Node> = d.nodes.iter().collect();
    nodes.sort_by(|a, b| {
        a.id.matches('.').count().cmp(&b.id.matches('.').count()).then(a.id.cmp(&b.id))
    });
    // A GID block named by two nodes is ambiguous: both are refused, never first come, first served.
    let mut uses: BTreeMap<u32, usize> = BTreeMap::new();
    for n in &d.nodes {
        *uses.entry(n.gid).or_default() += 1;
    }
    for n in nodes {
        let subject = format!("node {}", n.id);
        let parent = Valid::parent(&n.id);
        let reason = if !segments_valid(&n.id) || n.id.split('.').next() != Some(d.team.as_str()) {
            Some("invalid node id (dotted lowercase segments under the team)".to_string())
        } else if v.nodes.contains_key(&n.id) {
            Some("duplicate node id".to_string())
        } else if Valid::group(&n.id, Role::Admin).len() > MAX_NAME {
            Some(format!("group name n-{}-a is longer than {MAX_NAME} characters", n.id))
        } else if n.gid < FIRST_NODE_GID
            || n.gid > MAX_NODE_GID - 2
            || !(n.gid - FIRST_NODE_GID).is_multiple_of(3)
        {
            Some(format!("gid {} is not a node block (from {FIRST_NODE_GID}, steps of 3)", n.gid))
        } else if uses.get(&n.gid).copied().unwrap_or(0) > 1 {
            Some(format!("gid block {} is named by more than one node", n.gid))
        } else {
            match (n.kind, parent) {
                (NodeKind::Team, None) if n.id == d.team => None,
                (NodeKind::Team, _) => Some("only the team id is a team node".to_string()),
                (_, None) => Some("a project or person node needs a parent".to_string()),
                (NodeKind::Project, Some(p)) => match v.nodes.get(p).map(|x| x.kind) {
                    Some(NodeKind::Team | NodeKind::Project) => None,
                    _ => Some(format!("parent {p} is missing, refused or a person node")),
                },
                (NodeKind::Person, Some(p)) => {
                    let person = n.person.as_deref().unwrap_or("");
                    if p != d.team {
                        Some("a person node sits directly under the team".to_string())
                    } else if !names.contains(person) {
                        Some(format!("person {person:?} is not a member"))
                    } else if v.person_node_of(person).is_some() {
                        Some(format!("person {person} already has a node"))
                    } else {
                        None
                    }
                }
            }
        };
        match reason {
            Some(r) => refusals.push(Refusal::new(subject, r)),
            None => {
                v.nodes.insert(n.id.clone(), n.clone());
            }
        }
    }
    if !v.nodes.contains_key(&d.team) {
        refusals.push(Refusal::new(
            format!("team {}", d.team),
            "no valid team node; nothing is reconciled",
        ));
        v.nodes.clear();
        return (v, refusals);
    }
    let mut uids: BTreeSet<u32> = BTreeSet::new();
    for m in &d.members {
        let subject = format!("member {}", m.name);
        let reason = if !valid_member_name(&m.name) {
            Some("invalid Linux name".to_string())
        } else if v.members.contains_key(&m.name) {
            Some("duplicate member name".to_string())
        } else if m.uid < FIRST_UID
            || m.uid + UID_BLOCK > MAX_UID
            || !(m.uid - FIRST_UID).is_multiple_of(UID_BLOCK)
        {
            Some(format!(
                "uid {} is not a member block (from {FIRST_UID}, steps of {UID_BLOCK}, below {MAX_UID})",
                m.uid
            ))
        } else if uids.contains(&m.uid) {
            Some(format!("uid block {} is used twice", m.uid))
        } else {
            None
        };
        if let Some(r) = reason {
            refusals.push(Refusal::new(subject, r));
            continue;
        }
        uids.insert(m.uid);
        let mut keep = |grants: &[Grant], what: &str| -> Vec<Grant> {
            let mut out = Vec::new();
            for g in grants {
                match v.nodes.get(&g.node) {
                    None => refusals.push(Refusal::new(
                        format!("member {} {what} {}", m.name, g.node),
                        "unknown or refused node",
                    )),
                    // A person node is private: only its person (added below), never a grant.
                    Some(n) if n.kind == NodeKind::Person => {
                        refusals.push(Refusal::new(
                            format!("member {} {what} {}", m.name, g.node),
                            "person nodes take no grants",
                        ));
                    }
                    Some(_) => out.push(g.clone()),
                }
            }
            out.sort();
            out.dedup();
            out
        };
        let roles = keep(&m.roles, "role on");
        let agent_roles = m.agent_roles.as_ref().map(|a| keep(a, "agent role on"));
        v.members.insert(
            m.name.clone(),
            Member { name: m.name.clone(), uid: m.uid, roles, agent_roles },
        );
    }
    // Person nodes whose member was refused have no owner: drop them too.
    let orphans: Vec<String> = v
        .nodes
        .values()
        .filter(|n| {
            n.kind == NodeKind::Person && !v.members.contains_key(n.person.as_deref().unwrap_or(""))
        })
        .map(|n| n.id.clone())
        .collect();
    for id in orphans {
        v.nodes.remove(&id);
        refusals.push(Refusal::new(format!("node {id}"), "its person was refused"));
    }
    refusals.sort();
    (v, refusals)
}
