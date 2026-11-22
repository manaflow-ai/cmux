use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;

use serde_json::json;

use super::accounts::{
    Accounts, Class, NOLOGIN, UserInfo, View, WantedUser, reconcile, removed_users, verify,
};
use super::{ACCOUNTS_FILE, PRINCIPALS_DIR};
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
fn verify_takes_the_backend_shape_and_refuses_bad_rows_one_by_one() {
    let view: View = serde_json::from_value(json!({
        "team": TEAM,
        "users": [{ "user": "ada", "uid": 20000, "class": "human", "principals": ["ada"] },
                  { "user": "ada-agents", "uid": 20002, "class": "agent", "principals": ["ada-agents"] }]
    }))
    .expect("view");
    let (good, bad) = verify(&view).expect("ok");
    assert_eq!((good.len(), bad.len()), (2, 0));
    let rows = |users: Vec<WantedUser>| verify(&View { team: TEAM.into(), users }).expect("view");
    let mut no_principal = want("pat", 20012, Class::Human);
    no_principal.principals.clear();
    let mut newline = want("quinn", 20016, Class::Human);
    newline.principals = vec!["quinn\nroot".into()];
    let (good, bad) = rows(vec![
        want("ok", 20040, Class::Human),
        want("../etc", 20000, Class::Human),
        want("Root", 20004, Class::Human),
        want("sys", 1000, Class::Human),
        want("zero", 0, Class::Human),
        want("big", 60_000, Class::Human),
        want("twice", 20020, Class::Human),
        want("twice", 20024, Class::Human),
        want("uid1", 20028, Class::Human),
        want("uid2", 20028, Class::Human),
        no_principal,
        newline,
    ]);
    assert_eq!(good.iter().map(|u| u.user.as_str()).collect::<Vec<_>>(), ["ok"]);
    assert_eq!(bad.len(), 11, "{bad:?}");
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

#[test]
fn accounts_it_did_not_make_are_refused_and_get_no_principals() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    host.add_user("daemon", 1, 1, NOLOGIN);
    host.add_user("ops", 20004, 20004, "/bin/bash");
    // Right UID, but its primary group is a shared one (not made by the reconciler).
    host.add_user("mal", 20008, 27, "/bin/bash");
    let wanted = vec![
        want("daemon", 20000, Class::Human),
        want("eve", 20004, Class::Human),
        want("mal", 20008, Class::Human),
    ];
    let out = reconcile(&paths, TEAM, &wanted, &host);
    assert_eq!(out.refused.len(), 3, "{out:?}");
    assert!(out.refused[0].starts_with("daemon: exists with uid 1"), "{out:?}");
    assert!(out.refused[1].starts_with("eve: uid 20004 belongs to ops"), "{out:?}");
    assert!(out.refused[2].starts_with("mal: primary group 27"), "{out:?}");
    assert!(out.created.is_empty() && host.actions.borrow().is_empty());
    for u in ["daemon", "eve", "mal"] {
        assert!(principals(&paths, u).is_none(), "{u}");
    }
}

