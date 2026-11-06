//! Owner invariants of `workspace-kind-v1` (plans/cmux-next/home.md section
//! 7), driven through `cmux.protocol/2` requests and the raw close paths.

use std::path::PathBuf;

use serde_json::json;

use crate::mux::ProviderWorkspaceState;
use crate::mux::*;
use crate::resource_router::handle_resource_message;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

struct Session {
    root: PathBuf,
    name: &'static str,
}

impl Session {
    fn new(name: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-home-{name}-{}", WorkspacePublicId::random().unwrap()));
        Self { root, name }
    }

    fn open(&self) -> Arc<Mux> {
        let registry = WorkspaceRegistry::open(&self.root, self.name).unwrap();
        Mux::from_workspace_registry(
            self.name.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn send(
    mux: &Arc<Mux>,
    operation: &str,
    params: Value,
    key: Option<&str>,
) -> Result<Value, ResourceError> {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("{operation}-test"),
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())?;
    if response["ok"] == true {
        Ok(response["result"].clone())
    } else {
        Err(serde_json::from_value(response["error"].clone()).unwrap())
    }
}

fn ensure_home(mux: &Arc<Mux>, key: &str) -> Value {
    send(mux, "workspace.ensure_home", json!({}), Some(key))
        .unwrap_or_else(|error| panic!("workspace.ensure_home failed: {error:?}"))
}

fn empty_workspace(mux: &Arc<Mux>, name: &str) -> String {
    let result = send(
        mux,
        "workspace.create",
        json!({"name": name, "initial_content": "empty"}),
        Some(&format!("create-{name}")),
    )
    .unwrap();
    result["value"]["workspace_id"].as_str().unwrap().to_string()
}

fn workspaces(mux: &Mux) -> Vec<Value> {
    crate::resource_api::public_session_snapshot(mux).unwrap()["workspaces"]
        .as_array()
        .unwrap()
        .clone()
}

fn workspace(mux: &Mux, id: &str) -> Value {
    workspaces(mux).into_iter().find(|value| value["id"] == id).unwrap()
}

fn placements(mux: &Arc<Mux>) -> Vec<Value> {
    send(mux, "workspace.placement.list", json!({}), None).unwrap().as_array().unwrap().clone()
}

fn key_of(mux: &Mux, id: &str) -> String {
    mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == id).unwrap().key.clone()
    })
}

fn error_code(result: Result<Value, ResourceError>) -> String {
    result.expect_err("request unexpectedly succeeded").code
}

/// A session whose app never asks has no home; the first `ensure_home`
/// creates one marked home and placed first, every later call (with any
/// key, and after a restart) names the same workspace.
#[test]
fn home_ensure_creates_one_home_first_and_replays() {
    let session = Session::new("ensure");
    let mux = session.open();
    let other = empty_workspace(&mux, "work");
    assert!(workspaces(&mux).iter().all(|value| value["extra"].get("kind").is_none()));

    let before = mux.with_state(|state| state.resource_revision);
    let created = ensure_home(&mux, "connect-1");
    assert_eq!(created["replayed"], false);
    assert_eq!(created["value"]["kind"], "workspace");
    let home = created["value"]["workspace_id"].as_str().unwrap().to_string();
    assert_eq!(workspace(&mux, &home)["extra"]["kind"], "home");
    assert!(workspace(&mux, &other)["extra"].get("kind").is_none());
    let first = &placements(&mux)[0];
    assert_eq!(first["workspace"]["workspace_id"], home);
    assert_eq!((first["index"].as_u64(), first["group_id"].is_null()), (Some(0), true));
    // One commit: the workspace, its kind and its placement in one batch.
    let batches = mux.resource_events_after(before).unwrap().batches;
    assert_eq!(batches.len(), 1, "ensure_home committed more than once");
    let changes = batches[0].changes.as_array().unwrap();
    assert!(changes.iter().any(|change| change["kind"] == "upsert"
        && change["resource"] == "workspace"
        && change["value"]["extra"]["kind"] == "home"));
    assert!(changes.iter().any(|change| change["kind"] == "state_upsert"
        && change["resource"] == "workspace_placement"
        && change["value"]["workspace"]["workspace_id"] == home.as_str()
        && change["value"]["index"] == 0));

    let again = ensure_home(&mux, "connect-2");
    assert_eq!(again["replayed"], true);
    assert_eq!(again["value"]["workspace_id"], home);
    assert_eq!(workspaces(&mux).iter().filter(|value| value["extra"]["kind"] == "home").count(), 1);
    drop(mux);

    let mux = session.open();
    assert_eq!(workspace(&mux, &home)["extra"]["kind"], "home");
    let restarted = ensure_home(&mux, "connect-3");
    assert_eq!(
        (restarted["value"]["workspace_id"].as_str(), restarted["replayed"].as_bool()),
        (Some(home.as_str()), Some(true))
    );
    mux.shutdown();
}

