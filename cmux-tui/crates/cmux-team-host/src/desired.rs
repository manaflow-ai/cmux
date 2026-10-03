//! Compiles a validated directory into the Linux state the team VM must have (spec team-vm.md,
//! "Permission hierarchy"): users, groups with the membership closure, node directories with
//! setgid and an access ACL equal to the default ACL, and the mailbox modes. Pure.

use crate::acl::{Acl, AclEntry, Perm};
use crate::directory::{Grant, MUXES_GID, NodeKind, Role, Valid};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// Where the team tree and the homes live (`/srv/team` and `/home` on the VM; temp dirs in tests).
#[derive(Clone, Debug)]
pub struct Layout {
    pub root: PathBuf,
    pub homes: PathBuf,
}

impl Default for Layout {
    fn default() -> Self {
        Self { root: PathBuf::from("/srv/team"), homes: PathBuf::from("/home") }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DesiredUser {
    pub name: String,
    pub uid: u32,
    /// The user's private group (same name, GID = UID).
    pub gid: u32,
    pub home: PathBuf,
    pub shell: String,
    /// Supplementary groups.
    pub groups: BTreeSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DesiredDir {
    pub path: PathBuf,
    pub uid: u32,
    pub gid: u32,
    /// Including setgid (0o2000) and sticky (0o1000).
    pub mode: u32,
    /// `Some`: this access ACL and the same default ACL. `None`: no extended ACL at all.
    pub acl: Option<Acl>,
}

#[derive(Clone, Debug, Default)]
pub struct Desired {
    pub users: BTreeMap<String, DesiredUser>,
    /// Group name -> GID.
    pub groups: BTreeMap<String, u32>,
    /// Parents before children.
    pub dirs: Vec<DesiredDir>,
}

pub const MUXES: &str = "muxes";
pub const SHELL: &str = "/bin/bash";

/// The three Linux users of a member: the person, their mux, their ordinary agents (D27).
pub fn member_users(name: &str, uid: u32) -> [(String, u32); 3] {
    [(name.to_string(), uid), (format!("{name}-mux"), uid + 1), (format!("{name}-agents"), uid + 2)]
}

/// Groups for `grants` with the closure: role R on node N joins the R group (and every implied
/// role's group) of N and of every descendant of N that is not a person node.
pub fn closure(v: &Valid, grants: &[Grant]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for g in grants {
        for id in v.subtree(&g.node) {
            for r in g.role.implied() {
                out.insert(Valid::group(id, *r));
            }
        }
    }
    out
}

/// The node directory of `id`: `t/<team>/p/<a>/p/<b>…` for the team and projects,
/// `memory/people/<person>` for a person node.
pub fn node_path(v: &Valid, layout: &Layout, id: &str) -> PathBuf {
    let node = &v.nodes[id];
    if node.kind == NodeKind::Person {
        return layout.root.join("memory/people").join(node.person.as_deref().unwrap_or(""));
    }
    let mut p = layout.root.join("t").join(&v.team);
    for seg in id.split('.').skip(1) {
        p = p.join("p").join(seg);
    }
    p
}

/// `u::rwx, g::rwx, g:<r>:r-x, g:<w>:rwx, g:<a>:rwx, m::rwx, o::---` (group entries for the node's three groups).
fn node_acl(r: u32, w: u32, a: u32, read: Perm) -> Acl {
    Acl::new(vec![
        AclEntry::user_obj(Perm::RWX),
        AclEntry::group_obj(Perm::RWX),
        AclEntry::group(r, read),
        AclEntry::group(w, Perm::RWX),
        AclEntry::group(a, Perm::RWX),
        AclEntry::mask(Perm::RWX),
        AclEntry::other(Perm::NONE),
    ])
}

fn plain(path: PathBuf, mode: u32) -> DesiredDir {
    DesiredDir { path, uid: 0, gid: 0, mode, acl: None }
}

pub fn compile(v: &Valid, layout: &Layout) -> Desired {
    let mut d = Desired::default();
    if v.nodes.is_empty() {
        return d;
    }
    // Groups: every node's three, `muxes`, and each user's private group.
    for id in v.nodes.keys() {
        for r in Role::ALL {
            d.groups.insert(Valid::group(id, r), v.gid(id, r).unwrap_or_default());
        }
    }
    d.groups.insert(MUXES.to_string(), MUXES_GID);
    for m in v.members.values() {
        // A person's own node: the person, their mux and their ordinary agents (D30), nobody else.
        let own: Vec<Grant> = v.person_node_of(&m.name).map(|n| Grant { node: n.id.clone(), role: Role::Admin }).into_iter().collect();
        let mut human = closure(v, &m.roles);
        human.extend(closure(v, &own));
        let mut mux = human.clone();
        mux.insert(MUXES.to_string());
        let mut agents = closure(v, m.agent_roles.as_deref().unwrap_or(&m.roles));
        agents.extend(closure(v, &own));
        for ((name, uid), groups) in member_users(&m.name, m.uid).into_iter().zip([human, mux, agents]) {
            d.groups.insert(name.clone(), uid);
            let home = layout.homes.join(&name);
            d.users.insert(name.clone(), DesiredUser { name, uid, gid: uid, home, shell: SHELL.to_string(), groups });
        }
    }
    // Directories, parents first. Plain directories are root-owned and traversable only.
    let root = &layout.root;
    d.dirs.push(plain(root.clone(), 0o711));
    d.dirs.push(plain(root.join("t"), 0o711));
    d.dirs.push(plain(root.join("memory"), 0o711));
    d.dirs.push(plain(root.join("memory/people"), 0o711));
    let team = v.team.as_str();
    let (tr, tw, ta) = (v.gid(team, Role::Read).unwrap_or_default(), v.gid(team, Role::Write).unwrap_or_default(), v.gid(team, Role::Admin).unwrap_or_default());
    // Org memory: every member reads and writes (D29); the control is the audit trail.
    d.dirs.push(DesiredDir { path: root.join("memory/org"), uid: 0, gid: tr, mode: 0o2770, acl: Some(node_acl(tr, tw, ta, Perm::RWX)) });
    // Node directories: the team and projects (depth order), then person nodes.
    let mut ids: Vec<&str> = v.nodes.keys().map(String::as_str).collect();
    ids.sort_by(|a, b| a.matches('.').count().cmp(&b.matches('.').count()).then(a.cmp(b)));
    for id in ids {
        let node = &v.nodes[id];
        let path = node_path(v, layout, id);
        let (r, w, a) = (node.gid, node.gid + 1, node.gid + 2);
        let owner = match node.kind {
            NodeKind::Person => v.members.get(node.person.as_deref().unwrap_or("")).map_or(0, |m| m.uid),
            _ => 0,
        };
        if node.kind == NodeKind::Project {
            // `p/` between a node and its sub-projects: traversable, created only here.
            d.dirs.push(plain(path.parent().map(Path::to_path_buf).unwrap_or_default(), 0o711));
        }
        d.dirs.push(DesiredDir { path, uid: owner, gid: w, mode: 0o2770, acl: Some(node_acl(r, w, a, Perm::RX)) });
    }
    // Mailbox: inbox/<name> 1733 (others drop files, cannot list or read), inbox/all 1775 for the team.
    d.dirs.push(plain(root.join("mailbox"), 0o755));
    d.dirs.push(plain(root.join("mailbox/inbox"), 0o755));
    d.dirs.push(DesiredDir { path: root.join("mailbox/inbox/all"), uid: 0, gid: tr, mode: 0o1775, acl: None });
    for m in v.members.values() {
        d.dirs.push(DesiredDir { path: root.join("mailbox/inbox").join(&m.name), uid: m.uid, gid: m.uid, mode: 0o1733, acl: None });
    }
    // Homes: private to the user.
    d.dirs.push(DesiredDir { path: layout.homes.clone(), uid: 0, gid: 0, mode: 0o755, acl: None });
    for u in d.users.values() {
        d.dirs.push(DesiredDir { path: u.home.clone(), uid: u.uid, gid: u.gid, mode: 0o700, acl: None });
    }
    dedup_dirs(&mut d.dirs);
    d
}

/// A `p/` directory appears once per sibling project; keep the first.
fn dedup_dirs(dirs: &mut Vec<DesiredDir>) {
    let mut seen = BTreeSet::new();
    dirs.retain(|x| seen.insert(x.path.clone()));
}
