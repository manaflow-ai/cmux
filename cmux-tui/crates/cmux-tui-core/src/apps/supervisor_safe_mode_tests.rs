//! Supervisor tests of safe mode (`safe_mode.rs`) and rollback
//! (`rollback.rs`).

use super::*;
use crate::safe_mode_flag;

const OFF: &str = "off: safe mode";

/// Sets the version in the manifest of the app in `dir`.
fn save_version(dir: &Path, version: &str) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!(version);
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// The fixture's temp root back, so a second supervisor opens the same state.
fn restart(f: Fixture) -> TempDir {
    let Fixture { supervisor, _root, .. } = f;
    drop(supervisor);
    _root
}

fn flag_file(f: &Fixture) -> PathBuf {
    f._root.0.join("safe-mode.json")
}

/// Runs `app`'s `op` and returns its answer.
fn run(f: &Fixture, app: &str, op: &str) -> Result<Value, super::super::supervisor::ApiError> {
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request(app, op, None, Origin::User, None),
        Box::new(move |result| drop(tx.send(result))),
    );
    rx.recv_timeout(Duration::from_secs(10)).expect("the run answers")
}

/// Waits for `app`'s log line containing `text` (the caller follows the log).
fn wait_log(f: &Fixture, app: &str, text: &str) -> Value {
    f.wait(text, |e| {
        e["event"] == "apps-log"
            && e["app"] == app
            && e["message"].as_str().is_some_and(|m| m.contains(text))
    })
}

#[test]
fn safe_mode_from_the_env_starts_no_host_and_reloads_nothing() {
    let f = fixture_safe(&[], Duration::from_secs(60), temp_dir(), true);
    f.install("cmux/demo");
    f.install("local/spy");
    // Every scripted app, first-party included, is held off: no VM, no mount.
    for app in ["cmux/demo", "local/spy"] {
        let refused = f
            .supervisor
            .mount(CLIENT, &format!("m-{app}"), app, "cmux.section/1", json!({}))
            .unwrap_err();
        assert_eq!((refused.code.as_str(), refused.message.as_str()), ("apps.safe_mode", OFF));
    }
    let refused = run(&f, "cmux/demo", "demo.go").unwrap_err();
    assert_eq!(refused.code, "apps.safe_mode", "{refused:?}");
    // Every listing says why.
    let list = f.supervisor.list();
    assert_eq!(list["safe_mode"]["on"], true);
    assert_eq!(list["safe_mode"]["reason"], "env");
    assert_eq!(app_entry(&list, "local/spy")["run_state"], OFF);
    let installed =
        f.supervisor.store_call(CLIENT, "apps.installed.list", json!({}), Origin::Cli).unwrap();
    let demo = installed["apps"].as_array().unwrap().iter().find(|a| a["app"] == "cmux/demo");
    assert_eq!(demo.unwrap()["state"]["run_state"], OFF, "{installed}");
    // A save in safe mode is not applied.
    save_version(&f.state.join("apps/local/spy"), "1.0.1");
    f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.0");
    // The counter R1 asks for: not one host process.
    assert_eq!(f.supervisor.host_spawns(), 0);
    // The env holds for its run only: nothing was written.
    assert!(!flag_file(&f).exists());
    // Leaving applies the held save and mounts again.
    f.supervisor.set_safe_mode(false, Origin::User).unwrap();
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.1");
    assert!(app_entry(&f.supervisor.list(), "local/spy").get("run_state").is_none());
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    assert!(f.supervisor.host_spawns() > 0);
}

