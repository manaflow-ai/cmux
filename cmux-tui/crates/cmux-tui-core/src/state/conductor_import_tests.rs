//! Import from Conductor on the daemon (`conductor-import-v1`): the plan of
//! a fixture `conductor.db` and its worktree, the ledger the app records
//! into, a replayed record, and a newer build's ledger left alone.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::json;

use super::tests::{error_code, mutate, read, send};
use crate::mux::*;
use crate::state::conductor_import_store;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
        .args(["-c", "init.defaultBranch=main"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

/// A home with one repository, its Conductor worktree `lima` under
/// `~/conductor/workspaces`, and a `conductor.db` that lists both.
fn home() -> Home {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let suffix = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    let dir = std::env::temp_dir().join(format!("cmux-conductor-import-{suffix}"));
    std::fs::create_dir_all(&dir).unwrap();
    let home = Home(dir.canonicalize().unwrap());
    let repo = home.0.join("src/app");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("README"), "app\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "init"]);
    let lima = home.0.join("conductor/workspaces/app/lima");
    std::fs::create_dir_all(lima.parent().unwrap()).unwrap();
    git(&repo, &["worktree", "add", "-q", "-b", "leo/lima", lima.to_str().unwrap()]);
    let db = cmux_conductor_import::detect::database_path(&home.0);
    std::fs::create_dir_all(db.parent().unwrap()).unwrap();
    rusqlite::Connection::open(&db)
        .unwrap()
        .execute_batch(&format!(
            "CREATE TABLE repos (id TEXT PRIMARY KEY, root_path TEXT, name TEXT, is_hidden INTEGER);
             CREATE TABLE workspaces (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, state TEXT,
                 path TEXT, archive_commit TEXT, directory_name TEXT);
             INSERT INTO repos VALUES ('r1', '{repo}', 'app', 0);
             INSERT INTO workspaces VALUES ('w-lima', 'r1', 'leo/lima', 'ready', '{lima}', NULL, 'lima');",
            repo = repo.display(),
            lima = lima.display(),
        ))
        .unwrap();
    home
}

fn plan(mux: &Arc<Mux>, home: &Home) -> Value {
    mux.conductor_import_plan(Some(&home.0)).unwrap()
}

fn lima(result: &Value) -> Value {
    result["plan"]["projects"][0]["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"] == "w-lima")
        .cloned()
        .expect("w-lima in the plan")
}

/// A workspace opened now: its key, as the app records it (the key it
/// created the workspace with).
fn open_workspace(mux: &Arc<Mux>) -> String {
    mux.new_workspace(Some("lima".into()), None).unwrap();
    mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|w| w.name == "lima");
        workspace.map(|w| w.key.clone())
    })
    .unwrap()
}

fn stored_ledger(mux: &Arc<Mux>) -> Option<String> {
    mux.read_registry_state(|connection| {
        Ok(connection
            .query_row("SELECT ledger_json FROM conductor_import_ledger", [], |row| row.get(0))
            .ok())
    })
    .unwrap()
}

#[test]
fn conductor_import_plan_without_conductor_has_no_plan() {
    let mux = Mux::new_for_test("conductor-import-none", SurfaceOptions::default());
    let empty = std::env::temp_dir().join("cmux-conductor-import-none-at-all");
    let result = mux.conductor_import_plan(Some(&empty)).unwrap();
    assert_eq!(
        result,
        json!({"found": {"database": null, "workspaces": null, "app": null}, "plan": null})
    );
    // Over the wire, under the daemon's own HOME: always `found`, never a param.
    let wire = read(&mux, "conductor_import.plan", json!({}));
    assert!(wire["found"].is_object(), "{wire}");
}

