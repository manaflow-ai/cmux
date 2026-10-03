//! The difference between the desired and the observed state, as ordered actions plus refusals.
//! Pure. Applying the plan and planning again gives an empty plan (idempotent); drift (a manual
//! `useradd`, a changed mode or ACL, an extra group membership) shows up as actions that revert it.

use crate::acl::Acl;
use crate::desired::{Desired, DesiredDir};
use crate::directory::{FIRST_NODE_GID, FIRST_UID, MAX_NODE_GID, MAX_UID, MUXES_GID, Refusal};
use crate::observed::Observed;
use std::collections::BTreeSet;
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    DeleteUser {
        name: String,
    },
    DeleteGroup {
        name: String,
    },
    CreateGroup {
        name: String,
        gid: u32,
    },
    CreateUser {
        name: String,
        uid: u32,
        gid: u32,
        home: PathBuf,
        shell: String,
    },
    FixUser {
        name: String,
        gid: u32,
        home: PathBuf,
        shell: String,
    },
    SetGroups {
        name: String,
        groups: Vec<String>,
    },
    Mkdir {
        path: PathBuf,
    },
    Chown {
        path: PathBuf,
        uid: u32,
        gid: u32,
    },
    Chmod {
        path: PathBuf,
        mode: u32,
    },
    /// The access ACL and the same default ACL.
    SetAcl {
        path: PathBuf,
        acl: Acl,
    },
    ClearAcl {
        path: PathBuf,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    pub actions: Vec<Action>,
    pub refusals: Vec<Refusal>,
}

/// UIDs the reconciler owns: member blocks. Users there that the directory does not name are drift.
pub fn managed_uid(uid: u32) -> bool {
    (FIRST_UID..MAX_UID).contains(&uid)
}

/// GIDs the reconciler owns: private groups of member users, `muxes`, node groups.
pub fn managed_gid(gid: u32) -> bool {
    managed_uid(gid) || gid == MUXES_GID || (FIRST_NODE_GID..=MAX_NODE_GID).contains(&gid)
}

