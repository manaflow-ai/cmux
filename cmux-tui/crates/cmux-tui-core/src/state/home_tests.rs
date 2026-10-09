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

fn key_of(mux: &Mux, id: &str) -> String {
    mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == id).unwrap().key.clone()
    })
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