fn registry_folder(mux: &Arc<Mux>, path: &Path, sources: &[&str], hidden: bool) {
    let sources: serde_json::Map<String, Value> = sources
        .iter()
        .map(|source| (source.to_string(), json!({"first_seen_ms": 1, "last_used_ms": 2})))
        .collect();
    let project = json!({
        "path": path, "sources": sources,
        "overlay": {"hidden": hidden}, "state": "present"
    });
    mux.write_registry_meta(|transaction| {
        transaction.execute(
            "INSERT INTO projects(path, project_json) VALUES(?1, ?2)",
            rusqlite::params![path.to_str().unwrap(), project.to_string()],
        )?;
        Ok(())
    })
    .unwrap();
}

#[test]
fn conductor_import_agent_folders_use_shared_plan_and_ledger_without_conductor() {
    let mux = Mux::new_for_test("agent-import-flow", SurfaceOptions::default());
    let home = home();
    let folder = home.0.join("conductor/workspaces/app/lima");
    // Use a separate detection home so this is genuinely the no-Conductor path.
    let empty_home = home.0.join("empty-home");
    registry_folder(&mux, &folder, &["codex", "opencode"], false);
    let detection = mux.agent_import_detect(Some(&empty_home)).unwrap();
    assert_eq!(detection["candidate_folders"], json!({"codex": 1, "opencode": 1}));
    assert_eq!(detection["has_conductor"], false);
    assert_eq!(detection["card"]["id"], "agents.conductor");
    assert_eq!(detection["card"]["name"], "Agent worktrees");
    assert!(detection["card"]["count"].is_null(), "hints must not claim a worktree count");
    assert!(detection["plan"].is_null());
    assert!(stored_ledger(&mux).is_none(), "detection must not mutate the ledger");

    let first = mux
        .conductor_import_plan_with_policy(Some(&empty_home), &|path| path.is_absolute())
        .unwrap();
    assert_eq!(first["has_conductor"], false);
    assert_eq!(first["plan"]["has_conductor"], false);
    assert_eq!(first["plan"]["cloud_shutdown"], "");
    let workspace = &first["plan"]["projects"][0]["workspaces"][0];
    let id = workspace["id"].as_str().unwrap();
    assert_eq!(workspace["disposition"], json!({"kind": "adopt"}));
    assert_eq!(first["tool_sources"][id], json!(["codex", "opencode"]));
    let cmux_workspace = open_workspace(&mux);
    mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": id, "stage": "done", "cmux_workspace": cmux_workspace}),
        "agent-import-done",
    );
    let rerun = mux
        .conductor_import_plan_with_policy(Some(&empty_home), &|path| path.is_absolute())
        .unwrap();
    assert_eq!(
        rerun["plan"]["projects"][0]["workspaces"][0]["disposition"],
        json!({"kind": "already-imported", "cmux_workspace": cmux_workspace})
    );
}

#[test]
fn conductor_import_detection_ignores_hidden_disabled_and_non_agent_sources() {
    let mux = Mux::new_for_test("agent-import-filter", SurfaceOptions::default());
    registry_folder(
        &mux,
        Path::new("/does-not-exist/visible"),
        &["codex", "user", "unknown"],
        false,
    );
    registry_folder(&mux, Path::new("/does-not-exist/hidden"), &["opencode"], true);
    registry_folder(&mux, Path::new("/does-not-exist/disabled"), &["claude-code"], false);
    mux.write_registry_meta(|transaction| {
        transaction.execute("INSERT INTO project_sources_off(source) VALUES('claude-code')", [])?;
        Ok(())
    })
    .unwrap();
    let result = read(&mux, "conductor_import.plan", json!({"detect_only": true}));
    assert_eq!(result["candidate_folders"], json!({"codex": 1}));
    assert!(result["plan"].is_null());
    assert_eq!(
        error_code(send(&mux, "conductor_import.plan", json!({"detect_only": "true"}), None)),
        "validation.invalid"
    );
}

#[test]
fn conductor_import_detection_has_no_card_without_sources() {
    let mux = Mux::new_for_test("agent-import-detect-empty", SurfaceOptions::default());
    let result = mux.agent_import_detect(None).unwrap();
    assert!(result["card"].is_null());
    assert_eq!(result["has_conductor"], false);
    assert_eq!(result["candidate_folders"], json!({}));
}

