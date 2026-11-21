//! Review F1 of #40325: two changes at once both survive. A fake platform that enforces
//! `expected_revision` serves two `cmux env` runs; the first is stopped between its read and its
//! write while the second runs to the end, the race the review named.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::daemon::Daemon;
use super::ops::{Failure, Local, execute};
use super::parse;
use super::revision::{CONFLICT, MAX_TRIES};

const ID: &str = "env_000000000000000000000009";

/// The platform's environment and its rules: `revision` goes up with each write, and an update
/// whose `expected_revision` is not the current one writes nothing and answers 409.
struct Platform {
    record: Value,
    /// No `revision` at all: a platform from before #1144.
    revisions: bool,
    updates: Vec<Value>,
    conflicts: usize,
}

impl Platform {
    fn new(revisions: bool) -> Rc<RefCell<Self>> {
        let mut record = json!({"id": ID, "name": "race", "scope": "personal",
            "env_vars": [{"name": "BASE", "value": "1"}], "secrets": [],
            "files": [{"path": "base.txt", "content": "base"}],
            "network": {"mode": "full", "package_managers": true, "domains": []}});
        if revisions {
            record["revision"] = json!(1);
        }
        Rc::new(RefCell::new(Self { record, revisions, updates: Vec::new(), conflicts: 0 }))
    }

    fn call(&mut self, action: &str, params: &Value) -> Result<Value, Failure> {
        match action {
            "list" => Ok(json!([self.record])),
            "get" => Ok(self.record.clone()),
            "update" => {
                let mut patch = params["patch"].clone();
                self.updates.push(patch.clone());
                let expected = patch.as_object_mut().unwrap().remove("expected_revision");
                if self.revisions && expected.as_ref() != Some(&self.record["revision"]) {
                    self.conflicts += 1;
                    return Err(Failure::new(CONFLICT, "Could not save the cloud environment.", 1));
                }
                for (key, value) in patch.as_object().unwrap() {
                    self.record[key] = value.clone();
                }
                if self.revisions {
                    self.record["revision"] = json!(self.record["revision"].as_u64().unwrap() + 1);
                }
                Ok(self.record.clone())
            }
            other => panic!("unexpected action {other}"),
        }
    }
}

/// One `cmux env` run's daemon. With `interleave`, the run's first update waits while that
/// whole other command runs on the same platform: the second write lands between this run's read
/// and its write.
struct Client {
    platform: Rc<RefCell<Platform>>,
    interleave: Option<String>,
}

impl Daemon for Client {
    fn call(&mut self, action: &str, params: &Value) -> Result<Value, Failure> {
        if action == "update"
            && let Some(other) = self.interleave.take()
        {
            run(&other, &self.platform, None).expect("the interleaved run succeeds");
        }
        self.platform.borrow_mut().call(action, params)
    }
}

struct Files(HashMap<PathBuf, String>);

impl Local for Files {
    fn read_file(&self, path: &Path) -> Result<String, Failure> {
        self.0.get(path).cloned().ok_or_else(|| Failure::new("env.file_unreadable", "missing", 1))
    }
    fn current_repo(&self) -> Option<String> {
        None
    }
    fn secret_value(&self, _key: &str) -> Result<Zeroizing<String>, Failure> {
        unreachable!("no secret here")
    }
}

fn run(
    line: &str,
    platform: &Rc<RefCell<Platform>>,
    interleave: Option<&str>,
) -> Result<Value, Failure> {
    let words: Vec<String> = line.split_whitespace().map(str::to_owned).collect();
    let local = Files(HashMap::from([
        (PathBuf::from("a.txt"), "A".to_owned()),
        (PathBuf::from("b.txt"), "B".to_owned()),
    ]));
    let mut client =
        Client { platform: platform.clone(), interleave: interleave.map(str::to_owned) };
    execute(&parse(&words).unwrap(), &mut client, &local)
}

