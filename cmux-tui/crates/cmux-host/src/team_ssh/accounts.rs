//! The team VM's account reconciler (team-vm-plan.md S4, first part): from
//! the `team_vm.accounts` read (the team's current members, as the VM's own
//! install), it creates each member's Linux users and writes the principals
//! file that `principals` hands to sshd.
//!
//! Rules (each has a test):
//! - A user is created with exactly the UID (and a same-numbered group) the
//!   team allocated, in the sshd login group [`LOGIN_GROUP`] (agent users
//!   also in [`AGENTS_GROUP`], whose sshd `Match` forces the restricted
//!   shell whatever the certificate says), password locked. A name that
//!   exists with another UID, a UID another user holds, or an existing user
//!   whose primary group is not its UID is refused and reported: the
//!   reconciler never takes over an account it did not create.
//! - A user's shell, expiry and groups are put back when they drift.
//! - Principals files are rewritten when they differ (drift revert), and
//!   only for users in the view. Files of users the reconciler never managed
//!   (the work user's, written by bind) are left alone.
//! - A managed user that is no longer in the view (a member who left) loses
//!   its principals file and is retired: its logind sessions and user
//!   manager end, lingering goes off, the account expires with shell
//!   `nologin`, and it leaves the login groups. The Linux user, its UID and
//!   its files stay (UIDs are never reused); a member added back gets the
//!   same user, active again. The reaper also ends its recorded sessions
//!   ([`removed_users`], `sessions::reap`).
//! - One bad row in the view is refused and reported; the other rows (and
//!   removals) still apply.
//! - A transient lookup or tool error keeps that user's current principals
//!   and is reported; the next pass retries. An unreadable managed list, or
//!   one recorded for another team, stops the pass (no removal, no write).
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
/// sshd `Match Group`: agent users get the restricted shell even from a
/// certificate without the force-command (web/scripts/cmux-vm-image/sshd.ts).
pub const AGENTS_GROUP: &str = "cmux-agents";
/// The shell of a retired user.
pub const NOLOGIN: &str = "/usr/sbin/nologin";

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

    /// The groups a user of this class belongs to.
    pub fn groups(self) -> &'static [&'static str] {
        match self {
            Class::Human => &[LOGIN_GROUP],
            Class::Agent => &[LOGIN_GROUP, AGENTS_GROUP],
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

fn row_problem(u: &WantedUser) -> Option<String> {
    if !valid_user(&u.user) {
        return Some("not a valid Linux user name".into());
    }
    if !(FIRST_UID..MAX_UID).contains(&u.uid) {
        return Some(format!("uid {} is outside {FIRST_UID}..{MAX_UID}", u.uid));
    }
    if u.principals.is_empty() || u.principals.len() > 16 {
        return Some("1 to 16 principals".into());
    }
    u.principals.iter().find(|p| !valid_user(p)).map(|p| format!("principal {p:?} is not valid"))
}

/// Checks a view row by row: valid names and principals, UIDs in the team
/// range, no name or UID twice (every row of a duplicate is refused).
/// Returns the good rows and `<user>: <reason>` for each refused one; only
/// an oversized view is refused whole.
pub fn verify(view: &View) -> Result<(Vec<WantedUser>, Vec<String>), String> {
    if view.users.len() > MAX_USERS {
        return Err(format!("{} users is more than {MAX_USERS}", view.users.len()));
    }
    let mut names: BTreeMap<&str, usize> = BTreeMap::new();
    let mut uids: BTreeMap<u32, usize> = BTreeMap::new();
    for u in &view.users {
        *names.entry(u.user.as_str()).or_default() += 1;
        *uids.entry(u.uid).or_default() += 1;
    }
    let (mut good, mut refused) = (Vec::new(), Vec::new());
    for u in &view.users {
        let problem = row_problem(u).or_else(|| {
            (names[u.user.as_str()] > 1 || uids[&u.uid] > 1)
                .then(|| format!("name or uid {} is listed twice", u.uid))
        });
        match problem {
            Some(why) => refused.push(format!("{:?}: {why}", u.user)),
            None => good.push(u.clone()),
        }
    }
    Ok((good, refused))
}

/// A passwd and shadow entry, as far as the reconciler checks it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserInfo {
    pub uid: u32,
    pub gid: u32,
    pub shell: String,
    /// The shadow expiry date has passed (a retired user).
    pub expired: bool,
}

/// What the reconciler needs from the machine.
pub trait Accounts {
    /// `user`'s entry, `None` when there is no such user.
    fn user(&self, user: &str) -> io::Result<Option<UserInfo>>;
    /// The user that holds `uid`, `None` when it is free.
    fn user_of_uid(&self, uid: u32) -> io::Result<Option<String>>;
    fn group_exists(&self, group: &str) -> io::Result<bool>;
    /// Creates the group `user` with gid = uid, then the user (home, shell
    /// of its class, locked password, supplementary `groups`).
    fn create(&self, user: &WantedUser, groups: &[&str]) -> io::Result<()>;
    /// Makes a retired or drifted user usable again: no expiry, the shell
    /// of its class.
    fn activate(&self, user: &WantedUser) -> io::Result<()>;
    fn in_group(&self, user: &str, group: &str) -> io::Result<bool>;
    fn add_to_group(&self, user: &str, group: &str) -> io::Result<()>;
    fn remove_from_group(&self, user: &str, group: &str) -> io::Result<()>;
    /// Ends the user's logind sessions and user manager, turns lingering
    /// off, expires the account and sets its shell to [`NOLOGIN`].
    fn retire(&self, user: &str, uid: u32) -> io::Result<()>;
}

/// The users this reconciler created or adopted (name -> UID), and the team
/// they belong to.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Managed {
    #[serde(default)]
    team: String,
    users: BTreeMap<String, u32>,
}

