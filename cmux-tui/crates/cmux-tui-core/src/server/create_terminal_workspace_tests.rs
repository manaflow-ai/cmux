//! `create-terminal-workspace-v1`: a workspace and its first terminal in one
//! request. A new terminal workspace was two requests (`create-workspace`,
//! then `create-terminal` by key) with an empty workspace between them, which
//! every client saw and the app's empty-workspace repair had to own. With
//! `create_workspace`, `create-terminal {key}` makes the workspace when no
//! workspace has the key. The fields that choose a program stay top-level
//! fields of `create-terminal`, where the phone lane already refuses them.

use super::super::*;

const KEY: &str = "018f6e21-7b70-7e70-8000-0000000000c1";
const TERMINAL: &str = "018f6e217b704e7080000000000000c2";

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn request() -> Value {
    json!({"cmd":"create-terminal","key":KEY,"create_workspace":true,"workspace_name":"shell",
           "terminal_id":TERMINAL,"cols":80,"rows":24,
           "origin":"cmux-next","mutation_id":"terminal-workspace-create"})
}

fn workspaces(mux: &Arc<Mux>) -> Vec<(String, String)> {
    mux.with_state(|state| {
        state.workspaces.iter().map(|w| (w.key.to_string(), w.name.clone())).collect()
    })
}

#[test]
fn one_request_creates_a_terminal_workspace() {
    assert!(advertised_capabilities(false).contains(&"create-terminal-workspace-v1"));
    let mux = Mux::new_for_test("create-terminal-workspace", crate::SurfaceOptions::default());
    let created = run(&mux, request())
        .unwrap_or_else(|error| panic!("create-terminal did not make its workspace: {error:#}"));
    assert_eq!(created["key"], KEY, "{created}");
    assert_eq!(created["terminal_id"], TERMINAL, "{created}");
    assert!(created["surface"].as_u64().is_some(), "the reply names the terminal's tab: {created}");
    assert_eq!(workspaces(&mux), vec![(KEY.to_string(), "shell".to_string())]);
    assert_eq!(mux.with_state(|state| state.surfaces.len()), 1);

    // A retry after a lost reply answers the same terminal and makes nothing new.
    let again = run(&mux, request()).unwrap();
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(again["surface"], created["surface"], "{again}");
    assert_eq!(workspaces(&mux).len(), 1, "one workspace after the replay");
    assert_eq!(mux.with_state(|state| state.surfaces.len()), 1, "one terminal after the replay");
    mux.shutdown();
}

/// With a workspace that already has the key, the terminal just goes in it.
#[test]
fn an_existing_workspace_is_not_made_again() {
    let mux =
        Mux::new_for_test("create-terminal-workspace-existing", crate::SurfaceOptions::default());
    run(&mux, json!({"cmd":"create-workspace","key":KEY,"name":"mine"})).unwrap();
    let created = run(&mux, request()).unwrap();
    assert_eq!(created["key"], KEY, "{created}");
    assert_eq!(workspaces(&mux), vec![(KEY.to_string(), "mine".to_string())]);
    mux.shutdown();
}

/// It needs a key and a mutation id (the retry must be exactly once), and
/// nothing is made when they are missing.
#[test]
fn create_workspace_needs_a_key_and_a_mutation() {
    let mux =
        Mux::new_for_test("create-terminal-workspace-refused", crate::SurfaceOptions::default());
    let without = |fields: &[&str]| {
        let mut request = request();
        if let Some(object) = request.as_object_mut() {
            for field in fields {
                object.remove(*field);
            }
        }
        request
    };
    assert!(run(&mux, without(&["key"])).is_err(), "no key is a bad request");
    assert!(
        run(&mux, without(&["mutation_id", "origin"])).is_err(),
        "no mutation id is a bad request"
    );
    assert!(workspaces(&mux).is_empty(), "a refused request made a workspace");
    mux.shutdown();
}
