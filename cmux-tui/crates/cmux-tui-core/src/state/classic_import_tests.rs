//! The move from classic cmux on the daemon (`classic-import-v1`): a
//! launch's plan of classic's fixture session, the ledger steps the app
//! records, a replayed step, a relaunch that makes nothing, a manual run
//! that brings back only what was closed, first contact while cmux NEXT was
//! already in use, and a newer build's ledger left alone.

use std::path::{Path, PathBuf};

use serde_json::json;

use super::classic_import_router::{Places, Record, places_for_test};
use super::tests::{error_code, read, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use cmux_classic_import::plan::Mode;

const BUNDLE: &str = "com.cmuxterm.app";

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl Home {
    fn places(&self) -> Places {
        places_for_test(&self.0)
    }

    fn session(&self) -> PathBuf {
        self.0.join("Library/Application Support/cmux/session-com.cmuxterm.app.json")
    }

    fn ledger(&self) -> PathBuf {
        self.0.join(
            "Library/Application Support/cmux-next/com.cmuxterm.app/classic-migration/ledger.json",
        )
    }

    fn ledger_json(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.ledger()).unwrap()).unwrap()
    }
}

/// A home whose classic stable saved the fixture session (two windows, two
/// groups, a duplicate key and a Cloud VM workspace).
fn home(with_session: bool) -> Home {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let suffix = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    let dir = std::env::temp_dir().join(format!("cmux-classic-import-{suffix}"));
    std::fs::create_dir_all(&dir).unwrap();
    let home = Home(dir.canonicalize().unwrap());
    if with_session {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/fixtures/classic-to-next/session-groups.json");
        std::fs::create_dir_all(home.session().parent().unwrap()).unwrap();
        std::fs::copy(fixture, home.session()).unwrap();
    }
    home
}

fn plan(mux: &Arc<Mux>, home: &Home, mode: Mode) -> Value {
    mux.classic_import_plan(Some(&home.places()), BUNDLE, mode, false).unwrap()
}

fn record(mux: &Arc<Mux>, home: &Home, fields: Value, key: &str) -> Value {
    let mut fields = fields;
    fields["bundle_id"] = json!(BUNDLE);
    let record = Record::parse(fields.as_object().unwrap()).unwrap();
    let mutation = WorkspaceMutation::new(
        key.to_string(),
        "resource-api",
        crate::workspace_registry::Actor::Daemon,
    )
    .unwrap();
    let commit = mux.classic_import_record(Some(&home.places()), &mutation, &record).unwrap();
    json!({"value": commit.result, "replayed": commit.replayed})
}

fn keys(plan: &Value) -> Vec<String> {
    plan["plan"]["windows"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|window| window["workspaces"].as_array().unwrap().iter())
        .map(|workspace| workspace["key"].as_str().unwrap().to_string())
        .collect()
}

/// Runs a whole confirmed run the way the app does, each workspace made as `next-<n>`.
/// The `begin` step the app sends for `plan`.
fn begin(plan: &Value) -> Value {
    let cloud_vms: Vec<Value> = plan["plan"]["skipped"]
        .as_object()
        .unwrap()
        .iter()
        .filter(|(_, skip)| *skip == "cloud_vm")
        .map(|(key, _)| json!(key))
        .collect();
    json!({"event": "begin", "source": plan["source"], "backups": plan["backups"],
           "cloud_vm_keys": cloud_vms, "app_version": "1.2.3"})
}

fn run(mux: &Arc<Mux>, home: &Home, plan: &Value, prefix: &str) {
    record(mux, home, begin(plan), &format!("{prefix}-begin"));
    for (index, key) in keys(plan).iter().enumerate() {
        let made = format!("next-{index}");
        record(
            mux,
            home,
            json!({"event": "workspace", "key": key, "stage": "pending"}),
            &format!("{prefix}-p{index}"),
        );
        record(
            mux,
            home,
            json!({"event": "workspace", "key": key, "stage": "done", "next_workspace": made}),
            &format!("{prefix}-d{index}"),
        );
    }
    record(mux, home, json!({"event": "finish"}), &format!("{prefix}-finish"));
}