/// The managed list; absent is empty, unreadable is an error (never an
/// empty list, which would forget members who left).
fn load_managed(paths: &Paths) -> Result<Managed, String> {
    match fs::read(paths.at(ACCOUNTS_FILE)) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("accounts state: {e}")),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Managed::default()),
        Err(e) => Err(format!("accounts state: {e}")),
    }
}

/// What one pass did.
#[derive(Debug, Default, PartialEq, Eq, Serialize)]
pub struct Reconciled {
    pub created: Vec<String>,
    /// Principals files written (new or put back).
    pub written: Vec<String>,
    /// Users whose shell, expiry or groups were put back.
    pub restored: Vec<String>,
    /// Principals files removed (members who left).
    pub removed: Vec<String>,
    /// Members who left whose account this pass retired.
    pub retired: Vec<String>,
    /// `<user>: <reason>` for users the view names but this machine refuses.
    pub refused: Vec<String>,
    pub errors: Vec<String>,
}

impl Reconciled {
    /// Anything worth a log line besides refusals (they repeat every pass).
    pub fn changed(&self) -> bool {
        !(self.created.is_empty()
            && self.written.is_empty()
            && self.restored.is_empty()
            && self.removed.is_empty()
            && self.retired.is_empty()
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
    groups: &[&str],
    out: &mut Reconciled,
) -> Outcome {
    match host.user(&w.user) {
        Err(e) => return Outcome::Keep(format!("look up {}: {e}", w.user)),
        Ok(Some(info)) if info.uid == w.uid => {
            if info.gid != w.uid {
                return Outcome::Refused(format!("primary group {} is not {}", info.gid, w.uid));
            }
            if info.expired || info.shell != w.class.shell() {
                match host.activate(w) {
                    Ok(()) => out.restored.push(w.user.clone()),
                    Err(e) => return Outcome::Keep(format!("activate {}: {e}", w.user)),
                }
            }
        }
        Ok(Some(info)) => {
            return Outcome::Refused(format!("exists with uid {}, not {}", info.uid, w.uid));
        }
        Ok(None) => match host.user_of_uid(w.uid) {
            Err(e) => return Outcome::Keep(format!("look up uid {}: {e}", w.uid)),
            Ok(Some(other)) => {
                return Outcome::Refused(format!("uid {} belongs to {other}", w.uid));
            }
            Ok(None) => match host.create(w, groups) {
                Ok(()) => out.created.push(w.user.clone()),
                Err(e) => return Outcome::Keep(format!("create {}: {e}", w.user)),
            },
        },
    }
    for group in groups {
        match host.in_group(&w.user, group) {
            Ok(true) => {}
            Ok(false) => match host.add_to_group(&w.user, group) {
                Ok(()) if !out.restored.contains(&w.user) && !out.created.contains(&w.user) => {
                    out.restored.push(w.user.clone());
                }
                Ok(()) => {}
                Err(e) => out.errors.push(format!("add {} to {group}: {e}", w.user)),
            },
            Err(e) => out.errors.push(format!("groups of {}: {e}", w.user)),
        }
    }
    Outcome::Ready
}

/// Retires a managed user that left (once: an expired account with the
/// nologin shell is left alone).
fn retire_left(user: &str, uid: u32, host: &dyn Accounts, out: &mut Reconciled) {
    match host.user(user) {
        Ok(Some(info)) if info.uid == uid && !(info.expired && info.shell == NOLOGIN) => {
            match host.retire(user, uid) {
                Ok(()) => out.retired.push(user.to_owned()),
                Err(e) => out.errors.push(format!("retire {user}: {e}")),
            }
        }
        Ok(_) => {}
        Err(e) => out.errors.push(format!("look up {user}: {e}")),
    }
    for group in [LOGIN_GROUP, AGENTS_GROUP] {
        match host.in_group(user, group) {
            Ok(true) => {
                if let Err(e) = host.remove_from_group(user, group) {
                    out.errors.push(format!("remove {user} from {group}: {e}"));
                }
            }
            Ok(false) => {}
            Err(e) => out.errors.push(format!("groups of {user}: {e}")),
        }
    }
}

/// One pass for `team`: create missing users, write principals, retire the
/// managed users the view no longer lists (module docs).
pub fn reconcile(
    paths: &Paths,
    team: &str,
    wanted: &[WantedUser],
    host: &dyn Accounts,
) -> Reconciled {
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
    let mut managed = match load_managed(paths) {
        Ok(m) if m.team.is_empty() || m.team == team => m,
        Ok(m) => {
            out.errors.push(format!("accounts state belongs to {}, not {team}", m.team));
            return out;
        }
        Err(e) => {
            out.errors.push(e);
            return out;
        }
    };
    let before = (managed.team.clone(), managed.users.clone());
    managed.team = team.to_owned();
    let mut missing = Vec::new();
    for group in [LOGIN_GROUP, AGENTS_GROUP] {
        match host.group_exists(group) {
            Ok(true) => {}
            Ok(false) => {
                missing.push(group);
                out.errors.push(format!("group {group} is missing (the image bakes it)"));
            }
            Err(e) => {
                missing.push(group);
                out.errors.push(format!("group {group}: {e}"));
            }
        }
    }
    let mut keep = BTreeSet::new();
    for w in wanted {
        let groups: Vec<&str> =
            w.class.groups().iter().copied().filter(|g| !missing.contains(g)).collect();
        match ensure_user(w, host, &groups, &mut out) {
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
    for (user, uid) in managed.users.iter().filter(|(u, _)| !keep.contains(*u)) {
        match fs::remove_file(dir.join(user)) {
            Ok(()) => out.removed.push(user.clone()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => out.errors.push(format!("remove principals {user}: {e}")),
        }
        retire_left(user, *uid, host, &mut out);
    }
    if (managed.team.clone(), managed.users.clone()) != before {
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
/// sessions end on the next reaper pass. Empty when the list is unreadable.
pub fn removed_users(paths: &Paths) -> BTreeSet<String> {
    let dir = paths.at(PRINCIPALS_DIR);
    load_managed(paths)
        .map(|m| m.users.into_keys().filter(|u| !dir.join(u).exists()).collect())
        .unwrap_or_default()
}
