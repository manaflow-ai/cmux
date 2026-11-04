//! Discovery before approval (D21) through the worker, with an injected
//! desktop: pid 102 gedit (window 9001), pid 100 xterm (a terminal, window
//! 9000), pid 103 keepassxc (window 9003), pid 104 cmux-tui (window 9004),
//! pid 105 firefox (windows 9005 and 9006). Every upstream answer carries a
//! title, so a leak would show.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{App, Enumerator, TITLES_HIDDEN, Window, Windows};
use crate::approval::Target;
use crate::config::{ComputerUseConfig, Mode};
use crate::worker::Worker;
use crate::worker::driver::{CallError, Driver, DriverSession, SessionSpec};

struct Desktop {
    windows: Windows,
}

fn app(pid: u32) -> Option<App> {
    let executable = match pid {
        100 => "/usr/bin/xterm",
        102 => "/usr/bin/gedit",
        103 => "/usr/bin/keepassxc",
        104 => "/usr/bin/cmux-tui",
        105 => "/usr/lib/firefox/firefox",
        _ => return None,
    };
    Some(App::of(pid, std::path::Path::new(executable)))
}

impl Enumerator for Desktop {
    fn apps(&self) -> Vec<App> {
        [105, 100, 102, 103, 104, 102].into_iter().filter_map(app).collect()
    }
    fn windows(&self) -> Windows {
        self.windows.clone()
    }
    fn app_for_pid(&self, pid: u32) -> Option<App> {
        app(pid)
    }
}

fn listed() -> Windows {
    Windows::Listed(
        [(100, 9000), (102, 9001), (103, 9003), (104, 9004), (105, 9005), (105, 9006)]
            .into_iter()
            .map(|(pid, window_id)| Window { pid, window_id })
            .collect(),
    )
}

#[derive(Default)]
struct Upstream {
    calls: Mutex<Vec<(String, Value)>>,
}

struct UpstreamSession(Arc<Upstream>);

#[async_trait]
impl DriverSession for UpstreamSession {
    async fn call(&self, tool: &str, arguments: Value) -> Result<Value, CallError> {
        self.0.calls.lock().unwrap().push((tool.to_owned(), arguments.clone()));
        let pid = arguments.get("pid").cloned().unwrap_or(json!(102));
        Ok(json!({
            "content": [{"type": "text", "text": "upstream: \"Secret plan.txt - gedit\""}],
            "isError": false,
            "structuredContent": {"windows": [{"window_id": 9001, "pid": pid, "title": "Secret plan.txt - gedit"}]},
        }))
    }
    fn close(&self) {}
}

struct FakeDriver(Arc<Upstream>);

#[async_trait]
impl Driver for FakeDriver {
    async fn tools(&self) -> Result<Value, String> {
        Ok(json!([
            {"name": "list_apps", "annotations": {"readOnlyHint": true}},
            {"name": "list_windows", "annotations": {"readOnlyHint": true}},
            {"name": "click"},
            {"name": "get_window_state", "annotations": {"readOnlyHint": true}},
        ]))
    }
    fn session(&self, _spec: &SessionSpec) -> Result<Arc<dyn DriverSession>, String> {
        Ok(Arc::new(UpstreamSession(Arc::clone(&self.0))))
    }
}

async fn worker_with(mode: Mode, windows: Windows, name: &str) -> (Arc<Worker>, Arc<Upstream>) {
    let upstream = Arc::new(Upstream::default());
    let config = ComputerUseConfig { mode, ..ComputerUseConfig::default() };
    let dir = std::env::temp_dir().join(format!("cmux-cu-discovery-{name}-{}", std::process::id()));
    let worker = Worker::detached(Ok(config), Arc::new(FakeDriver(Arc::clone(&upstream))), Arc::new(Desktop { windows }), dir)
        .await
        .unwrap();
    (worker, upstream)
}

fn upstream_tools(upstream: &Upstream) -> Vec<String> {
    upstream.calls.lock().unwrap().iter().map(|(tool, _)| tool.clone()).collect()
}

fn gedit() -> Target {
    app(102).unwrap().target()
}

