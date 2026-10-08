use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::io;

use serde_json::json;

use super::accounts::{Accounts, Class, View, WantedUser, reconcile, removed_users, verify};
use super::{ACCOUNTS_FILE, PRINCIPALS_DIR};
use crate::config::Paths;

/// (user, uid, shell, login group) of each `create`.
pub(super) type Created = (String, u32, &'static str, Option<String>);

/// A fake passwd/group database.
#[derive(Default)]
pub(super) struct FakeAccounts {
    pub(super) users: RefCell<BTreeMap<String, u32>>,
    pub(super) login_members: RefCell<Vec<String>>,
    pub(super) no_login_group: bool,
    pub(super) create_fails: bool,
    pub(super) lookup_fails: bool,
    pub(super) created: RefCell<Vec<Created>>,
}

impl Accounts for FakeAccounts {
    fn uid_of(&self, user: &str) -> io::Result<Option<u32>> {
        if self.lookup_fails {
            return Err(io::Error::other("nss down"));
        }
        Ok(self.users.borrow().get(user).copied())
    }
    fn user_of_uid(&self, uid: u32) -> io::Result<Option<String>> {
        Ok(self.users.borrow().iter().find(|(_, u)| **u == uid).map(|(n, _)| n.clone()))
    }
    fn group_exists(&self, _group: &str) -> io::Result<bool> {
        Ok(!self.no_login_group)
    }
    fn create(&self, user: &WantedUser, login_group: Option<&str>) -> io::Result<()> {
        if self.create_fails {
            return Err(io::Error::other("useradd failed"));
        }
        self.users.borrow_mut().insert(user.user.clone(), user.uid);
        if let Some(g) = login_group {
            self.login_members.borrow_mut().push(user.user.clone());
            let _ = g;
        }
        self.created.borrow_mut().push((
            user.user.clone(),
            user.uid,
            user.class.shell(),
            login_group.map(str::to_owned),
        ));
        Ok(())
    }
    fn in_group(&self, user: &str, _group: &str) -> io::Result<bool> {
        Ok(self.login_members.borrow().iter().any(|u| u == user))
    }
    fn add_to_group(&self, user: &str, _group: &str) -> io::Result<()> {
        self.login_members.borrow_mut().push(user.to_owned());
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
fn verify_takes_the_backend_shape_and_refuses_bad_names_uids_and_duplicates() {
    let view: View = serde_json::from_value(json!({
        "team": "team_t",
        "users": [{ "user": "ada", "uid": 20000, "class": "human", "principals": ["ada"] },
                  { "user": "ada-agents", "uid": 20002, "class": "agent", "principals": ["ada-agents"] }]
    }))
    .expect("view");
    assert_eq!(verify(&view).expect("ok").len(), 2);
    let bad = |users: Vec<WantedUser>| verify(&View { team: "team_t".into(), users });
    assert!(bad(vec![want("../etc", 20000, Class::Human)]).is_err(), "path name");
    assert!(bad(vec![want("Root", 20000, Class::Human)]).is_err(), "upper case");
    assert!(bad(vec![want("ada", 1000, Class::Human)]).is_err(), "system uid");
    assert!(bad(vec![want("ada", 0, Class::Human)]).is_err(), "root uid");
    assert!(bad(vec![want("ada", 60_000, Class::Human)]).is_err(), "uid past the range");
    assert!(bad(vec![want("ada", 20000, Class::Human), want("ada", 20004, Class::Human)]).is_err());
    assert!(bad(vec![want("ada", 20000, Class::Human), want("bob", 20000, Class::Human)]).is_err());
    let mut no_principal = want("ada", 20000, Class::Human);
    no_principal.principals.clear();
    assert!(bad(vec![no_principal]).is_err());
    let mut odd = want("ada", 20000, Class::Human);
    odd.principals = vec!["ada\nroot".into()];
    assert!(bad(vec![odd]).is_err(), "a principal with a newline");
}

#[test]
fn creates_users_with_the_team_uid_shell_and_login_group_and_writes_principals() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    let out = reconcile(&paths, &member("ada", 20000), &host);
    assert_eq!(out.created, vec!["ada", "ada-agents"]);
    assert_eq!(out.written, vec!["ada", "ada-agents"]);
    assert!(out.errors.is_empty() && out.refused.is_empty(), "{out:?}");
    assert_eq!(
        host.created.borrow().clone(),
        vec![
            ("ada".to_owned(), 20000, "/bin/bash", Some("cmux-ssh".to_owned())),
            ("ada-agents".to_owned(), 20002, "/bin/sh", Some("cmux-ssh".to_owned())),
        ]
    );
    assert_eq!(principals(&paths, "ada").as_deref(), Some("ada\n"));
    assert_eq!(principals(&paths, "ada-agents").as_deref(), Some("ada-agents\n"));
    // Second pass: nothing to do.
    let again = reconcile(&paths, &member("ada", 20000), &host);
    assert!(!again.changed(), "{again:?}");
}

#[test]
fn drift_is_reverted_and_a_dropped_login_group_membership_is_put_back() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    reconcile(&paths, &member("ada", 20000), &host);
    fs::write(paths.at(PRINCIPALS_DIR).join("ada"), "root\n").expect("tamper");
    host.login_members.borrow_mut().retain(|u| u != "ada-agents");
    let out = reconcile(&paths, &member("ada", 20000), &host);
    assert_eq!(out.written, vec!["ada"]);
    assert_eq!(principals(&paths, "ada").as_deref(), Some("ada\n"));
    assert!(host.login_members.borrow().iter().any(|u| u == "ada-agents"));
}

#[test]
fn an_existing_name_with_another_uid_or_a_held_uid_is_refused_and_gets_no_principals() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    host.users.borrow_mut().insert("daemon".into(), 1);
    host.users.borrow_mut().insert("ops".into(), 20004);
    let wanted = vec![want("daemon", 20000, Class::Human), want("eve", 20004, Class::Human)];
    let out = reconcile(&paths, &wanted, &host);
    assert_eq!(out.refused.len(), 2, "{out:?}");
    assert!(out.refused[0].starts_with("daemon: exists with uid 1"), "{out:?}");
    assert!(out.refused[1].starts_with("eve: uid 20004 belongs to ops"), "{out:?}");
    assert!(out.created.is_empty());
    assert!(principals(&paths, "daemon").is_none() && principals(&paths, "eve").is_none());
}