/// Only the store writes `kind`: `workspace.create` refuses the field.
#[test]
fn home_workspace_create_refuses_kind() {
    let session = Session::new("create-kind");
    let mux = session.open();
    let refused = send(
        &mux,
        "workspace.create",
        json!({"name": "fake", "initial_content": "empty", "kind": "home"}),
        Some("create-fake-home"),
    );
    assert_eq!(error_code(refused), "validation.invalid");
    assert!(workspaces(&mux).iter().all(|value| value["extra"].get("kind").is_none()));
    mux.shutdown();
}

/// Every close path refuses the home workspace with the typed code and
/// leaves it in the store; normal workspaces still close.
#[test]
fn home_refuses_every_close_path() {
    let session = Session::new("close");
    let mux = session.open();
    let home = ensure_home(&mux, "connect")["value"]["workspace_id"].as_str().unwrap().to_string();
    let other = empty_workspace(&mux, "work");

    let refused = send(&mux, "workspace.close", json!({"workspace": home}), Some("close-home"));
    let error = refused.expect_err("workspace.close closed the home workspace");
    assert_eq!(error.code, "home.not_closable");
    assert_eq!(error.details["workspace_id"], home);

    let key = key_of(&mux, &home);
    let raw = mux
        .close_workspace_with_mutation(
            None,
            Some(&key),
            None,
            None,
            &WorkspaceMutation::daemon("raw-close-home", "test").unwrap(),
        )
        .expect_err("raw close-workspace closed the home workspace");
    assert_eq!(crate::state::home_error_code(&raw).as_deref(), Some("home_not_closable"));

    let batch = mux
        .close_workspace_ending_terminals(
            None,
            Some(&key),
            None,
            None,
            &WorkspaceMutation::daemon("batch-close-home", "test").unwrap(),
        )
        .expect_err("close-workspace end_terminals closed the home workspace");
    assert_eq!(crate::state::home_error_code(&batch).as_deref(), Some("home_not_closable"));

    assert_eq!(workspace(&mux, &home)["extra"]["kind"], "home");
    send(&mux, "workspace.close", json!({"workspace": other}), Some("close-other")).unwrap();
    assert!(workspaces(&mux).iter().all(|value| value["id"] != other));
    mux.shutdown();
}

