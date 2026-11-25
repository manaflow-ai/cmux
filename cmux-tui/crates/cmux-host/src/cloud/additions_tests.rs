//! The additions list under the opt-in setting (`additions.rs`, `additions_thread.rs`).

use std::cell::Cell;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::Path;

use serde_json::{Value, json};

use super::additions::{
    Gate, IMAGE_PACKAGES_FILE, Outcome, SENT_FILE, additions, collect, dpkg_names, list_hash,
    report_idle, usage_sharing, valid_line,
};
use super::additions_thread::{collect_once, names};
use super::client::{MemoryStore, Store};
use super::sender::Answer;
use crate::config::Paths;

const HOME: &str = "/home/cmux";

fn reply(value: Value) -> Answer {
    Answer::Http { status: 200, body: json!({"ok": true, "value": value}) }
}

fn report(sessions: u64) -> Value {
    json!({"machine": "m", "state": "running", "activity": {"active_sessions": sessions}})
}

fn stored() -> Answer {
    Answer::Http { status: 200, body: json!({"stored": 1, "added": 1, "removed": 0}) }
}

#[test]
fn the_reply_carries_the_choice_and_a_missing_field_is_off() {
    assert_eq!(usage_sharing(&reply(json!({"applied": true, "usage_sharing": true}))), Some(true));
    assert_eq!(
        usage_sharing(&reply(json!({"applied": true, "usage_sharing": false}))),
        Some(false)
    );
    assert_eq!(usage_sharing(&reply(json!({"applied": true}))), Some(false));
    assert_eq!(usage_sharing(&reply(json!({"usage_sharing": "yes"}))), Some(false));
    let top = Answer::Http { status: 200, body: json!({"ok": true, "usage_sharing": true}) };
    assert_eq!(usage_sharing(&top), Some(true));
    // An unanswered report says nothing: the last value stands.
    assert_eq!(usage_sharing(&Answer::Transport), None);
    let refused = Answer::Http { status: 429, body: json!({"usage_sharing": true}) };
    assert_eq!(usage_sharing(&refused), None);
}

#[test]
fn idle_is_no_session_and_no_acpmux_turn() {
    assert!(report_idle(&report(0)));
    assert!(!report_idle(&report(1)));
    let turn = json!({"activity": {"active_sessions": 0, "phases": {"turns": [{"phase": "x"}]}}});
    assert!(!report_idle(&turn));
    assert!(!report_idle(&json!({})));
}

#[test]
fn on_and_idle_collects_once_at_the_edge() {
    let mut gate = Gate::default();
    let on = reply(json!({"applied": true, "usage_sharing": true}));
    assert!(!gate.report_answered(&report(1), &on), "busy: no collection");
    assert!(gate.report_answered(&report(0), &on), "the edge into idle collects");
    assert!(!gate.report_answered(&report(0), &on), "a heartbeat while idle is no edge");
    assert!(!gate.report_answered(&report(0), &Answer::Transport));
    assert!(!gate.report_answered(&report(2), &on));
    assert!(gate.report_answered(&report(0), &on), "the next edge collects again");
}

#[test]
fn off_or_absent_never_collects() {
    for value in [json!({"applied": true}), json!({"applied": true, "usage_sharing": false})] {
        let mut gate = Gate::default();
        for sessions in [0, 1, 0, 3, 0] {
            assert!(!gate.report_answered(&report(sessions), &reply(value.clone())));
        }
        assert!(!gate.sharing());
    }
    // Before any answer the choice is off.
    let mut gate = Gate::default();
    assert!(!gate.report_answered(&report(0), &Answer::Transport));
    assert!(!gate.sharing());
}

#[test]
fn off_end_to_end_never_lists_and_never_sends() {
    let (listed, sent) = (Cell::new(0), Cell::new(0));
    let mut gate = Gate::default();
    let off = reply(json!({"applied": true}));
    for sessions in [1, 0, 1, 0] {
        if gate.report_answered(&report(sessions), &off) {
            collect(
                Some(""),
                || {
                    listed.set(listed.get() + 1);
                    vec![]
                },
                None,
                |_| {
                    sent.set(sent.get() + 1);
                    stored()
                },
            );
        }
    }
    assert_eq!((listed.get(), sent.get()), (0, 0));
}

#[test]
fn a_name_is_kind_space_name_from_the_routes_alphabet() {
    assert!(valid_line("apt jq"));
    assert!(valid_line("npm @scope/pkg"));
    assert!(valid_line("cargo ripgrep"));
    assert!(!valid_line("bin node"), "not a kind the route takes");
    assert!(!valid_line("apt "));
    assert!(!valid_line("apt a b"));
    assert!(!valid_line("npm ../x"));
    assert!(!valid_line(&format!("apt {}", "a".repeat(215))));
}

#[test]
fn additions_drop_the_baseline_sort_and_dedupe() {
    let now = ["apt jq", "apt git", "npm @a/b", "apt jq", "cargo rg", "bin x"].map(String::from);
    let names = additions(now, "apt git\nnpm npm\n");
    assert_eq!(names, ["apt jq", "cargo rg", "npm @a/b"]);
}