#[test]
fn a_member_who_left_loses_principals_but_keeps_the_user_and_others_are_untouched() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    // The work user's principals file, written by bind, is not the reconciler's.
    fs::create_dir_all(paths.at(PRINCIPALS_DIR)).expect("dir");
    fs::write(paths.at(PRINCIPALS_DIR).join("cmux"), "personal-agents\n").expect("work user");
    let both = [member("ada", 20000), member("bob", 20004)].concat();
    reconcile(&paths, &both, &host);
    assert!(removed_users(&paths).is_empty());
    let out = reconcile(&paths, &member("bob", 20004), &host);
    assert_eq!(out.removed, vec!["ada", "ada-agents"]);
    assert!(principals(&paths, "ada").is_none() && principals(&paths, "ada-agents").is_none());
    assert_eq!(principals(&paths, "bob").as_deref(), Some("bob\n"));
    assert_eq!(principals(&paths, "cmux").as_deref(), Some("personal-agents\n"));
    assert_eq!(host.users.borrow().get("ada"), Some(&20000), "the Linux user stays");
    assert_eq!(removed_users(&paths).into_iter().collect::<Vec<_>>(), vec!["ada", "ada-agents"]);
    // Removing again is a no-op; adding the member back reuses the same user.
    assert!(reconcile(&paths, &member("bob", 20004), &host).removed.is_empty());
    let back = reconcile(&paths, &both, &host);
    assert!(back.created.is_empty(), "{back:?}");
    assert_eq!(back.written, vec!["ada", "ada-agents"]);
    assert!(removed_users(&paths).is_empty());
}

#[test]
fn a_lookup_or_create_error_keeps_current_principals_and_is_reported() {
    let (_d, paths) = setup();
    let ok = FakeAccounts::default();
    reconcile(&paths, &member("ada", 20000), &ok);
    let flaky = FakeAccounts { lookup_fails: true, ..FakeAccounts::default() };
    let out = reconcile(&paths, &member("ada", 20000), &flaky);
    assert_eq!(out.errors.len(), 2, "{out:?}");
    assert!(out.removed.is_empty(), "an error never removes access: {out:?}");
    assert_eq!(principals(&paths, "ada").as_deref(), Some("ada\n"));
    let broken = FakeAccounts { create_fails: true, ..FakeAccounts::default() };
    let out = reconcile(&paths, &member("bob", 20004), &broken);
    assert!(out.created.is_empty() && out.written.is_empty(), "{out:?}");
    assert!(principals(&paths, "bob").is_none());
}

#[test]
fn without_the_login_group_users_are_still_made_but_the_gap_is_reported() {
    let (_d, paths) = setup();
    let host = FakeAccounts { no_login_group: true, ..FakeAccounts::default() };
    let out = reconcile(&paths, &member("ada", 20000), &host);
    assert_eq!(out.created, vec!["ada", "ada-agents"]);
    assert!(out.errors.iter().any(|e| e.contains("cmux-ssh")), "{out:?}");
    assert_eq!(host.created.borrow()[0].3, None);
}

#[test]
fn the_managed_list_is_root_only() {
    let (_d, paths) = setup();
    reconcile(&paths, &member("ada", 20000), &FakeAccounts::default());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(paths.at(ACCOUNTS_FILE)).expect("state").permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
