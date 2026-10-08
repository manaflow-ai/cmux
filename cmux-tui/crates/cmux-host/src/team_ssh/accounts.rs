//! The team VM's account reconciler (team-vm-plan.md S4, first part): from
//! the `team_vm.accounts` read (the team's current members, as the VM's own
//! install), it creates each member's Linux users and writes the principals
//! file that `principals` hands to sshd.
//!
//! Rules (each has a test):
//! - A user is created with exactly the UID (and a same-numbered group) the
//!   team allocated, in the sshd login group [`LOGIN_GROUP`], password
//!   locked. A name that exists with another UID, or a UID another user
//!   holds, is refused and reported: the reconciler never takes over an
//!   account it did not create with that UID (a system user the backend's
//!   reserved list missed stays out of reach).
//! - Principals files are rewritten when they differ (drift revert), and
//!   only for users in the view. Files of users the reconciler never managed
//!   (the work user's, written by bind) are left alone.
//! - A managed user that is no longer in the view (a member who left) loses
//!   its principals file. The Linux user, its UID and its files stay (UIDs
//!   are never reused); the reaper ends its open sessions
//!   ([`removed_users`], `sessions::reap`).
//! - A transient lookup or tool error keeps that user's current principals
//!   and is reported; the next pass retries.
//! - Applies hold the trust apply lock, so a sync and a manual apply never
//!   interleave.
//!
//! Not here yet (S4 later parts): node groups, directories and ACLs.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;

use serde::{Deserialize, Serialize};

use super::store::{self, write_atomic};
use super::trust::valid_user;
use super::{ACCOUNTS_FILE, PRINCIPALS_DIR};
use crate::config::Paths;

/// First UID the team allocates (backend `FIRST_UID`).
pub const FIRST_UID: u32 = 20_000;
/// UIDs stay below this (backend `MAX_UID`).
pub const MAX_UID: u32 = 60_000;
/// Upper bound on users in one view (two per UID block of 4).
pub const MAX_USERS: usize = ((MAX_UID - FIRST_UID) / 2) as usize;
/// sshd `AllowGroups`: the image puts the work user in it, the reconciler
/// every team user (web/scripts/cmux-vm-image/sshd.ts).
pub const LOGIN_GROUP: &str = "cmux-ssh";

/// What a user's certificates may do (`agent`: the force-command).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Class {
    Human,
    Agent,
}