#[test]
fn classic_import_plan_without_a_classic_session_has_no_plan() {
    let mux = Mux::new_for_test("classic-import-none", SurfaceOptions::default());
    let home = home(false);
    let result = plan(&mux, &home, Mode::Automatic);
    assert_eq!(result["ledger"], "none");
    assert_eq!(result["decision"], json!({"decision": "skip", "reason": "no_classic_session"}));
    assert_eq!(result["plan"], Value::Null);
    // Over the wire, under the daemon's own HOME: a bundle id and a mode, never a path.
    let wire = read(&mux, "classic_import.plan", json!({"bundle_id": BUNDLE, "mode": "manual"}));
    assert!(wire["ledger"].is_string(), "{wire}");
    let bad = send(
        &mux,
        "classic_import.plan",
        json!({"bundle_id": "../../etc", "mode": "manual"}),
        None,
    );
    assert_eq!(error_code(bad), "validation.invalid");
}

#[test]
fn a_first_launch_plans_records_and_a_relaunch_makes_nothing() {
    let mux = Mux::new_for_test("classic-import-flow", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Automatic);
    assert_eq!(first["decision"], json!({"decision": "first_run"}));
    assert_eq!(keys(&first).len(), 4, "{first}");
    assert_eq!(first["preview"]["skipped_cloud_vms"], 1);
    assert_eq!(first["source"]["bundleID"], BUNDLE);
    assert_eq!(first["backups"][0], home.session().to_string_lossy().as_ref());

    run(&mux, &home, &first, "first");
    let ledger = home.ledger_json();
    assert_eq!(ledger["state"], "completed");
    assert_eq!(ledger["runs"], 1);
    assert_eq!(ledger["appVersion"], "1.2.3");
    assert_eq!(ledger["workspaces"]["AAAAAAAA-0000-4000-8000-000000000004"]["stage"], "skipped");
    assert_eq!(
        ledger["workspaces"]["AAAAAAAA-0000-4000-8000-000000000001"]["nextWorkspace"],
        "next-0"
    );
    // The classic file is backed up, byte for byte, and never changed.
    let backups = home.ledger().parent().unwrap().join("backups");
    let folder = std::fs::read_dir(&backups).unwrap().next().unwrap().unwrap().path();
    assert_eq!(
        std::fs::read(folder.join("session-com.cmuxterm.app.json")).unwrap(),
        std::fs::read(home.session()).unwrap()
    );

    // The same step's key replays its first result and changes nothing.
    let before = std::fs::read(home.ledger()).unwrap();
    let replay = record(&mux, &home, begin(&first), "first-begin");
    assert_eq!(replay["replayed"], true);
    assert_eq!(std::fs::read(home.ledger()).unwrap(), before);

    // A relaunch on the same save makes nothing.
    let relaunch = plan(&mux, &home, Mode::Automatic);
    assert_eq!(relaunch["decision"], json!({"decision": "skip", "reason": "unchanged"}));
    assert_eq!(relaunch["plan"], Value::Null);

    // Import from Classic brings back the ones closed here (none of next-<n> is open).
    let manual = plan(&mux, &home, Mode::Manual);
    assert_eq!(manual["decision"], Value::Null);
    assert_eq!(keys(&manual).len(), 4);
}

#[test]
fn first_contact_while_cmux_next_was_in_use_records_classic_as_seen() {
    let mux = Mux::new_for_test("classic-import-baseline", SurfaceOptions::default());
    let home = home(true);
    let reply = record(&mux, &home, json!({"event": "baseline"}), "baseline");
    assert_eq!(reply["value"]["state"], "completed");
    assert_eq!(reply["value"]["workspaces"], 5);
    assert_eq!(
        home.ledger_json()["workspaces"]["AAAAAAAA-0000-4000-8000-000000000001"]["reason"],
        "baseline"
    );
    assert_eq!(
        plan(&mux, &home, Mode::Automatic)["decision"],
        json!({"decision": "skip", "reason": "unchanged"})
    );
    // A second first contact (a later launch) changes nothing.
    let before = std::fs::read(home.ledger()).unwrap();
    record(&mux, &home, json!({"event": "seen"}), "seen");
    assert_eq!(std::fs::read(home.ledger()).unwrap(), before);
}