/// No title, from upstream or anywhere else, in what the agent sees.
fn assert_no_titles(result: &Value) {
    let text = result.to_string();
    assert!(!text.contains("Secret plan"), "a title leaked: {text}");
    assert!(!text.contains("\"title\""), "a title field leaked: {text}");
    assert_eq!(result["structuredContent"]["titles"], TITLES_HIDDEN);
    assert_eq!(result["isError"], false);
    assert!(result["content"][0]["text"].as_str().unwrap().contains(TITLES_HIDDEN));
}

#[tokio::test]
async fn ask_lists_apps_without_upstream_and_omits_never_allowed_apps() {
    let (worker, upstream) = worker_with(Mode::Ask, listed(), "apps").await;
    let session = worker.open_session("s1");
    let result = worker.call(&session, "list_apps", json!({})).await.unwrap();
    assert_no_titles(&result);
    assert!(upstream_tools(&upstream).is_empty(), "upstream refuses unscoped discovery; the worker answers it");
    let apps = result["structuredContent"]["apps"].as_array().unwrap();
    let pids: Vec<u64> = apps.iter().map(|app| app["pid"].as_u64().unwrap()).collect();
    assert_eq!(pids, vec![105, 102], "firefox and gedit once each; xterm, keepassxc and cmux-tui left out");
    assert_eq!(apps[1], json!({"pid": 102, "name": "gedit", "executable": "/usr/bin/gedit", "running": true}));
    let text = result["content"][0]["text"].as_str().unwrap();
    assert!(!text.contains("xterm") && !text.contains("keepassxc") && !text.contains("cmux"), "{text}");
}

#[tokio::test]
async fn ask_lists_windows_as_ids_and_owners_only() {
    let (worker, upstream) = worker_with(Mode::Ask, listed(), "windows").await;
    let session = worker.open_session("s1");
    let result = worker.call(&session, "list_windows", json!({})).await.unwrap();
    assert_no_titles(&result);
    assert!(upstream_tools(&upstream).is_empty());
    let windows = result["structuredContent"]["windows"].as_array().unwrap();
    let ids: Vec<u64> = windows.iter().map(|window| window["window_id"].as_u64().unwrap()).collect();
    assert_eq!(ids, vec![9001, 9005, 9006]);
    assert_eq!(
        windows[0],
        json!({"window_id": 9001, "pid": 102, "app_name": "gedit", "executable": "/usr/bin/gedit"}),
        "exactly these fields: no title, no frame"
    );
}