#[test]
fn conductor_import_agent_folders_recheck_project_path_refusals() {
    let mux = Mux::new_for_test("agent-import-path-policy", SurfaceOptions::default());
    let home = home();
    let empty_home = home.0.join("empty-home");
    registry_folder(&mux, &home.0.join("conductor/workspaces/app/lima"), &["codex"], false);
    // Registry rows may predate a path rule. The daemon refuses temporary
    // folders again when planning, even if an old row is still in storage.
    assert!(mux.conductor_import_plan(Some(&empty_home)).unwrap()["plan"].is_null());
}

#[test]
fn conductor_import_plan_adopts_then_records_pending_and_done() {
    let mux = Mux::new_for_test("conductor-import-flow", SurfaceOptions::default());
    let home = home();

    let first = plan(&mux, &home);
    assert!(first["found"]["database"].is_string(), "{first}");
    assert_eq!(lima(&first)["disposition"], json!({"kind": "adopt"}));
    assert_eq!(lima(&first)["checked"], true);

    // The app records the key before it makes the workspace with it.
    let cmux_workspace = open_workspace(&mux);
    let pending = mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": cmux_workspace}),
        "lima-pending",
    );
    assert_eq!(
        pending,
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": cmux_workspace, "runs": 0})
    );

    let done = mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "done", "cmux_workspace": cmux_workspace,
               "run_completed": true}),
        "lima-done",
    );
    assert_eq!(done["stage"], "done");
    assert_eq!(done["runs"], 1);

    let after = plan(&mux, &home);
    assert_eq!(
        lima(&after)["disposition"],
        json!({"kind": "already-imported", "cmux_workspace": cmux_workspace})
    );
    assert_eq!(lima(&after)["checked"], false);

    // The same key replays its result and changes nothing.
    let before = stored_ledger(&mux);
    let replay = send(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "done", "cmux_workspace": cmux_workspace,
               "run_completed": true}),
        Some("lima-done"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"]["runs"], 1);
    assert_eq!(stored_ledger(&mux), before);
}

#[test]
fn conductor_import_record_checks_its_fields() {
    let mux = Mux::new_for_test("conductor-import-fields", SurfaceOptions::default());
    for (params, key) in [
        (json!({"stage": "pending"}), "no-workspace"),
        (json!({"workspace": "w", "stage": "started"}), "bad-stage"),
        (json!({"workspace": "w", "stage": "done"}), "done-without-cmux-workspace"),
        (json!({"workspace": "w", "stage": "pending", "run_completed": "yes"}), "bad-run"),
    ] {
        assert_eq!(
            error_code(send(&mux, "conductor_import.record", params, Some(key))),
            "validation.invalid",
            "{key}"
        );
    }
    assert_eq!(stored_ledger(&mux), None);
}

#[test]
fn conductor_import_leaves_a_newer_ledger_alone() {
    let mux = Mux::new_for_test("conductor-import-newer", SurfaceOptions::default());
    let home = home();
    let newer = r#"{"version":99,"runs":7,"workspaces":{}}"#;
    mux.write_registry_meta(|transaction| {
        transaction.execute(
            "INSERT INTO conductor_import_ledger(id, ledger_json) VALUES(1, ?1)",
            [newer],
        )?;
        Ok(())
    })
    .unwrap();
    assert!(matches!(
        mux.read_registry_state(conductor_import_store::load).unwrap(),
        cmux_conductor_import::ledger::Load::Newer(99)
    ));

    let result = plan(&mux, &home);
    assert_eq!(result["plan"], Value::Null);
    assert_eq!(result["error"], "ledger from a newer cmux");

    let refused = send(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "pending"}),
        Some("over-newer"),
    );
    assert_eq!(error_code(refused), "validation.invalid");
    assert_eq!(stored_ledger(&mux).as_deref(), Some(newer));
}