#[test]
fn a_newer_ledger_is_left_alone_and_only_classics_files_are_backed_up() {
    let mux = Mux::new_for_test("classic-import-newer", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Manual);
    let stray = home.0.join("secret.json");
    std::fs::write(&stray, "{}").unwrap();
    let mut fields = json!({"bundle_id": BUNDLE, "event": "begin", "source": first["source"], "backups": [stray]});
    let parsed = Record::parse(fields.as_object().unwrap()).unwrap();
    let mutation =
        WorkspaceMutation::new("stray", "resource-api", crate::workspace_registry::Actor::Daemon)
            .unwrap();
    assert!(mux.classic_import_record(Some(&home.places()), &mutation, &parsed).is_err());
    assert!(!home.ledger().exists());

    std::fs::create_dir_all(home.ledger().parent().unwrap()).unwrap();
    let newer = r#"{"schema":9,"future":true}"#;
    std::fs::write(home.ledger(), newer).unwrap();
    assert_eq!(
        plan(&mux, &home, Mode::Automatic)["decision"],
        json!({"decision": "skip", "reason": "ledger_not_usable"})
    );
    let manual = plan(&mux, &home, Mode::Manual);
    assert_eq!(
        (manual["plan"].clone(), manual["error"].clone()),
        (Value::Null, json!("ledger from a newer cmux"))
    );
    fields["backups"] = first["backups"].clone();
    let parsed = Record::parse(fields.as_object().unwrap()).unwrap();
    let mutation = WorkspaceMutation::new(
        "over-newer",
        "resource-api",
        crate::workspace_registry::Actor::Daemon,
    )
    .unwrap();
    assert!(mux.classic_import_record(Some(&home.places()), &mutation, &parsed).is_err());
    assert_eq!(std::fs::read_to_string(home.ledger()).unwrap(), newer);
}

#[test]
fn classic_import_record_checks_its_fields() {
    let mux = Mux::new_for_test("classic-import-fields", SurfaceOptions::default());
    for (params, key) in [
        (json!({"bundle_id": BUNDLE, "event": "later"}), "bad-event"),
        (json!({"bundle_id": BUNDLE, "event": "begin"}), "begin-without-source"),
        (
            json!({"bundle_id": BUNDLE, "event": "workspace", "key": "k", "stage": "done"}),
            "done-without-next",
        ),
        (
            json!({"bundle_id": BUNDLE, "event": "group", "classic_group": "g"}),
            "group-without-next",
        ),
    ] {
        assert_eq!(
            error_code(send(&mux, "classic_import.record", params, Some(key))),
            "validation.invalid",
            "{key}"
        );
    }
}