#[tokio::test]
async fn an_ungranted_pid_gets_metadata_and_a_granted_pid_goes_upstream() {
    let (worker, upstream) = worker_with(Mode::Ask, listed(), "scoped").await;
    let session = worker.open_session("s1");
    let before = worker.call(&session, "list_windows", json!({"pid": 105})).await.unwrap();
    assert_no_titles(&before);
    let ids: Vec<u64> = before["structuredContent"]["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|window| window["window_id"].as_u64().unwrap())
        .collect();
    assert_eq!(ids, vec![9005, 9006], "only that pid's windows");
    assert!(upstream_tools(&upstream).is_empty(), "no question and no upstream call before the grant");
    worker.allow_for_session(&session, gedit());
    let after = worker.call(&session, "list_windows", json!({"pid": 102})).await.unwrap();
    assert_eq!(upstream_tools(&upstream), vec!["list_windows"], "the granted app's list is upstream's, titles included");
    assert!(after.to_string().contains("Secret plan"));
    let other = worker.call(&session, "list_windows", json!({"pid": 105})).await.unwrap();
    assert_no_titles(&other);
    assert_eq!(upstream_tools(&upstream).len(), 1, "another session's grant or another app stays metadata only");
}

#[tokio::test]
async fn a_never_allowed_pid_is_refused_not_listed() {
    let (worker, upstream) = worker_with(Mode::Ask, listed(), "refused").await;
    let session = worker.open_session("s1");
    let error = worker.call(&session, "list_windows", json!({"pid": 103})).await.unwrap_err();
    assert_eq!(error.code.as_deref(), Some("target_refused"));
    assert!(upstream_tools(&upstream).is_empty());
}

#[tokio::test]
async fn a_window_id_resolves_through_the_workers_list() {
    // Under ask upstream refuses the unscoped list the resolver used to read;
    // the worker's own list names gedit, and gedit is asked about (no collector here).
    let (worker, upstream) = worker_with(Mode::Ask, listed(), "window").await;
    let session = worker.open_session("s1");
    let error = worker.call(&session, "click", json!({"window_id": 9001, "x": 1, "y": 1})).await.unwrap_err();
    assert_eq!(error.code.as_deref(), Some("approval_unavailable"), "{error:?}");
    assert!(error.message.contains("gedit"), "{}", error.message);
    assert!(upstream_tools(&upstream).is_empty());
}

#[tokio::test]
async fn wayland_says_windows_are_unavailable() {
    let (worker, _) = worker_with(Mode::Ask, Windows::Unavailable("Wayland has no window list for clients".into()), "wayland").await;
    let session = worker.open_session("s1");
    let result = worker.call(&session, "list_windows", json!({})).await.unwrap();
    assert_no_titles(&result);
    assert_eq!(result["structuredContent"]["windows"], json!([]));
    assert_eq!(result["structuredContent"]["windows_unavailable"], "Wayland has no window list for clients");
    let apps = worker.call(&session, "list_apps", json!({})).await.unwrap();
    assert_eq!(apps["structuredContent"]["apps"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn standard_and_unrestricted_modes_are_untouched() {
    for mode in [Mode::Standard, Mode::Unrestricted] {
        let (worker, upstream) = worker_with(mode, listed(), mode.as_str()).await;
        let session = worker.open_session("s1");
        worker.call(&session, "list_apps", json!({})).await.unwrap();
        let windows = worker.call(&session, "list_windows", json!({})).await.unwrap();
        assert!(windows.to_string().contains("Secret plan"), "upstream answers in {mode:?}");
        assert_eq!(upstream_tools(&upstream), vec!["list_apps", "list_windows"]);
    }
}

#[test]
fn an_owner_manifest_with_the_display_leaves_discovery_upstream() {
    let with: Value = serde_yaml_ng::from_str("version: 3\nresources:\n  desktop:\n    display: true\n").unwrap();
    let without: Value = serde_yaml_ng::from_str("version: 3\nresources:\n  apps: []\n").unwrap();
    assert!(crate::worker::manifest_grants_display(&with));
    assert!(!crate::worker::manifest_grants_display(&without));
}

/// Review 3 #2: a bounded owner decides which tools exist. Discovery the owner's manifest
/// does not allow is not answered by the worker (upstream refuses it).
#[test]
fn a_bounded_owner_manifest_lists_the_tools_discovery_may_answer() {
    let allows: Value =
        serde_yaml_ng::from_str("version: 3\nallow:\n  tools: [list_apps, click]\nresources:\n  apps: []\n").unwrap();
    let narrow: Value = serde_yaml_ng::from_str("version: 3\nallow:\n  tools: [click]\n").unwrap();
    assert_eq!(crate::worker::tools_of_manifest(&allows), vec!["list_apps".to_owned(), "click".to_owned()]);
    assert_eq!(crate::worker::tools_of_manifest(&narrow), vec!["click".to_owned()]);
    assert!(crate::worker::tools_of_manifest(&json!({"version": 3})).is_empty());
}

/// A window the worker's list does not have (one it dropped: no trustworthy pid, such as a
/// forwarded one) stays unresolved, in every mode; upstream's `_NET_WM_PID` is never asked
/// for it (review 3 re-review #1).
#[tokio::test]
async fn a_window_the_list_dropped_is_never_resolved_through_upstream() {
    for mode in [Mode::Ask, Mode::Standard] {
        let (worker, upstream) = worker_with(mode, listed(), "dropped-window").await;
        let session = worker.open_session("s1");
        let error = worker.call(&session, "click", json!({"window_id": 77_777, "x": 1, "y": 1})).await.unwrap_err();
        assert_eq!(error.code.as_deref(), Some("target_unresolved"), "{mode:?}: {error:?}");
        assert!(upstream_tools(&upstream).is_empty(), "{mode:?}: upstream was asked: {:?}", upstream_tools(&upstream));
        session.close();
    }
}