/// A ledger that parses but has a done workspace naming no cmux workspace
/// is damaged: the plan shows no plan and says why, and a record is refused,
/// as for a ledger that does not parse, so nothing is made twice from it.
#[test]
fn conductor_import_refuses_a_damaged_ledger() {
    let mux = Mux::new_for_test("conductor-import-damaged", SurfaceOptions::default());
    let home = home();
    let damaged = r#"{"version":1,"runs":0,"workspaces":{"w-lima":{"stage":"done"}}}"#;
    mux.write_registry_meta(|transaction| {
        transaction.execute(
            "INSERT INTO conductor_import_ledger(id, ledger_json) VALUES(1, ?1)",
            [damaged],
        )?;
        Ok(())
    })
    .unwrap();

    let result = plan(&mux, &home);
    assert_eq!(result["plan"], Value::Null);
    assert_eq!(result["error"], "ledger unreadable: done workspace w-lima names no cmux workspace");

    let refused = send(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": "ws-new"}),
        Some("over-damaged"),
    );
    assert_eq!(error_code(refused), "validation.invalid");
    assert_eq!(stored_ledger(&mux).as_deref(), Some(damaged));
}

/// Two runs that overlap both plan `w-lima` as one to adopt. Once the first
/// records it done while its workspace is open, the second run's pending and
/// done records are refused and the ledger keeps the first. The same
/// workspace recorded again, pending over pending, and a done entry whose
/// workspace was closed since all still record.
#[test]
fn conductor_import_record_keeps_an_open_done_workspace() {
    let mux = Mux::new_for_test("conductor-import-overlap", SurfaceOptions::default());

    // Pending replaces pending: a cut-off run's entry is made again.
    for (cmux_workspace, key) in [("ws-first", "a-pending"), ("ws-again", "b-pending")] {
        let pending = mutate(
            &mux,
            "conductor_import.record",
            json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": cmux_workspace}),
            key,
        );
        assert_eq!(pending["cmux_workspace"], cmux_workspace);
    }

    // Two runs both recorded pending: the earlier run's done, naming the
    // workspace it made instead of the one pending names now, is refused.
    let earlier = send(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "done", "cmux_workspace": "ws-first"}),
        Some("a-done-earlier"),
    );
    let earlier = earlier.expect_err("a done record over another run's pending one");
    assert_eq!(earlier.code, "validation.invalid");
    assert_eq!(earlier.details["field"], "cmux_workspace", "{earlier:?}");

    let first = open_workspace(&mux);
    mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": first}),
        "a-pending-made",
    );
    mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "done", "cmux_workspace": first}),
        "a-done",
    );
    let kept = stored_ledger(&mux);

    // The second run, with its own keys and its own workspace.
    for (stage, key) in [("pending", "b-pending-2"), ("done", "b-done")] {
        let refused = send(
            &mux,
            "conductor_import.record",
            json!({"workspace": "w-lima", "stage": stage, "cmux_workspace": "ws-second"}),
            Some(key),
        );
        assert_eq!(error_code(refused), "validation.invalid", "{stage}");
    }
    assert_eq!(stored_ledger(&mux), kept);

    // The same workspace by its public id, under another key: no conflict.
    let public_id = mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|w| w.key == first);
        workspace.map(|w| w.public_id.to_string())
    });
    mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "done", "cmux_workspace": public_id}),
        "a-done-again",
    );

    // Closed in cmux since: offered again, and recorded over.
    let id = mux.with_state(|state| state.workspaces.iter().find(|w| w.key == first).map(|w| w.id));
    assert!(mux.close_workspace(id.unwrap()));
    let again = mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": "ws-third"}),
        "c-pending",
    );
    assert_eq!(again["cmux_workspace"], "ws-third");
}

#[path = "conductor_import_edge_tests.rs"]
mod edge_tests;