/// A run cut off midway finishes from the save it started with: classic
/// closing a workspace (and saving again) before the relaunch does not
/// drop it from the resumed run.
#[test]
fn a_resumed_run_plans_from_the_save_it_started_with() {
    let mux = Mux::new_for_test("classic-import-resume", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Automatic);
    let started = keys(&first);
    record(&mux, &home, begin(&first), "cut-begin");
    let done = json!({"event": "workspace", "key": started[0], "stage": "done", "next_workspace": "next-0"});
    record(&mux, &home, done, "cut-d0");

    // Classic saves again without the last workspace.
    let mut later: Value = serde_json::from_slice(&std::fs::read(home.session()).unwrap()).unwrap();
    later["createdAt"] = json!(1_791_800_000.0);
    later["windows"][1]["tabManager"]["workspaces"].as_array_mut().unwrap().pop();
    std::fs::write(home.session(), serde_json::to_vec(&later).unwrap()).unwrap();

    let resumed = plan(&mux, &home, Mode::Automatic);
    assert_eq!(resumed["decision"], json!({"decision": "resume"}), "{resumed}");
    assert_eq!(resumed["source"], first["source"]);
    assert_eq!(resumed["backups"], json!([]));
    assert!(keys(&resumed).contains(started.last().unwrap()), "{resumed}");
    assert!(!keys(&resumed).contains(&started[0]));

    // With the file and its copies gone, the newest save is read instead.
    std::fs::remove_dir_all(home.ledger().parent().unwrap().join("backups")).unwrap();
    let fallback = plan(&mux, &home, Mode::Automatic);
    assert!(!keys(&fallback).contains(started.last().unwrap()), "{fallback}");
}

/// A replayed `begin` makes no second backup, so it never rotates out the
/// copy the in-progress run started from, even after classic saved again
/// and with retention full.
#[test]
fn a_replayed_begin_after_later_saves_keeps_the_backup_the_run_needs() {
    let mux = Mux::new_for_test("classic-import-replay-backup", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Automatic);
    let original = std::fs::read(home.session()).unwrap();
    record(&mux, &home, begin(&first), "once-begin");
    let backups = home.ledger().parent().unwrap().join("backups");
    let kept = |backups: &Path| -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(backups)
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    };
    let ours = kept(&backups);
    assert_eq!(ours.len(), 1, "{ours:?}");
    // Four later runs' backups fill retention (they sort after ours).
    for index in 0..4 {
        std::fs::create_dir_all(backups.join(format!("29990101T00000{index}Z-later"))).unwrap();
    }
    for save in 0..3 {
        std::fs::write(
            home.session(),
            format!("{{\"version\":1,\"createdAt\":{save},\"windows\":[]}}"),
        )
        .unwrap();
        let replay = record(&mux, &home, begin(&first), "once-begin");
        assert_eq!(replay["replayed"], true);
    }
    let after = kept(&backups);
    assert_eq!(after.len(), 5, "{after:?}");
    assert!(after.contains(&ours[0]), "{after:?}");
    assert_eq!(
        std::fs::read(backups.join(&ours[0]).join("session-com.cmuxterm.app.json")).unwrap(),
        original
    );
}

/// The daemon's origin gate keeps agents and pages off both operations:
/// they read classic's session and write the app's ledger and backups.
#[test]
fn only_the_verified_app_runs_the_move_from_classic() {
    use crate::request_origin::{RequestOrigin, require_origin};
    for operation in ["classic_import.plan", "classic_import.record"] {
        for origin in [RequestOrigin::Page, RequestOrigin::Agent, RequestOrigin::App] {
            assert!(require_origin(operation, origin).is_err(), "{operation} {origin:?}");
        }
        assert!(require_origin(operation, RequestOrigin::User).is_ok());
    }
}

/// `begin` copies only the exact session files a run reads: a link named
/// like classic's session is refused.
#[cfg(unix)]
#[test]
fn begin_refuses_a_link_in_place_of_classics_session() {
    let mux = Mux::new_for_test("classic-import-link", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Automatic);
    let secret = home.0.join("secret.json");
    std::fs::write(&secret, "{}").unwrap();
    std::fs::remove_file(home.session()).unwrap();
    std::os::unix::fs::symlink(&secret, home.session()).unwrap();
    let mut fields = begin(&first);
    fields["bundle_id"] = json!(BUNDLE);
    let record = Record::parse(fields.as_object().unwrap()).unwrap();
    let mutation = WorkspaceMutation::new(
        "link-begin".to_string(),
        "resource-api",
        crate::workspace_registry::Actor::Daemon,
    )
    .unwrap();
    let error = mux.classic_import_record(Some(&home.places()), &mutation, &record).unwrap_err();
    assert!(error.to_string().contains("not one of classic's session files"), "{error}");
    assert!(!home.ledger().parent().unwrap().join("backups").exists());
}