#[test]
fn entering_stops_running_hosts_and_only_the_person_leaves() {
    let f = fixture();
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    // Entering is always allowed, from any origin.
    let on = f.supervisor.set_safe_mode(true, Origin::Mcp).unwrap();
    assert_eq!((on["on"].clone(), on["reason"].clone()), (json!(true), json!("user")));
    let failed = f.wait("the open view fails", |e| e["event"] == "apps-mount-failed");
    assert_eq!(failed["reason"], OFF);
    let written = safe_mode_flag::read(&flag_file(&f)).expect("the flag file");
    assert_eq!(written.reason, safe_mode_flag::Reason::User);
    // Entering again keeps the first time.
    let again = f.supervisor.set_safe_mode(true, Origin::Cli).unwrap();
    assert_eq!(again["sinceMs"], on["sinceMs"]);
    let spawns = f.supervisor.host_spawns();
    assert!(f.supervisor.mount(CLIENT, "m2", "local/spy", "cmux.section/1", json!({})).is_err());
    assert_eq!(f.supervisor.host_spawns(), spawns, "no host starts in safe mode");
    // Only origin user leaves.
    for origin in [Origin::Cli, Origin::Mcp, Origin::Script, Origin::Remote] {
        let refused = f.supervisor.set_safe_mode(false, origin).unwrap_err();
        assert_eq!(refused.code, "apps.safe_mode.origin", "{origin:?}");
    }
    assert!(f.supervisor.safe_mode_on());
    let off = f.supervisor.set_safe_mode(false, Origin::User).unwrap();
    assert_eq!(off, json!({ "on": false }));
    assert!(!flag_file(&f).exists());
}

#[test]
fn the_flag_file_brings_the_next_start_up_in_safe_mode() {
    // `cmux safe-mode on` with no daemon writes the file.
    let root = temp_dir();
    let flag = safe_mode_flag::Flag {
        on: true,
        reason: safe_mode_flag::Reason::User,
        since_ms: 7,
        extensions: vec![],
    };
    safe_mode_flag::write(&root.0.join("safe-mode.json"), Some(&flag)).unwrap();
    let f = fixture_with(&[], Duration::from_secs(60), root);
    assert_eq!(f.supervisor.safe_mode_json()["sinceMs"], 7);
    f.install("local/spy");
    assert!(f.supervisor.mount(CLIENT, "m1", "local/spy", "cmux.section/1", json!({})).is_err());
    assert_eq!(f.supervisor.host_spawns(), 0);
    // And a supervisor started after leaving is not in safe mode.
    f.supervisor.set_safe_mode(false, Origin::User).unwrap();
    let f = fixture_with(&[], Duration::from_secs(60), restart(f));
    assert!(!f.supervisor.safe_mode_on());
}

#[test]
fn a_crash_loop_enters_safe_mode_and_names_what_was_mounted() {
    let f = fixture();
    f.install("local/spy");
    let minute = 60_000;
    let start = 1_000 * minute;
    // Two launches that mount and never settle, then the daemon restarts:
    // the count is on disk.
    for (i, at) in [start, start + minute].into_iter().enumerate() {
        assert_eq!(f.supervisor.launch_began(at)["on"], false);
        f.mount(&format!("m{i}"), "local/spy", "cmux.section/1", json!({}));
    }
    let f = fixture_with(&[], Duration::from_secs(60), restart(f));
    assert_eq!(f.supervisor.launch_began(start + 2 * minute)["on"], false);
    f.mount("m2", "local/spy", "cmux.section/1", json!({}));
    // The fourth launch sees three that never settled.
    let state = f.supervisor.launch_began(start + 3 * minute);
    assert_eq!(state["on"], true, "{state}");
    assert_eq!(state["reason"], "crash-loop");
    assert_eq!(state["extensions"], json!(["local/spy"]));
    let written = safe_mode_flag::read(&flag_file(&f)).expect("the flag file");
    assert_eq!(written.extensions, vec!["local/spy".to_string()]);
    f.wait("the open view fails", |e| e["event"] == "apps-mount-failed" && e["reason"] == OFF);
}

