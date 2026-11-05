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

#[test]
fn conductor_import_plan_adopts_then_records_pending_and_done() {
    let mux = Mux::new_for_test("conductor-import-flow", SurfaceOptions::default());
    let home = home();

    let first = plan(&mux, &home);
    assert!(first["found"]["database"].is_string(), "{first}");
    assert_eq!(lima(&first)["disposition"], json!({"kind": "adopt"}));
    assert_eq!(lima(&first)["checked"], true);

    let pending = mutate(
        &mux,
        "conductor_import.record",
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": "ws-half"}),
        "lima-pending",
    );
    assert_eq!(
        pending,
        json!({"workspace": "w-lima", "stage": "pending", "cmux_workspace": "ws-half", "runs": 0})
    );

    let cmux_workspace = open_workspace(&mux);
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