/// Cancel on the launch's preview stands: later launches skip with
/// `declined` whatever classic saves, a cut-off run still resumes, and a
/// manual run's `begin` or `finish` takes the No back.
#[test]
fn a_launchs_no_stands_until_a_manual_run() {
    let mux = Mux::new_for_test("classic-import-decline", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Automatic);
    assert_eq!(first["decision"], json!({"decision": "first_run"}));
    // First contact: the No is recorded with the save the preview showed.
    record(&mux, &home, json!({"event": "decline", "source": first["source"]}), "no");
    let ledger = home.ledger_json();
    assert_eq!(ledger["state"], "completed");
    assert!(ledger["declinedAt"].is_f64(), "{ledger}");
    assert_eq!(ledger["source"], first["source"]);
    assert_eq!(
        plan(&mux, &home, Mode::Automatic)["decision"],
        json!({"decision": "skip", "reason": "declined"})
    );
    // Classic saves again: still no question.
    let mut later: Value = serde_json::from_slice(&std::fs::read(home.session()).unwrap()).unwrap();
    later["createdAt"] = json!(1_791_900_000.0);
    std::fs::write(home.session(), serde_json::to_vec(&later).unwrap()).unwrap();
    let relaunch = plan(&mux, &home, Mode::Automatic);
    assert_eq!(relaunch["decision"], json!({"decision": "skip", "reason": "declined"}));
    assert_eq!(relaunch["plan"], Value::Null);

    // Import Workspaces from Classic cmux still plans everything, and its begin clears the No.
    let manual = plan(&mux, &home, Mode::Manual);
    assert_eq!(keys(&manual).len(), 4, "{manual}");
    run(&mux, &home, &manual, "manual");
    assert!(home.ledger_json().get("declinedAt").is_none());

    // A No on a resume ends the run; a finish with nothing to bring clears it too.
    record(&mux, &home, begin(&manual), "resume-begin");
    record(&mux, &home, json!({"event": "decline"}), "resume-no");
    let ledger = home.ledger_json();
    assert_eq!(
        (ledger["state"].clone(), ledger["declinedAt"].is_f64()),
        (json!("completed"), true)
    );
    record(&mux, &home, json!({"event": "finish"}), "empty-finish");
    assert!(home.ledger_json().get("declinedAt").is_none());
}

/// Every plan says whether the classic app that saved it is open now: its
/// launch sentinel with a recent save, or the lock beside its socket.
#[test]
fn the_plan_says_whether_classic_is_open() {
    let mux = Mux::new_for_test("classic-import-running", SurfaceOptions::default());
    let none = home(false);
    assert_eq!(plan(&mux, &none, Mode::Manual)["classic_running"], false);
    let home = home(true);
    assert_eq!(plan(&mux, &home, Mode::Manual)["classic_running"], false);
    let sentinel = home.0.join(".local/state/cmux/lifecycle/com.cmuxterm.app/running.sentinel");
    std::fs::create_dir_all(sentinel.parent().unwrap()).unwrap();
    std::fs::write(&sentinel, "").unwrap();
    // Classic saved just now.
    std::fs::File::options()
        .write(true)
        .open(home.session())
        .unwrap()
        .set_modified(std::time::SystemTime::now())
        .unwrap();
    let open = plan(&mux, &home, Mode::Automatic);
    assert_eq!(open["classic_running"], true);
    assert_eq!(open["decision"], json!({"decision": "skip", "reason": "classic_running"}));
    std::fs::remove_file(&sentinel).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let lock = home.0.join(".local/state/cmux/cmux.sock.lock");
        std::fs::write(&lock, "").unwrap();
        assert_eq!(plan(&mux, &home, Mode::Manual)["classic_running"], false);
        let holder = std::fs::File::open(&lock).unwrap();
        // SAFETY: the descriptor is open for the call.
        assert_eq!(unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
        assert_eq!(plan(&mux, &home, Mode::Manual)["classic_running"], true);
    }
}

