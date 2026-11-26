//! The move from classic cmux on the daemon (`classic-import-v1`): a
//! launch's plan of classic's fixture session, the ledger steps the app
//! records, a replayed step, a relaunch that makes nothing, a manual run
//! that brings back only what was closed, first contact while cmux NEXT was
//! already in use, and a newer build's ledger left alone.

use std::path::{Path, PathBuf};

use serde_json::json;

use super::classic_import_router::{Places, Record, dispatch_in, places_for_test};
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
    record_at(mux, &home.places(), fields, key)
}

fn record_at(mux: &Arc<Mux>, places: &Places, fields: Value, key: &str) -> Value {
    let mut fields = fields;
    fields["bundle_id"] = json!(BUNDLE);
    let record = Record::parse(fields.as_object().unwrap()).unwrap();
    let mutation = WorkspaceMutation::new(
        key.to_string(),
        "resource-api",
        crate::workspace_registry::Actor::Daemon,
    )
    .unwrap();
    let commit = mux.classic_import_record(Some(places), &mutation, &record).unwrap();
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
fn settings_presence_is_probeable_without_decoding_a_classic_session() {
    let mux = Mux::new_for_test("classic-import-settings-probe", SurfaceOptions::default());
    let home = home(false);
    let mut places = home.places();
    places.config_home = home.0.join("classic-xdg");
    places.settings_directory = home.0.join("next-settings/cmux");
    let classic = places.config_home.join("cmux");
    std::fs::create_dir_all(&classic).unwrap();
    // This is intentionally not valid session JSON. The metadata-only probe must
    // still offer the settings import, while the consented workspace plan reports
    // that there is no session to decode.
    std::fs::write(classic.join("cmux.json"), b"{not a session").unwrap();

    let probe = mux.classic_import_probe(Some(&places), BUNDLE, Mode::Manual).unwrap();
    assert_eq!(probe["available"], true, "{probe}");
    assert!(probe["source"].is_null() && probe["observed"].is_string(), "{probe}");

    let plan = mux.classic_import_plan(Some(&places), BUNDLE, Mode::Manual, false).unwrap();
    assert_eq!(plan["settings_only"], true, "{plan}");
    assert!(plan["source"].is_null() && plan["plan"].is_null(), "{plan}");
}

#[cfg(unix)]
#[test]
fn consented_settings_record_imports_sidecars_once_then_finish_marks_observed() {
    let mux = Mux::new_for_test("classic-import-settings-record", SurfaceOptions::default());
    let home = home(false);
    let mut places = home.places();
    places.config_home = home.0.join("classic-xdg");
    places.settings_directory = home.0.join("next-settings/cmux");

    // Ghostty's source is in Classic Application Support. The ledger directory
    // is present because a real import would have loaded it before recording.
    std::fs::create_dir_all(home.ledger().parent().unwrap()).unwrap();
    let ghostty = places.support.join(BUNDLE).join("config.ghostty");
    std::fs::create_dir_all(ghostty.parent().unwrap()).unwrap();
    std::fs::write(&ghostty, b"font-size = 17\n").unwrap();

    let classic = places.config_home.join("cmux");
    std::fs::create_dir_all(&classic).unwrap();
    std::fs::write(
        classic.join("cmux.json"),
        br#"{"agents":{"harnesses":{"inline":{"command":"launch"}}}}"#,
    )
    .unwrap();

    let probe = mux.classic_import_probe(Some(&places), BUNDLE, Mode::Manual).unwrap();
    assert_eq!(probe["available"], true, "{probe}");
    let plan = mux.classic_import_plan(Some(&places), BUNDLE, Mode::Manual, false).unwrap();
    assert_eq!(plan["settings_only"], true, "{plan}");
    let observed = probe["observed"].as_str().unwrap();

    let first = record_at(&mux, &places, json!({"event": "settings"}), "settings");
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"]["changed"], false);
    assert_eq!(
        std::fs::read_to_string(places.settings_directory.join("classic-ghostty/config.ghostty"))
            .unwrap(),
        "font-size = 17\n"
    );
    assert!(places.settings_directory.join("classic-harnesses/profiles.json").is_file());

    // A retry returns the first result and cannot overwrite an edit made after
    // the accepted import.
    std::fs::write(
        places.settings_directory.join("classic-ghostty/config.ghostty"),
        "font-size = 19\n",
    )
    .unwrap();
    let replay = record_at(&mux, &places, json!({"event": "settings"}), "settings");
    assert_eq!(replay["replayed"], true);
    assert_eq!(
        std::fs::read_to_string(places.settings_directory.join("classic-ghostty/config.ghostty"))
            .unwrap(),
        "font-size = 19\n"
    );

    let finish = record_at(
        &mux,
        &places,
        json!({"event": "finish", "observed": observed}),
        "settings-finish",
    );
    assert_eq!(finish["value"]["state"], "completed");
    assert_eq!(home.ledger_json()["observedClassicFiles"], observed);
    assert_eq!(
        mux.classic_import_probe(Some(&places), BUNDLE, Mode::Manual).unwrap()["already_imported"],
        true
    );
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
    let probe =
        || checked_ok(&mux, &home, "classic_import.plan", json!({"mode": "automatic"}), None);
    let offer = probe();
    let reply = checked_ok(
        &mux,
        &home,
        "classic_import.record",
        json!({"event": "baseline", "observed": offer["observed"]}),
        Some("baseline"),
    );
    assert_eq!(reply["value"]["state"], "completed");
    assert_eq!(reply["value"]["workspaces"], 0);
    assert_eq!(probe()["decision"], json!({"decision": "skip", "reason": "unchanged"}));
    assert_ne!(
        mux.classic_import_probe(Some(&home.places()), BUNDLE, Mode::Manual).unwrap()["already_imported"],
        true
    );
    assert_eq!(keys(&plan(&mux, &home, Mode::Manual)).len(), 4);
    std::fs::write(home.session(), b"broken save").unwrap();
    let changed = probe();
    assert_ne!(offer["observed"], changed["observed"]);
    assert_eq!(changed["decision"], json!({"decision": "merge"}));
    assert!(changed["source"].is_null() && changed["error"].is_null());
    assert!(plan(&mux, &home, Mode::Manual)["error"].is_string());
    record(&mux, &home, json!({"event": "decline"}), "decline");
    assert_eq!(probe()["decision"], json!({"decision": "skip", "reason": "declined"}));
    assert_ne!(
        mux.classic_import_probe(Some(&home.places()), BUNDLE, Mode::Manual).unwrap()["already_imported"],
        true
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

    let checkpoint = std::fs::read(home.ledger()).unwrap();
    record(&mux, &home, json!({"event": "settings"}), "resume-settings");
    assert_eq!(std::fs::read(home.ledger()).unwrap(), checkpoint);

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

/// A retried `begin` that already ran replays its first result before any
/// file is checked or copied: classic removing the file it read, or saving
/// a newer archive, since does not turn the retry into a refusal.
#[test]
fn a_replayed_begin_answers_before_checking_classics_files() {
    let mux = Mux::new_for_test("classic-import-replay-first", SurfaceOptions::default());
    let home = home(true);
    let first = plan(&mux, &home, Mode::Automatic);
    let once = record(&mux, &home, begin(&first), "early-begin");
    assert_eq!(once["replayed"], false);
    let backups = home.ledger().parent().unwrap().join("backups");
    let count = |backups: &Path| std::fs::read_dir(backups).unwrap().count();
    assert_eq!(count(&backups), 1);

    std::fs::remove_file(home.session()).unwrap();
    let history = home.session().parent().unwrap().join("session-history");
    std::fs::create_dir_all(&history).unwrap();
    std::fs::write(
        history.join("session-com.cmuxterm.app-99999999999-w1-p1.json"),
        r#"{"version":1,"createdAt":9,"windows":[]}"#,
    )
    .unwrap();
    let again = record(&mux, &home, begin(&first), "early-begin");
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(again["value"], once["value"]);
    assert_eq!(count(&backups), 1);
}

/// A ledger that does not decode stops automatic runs at every later launch,
/// not only the first: the copy moved aside keeps it unusable until a manual
/// import writes a new ledger, so no launch makes every workspace again.
#[test]
fn a_damaged_ledger_stops_every_automatic_run_until_a_manual_import() {
    let mux = Mux::new_for_test("classic-import-damaged-ledger", SurfaceOptions::default());
    let home = home(true);
    std::fs::create_dir_all(home.ledger().parent().unwrap()).unwrap();
    std::fs::write(home.ledger(), "{not json").unwrap();
    let skip = json!({"decision": "skip", "reason": "ledger_not_usable"});
    for _ in 0..2 {
        let launch = plan(&mux, &home, Mode::Automatic);
        assert_eq!(launch["ledger"], "unreadable");
        assert_eq!(launch["decision"], skip, "{launch}");
        assert!(launch["plan"].is_null());
    }

    let manual = plan(&mux, &home, Mode::Manual);
    assert!(!keys(&manual).is_empty(), "{manual}");
    run(&mux, &home, &manual, "recover");
    let relaunch = plan(&mux, &home, Mode::Automatic);
    assert_eq!(relaunch["ledger"], "ledger");
    assert_eq!(relaunch["decision"], json!({"decision": "skip", "reason": "unchanged"}));
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
    // Both sources exist and Classic is live. A probe must not inspect either content.
    let unread_since = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1);
    for path in [&home.session(), &sentinel] {
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_accessed(unread_since))
            .unwrap();
    }
    for fields in [json!({"mode": "automatic"}), json!({"mode": "manual", "consented": false})] {
        let probe = checked_ok(&mux, &home, "classic_import.plan", fields, None);
        assert_eq!(probe["available"], true);
        assert_eq!(probe["classic_running"], false);
        assert_eq!(probe["backups"], json!([]));
        assert!(probe["source"].is_null() && probe["plan"].is_null() && probe["preview"].is_null());
    }
    for path in [&home.session(), &sentinel] {
        assert_eq!(std::fs::metadata(path).unwrap().accessed().unwrap(), unread_since);
    }
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

/// An idle classic saves only when its session changes, so a save long ago
/// says nothing about whether it runs: a sentinel naming a live pid, or the
/// per-user `cmux-<uid>.sock.lock` held, keeps a launch from asking. On
/// 2026-11-15 a classic stable (open since Nov 7, last save 2 min
/// earlier, its lock `cmux-501.sock.lock`) read as closed, and a relaunch
/// offered its workspaces unasked.
#[cfg(unix)]
#[test]
fn an_idle_classic_that_saved_long_ago_is_still_open() {
    use std::os::unix::io::AsRawFd;
    let mux = Mux::new_for_test("classic-import-idle", SurfaceOptions::default());
    let home = home(true);
    // Classic's last save, a day ago.
    let day_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(24 * 60 * 60);
    std::fs::File::options()
        .write(true)
        .open(home.session())
        .unwrap()
        .set_modified(day_ago)
        .unwrap();
    let sentinel = home.0.join(".local/state/cmux/lifecycle/com.cmuxterm.app/running.sentinel");
    std::fs::create_dir_all(sentinel.parent().unwrap()).unwrap();
    // A sentinel with no pid and an old save is a classic that crashed.
    std::fs::write(&sentinel, "").unwrap();
    assert_eq!(plan(&mux, &home, Mode::Manual)["classic_running"], false);
    // The sentinel names a live pid (this test's): classic runs, however old its save.
    std::fs::write(&sentinel, format!("pid={}\n", std::process::id())).unwrap();
    let open = plan(&mux, &home, Mode::Automatic);
    assert_eq!(open["classic_running"], true);
    assert_eq!(open["decision"], json!({"decision": "skip", "reason": "classic_running"}));
    std::fs::remove_file(&sentinel).unwrap();
    assert_eq!(plan(&mux, &home, Mode::Manual)["classic_running"], false);
    // Classic stable's lock beside its per-user socket, held.
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let lock = home.0.join(format!(".local/state/cmux/cmux-{uid}.sock.lock"));
    std::fs::write(&lock, "").unwrap();
    let holder = std::fs::File::open(&lock).unwrap();
    // SAFETY: the descriptor is open for the call.
    assert_eq!(unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let open = plan(&mux, &home, Mode::Automatic);
    assert_eq!(open["classic_running"], true);
    assert_eq!(open["decision"], json!({"decision": "skip", "reason": "classic_running"}));
}

/// The channel saved last is read, whichever build this is, and a newest
/// channel whose files do not decode falls back to the next channel's.
#[test]
fn the_newest_channel_is_read_and_a_broken_one_falls_back() {
    let mux = Mux::new_for_test("classic-import-channels", SurfaceOptions::default());
    let home = home(true);
    let nightly = home.session().with_file_name("session-com.cmuxterm.app.nightly.json");
    std::fs::copy(home.session(), &nightly).unwrap();
    // Nightly saved just now. A copy can keep its source's modified time (macOS clones the file).
    let now = std::time::SystemTime::now();
    std::fs::File::options().write(true).open(&nightly).unwrap().set_modified(now).unwrap();
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

/// One request the way the daemon answers it, under `home`: the envelope and
/// its params checked against the embedded catalog, the op run, then its
/// result or error checked against the catalog too. A reply field, param or
/// event the catalog does not carry is refused here as it is in the app.
fn checked(
    mux: &Arc<Mux>,
    home: &Home,
    operation: &str,
    params: Value,
    key: Option<&str>,
) -> Result<Value, ResourceError> {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    params["bundle_id"] = json!(BUNDLE);
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("{operation}-checked"),
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let request =
        crate::resource_router::parse_resource_request(&serde_json::to_string(&envelope).unwrap())?;
    let operation = request.envelope.operation;
    crate::resource_router::validate_operation_outcome(
        operation,
        dispatch_in(mux, request, Some(home.places())),
    )
}

fn checked_ok(
    mux: &Arc<Mux>,
    home: &Home,
    operation: &str,
    params: Value,
    key: Option<&str>,
) -> Value {
    checked(mux, home, operation, params.clone(), key)
        .unwrap_or_else(|error| panic!("{operation} {params} breaks its catalog: {error:?}"))
}

/// Every reply the app reads from classic_import.plan and every step it
/// records, with classic's session there, passes the catalog the daemon
/// enforces: the plan's classic_running, outline (scrollback null), and the
/// decline event that sets the ledger's declinedAt.
#[test]
fn classic_import_replies_match_the_embedded_catalog() {
    let mux = Mux::new_for_test("classic-import-catalog", SurfaceOptions::default());
    let none = home(false);
    let empty = checked_ok(
        &mux,
        &none,
        "classic_import.plan",
        json!({"mode": "automatic", "consented": true}),
        None,
    );
    assert_eq!(empty["classic_running"], false, "{empty}");

    let home = home(true);
    let probe = checked_ok(&mux, &home, "classic_import.plan", json!({"mode": "automatic"}), None);
    assert_eq!(probe["available"], true);
    assert!(probe["plan"].is_null() && probe["preview"].is_null() && probe["source"].is_null());
    let first = checked_ok(
        &mux,
        &home,
        "classic_import.plan",
        json!({"mode": "automatic", "consented": true}),
        None,
    );
    assert_eq!(first["decision"], json!({"decision": "first_run"}));
    assert_eq!(first["classic_running"], false);
    assert!(first["plan"].is_object(), "{first}");
    let manual = checked_ok(
        &mux,
        &home,
        "classic_import.plan",
        json!({"mode": "manual", "consented": true}),
        None,
    );
    assert_eq!(keys(&manual).len(), 4, "{manual}");
    for outline in [false, true] {
        let reply = checked_ok(
            &mux,
            &home,
            "classic_import.plan",
            json!({"mode": "manual", "consented": true, "outline": outline}),
            None,
        );
        assert_eq!(keys(&reply), keys(&manual));
    }

    let declined = checked_ok(
        &mux,
        &home,
        "classic_import.record",
        json!({"event": "decline", "source": first["source"]}),
        Some("catalog-decline"),
    );
    assert_eq!(declined["value"]["state"], "completed", "{declined}");
    assert!(home.ledger_json()["declinedAt"].is_f64());
    let skipped = checked_ok(
        &mux,
        &home,
        "classic_import.plan",
        json!({"mode": "automatic", "consented": true}),
        None,
    );
    assert_eq!(skipped["decision"], json!({"decision": "skip", "reason": "declined"}));
    // A decline without a source (a resumed run's No) passes too.
    checked_ok(
        &mux,
        &home,
        "classic_import.record",
        json!({"event": "decline"}),
        Some("catalog-decline-again"),
    );
    checked_ok(
        &mux,
        &home,
        "classic_import.record",
        json!({"event": "finish"}),
        Some("catalog-finish"),
    );

    // The catalog still refuses what the op does not take.
    let bad = checked(
        &mux,
        &home,
        "classic_import.plan",
        json!({"mode": "manual", "consented": true, "outline": "yes"}),
        None,
    );
    assert_eq!(error_code(bad), "validation.invalid");
}

/// A DEV build never imports the person's classic data: its launch names its own folder
/// (`CMUX_NEXT_CLASSIC_IMPORT_DIR`, BuildStatePaths), which stands for classic's Application Support. Classic's
/// files there (none until someone puts a test session in) are the only ones read, and the ledger goes there too.
#[test]
fn dev_build_own_classic_import_never_reads_the_persons_classic() {
    let mux = Mux::new_for_test("classic-import-dev-build", SurfaceOptions::default());
    let home = home(true);
    let own = home.0.join("dev-build/classic-import");
    let settings = home.0.join("dev-build/settings/cmux-next.json");
    let (home_path, own_path) = (home.0.clone(), own.clone());
    let places = Places::from_vars(|name| match name {
        "CMUX_NEXT_CONFIG_FILE" => Some(settings.clone().into_os_string()),
        "HOME" => Some(home_path.clone().into_os_string()),
        "CMUX_NEXT_CLASSIC_IMPORT_DIR" => Some(own_path.clone().into_os_string()),
        _ => None,
    })
    .expect("places");
    assert_eq!(places.config_home, own.join(".config"));
    assert_eq!(places.settings_directory, settings.parent().unwrap());
    let empty = mux.classic_import_plan(Some(&places), BUNDLE, Mode::Manual, false).unwrap();
    assert_eq!(
        empty["source"],
        Value::Null,
        "a DEV build read the person's classic session: {empty}"
    );
    assert_eq!(empty["plan"], Value::Null);

    // A classic session put in the build's own folder is the one it imports.
    let session = own.join("cmux/session-com.cmuxterm.app.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    std::fs::copy(home.session(), &session).unwrap();
    let own_plan = mux.classic_import_plan(Some(&places), BUNDLE, Mode::Manual, false).unwrap();
    assert_eq!(own_plan["source"]["path"], session.to_string_lossy().as_ref(), "{own_plan}");

    let fields = json!({"event": "seen", "bundle_id": BUNDLE});
    let record = Record::parse(fields.as_object().unwrap()).unwrap();
    let mutation = WorkspaceMutation::new(
        "dev-build-seen".to_string(),
        "resource-api",
        crate::workspace_registry::Actor::Daemon,
    )
    .unwrap();
    mux.classic_import_record(Some(&places), &mutation, &record).unwrap();
    assert!(
        own.join("cmux-next/com.cmuxterm.app/classic-migration/ledger.json").is_file(),
        "the ledger is not in the build's own folder"
    );
    assert!(
        !home.ledger().exists(),
        "the DEV build wrote a ledger beside the person's classic data"
    );
}