fn names(record: &Value, key: &str, field: &str) -> Vec<String> {
    let mut names: Vec<String> = record[key]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item[field].as_str().unwrap().to_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn two_set_vars_at_once_on_different_keys_both_survive() {
    for round in 0..20 {
        let platform = Platform::new(true);
        let (first, second) = (format!("K{round}A"), format!("K{round}B"));
        run(
            &format!("set-var {ID} {first} one"),
            &platform,
            Some(&format!("set-var {ID} {second} two")),
        )
        .unwrap();
        let platform = platform.borrow();
        assert_eq!(names(&platform.record, "env_vars", "name"), ["BASE", &first, &second]);
        assert_eq!(platform.conflicts, 1, "round {round}: the stale write was refused once");
        assert_eq!(platform.record["revision"], 3);
    }
}

#[test]
fn set_and_unset_var_at_once_both_hold() {
    for _ in 0..10 {
        let platform = Platform::new(true);
        run(&format!("unset-var {ID} BASE"), &platform, Some(&format!("set-var {ID} NEW v")))
            .unwrap();
        assert_eq!(names(&platform.borrow().record, "env_vars", "name"), ["NEW"]);
    }
}

#[test]
fn two_files_added_at_once_both_survive_and_a_removal_holds() {
    for _ in 0..10 {
        let platform = Platform::new(true);
        run(
            &format!("add-file {ID} one.txt --from a.txt"),
            &platform,
            Some(&format!("add-file {ID} two.txt --from b.txt")),
        )
        .unwrap();
        assert_eq!(
            names(&platform.borrow().record, "files", "path"),
            ["base.txt", "one.txt", "two.txt"]
        );
        run(
            &format!("rm-file {ID} base.txt"),
            &platform,
            Some(&format!("add-file {ID} three.txt --from a.txt")),
        )
        .unwrap();
        assert_eq!(
            names(&platform.borrow().record, "files", "path"),
            ["one.txt", "three.txt", "two.txt"]
        );
    }
}

#[test]
fn an_edit_of_the_network_keeps_a_concurrent_variable() {
    let platform = Platform::new(true);
    run(&format!("edit {ID} --network off"), &platform, Some(&format!("set-var {ID} X y")))
        .unwrap();
    let platform = platform.borrow();
    assert_eq!(platform.record["network"]["mode"], "off");
    assert_eq!(names(&platform.record, "env_vars", "name"), ["BASE", "X"]);
}

#[test]
fn every_update_names_the_revision_it_read() {
    let platform = Platform::new(true);
    for line in [
        format!("set-var {ID} A b"),
        format!("unset-var {ID} A"),
        format!("add-file {ID} x.txt --from a.txt"),
        format!("rm-file {ID} x.txt"),
        format!("edit {ID} --image default"),
    ] {
        run(&line, &platform, None).unwrap();
    }
    let platform = platform.borrow();
    assert_eq!(platform.updates.len(), 5);
    for (index, update) in platform.updates.iter().enumerate() {
        assert_eq!(update["expected_revision"], index as u64 + 1, "{update}");
    }
}

#[test]
fn a_platform_that_keeps_changing_fails_after_the_cap_with_nothing_saved() {
    let platform = Platform::new(true);
    // Every read answers a revision the write then misses: a writer that never stops.
    struct Busy(Rc<RefCell<Platform>>);
    impl Daemon for Busy {
        fn call(&mut self, action: &str, params: &Value) -> Result<Value, Failure> {
            let mut platform = self.0.borrow_mut();
            if action == "update" {
                let next = platform.record["revision"].as_u64().unwrap() + 1;
                platform.record["revision"] = json!(next);
            }
            platform.call(action, params)
        }
    }
    let words: Vec<String> =
        format!("set-var {ID} K v").split_whitespace().map(str::to_owned).collect();
    let failure =
        execute(&parse(&words).unwrap(), &mut Busy(platform.clone()), &Files(HashMap::new()))
            .unwrap_err();
    assert_eq!(failure.code, CONFLICT);
    assert!(failure.message.contains("nothing was saved"), "{}", failure.message);
    let platform = platform.borrow();
    assert_eq!(platform.updates.len(), MAX_TRIES);
    assert_eq!(names(&platform.record, "env_vars", "name"), ["BASE"]);
}

#[test]
fn a_platform_without_revisions_gets_the_change_without_a_precondition() {
    let platform = Platform::new(false);
    run(&format!("set-var {ID} K v"), &platform, None).unwrap();
    let platform = platform.borrow();
    assert_eq!(platform.updates.len(), 1);
    assert!(platform.updates[0].get("expected_revision").is_none(), "{}", platform.updates[0]);
    assert_eq!(names(&platform.record, "env_vars", "name"), ["BASE", "K"]);
}
