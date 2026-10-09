//! Behavioral tests of the state resources (state-ownership.md steps A and
//! B), driven through `cmux.protocol/2` requests.

use std::path::PathBuf;

use serde_json::json;

use crate::mux::ProviderWorkspaceState;
use crate::mux::*;
use crate::resource_router::handle_resource_message;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

pub(super) struct Session {
    pub(super) root: PathBuf,
    pub(super) name: &'static str,
}

impl Session {
    pub(super) fn new(name: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-state-{name}-{}", WorkspacePublicId::random().unwrap()));
        Self { root, name }
    }

    pub(super) fn open(&self) -> Arc<Mux> {
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

pub(super) fn send(
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

/// A committed mutation's value.
pub(super) fn mutate(mux: &Arc<Mux>, operation: &str, params: Value, key: &str) -> Value {
    let result = send(mux, operation, params, Some(key))
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(result["replayed"], false, "{operation} unexpectedly replayed");
    result["value"].clone()
}

pub(super) fn read(mux: &Arc<Mux>, operation: &str, params: Value) -> Value {
    send(mux, operation, params, None)
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"))
}

pub(super) fn error_code(result: Result<Value, ResourceError>) -> String {
    result.expect_err("request unexpectedly succeeded").code
}

/// Every change of every resource batch after `revision`.
pub(super) fn changes_after(mux: &Mux, revision: u64) -> Vec<Value> {
    mux.resource_events_after(revision)
        .unwrap()
        .batches
        .into_iter()
        .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
        .collect()
}

/// `workspace.placement.list` as `session/key -> (index, group_id)`.
pub(super) fn placements_by_id(mux: &Arc<Mux>) -> std::collections::BTreeMap<String, (u64, Value)> {
    let list = read(mux, "workspace.placement.list", json!({}));
    list.as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let id = format!(
                "{}/{}",
                row["workspace"]["session_id"].as_str().unwrap(),
                row["workspace"]["workspace_ref"].as_str().unwrap()
            );
            (id, (row["index"].as_u64().unwrap(), row["group_id"].clone()))
        })
        .collect()
}

/// The placements a client that rebuilds from `session.events` holds:
/// `start` with every `workspace_placement` change after `revision` applied.
pub(super) fn replayed_placements(
    mux: &Mux,
    mut start: std::collections::BTreeMap<String, (u64, Value)>,
    revision: u64,
) -> std::collections::BTreeMap<String, (u64, Value)> {
    for change in changes_after(mux, revision) {
        if change["resource"] != "workspace_placement" {
            continue;
        }
        let id = change["id"].as_str().unwrap().to_string();
        if change["kind"] == "state_delete" {
            start.remove(&id);
        } else {
            let value = &change["value"];
            start.insert(id, (value["index"].as_u64().unwrap(), value["group_id"].clone()));
        }
    }
    start
}

pub(super) fn revision(mux: &Mux) -> u64 {
    mux.with_state(|state| state.resource_revision)
}

pub(super) fn snapshot(mux: &Mux) -> Value {
    crate::resource_api::public_session_snapshot(mux).unwrap()
}

pub(super) fn empty_workspace(mux: &Arc<Mux>, name: &str) -> String {
    let created = mutate(
        mux,
        "workspace.create",
        json!({"name": name, "initial_content": "empty"}),
        &format!("create-{name}"),
    );
    created["workspace_id"].as_str().unwrap().to_string()
}

pub(super) fn tab_id(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| state.resource_indexes.tab_ids[&surface].to_string())
}

pub(super) fn pane_id(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        state.resource_indexes.pane_ids[&pane].to_string()
    })
}

pub(super) fn pane_tab_ids(mux: &Mux, surface: SurfaceId) -> Vec<String> {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        state.panes[&pane]
            .tabs
            .iter()
            .map(|tab| state.resource_indexes.tab_ids[tab].to_string())
            .collect()
    })
}

/// One workspace with one pane holding `count` terminal tabs.
pub(super) fn terminal_tabs(mux: &Arc<Mux>, count: usize) -> Vec<SurfaceId> {
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let mut tabs = vec![first];
    for _ in 1..count {
        tabs.push(mux.new_tab(Some(pane), None, None).unwrap().id);
    }
    tabs
}

/// ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS: a tab carries a user icon (one
/// emoji or an SF Symbol name, the shared icon wire string) on its record,
/// listed in the snapshot so every client shows it; null clears it.
#[test]
fn tab_update_sets_and_clears_a_user_icon() {
    let mux = Mux::new_for_test("state-tab-icon", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 1);
    let tab = tab_id(&mux, tabs[0]);
    let before = revision(&mux);
    let set = mutate(&mux, "tab.update", json!({"tab": tab, "icon": "🚀"}), "icon-1");
    assert_eq!(set["extra"]["icon"], "🚀");
    assert!(
        changes_after(&mux, before)
            .iter()
            .any(|change| change["id"] == tab && change["value"]["extra"]["icon"] == "🚀")
    );
    let symbol = mutate(
        &mux,
        "tab.update",
        json!({"tab": tab, "icon": "hammer.fill", "zoom": 1.25}),
        "icon-2",
    );
    assert_eq!(symbol["extra"]["icon"], "hammer.fill");
    assert_eq!(symbol["extra"]["zoom"], 1.25);
    let listed = snapshot(&mux)["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == tab)
        .unwrap()
        .clone();
    assert_eq!(listed["extra"]["icon"], "hammer.fill");
    // Clearing the zoom keeps the icon; clearing the icon removes it.
    let zoom_cleared = mutate(&mux, "tab.update", json!({"tab": tab, "zoom": null}), "icon-3");
    assert_eq!(zoom_cleared["extra"]["icon"], "hammer.fill");
    let cleared = mutate(&mux, "tab.update", json!({"tab": tab, "icon": null}), "icon-4");
    assert!(cleared["extra"].get("icon").is_none());
    for (index, bad) in ["two words", "🚀🚀", "Hammer", ""].into_iter().enumerate() {
        let key = format!("icon-bad-{index}");
        assert_eq!(
            error_code(send(&mux, "tab.update", json!({"tab": tab, "icon": bad}), Some(&key))),
            "validation.invalid",
            "{bad:?} must be refused"
        );
    }
}

#[test]
fn closed_tabs_and_workspaces_are_recorded_and_reopen() {
    let mux = Mux::new_for_test("state-closed", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let pane = pane_id(&mux, tabs[0]);
    mux.rename_surface(tabs[1], "logs".into());
    let before = revision(&mux);
    assert!(mux.close_surface(tabs[1]).unwrap());
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed[0]["kind"], "tab");
    assert_eq!(closed[0]["name"], "logs");
    assert_eq!(closed[0]["pane_id"], pane);
    assert_eq!(closed[0]["screens"][0]["tabs"][0]["kind"], "terminal");
    assert!(
        changes_after(&mux, before)
            .iter()
            .any(|change| change["kind"] == "state_upsert" && change["resource"] == "closed")
    );
    let closed_id = closed[0]["id"].as_str().unwrap().to_string();

    let reopened = mutate(&mux, "closed.reopen", json!({"closed": closed_id}), "reopen");
    assert_eq!(reopened["kind"], "tab");
    let tab = reopened["tab_ids"][0].as_str().unwrap().to_string();
    assert!(pane_tab_ids(&mux, tabs[0]).contains(&tab));
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
    assert_eq!(
        send(&mux, "closed.reopen", json!({"closed": closed_id}), Some("reopen")).unwrap()["replayed"],
        true
    );
    assert_eq!(
        error_code(send(&mux, "closed.reopen", json!({"closed": closed_id}), Some("reopen-2"))),
        "resource.not_found"
    );

    let workspace = empty_workspace(&mux, "scratch");
    mutate(&mux, "workspace.close", json!({"workspace": workspace}), "close-scratch");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed[0]["kind"], "workspace");
    assert_eq!(closed[0]["name"], "scratch");
    let reopened =
        mutate(&mux, "closed.reopen", json!({"closed": closed[0]["id"]}), "reopen-workspace");
    assert_eq!(reopened["kind"], "workspace");
    let restored = reopened["workspace_id"].as_str().unwrap();
    assert!(
        snapshot(&mux)["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value["id"] == restored && value["name"] == "scratch")
    );
}

/// Closed history records what a user or client closed, not what ended on
/// its own: an explicit tab close leaves a record, a terminal whose process
/// exited (its tab detaches) leaves none. Follow-up with the host-death
/// branch: a lost host (`TerminalEnd::HostLost`, including signal exits
/// during owner shutdown) keeps its tab and must leave no record either.
#[cfg(unix)]
#[test]
fn closed_history_records_explicit_closes_but_not_process_exits() {
    const TERMINAL: &str = "0000000000004000800000000000c105";
    const INCARNATION: &str = "1000000000004000800000000000c105";
    let mux = Mux::new_for_test("state-closed-exit", SurfaceOptions::default());
    let workspace = mux
        .create_empty_workspace(
            Some("exits".into()),
            Some("018f6e21-7b70-7e70-8000-00000000c105".into()),
            None,
        )
        .unwrap();
    let exited = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let pane = mux.with_state(|state| state.pane_of(exited).unwrap());
    let closed = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap().id;
    let kept = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap().id;
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1_000,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());
    mux.surface_exited(exited);
    mux.with_state(|state| assert!(!state.surfaces.contains_key(&exited)));
    assert_eq!(read(&mux, "closed.list", json!({})), json!([]), "a process exit is not a close");

    assert!(mux.close_surface(closed).unwrap());
    let records = read(&mux, "closed.list", json!({}));
    assert_eq!(records.as_array().unwrap().len(), 1, "{records}");
    assert_eq!(records[0]["kind"], "tab");
    mux.with_state(|state| assert!(state.surfaces.contains_key(&kept)));
    mux.shutdown();
}