/// The top (ungrouped) section of the personal order keeps the home
/// workspace first; grouped workspaces may take any index, also index 0.
#[test]
fn home_stays_first_in_the_top_section() {
    let session = Session::new("order");
    let mux = session.open();
    let home = ensure_home(&mux, "connect")["value"]["workspace_id"].as_str().unwrap().to_string();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let group = send(&mux, "workspace_group.create", json!({"name": "Work"}), Some("group-1"))
        .unwrap()["value"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    send(&mux, "workspace.place", json!({"workspace": b, "index": 1}), Some("place-b")).unwrap();

    for (params, key) in [
        (json!({"workspace": a, "index": 0}), "place-a-first"),
        (json!({"workspace": home, "index": 1}), "place-home-second"),
        (json!({"workspace": home, "group": group}), "place-home-grouped"),
    ] {
        let refused = send(&mux, "workspace.place", params.clone(), Some(key));
        assert_eq!(error_code(refused), "home.pinned_first", "{params}");
    }
    let order = placements(&mux);
    assert_eq!(order[0]["workspace"]["workspace_id"], home);
    assert_eq!(order[1]["workspace"]["workspace_id"], b);

    // A grouped workspace at index 0 is outside the top section.
    send(
        &mux,
        "workspace.place",
        json!({"workspace": a, "group": group, "index": 0}),
        Some("group-a-first"),
    )
    .unwrap();
    let order = placements(&mux);
    assert_eq!(order[0]["workspace"]["workspace_id"], a);
    assert_eq!(order[0]["group_id"], group);
    assert_eq!(order[1]["workspace"]["workspace_id"], home);
    assert!(order[1]["group_id"].is_null());
    assert_eq!(order[2]["workspace"]["workspace_id"], b);
    // Moving home within the top section's first slot stays allowed.
    send(&mux, "workspace.place", json!({"workspace": home, "index": 0}), Some("place-home"))
        .unwrap();
    mux.shutdown();
}

/// An order that already has home out of the first slot (a synced order:
/// sidebar-doc sync moves rows without the rule) still takes other moves;
/// the rule refuses only a change that takes home out of the first slot
/// (2026-10-20: home at index 13 refused every `workspace.place`).
#[test]
fn home_already_out_of_first_slot_does_not_block_other_moves() {
    let session = Session::new("order-stale");
    let mux = session.open();
    let home = ensure_home(&mux, "connect")["value"]["workspace_id"].as_str().unwrap().to_string();
    let a = empty_workspace(&mux, "a");
    let c = empty_workspace(&mux, "c");
    {
        let registry = mux.workspace_registry.lock().unwrap();
        let db = registry.connection.get();
        db.execute(
            "UPDATE personal_workspaces
             SET position = (SELECT MAX(position) + 1 FROM personal_workspaces)
             WHERE workspace_key = ?1",
            [key_of(&mux, &home)],
        )
        .unwrap();
    }
    let ids = |order: Vec<Value>| -> Vec<String> {
        order
            .iter()
            .map(|row| row["workspace"]["workspace_id"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(ids(placements(&mux)).last(), Some(&home), "the order does not start stale");

    send(&mux, "workspace.place", json!({"workspace": c, "index": 0}), Some("place-c-first"))
        .unwrap_or_else(|error| panic!("a stale home order refused another move: {error:?}"));
    assert_eq!(ids(placements(&mux))[0], c);
    // Putting home back first is allowed, and from then on the rule holds.
    send(&mux, "workspace.place", json!({"workspace": home, "index": 0}), Some("place-home-first"))
        .unwrap();
    assert_eq!(ids(placements(&mux))[0], home);
    let refused =
        send(&mux, "workspace.place", json!({"workspace": a, "index": 0}), Some("place-a-first"));
    assert_eq!(error_code(refused), "home.pinned_first");
    mux.shutdown();
}

/// The raw tree names the home workspace with `kind: "home"`.
#[test]
fn home_raw_tree_names_the_home_workspace() {
    let session = Session::new("raw-kind");
    let mux = session.open();
    let other = empty_workspace(&mux, "work");
    let home = ensure_home(&mux, "connect")["value"]["workspace_id"].as_str().unwrap().to_string();
    let tree = crate::server::workspaces_json(
        &mux.with_state(|state| state.clone()),
        &mux.tree_decorations(),
    );
    let kind_of = |id: &str| {
        tree["workspaces"].as_array().unwrap().iter().find(|w| w["resource_id"] == id).unwrap()
            ["kind"]
            .clone()
    };
    assert_eq!(kind_of(&home), "home");
    assert_eq!(kind_of(&other), "normal");
    mux.shutdown();
}

/// The `workspace-added` event that announces the home names it `kind: "home"`, as every
/// later tree read does. A subscriber applies that event before its next tree read, so an
/// event that said `normal` showed the home as an ordinary workspace row for a moment (the
/// app's Cmd-2 then picked that row, and the window showed Home: SidebarCmdNumberTwiceTests).
#[test]
fn home_workspace_added_event_names_the_home() {
    let session = Session::new("added-kind");
    let mux = session.open();
    empty_workspace(&mux, "work");
    let events = mux.subscribe();
    let home = ensure_home(&mux, "connect")["value"]["workspace_id"].as_str().unwrap().to_string();
    let added = std::iter::from_fn(|| events.try_recv().ok())
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta)
                if delta.kind == TreeDeltaKind::WorkspaceAdded
                    && delta.entity["resource_id"] == home.as_str() =>
            {
                Some(delta)
            }
            _ => None,
        })
        .expect("ensure_home emits workspace-added for the home");
    assert_eq!(added.entity["kind"], "home", "workspace-added entity: {}", added.entity);
    mux.shutdown();
}

/// The app's hidden home is not one of the user's workspaces: the first one
/// it names after `ensure_home` is `workspace-1`, not `workspace-2` (a
/// first launch showed its only workspace as `workspace-2`).
#[test]
fn home_does_not_count_toward_workspace_names() {
    let session = Session::new("names");
    let mux = session.open();
    ensure_home(&mux, "connect-1");
    let name_of = |id: &str| {
        mux.with_state(|state| {
            state.workspaces.iter().find(|item| item.public_id.as_str() == id).unwrap().name.clone()
        })
    };
    let create = |key: &str| {
        send(&mux, "workspace.create", json!({"initial_content": "empty"}), Some(key)).unwrap()["value"]
            ["workspace_id"]
            .as_str()
            .unwrap()
            .to_string()
    };
    let first = create("create-first");
    assert_eq!(name_of(&first), "workspace-1");
    let second = create("create-second");
    assert_eq!(name_of(&second), "workspace-2");
}
