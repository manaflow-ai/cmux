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

    let created = ensure_home(&mux, "connect-1");
    assert_eq!(created["replayed"], false);
    assert_eq!(created["value"]["kind"], "workspace");
    let home = created["value"]["workspace_id"].as_str().unwrap().to_string();
    assert_eq!(workspace(&mux, &home)["extra"]["kind"], "home");
    assert!(workspace(&mux, &other)["extra"].get("kind").is_none());
    let first = &placements(&mux)[0];
    assert_eq!(first["workspace"]["workspace_id"], home);
    assert_eq!((first["index"].as_u64(), first["group_id"].is_null()), (Some(0), true));

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
            &WorkspaceMutation::new("raw-close-home", "test").unwrap(),
        )
        .expect_err("raw close-workspace closed the home workspace");
    assert_eq!(crate::state::home_error_code(&raw).as_deref(), Some("home_not_closable"));

    let batch = mux
        .close_workspace_ending_terminals(
            None,
            Some(&key),
            None,
            None,
            &WorkspaceMutation::new("batch-close-home", "test").unwrap(),
        )
        .expect_err("close-workspace end_terminals closed the home workspace");
    assert_eq!(crate::state::home_error_code(&batch).as_deref(), Some("home_not_closable"));

    assert_eq!(workspace(&mux, &home)["extra"]["kind"], "home");
    send(&mux, "workspace.close", json!({"workspace": other}), Some("close-other")).unwrap();
    assert!(workspaces(&mux).iter().all(|value| value["id"] != other));
    mux.shutdown();
}

/// The personal order keeps the home workspace first and ungrouped; other
/// placements behind it still work.
#[test]
fn home_stays_first_in_the_personal_order() {
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

    send(&mux, "workspace.place", json!({"workspace": b, "index": 1}), Some("place-b")).unwrap();
    send(&mux, "workspace.place", json!({"workspace": a, "group": group}), Some("group-a"))
        .unwrap();
    let order = placements(&mux);
    assert_eq!(order[0]["workspace"]["workspace_id"], home);
    assert_eq!(order[1]["workspace"]["workspace_id"], b);
    // Placing home where it already is stays allowed.
    send(&mux, "workspace.place", json!({"workspace": home, "index": 0}), Some("place-home"))
        .unwrap();
    mux.shutdown();
}