#[test]
fn settled_launches_and_clean_quits_never_trip() {
    let f = fixture();
    f.install("local/spy");
    let minute = 60_000;
    for i in 0..6u64 {
        f.supervisor.launch_began(i * minute);
        f.mount(&format!("m{i}"), "local/spy", "cmux.section/1", json!({}));
        let reason = if i % 2 == 0 { "frame" } else { "quit" };
        f.supervisor
            .safe_mode_call("safe_mode.launch_settled", json!({ "reason": reason }), Origin::Cli)
            .unwrap();
    }
    assert_eq!(f.supervisor.launch_began(6 * minute)["on"], false);
    let bad = f
        .supervisor
        .safe_mode_call("safe_mode.launch_settled", json!({ "reason": "crash" }), Origin::Cli)
        .unwrap_err();
    assert_eq!(bad.code, "bad-request");
}

#[test]
fn rollback_restores_the_last_good_version_after_a_restart() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.supervisor.logs(CLIENT, "local/spy", true);
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    wait_log(&f, "local/spy", "kept 1.0.0 as the version to roll back to");
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["can_rollback"], false);
    // A broken 1.0.1 is saved while cmux is closed.
    let state = f.state.clone();
    let root = restart(f);
    let spy = state.join("apps/local/spy");
    save_version(&spy, "1.0.1");
    std::fs::write(spy.join("dist/main.js"), "const a b = 2 // THROW_AT_INIT").unwrap();
    std::fs::write(spy.join("dist/extra.js"), "// new in 1.0.1").unwrap();
    let f = fixture_with(&[], Duration::from_secs(60), root);
    let entry = app_entry(&f.supervisor.list(), "local/spy");
    assert_eq!(
        (entry["version"].clone(), entry["can_rollback"].clone()),
        (json!("1.0.1"), json!(true))
    );
    // Its view fails, and the listing says so.
    f.supervisor.mount(CLIENT, "m1", "local/spy", "cmux.section/1", json!({})).unwrap();
    f.wait("the broken view fails", |e| e["event"] == "apps-mount-failed");
    let entry = app_entry(&f.supervisor.list(), "local/spy");
    assert!(entry["run_state"].as_str().is_some_and(|s| s.starts_with("failed: ")), "{entry}");
    // Agents propose (an agent's CLI call included); the person rolls back.
    let args = json!({ "app": "local/spy" });
    for origin in [Origin::Mcp, Origin::Cli] {
        let refused = f.supervisor.store_call(CLIENT, "cmux.apps.rollback", args.clone(), origin);
        assert_eq!(refused.unwrap_err().code, "apps.origin");
    }
    let done = f.supervisor.store_call(CLIENT, "apps.rollback", args.clone(), Origin::User);
    assert_eq!(done.unwrap(), json!({ "app": "local/spy", "version": "1.0.0", "restored": true }));
    assert_eq!(
        std::fs::read_to_string(spy.join("dist/main.js")).unwrap(),
        "var __cmuxAppExports = {};"
    );
    assert!(!spy.join("dist/extra.js").exists());
    // Nothing is lost: the replaced files are kept.
    let replaced = state.join("apps-last-good/local%2Fspy/replaced");
    assert!(
        std::fs::read_to_string(replaced.join("dist/main.js")).unwrap().contains("THROW_AT_INIT")
    );
    assert!(replaced.join("dist/extra.js").is_file());
    let entry = app_entry(&f.supervisor.list(), "local/spy");
    assert_eq!(
        (entry["version"].clone(), entry["can_rollback"].clone(), entry.get("run_state").cloned()),
        (json!("1.0.0"), json!(false), None),
        "{entry}"
    );
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    // Nothing left to roll back to.
    let again = f.supervisor.store_call(CLIENT, "apps.rollback", args, Origin::User).unwrap_err();
    assert_eq!(again.code, "apps.rollback.none");
}

#[test]
fn shipped_apps_have_no_rollback() {
    let f = fixture();
    f.install("cmux/demo");
    let refused = f
        .supervisor
        .store_call(CLIENT, "apps.rollback", json!({ "app": "cmux/demo" }), Origin::User)
        .unwrap_err();
    assert_eq!(refused.code, "apps.rollback.unsupported");
    assert_eq!(app_entry(&f.supervisor.list(), "cmux/demo")["can_rollback"], false);
}