/// The channel saved last is read, whichever build this is, and a newest
/// channel whose files do not decode falls back to the next channel's.
#[test]
fn the_newest_channel_is_read_and_a_broken_one_falls_back() {
    let mux = Mux::new_for_test("classic-import-channels", SurfaceOptions::default());
    let home = home(true);
    let nightly = home.session().with_file_name("session-com.cmuxterm.app.nightly.json");
    std::fs::copy(home.session(), &nightly).unwrap();
    let old = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    std::fs::File::options().write(true).open(home.session()).unwrap().set_modified(old).unwrap();
    let newest = plan(&mux, &home, Mode::Manual);
    assert_eq!(newest["source"]["bundleID"], "com.cmuxterm.app.nightly", "{newest}");
    // Only the read channel's files are backed up.
    assert_eq!(newest["backups"], json!([nightly.to_string_lossy()]));

    std::fs::write(&nightly, "{").unwrap();
    let fallback = plan(&mux, &home, Mode::Manual);
    assert_eq!(fallback["source"]["bundleID"], BUNDLE, "{fallback}");
    assert_eq!(fallback["error"], Value::Null);
    assert_eq!(keys(&fallback).len(), 4);
}

/// `outline: true` plans the same workspaces with every tab's scrollback left
/// out; without it a terminal's scrollback is its replay text.
#[test]
fn an_outline_plan_leaves_scrollback_out() {
    let mux = Mux::new_for_test("classic-import-outline", SurfaceOptions::default());
    let home = home(true);
    let mut saved: Value = serde_json::from_slice(&std::fs::read(home.session()).unwrap()).unwrap();
    for window in saved["windows"].as_array_mut().unwrap() {
        for workspace in window["tabManager"]["workspaces"].as_array_mut().unwrap() {
            for panel in workspace["panels"].as_array_mut().unwrap() {
                if panel["type"] == "terminal" {
                    panel["terminal"]["scrollback"] = json!("$ ls\r\n\u{1b}]0;t\u{7}ok\r\n");
                }
            }
        }
    }
    std::fs::write(home.session(), serde_json::to_vec(&saved).unwrap()).unwrap();
    let scrollbacks = |reply: &Value| -> Vec<Value> {
        let mut found = Vec::new();
        fn walk(node: &Value, found: &mut Vec<Value>) {
            match node {
                Value::Object(map) => {
                    if let Some(scrollback) = map.get("scrollback") {
                        found.push(scrollback.clone());
                    }
                    map.values().for_each(|value| walk(value, found));
                }
                Value::Array(items) => items.iter().for_each(|value| walk(value, found)),
                _ => {}
            }
        }
        walk(&reply["plan"], &mut found);
        found
    };
    // Over the wire the field is accepted.
    let wire = read(
        &mux,
        "classic_import.plan",
        json!({"bundle_id": BUNDLE, "mode": "manual", "outline": true}),
    );
    assert!(wire["ledger"].is_string(), "{wire}");
    let full = mux.classic_import_plan(Some(&home.places()), BUNDLE, Mode::Manual, false).unwrap();
    let texts = scrollbacks(&full);
    assert!(texts.contains(&json!("\u{1b}[0m$ ls\nok\u{1b}[0m\n")), "{texts:?}");
    let outline =
        mux.classic_import_plan(Some(&home.places()), BUNDLE, Mode::Manual, true).unwrap();
    assert_eq!(keys(&outline), keys(&full));
    let left = scrollbacks(&outline);
    assert!(!left.is_empty() && left.iter().all(Value::is_null), "{left:?}");
    let bad = send(
        &mux,
        "classic_import.plan",
        json!({"bundle_id": BUNDLE, "mode": "manual", "outline": "yes"}),
        None,
    );
    assert_eq!(error_code(bad), "validation.invalid");
}