pub fn plan(d: &Desired, o: &Observed) -> Plan {
    let mut p = Plan::default();
    let mut blocked_users: BTreeSet<String> = BTreeSet::new();
    let mut blocked_gids: BTreeSet<u32> = BTreeSet::new();
    let mut deletes = Vec::new();
    let mut creates = Vec::new();
    let mut fixes = Vec::new();

    // Users first: a name taken by a system account is refused (contract with TeamDO: a member
    // never logs in as an account the reserved list missed), and so is UID drift on a member name.
    for (name, u) in &d.users {
        if let Some(e) = o.users.get(name) {
            if e.uid < FIRST_UID {
                p.refusals.push(Refusal::new(
                    format!("user {name}"),
                    format!("a system account (uid {}) has this name; not touched", e.uid),
                ));
                blocked_users.insert(name.clone());
            } else if e.uid != u.uid {
                p.refusals.push(Refusal::new(format!("user {name}"), format!("exists with uid {} instead of {}; files would change owner, repair by hand", e.uid, u.uid)));
                blocked_users.insert(name.clone());
            }
        }
    }
    for name in &blocked_users {
        blocked_gids.insert(d.users[name].uid);
    }
    for (name, gid) in &d.groups {
        if blocked_users.contains(name) {
            continue;
        }
        match o.groups.get(name) {
            Some(g) if g.gid == *gid => {}
            Some(g) => {
                p.refusals.push(Refusal::new(
                    format!("group {name}"),
                    format!("exists with gid {} instead of {gid}; not changed", g.gid),
                ));
                blocked_gids.insert(*gid);
            }
            None => creates.push(Action::CreateGroup { name: name.clone(), gid: *gid }),
        }
    }
    // A member user whose private group is refused cannot be created either.
    for (name, u) in &d.users {
        if !blocked_users.contains(name) && blocked_gids.contains(&u.gid) {
            p.refusals.push(Refusal::new(format!("user {name}"), "its private group is refused"));
            blocked_users.insert(name.clone());
        }
    }

    // Drift in the managed ranges that the directory does not name is removed (files are kept).
    for e in o.users.values() {
        if managed_uid(e.uid) && !d.users.contains_key(&e.name) {
            deletes.push(Action::DeleteUser { name: e.name.clone() });
        }
    }
    for g in o.groups.values() {
        if managed_gid(g.gid) && !d.groups.contains_key(&g.name) {
            deletes.push(Action::DeleteGroup { name: g.name.clone() });
        }
    }

    let mut memberships = Vec::new();
    for (name, u) in &d.users {
        if blocked_users.contains(name) {
            continue;
        }
        let home = u.home.to_string_lossy().into_owned();
        match o.users.get(name) {
            None => creates.push(Action::CreateUser {
                name: name.clone(),
                uid: u.uid,
                gid: u.gid,
                home: u.home.clone(),
                shell: u.shell.clone(),
            }),
            Some(e) if e.gid != u.gid || e.home != home || e.shell != u.shell => {
                fixes.push(Action::FixUser {
                    name: name.clone(),
                    gid: u.gid,
                    home: u.home.clone(),
                    shell: u.shell.clone(),
                });
            }
            Some(_) => {}
        }
        let want: BTreeSet<String> = u
            .groups
            .iter()
            .filter(|g| !d.groups.get(*g).is_some_and(|gid| blocked_gids.contains(gid)))
            .cloned()
            .collect();
        let have = if o.users.contains_key(name) { o.supplementary(name) } else { BTreeSet::new() };
        if want != have {
            memberships
                .push(Action::SetGroups { name: name.clone(), groups: want.into_iter().collect() });
        }
    }

    p.actions.extend(deletes);
    p.actions.extend(creates);
    p.actions.extend(fixes);
    p.actions.extend(memberships);

    let blocked_uids: BTreeSet<u32> = blocked_users.iter().map(|n| d.users[n].uid).collect();
    let mut blocked_paths: Vec<PathBuf> = Vec::new();
    for dir in &d.dirs {
        if blocked_paths.iter().any(|b| dir.path.starts_with(b)) {
            continue;
        }
        if blocked_uids.contains(&dir.uid)
            || blocked_gids.contains(&dir.gid)
            || acl_gids(dir).iter().any(|g| blocked_gids.contains(g))
        {
            p.refusals.push(Refusal::new(
                format!("directory {}", dir.path.display()),
                "names a refused user or group; not touched",
            ));
            blocked_paths.push(dir.path.clone());
            continue;
        }
        match o.dirs.get(&dir.path).cloned().flatten() {
            None => {
                p.actions.push(Action::Mkdir { path: dir.path.clone() });
                p.actions.push(Action::Chown {
                    path: dir.path.clone(),
                    uid: dir.uid,
                    gid: dir.gid,
                });
                if dir.acl.is_none() {
                    // A new directory inherits its parent's default ACL; a plain one must not keep it.
                    p.actions.push(Action::ClearAcl { path: dir.path.clone() });
                }
                p.actions.push(Action::Chmod { path: dir.path.clone(), mode: dir.mode });
                if let Some(acl) = &dir.acl {
                    p.actions.push(Action::SetAcl { path: dir.path.clone(), acl: acl.clone() });
                }
            }
            Some(s) if !s.is_dir => {
                p.refusals.push(Refusal::new(
                    format!("directory {}", dir.path.display()),
                    "exists and is not a directory (or is a symlink); not touched",
                ));
                blocked_paths.push(dir.path.clone());
            }
            Some(s) => {
                if s.uid != dir.uid || s.gid != dir.gid {
                    p.actions.push(Action::Chown {
                        path: dir.path.clone(),
                        uid: dir.uid,
                        gid: dir.gid,
                    });
                }
                let acl_wrong = match &dir.acl {
                    Some(a) => s.acl.access != *a || s.acl.default != *a,
                    None => !s.acl.access.is_minimal() || !s.acl.default.0.is_empty(),
                };
                if dir.acl.is_none() && acl_wrong {
                    p.actions.push(Action::ClearAcl { path: dir.path.clone() });
                }
                if s.mode != dir.mode || (dir.acl.is_none() && acl_wrong) {
                    p.actions.push(Action::Chmod { path: dir.path.clone(), mode: dir.mode });
                }
                if let (Some(a), true) = (&dir.acl, acl_wrong) {
                    p.actions.push(Action::SetAcl { path: dir.path.clone(), acl: a.clone() });
                }
            }
        }
    }
    p.refusals.sort();
    p.refusals.dedup();
    p
}

fn acl_gids(dir: &DesiredDir) -> Vec<u32> {
    use crate::acl::Tag;
    dir.acl.as_ref().map_or_else(Vec::new, |a| {
        a.0.iter().filter_map(|e| if let Tag::Group(g) = e.tag { Some(g) } else { None }).collect()
    })
}
