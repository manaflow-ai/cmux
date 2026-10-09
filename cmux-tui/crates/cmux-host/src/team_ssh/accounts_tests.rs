use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;

use super::PRINCIPALS_DIR;
use super::accounts::{Accounts, Class, NOLOGIN, UserInfo, WantedUser, reconcile};
use crate::config::Paths;

const TEAM: &str = "team_t";

/// (user, uid, shell, groups) of each `create`.
pub(super) type Created = (String, u32, &'static str, Vec<String>);

/// A fake passwd/shadow/group database.
#[derive(Default)]
pub(super) struct FakeAccounts {
    pub(super) users: RefCell<BTreeMap<String, UserInfo>>,
    /// (user, group) memberships.
    pub(super) members: RefCell<BTreeSet<(String, String)>>,
    pub(super) missing_groups: Vec<&'static str>,
    pub(super) create_fails: bool,
    pub(super) lookup_fails: bool,
    pub(super) created: RefCell<Vec<Created>>,
    /// `retire <user>` and `activate <user>`, in order.
    pub(super) actions: RefCell<Vec<String>>,
}

impl FakeAccounts {
    pub(super) fn add_user(&self, name: &str, uid: u32, gid: u32, shell: &str) {
        self.users
            .borrow_mut()
            .insert(name.into(), UserInfo { uid, gid, shell: shell.into(), expired: false });
    }
    fn in_groups(&self, user: &str) -> Vec<String> {
        self.members.borrow().iter().filter(|(u, _)| u == user).map(|(_, g)| g.clone()).collect()
    }
}

impl Accounts for FakeAccounts {
    fn user(&self, user: &str) -> io::Result<Option<UserInfo>> {
        if self.lookup_fails {
            return Err(io::Error::other("nss down"));
        }
        Ok(self.users.borrow().get(user).cloned())
    }
    fn user_of_uid(&self, uid: u32) -> io::Result<Option<String>> {
        Ok(self.users.borrow().iter().find(|(_, u)| u.uid == uid).map(|(n, _)| n.clone()))
    }
    fn group_exists(&self, group: &str) -> io::Result<bool> {
        Ok(!self.missing_groups.contains(&group))
    }
    fn create(&self, user: &WantedUser, groups: &[&str]) -> io::Result<()> {
        if self.create_fails {
            return Err(io::Error::other("useradd failed"));
        }
        self.add_user(&user.user, user.uid, user.uid, user.class.shell());
        for g in groups {
            self.members.borrow_mut().insert((user.user.clone(), (*g).to_owned()));
        }
        self.created.borrow_mut().push((
            user.user.clone(),
            user.uid,
            user.class.shell(),
            groups.iter().map(|g| (*g).to_owned()).collect(),
        ));
        Ok(())
    }
    fn activate(&self, user: &WantedUser) -> io::Result<()> {
        if let Some(info) = self.users.borrow_mut().get_mut(&user.user) {
            info.expired = false;
            info.shell = user.class.shell().into();
        }
        self.actions.borrow_mut().push(format!("activate {}", user.user));
        Ok(())
    }
    fn in_group(&self, user: &str, group: &str) -> io::Result<bool> {
        Ok(self.members.borrow().contains(&(user.to_owned(), group.to_owned())))
    }
    fn add_to_group(&self, user: &str, group: &str) -> io::Result<()> {
        self.members.borrow_mut().insert((user.to_owned(), group.to_owned()));
        Ok(())
    }
    fn remove_from_group(&self, user: &str, group: &str) -> io::Result<()> {
        self.members.borrow_mut().remove(&(user.to_owned(), group.to_owned()));
        Ok(())
    }
    fn retire(&self, user: &str, _uid: u32) -> io::Result<()> {
        if let Some(info) = self.users.borrow_mut().get_mut(user) {
            info.expired = true;
            info.shell = NOLOGIN.into();
        }
        self.actions.borrow_mut().push(format!("retire {user}"));
        Ok(())
    }
}

fn want(user: &str, uid: u32, class: Class) -> WantedUser {
    WantedUser { user: user.into(), uid, class, principals: vec![user.into()] }
}

fn member(name: &str, uid: u32) -> Vec<WantedUser> {
    vec![want(name, uid, Class::Human), want(&format!("{name}-agents"), uid + 2, Class::Agent)]
}

fn setup() -> (tempfile::TempDir, Paths) {
    let dir = tempfile::tempdir().expect("tempdir");
    let paths = Paths::new(dir.path());
    (dir, paths)
}

fn principals(paths: &Paths, user: &str) -> Option<String> {
    fs::read_to_string(paths.at(PRINCIPALS_DIR).join(user)).ok()
}

#[test]
fn creates_users_with_the_team_uid_shell_and_groups_and_writes_principals() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    let out = reconcile(&paths, TEAM, &member("ada", 20000), &host);
    assert_eq!(out.created, vec!["ada", "ada-agents"]);
    assert_eq!(out.written, vec!["ada", "ada-agents"]);
    assert!(out.errors.is_empty() && out.refused.is_empty(), "{out:?}");
    assert_eq!(
        host.created.borrow().clone(),
        vec![
            ("ada".to_owned(), 20000, "/bin/bash", vec!["cmux-ssh".to_owned()]),
            (
                "ada-agents".to_owned(),
                20002,
                "/bin/sh",
                vec!["cmux-ssh".to_owned(), "cmux-agents".to_owned()]
            ),
        ]
    );
    assert_eq!(principals(&paths, "ada").as_deref(), Some("ada\n"));
    assert_eq!(principals(&paths, "ada-agents").as_deref(), Some("ada-agents\n"));
    let again = reconcile(&paths, TEAM, &member("ada", 20000), &host);
    assert!(!again.changed() && again.refused.is_empty(), "{again:?}");
}

#[test]
fn drift_in_principals_shell_and_groups_is_put_back() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    reconcile(&paths, TEAM, &member("ada", 20000), &host);
    fs::write(paths.at(PRINCIPALS_DIR).join("ada"), "root\n").expect("tamper");
    host.members.borrow_mut().remove(&("ada-agents".to_owned(), "cmux-agents".to_owned()));
    host.users.borrow_mut().get_mut("ada-agents").expect("user").shell = "/bin/bash".into();
    let out = reconcile(&paths, TEAM, &member("ada", 20000), &host);
    assert_eq!(out.written, vec!["ada"]);
    assert_eq!(out.restored, vec!["ada-agents"]);
    assert_eq!(principals(&paths, "ada").as_deref(), Some("ada\n"));
    assert!(host.in_groups("ada-agents").contains(&"cmux-agents".to_owned()));
    assert_eq!(host.users.borrow()["ada-agents"].shell, "/bin/sh");
}