/// Closed history keeps every group (ARCHIVE-1: retention forever); a
/// list returns the newest `limit` groups (default 100).
#[test]
fn closed_history_keeps_every_group_and_lists_the_newest_limit() {
    let mux = Mux::new_for_test("state-closed-bound", SurfaceOptions::default());
    for index in 0..52 {
        let workspace = empty_workspace(&mux, &format!("w{index}"));
        mutate(&mux, "workspace.close", json!({"workspace": workspace}), &format!("close-{index}"));
    }
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 52);
    assert_eq!(closed[0]["name"], "w51");
    assert_eq!(closed[51]["name"], "w0");
    let newest = read(&mux, "closed.list", json!({"limit": 10}));
    assert_eq!(newest.as_array().unwrap().len(), 10);
    assert_eq!(newest[9]["name"], "w42");
}

#[test]
fn ephemeral_workspaces_are_flagged_unrecorded_and_closed_at_the_next_start() {
    let session = Session::new("ephemeral");
    let mux = session.open();
    let kept = empty_workspace(&mux, "kept");
    let created = mutate(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "empty", "ephemeral": true}),
        "create-ephemeral",
    );
    let ephemeral = created["workspace_id"].as_str().unwrap().to_string();
    let listed = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    let value = listed.iter().find(|value| value["id"] == ephemeral).unwrap();
    assert_eq!(value["extra"]["ephemeral"], true);
    assert!(
        listed.iter().find(|value| value["id"] == kept).unwrap()["extra"]
            .get("ephemeral")
            .is_none()
    );
    // A replay repeats the mark idempotently.
    let replay = send(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "empty", "ephemeral": true}),
        Some("create-ephemeral"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    drop(mux);

    let mux = session.open();
    let workspaces = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    assert!(workspaces.iter().any(|value| value["id"] == kept));
    assert!(!workspaces.iter().any(|value| value["id"] == ephemeral));
    // Incognito content leaves no closed-history record.
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

/// `workspace.create {ephemeral: true}` commits the workspace and its flag
/// in one transaction on both creation paths: no committed read and no
/// `session.events` change ever shows the workspace without the flag.
#[test]
fn ephemeral_workspace_create_commits_the_flag_with_the_workspace() {
    let mux = Mux::new_for_test("state-ephemeral-atomic", SurfaceOptions::default());
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let reader = {
        let mux = Arc::clone(&mux);
        let done = Arc::clone(&done);
        std::thread::spawn(move || {
            let mut observed = 0usize;
            loop {
                let finished = done.load(std::sync::atomic::Ordering::Acquire);
                for value in snapshot(&mux)["workspaces"].as_array().unwrap() {
                    if value["name"].as_str().is_some_and(|name| name.starts_with("incognito-")) {
                        assert_eq!(
                            value["extra"]["ephemeral"], true,
                            "read without the flag: {value}"
                        );
                        observed += 1;
                    }
                }
                if finished {
                    return observed;
                }
            }
        })
    };
    let before = revision(&mux);
    let mut created = Vec::new();
    for index in 0..6 {
        let content = if index % 2 == 0 { "empty" } else { "terminal" };
        let value = mutate(
            &mux,
            "workspace.create",
            json!({"name": format!("incognito-{index}"), "initial_content": content, "ephemeral": true}),
            &format!("atomic-ephemeral-{index}"),
        );
        created.push(value["workspace_id"].as_str().unwrap().to_string());
    }
    done.store(true, std::sync::atomic::Ordering::Release);
    assert!(reader.join().unwrap() > 0, "the reader saw no created workspace");

    let changes = changes_after(&mux, before);
    for workspace in &created {
        let upserts = changes
            .iter()
            .filter(|change| {
                change["kind"] == "upsert"
                    && change["resource"] == "workspace"
                    && change["id"] == workspace.as_str()
            })
            .collect::<Vec<_>>();
        assert!(!upserts.is_empty(), "no upsert for {workspace}");
        for upsert in upserts {
            assert_eq!(
                upsert["value"]["extra"]["ephemeral"], true,
                "event without the flag: {upsert}"
            );
        }
    }
    // The flag is part of the request: the same key without it is a different request.
    let retried = send(
        &mux,
        "workspace.create",
        json!({"name": "incognito-0", "initial_content": "empty"}),
        Some("atomic-ephemeral-0"),
    );
    assert!(retried.is_err(), "a retry that drops the flag replayed: {retried:?}");
    mux.shutdown();
}

#[test]
fn workspace_status_progress_and_bounded_log() {
    let mux = Mux::new_for_test("state-status", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "status");
    let before = revision(&mux);
    let set = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "build", "text": "compiling", "icon": "hammer"}),
        "s1",
    );
    assert_eq!(set["entries"][0]["key"], "build");
    assert_eq!(set["entries"][0]["icon"], "hammer");
    mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "tests", "text": "queued"}),
        "s2",
    );
    let replaced = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "build", "text": "done"}),
        "s3",
    );
    assert_eq!(replaced["entries"][0]["text"], "done");
    assert_eq!(replaced["entries"][1]["key"], "tests");
    let progress = mutate(
        &mux,
        "workspace_progress.set",
        json!({"workspace": workspace, "value": 0.25, "label": "step 1"}),
        "p1",
    );
    assert_eq!(progress["progress"]["value"], 0.25);
    let indeterminate = mutate(
        &mux,
        "workspace_progress.set",
        json!({"workspace": workspace, "value": null}),
        "p2",
    );
    assert!(indeterminate["progress"]["value"].is_null());
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_progress.set",
            json!({"workspace": workspace, "value": 1.5}),
            Some("p3")
        )),
        "validation.invalid"
    );

    for index in 0..201 {
        mutate(
            &mux,
            "workspace_log.append",
            json!({"workspace": workspace, "text": format!("line {index}")}),
            &format!("log-{index}"),
        );
    }
    let lines = read(&mux, "workspace_log.list", json!({"workspace": workspace}));
    assert_eq!(lines.as_array().unwrap().len(), 200);
    assert_eq!(lines[0]["text"], "line 1");
    assert_eq!(lines[199]["text"], "line 200");
    assert_eq!(
        read(&mux, "workspace_log.list", json!({"workspace": workspace, "limit": 2}))[1]["text"],
        "line 200"
    );
    let listed = read(&mux, "workspace_status.list", json!({}));
    assert_eq!(listed[0]["log_count"], 200);
    assert_eq!(listed[0]["last_log"]["level"], "info");
    assert!(
        changes_after(&mux, before)
            .iter()
            .any(|change| change["kind"] == "state_upsert"
                && change["resource"] == "workspace_status")
    );

    let cleared = mutate(
        &mux,
        "workspace_status.clear",
        json!({"workspace": workspace, "key": "build"}),
        "c1",
    );
    assert_eq!(cleared["entries"].as_array().unwrap().len(), 1);
    let cleared = mutate(&mux, "workspace_progress.clear", json!({"workspace": workspace}), "c2");
    assert!(cleared["progress"].is_null());
    let cleared = mutate(&mux, "workspace_log.clear", json!({"workspace": workspace}), "c3");
    assert_eq!(cleared["log_count"], 0);
    let cleared = mutate(&mux, "workspace_status.clear", json!({"workspace": workspace}), "c4");
    assert!(cleared["entries"].as_array().unwrap().is_empty());
    assert!(read(&mux, "workspace_status.list", json!({})).as_array().unwrap().is_empty());
}