#[test]
fn a_member_who_left_is_retired_once_and_comes_back_active() {
    let (_d, paths) = setup();
    let host = FakeAccounts::default();
    // The work user's principals file, written by bind, is not the reconciler's.
    fs::create_dir_all(paths.at(PRINCIPALS_DIR)).expect("dir");
    fs::write(paths.at(PRINCIPALS_DIR).join("cmux"), "personal-agents\n").expect("work user");
    let both = [member("ada", 20000), member("bob", 20004)].concat();
    reconcile(&paths, TEAM, &both, &host);
    assert!(removed_users(&paths).is_empty());
    let out = reconcile(&paths, TEAM, &member("bob", 20004), &host);
    assert_eq!(out.removed, vec!["ada", "ada-agents"]);
    assert_eq!(out.retired, vec!["ada", "ada-agents"]);
    assert!(principals(&paths, "ada").is_none() && principals(&paths, "ada-agents").is_none());
    assert_eq!(principals(&paths, "bob").as_deref(), Some("bob\n"));
    assert_eq!(principals(&paths, "cmux").as_deref(), Some("personal-agents\n"));
    let ada = host.users.borrow()["ada"].clone();
    assert_eq!((ada.uid, ada.expired, ada.shell.as_str()), (20000, true, NOLOGIN));
    assert!(host.in_groups("ada").is_empty() && host.in_groups("ada-agents").is_empty());
    assert_eq!(removed_users(&paths).into_iter().collect::<Vec<_>>(), vec!["ada", "ada-agents"]);
    // The next pass changes nothing (retired once).
    let again = reconcile(&paths, TEAM, &member("bob", 20004), &host);
    assert!(!again.changed(), "{again:?}");
    // Added back: the same user, active again, in its groups.
    let back = reconcile(&paths, TEAM, &both, &host);
    assert!(back.created.is_empty(), "{back:?}");
    assert_eq!(back.restored, vec!["ada", "ada-agents"]);
    assert_eq!(back.written, vec!["ada", "ada-agents"]);
    let ada = host.users.borrow()["ada"].clone();
    assert_eq!((ada.expired, ada.shell.as_str()), (false, "/bin/bash"));
    assert_eq!(host.in_groups("ada-agents"), vec!["cmux-agents", "cmux-ssh"]);
    assert!(removed_users(&paths).is_empty());
}

#[test]
fn errors_never_remove_access_and_an_unreadable_or_foreign_list_stops_the_pass() {
    let (_d, paths) = setup();
    let ok = FakeAccounts::default();
    reconcile(&paths, TEAM, &member("ada", 20000), &ok);
    let flaky = FakeAccounts { lookup_fails: true, ..FakeAccounts::default() };
    let out = reconcile(&paths, TEAM, &member("ada", 20000), &flaky);
    assert_eq!(out.errors.len(), 2, "{out:?}");
    assert!(out.removed.is_empty(), "{out:?}");
    assert_eq!(principals(&paths, "ada").as_deref(), Some("ada\n"));
    let broken = FakeAccounts { create_fails: true, ..FakeAccounts::default() };
    let out = reconcile(&paths, TEAM, &member("bob", 20004), &broken);
    assert!(out.created.is_empty() && out.written.is_empty(), "{out:?}");
    assert!(principals(&paths, "bob").is_none());
    // Another team's list: nothing happens.
    let out = reconcile(&paths, "team_other", &[], &ok);
    assert!(out.errors[0].contains("belongs to team_t"), "{out:?}");
    // A corrupt list is never read as empty (that would forget who left).
    fs::write(paths.at(ACCOUNTS_FILE), "{not json").expect("corrupt");
    let out = reconcile(&paths, TEAM, &[], &ok);
    assert!(out.errors[0].contains("accounts state"), "{out:?}");
    assert!(out.removed.is_empty() && out.retired.is_empty());
}

#[test]
fn without_a_baked_group_users_are_still_made_but_the_gap_is_reported() {
    let (_d, paths) = setup();
    let host = FakeAccounts { missing_groups: vec!["cmux-agents"], ..FakeAccounts::default() };
    let out = reconcile(&paths, TEAM, &member("ada", 20000), &host);
    assert_eq!(out.created, vec!["ada", "ada-agents"]);
    assert!(out.errors.iter().any(|e| e.contains("cmux-agents")), "{out:?}");
    assert_eq!(host.created.borrow()[1].3, vec!["cmux-ssh".to_owned()]);
}

#[test]
fn the_managed_list_is_root_only() {
    let (_d, paths) = setup();
    reconcile(&paths, TEAM, &member("ada", 20000), &FakeAccounts::default());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(paths.at(ACCOUNTS_FILE)).expect("state").permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}