#[test]
fn dpkg_names_skip_packages_not_installed() {
    let status = "Package: jq\nStatus: install ok installed\n\nPackage: gone\nStatus: deinstall ok not-installed\n\nPackage: conf\nStatus: deinstall ok config-files\n";
    assert_eq!(dpkg_names(status), ["apt jq", "apt conf"]);
}

#[test]
fn no_baseline_lists_nothing_and_sends_nothing() {
    let listed = Cell::new(false);
    let out = collect(
        None,
        || {
            listed.set(true);
            vec!["apt jq".into()]
        },
        None,
        |_| panic!("sent with no baseline"),
    );
    assert_eq!(out, Outcome::NoBaseline);
    assert!(!listed.get());
}

#[test]
fn an_unchanged_list_is_not_resent_and_a_changed_one_is() {
    let list = || vec!["apt jq".to_owned()];
    let body = std::cell::RefCell::new(None);
    let first = collect(Some(""), list, None, |b| {
        *body.borrow_mut() = Some(b.clone());
        stored()
    });
    let Outcome::Stored { hash, names: 1 } = first else { panic!("{first:?}") };
    let sent = body.borrow().clone().expect("sent");
    assert_eq!(sent["names"], json!(["apt jq"]));
    assert_eq!(sent["batch"], json!(&hash[..24]));
    assert_eq!(hash, list_hash(&["apt jq".to_owned()]));
    assert_eq!(collect(Some(""), list, Some(&hash), |_| panic!("resent")), Outcome::Unchanged);
    let changed = collect(
        Some(""),
        || vec!["apt jq".into(), "apt ripgrep".into()],
        Some(&hash),
        |_| stored(),
    );
    assert!(matches!(changed, Outcome::Stored { names: 2, .. }));
}

#[test]
fn not_shared_and_failures_keep_nothing() {
    let refused =
        Answer::Http { status: 403, body: json!({"error": {"code": "install_counts.not_shared"}}) };
    assert_eq!(collect(Some(""), Vec::new, None, |_| refused), Outcome::NotShared);
    assert!(matches!(collect(Some(""), Vec::new, None, |_| Answer::Transport), Outcome::Failed(_)));
}

fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel.trim_start_matches('/'));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn dir(root: &Path, rel: &str) {
    fs::create_dir_all(root.join(rel.trim_start_matches('/'))).unwrap();
}

/// A machine laid out as the image lays it out, read from disk only.
#[test]
fn names_read_every_kind_from_disk() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    write(root, "/var/lib/dpkg/status", "Package: jq\nStatus: install ok installed\n");
    write(root, "/opt/cmux/store/abc/lib/node_modules/npm/bin/npm-cli.js", "");
    dir(root, "/opt/cmux/store/abc/lib/node_modules/@scope/pkg");
    dir(root, "/opt/cmux/store/abc/lib/node_modules/.bin");
    dir(root, "/opt/cmux/current/bin");
    symlink(
        root.join("opt/cmux/store/abc/lib/node_modules/npm/bin/npm-cli.js"),
        root.join("opt/cmux/current/bin/npm"),
    )
    .unwrap();
    dir(root, "/home/cmux/.bun/install/global/node_modules/cowsay");
    dir(root, "/home/cmux/.local/share/uv/tools/ruff");
    dir(root, "/home/cmux/.local/pipx/venvs/black");
    write(root, "/home/cmux/.cargo/bin/rg", "");
    let paths = Paths::new(root);
    let mut got = names(&paths, HOME);
    got.sort();
    assert_eq!(
        got,
        ["apt jq", "bun cowsay", "cargo rg", "npm @scope/pkg", "npm npm", "pipx black", "uv ruff"]
    );
}

#[test]
fn a_symlinked_folder_under_the_home_is_not_followed() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    dir(root, "/elsewhere/secret");
    dir(root, "/home/cmux/.cargo");
    symlink(root.join("elsewhere"), root.join("home/cmux/.cargo/bin")).unwrap();
    assert!(names(&Paths::new(root), HOME).is_empty());
}

#[test]
fn collect_once_posts_once_and_keeps_the_hash_across_a_restart() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    write(
        root,
        "/var/lib/dpkg/status",
        "Package: git\nStatus: install ok installed\n\nPackage: jq\nStatus: install ok installed\n",
    );
    let paths = Paths::new(root);
    let mut store = MemoryStore::default();
    // No baseline yet: nothing sent.
    let out = collect_once(&paths, HOME, &mut store, |_| panic!("sent with no baseline"));
    assert_eq!(out, Outcome::NoBaseline);
    write(root, IMAGE_PACKAGES_FILE, "apt git\n");
    let posts = Cell::new(0);
    let post = |body: &Value| {
        assert_eq!(body["names"], json!(["apt jq"]));
        posts.set(posts.get() + 1);
        stored()
    };
    assert!(matches!(collect_once(&paths, HOME, &mut store, post), Outcome::Stored { .. }));
    assert!(store.read(SENT_FILE).is_some());
    // The hash is in the store (the state dir): a restart's first idle sends nothing.
    assert_eq!(collect_once(&paths, HOME, &mut store, post), Outcome::Unchanged);
    assert_eq!(posts.get(), 1);
}