impl Class {
    /// The login shell. sshd runs the force-command through it; `sh` reads
    /// no startup file for `-c`, so an agent user's dot files never run.
    pub fn shell(self) -> &'static str {
        match self {
            Class::Human => "/bin/bash",
            Class::Agent => "/bin/sh",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct WantedUser {
    pub user: String,
    pub uid: u32,
    pub class: Class,
    pub principals: Vec<String>,
}

/// The `team_vm.accounts` read value.
#[derive(Clone, Debug, Deserialize)]
pub struct View {
    pub team: String,
    pub users: Vec<WantedUser>,
}

/// Checks a view: valid names and principals, UIDs in the team range, no
/// name or UID twice.
pub fn verify(view: &View) -> Result<Vec<WantedUser>, String> {
    if view.users.len() > MAX_USERS {
        return Err(format!("{} users is more than {MAX_USERS}", view.users.len()));
    }
    let mut names = BTreeSet::new();
    let mut uids = BTreeSet::new();
    for u in &view.users {
        if !valid_user(&u.user) {
            return Err(format!("user {:?} is not a valid Linux user name", u.user));
        }
        if !(FIRST_UID..MAX_UID).contains(&u.uid) {
            return Err(format!(
                "user {}: uid {} is outside {FIRST_UID}..{MAX_UID}",
                u.user, u.uid
            ));
        }
        if u.principals.is_empty() || u.principals.len() > 16 {
            return Err(format!("user {}: 1 to 16 principals", u.user));
        }
        if let Some(p) = u.principals.iter().find(|p| !valid_user(p)) {
            return Err(format!("user {}: principal {p:?} is not valid", u.user));
        }
        if !names.insert(u.user.as_str()) {
            return Err(format!("user {} is listed twice", u.user));
        }
        if !uids.insert(u.uid) {
            return Err(format!("uid {} is listed twice", u.uid));
        }
    }
    Ok(view.users.clone())
}

/// What the reconciler needs from the machine.
pub trait Accounts {
    /// The UID of `user`, `None` when there is no such user.
    fn uid_of(&self, user: &str) -> io::Result<Option<u32>>;
    /// The user that holds `uid`, `None` when it is free.
    fn user_of_uid(&self, uid: u32) -> io::Result<Option<String>>;
    fn group_exists(&self, group: &str) -> io::Result<bool>;
    /// Creates the group `user` with gid = uid, then the user (home, shell
    /// of its class, locked password, supplementary `login_group`).
    fn create(&self, user: &WantedUser, login_group: Option<&str>) -> io::Result<()>;
    fn in_group(&self, user: &str, group: &str) -> io::Result<bool>;
    fn add_to_group(&self, user: &str, group: &str) -> io::Result<()>;
}

/// The users this reconciler created or adopted (name -> UID).
#[derive(Debug, Default, Serialize, Deserialize)]
struct Managed {
    users: BTreeMap<String, u32>,
}

fn load_managed(paths: &Paths) -> Managed {
    fs::read(paths.at(ACCOUNTS_FILE))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// What one pass did.
#[derive(Debug, Default, PartialEq, Eq, Serialize)]
pub struct Reconciled {
    pub created: Vec<String>,
    /// Principals files written (new or put back).
    pub written: Vec<String>,
    /// Principals files removed (members who left).
    pub removed: Vec<String>,
    /// `<user>: <reason>` for users the view names but this machine refuses.
    pub refused: Vec<String>,
    pub errors: Vec<String>,
}

impl Reconciled {
    pub fn changed(&self) -> bool {
        !(self.created.is_empty()
            && self.written.is_empty()
            && self.removed.is_empty()
            && self.refused.is_empty()
            && self.errors.is_empty())
    }
}

enum Outcome {
    Ready,
    Refused(String),
    /// Keep the current principals (a retryable error).
    Keep(String),
}

fn ensure_user(
    w: &WantedUser,
    host: &dyn Accounts,
    login: Option<&str>,
    out: &mut Reconciled,
) -> Outcome {
    match host.uid_of(&w.user) {
        Err(e) => return Outcome::Keep(format!("look up {}: {e}", w.user)),
        Ok(Some(uid)) if uid == w.uid => {}
        Ok(Some(uid)) => return Outcome::Refused(format!("exists with uid {uid}, not {}", w.uid)),
        Ok(None) => match host.user_of_uid(w.uid) {
            Err(e) => return Outcome::Keep(format!("look up uid {}: {e}", w.uid)),
            Ok(Some(other)) => {
                return Outcome::Refused(format!("uid {} belongs to {other}", w.uid));
            }
            Ok(None) => match host.create(w, login) {
                Ok(()) => out.created.push(w.user.clone()),
                Err(e) => return Outcome::Keep(format!("create {}: {e}", w.user)),
            },
        },
    }
    if let Some(group) = login {
        match host.in_group(&w.user, group) {
            Ok(true) => {}
            Ok(false) => {
                if let Err(e) = host.add_to_group(&w.user, group) {
                    out.errors.push(format!("add {} to {group}: {e}", w.user));
                }
            }
            Err(e) => out.errors.push(format!("groups of {}: {e}", w.user)),
        }
    }
    Outcome::Ready
}

/// One pass: create missing users, write principals, remove the principals
/// of managed users the view no longer lists (module docs).
pub fn reconcile(paths: &Paths, wanted: &[WantedUser], host: &dyn Accounts) -> Reconciled {
    let mut out = Reconciled::default();
    let dir = paths.at(PRINCIPALS_DIR);
    if let Err(e) = fs::create_dir_all(&dir) {
        out.errors.push(format!("principals dir: {e}"));
        return out;
    }
    let _lock = match store::lock(paths) {
        Ok(l) => l,
        Err(e) => {
            out.errors.push(format!("apply lock: {e}"));
            return out;
        }
    };
    let mut managed = load_managed(paths);
    let before = managed.users.clone();
    let login = match host.group_exists(LOGIN_GROUP) {
        Ok(true) => Some(LOGIN_GROUP),
        Ok(false) => {
            out.errors.push(format!("group {LOGIN_GROUP} is missing: team users cannot log in"));
            None
        }
        Err(e) => {
            out.errors.push(format!("group {LOGIN_GROUP}: {e}"));
            None
        }
    };
    let mut keep = BTreeSet::new();
    for w in wanted {
        match ensure_user(w, host, login, &mut out) {
            Outcome::Ready => {}
            Outcome::Refused(why) => {
                out.refused.push(format!("{}: {why}", w.user));
                continue;
            }
            Outcome::Keep(e) => {
                out.errors.push(e);
                keep.insert(w.user.clone());
                continue;
            }
        }
        managed.users.insert(w.user.clone(), w.uid);
        keep.insert(w.user.clone());
        let body = w.principals.iter().fold(String::new(), |mut s, p| {
            s.push_str(p);
            s.push('\n');
            s
        });
        let path = dir.join(&w.user);
        if fs::read_to_string(&path).ok().as_deref() != Some(body.as_str()) {
            match write_atomic(&path, body.as_bytes(), 0o644) {
                Ok(()) => out.written.push(w.user.clone()),
                Err(e) => out.errors.push(format!("principals {}: {e}", w.user)),
            }
        }
    }
    for user in managed.users.keys().filter(|u| !keep.contains(*u)) {
        match fs::remove_file(dir.join(user)) {
            Ok(()) => out.removed.push(user.clone()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => out.errors.push(format!("remove principals {user}: {e}")),
        }
    }
    if managed.users != before {
        let saved = serde_json::to_vec(&managed)
            .map_err(io::Error::other)
            .and_then(|json| write_atomic(&paths.at(ACCOUNTS_FILE), &json, 0o600));
        if let Err(e) = saved {
            out.errors.push(format!("accounts state: {e}"));
        }
    }
    out
}

/// Managed users with no principals file: members who left. Their open
/// sessions end on the next reaper pass.
pub fn removed_users(paths: &Paths) -> BTreeSet<String> {
    let dir = paths.at(PRINCIPALS_DIR);
    load_managed(paths).users.into_keys().filter(|u| !dir.join(u).exists()).collect()
}
