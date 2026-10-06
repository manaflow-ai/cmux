//! A Chief (or any script) in an app-owned session: `workspace <id> focus`
//! must move the app's window, and `focused` must say what the window
//! shows, not the daemon default a `workspace create` moved (chwsr1 E2E:
//! the Chief focused a workspace and the window stayed on Home; after a
//! create it told the user cmux had probably switched them).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;

/// An app control socket that answers each request with the next response
/// and returns what it received.
fn fake_app(responses: Vec<Value>) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
    let dir = cmux_unix_socket::short_test_dir("cmux-focus");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut received = Vec::new();
        let mut responses = responses.into_iter();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            received.push(serde_json::from_str::<Value>(&line).unwrap());
            line.clear();
            let Some(response) = responses.next() else { break };
            writeln!(writer, "{response}").unwrap();
        }
        drop(dir);
        received
    });
    (socket, handle)
}

fn ok(result: Value) -> Value {
    json!({"id": 1, "ok": true, "result": result})
}

#[test]
fn workspace_focus_runs_the_apps_go_to_workspace() {
    let (socket, app) = fake_app(vec![ok(json!({"ran": true}))]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!({"revision": "43", "value": {"id": "ws_b", "focused": true}});
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::WorkspaceFocus), &mut reply)
        .unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received.len(), 1, "{received:?}");
    assert_eq!(received[0]["method"], "action.run");
    assert_eq!(received[0]["params"]["action"], "goToWorkspace");
    assert_eq!(received[0]["params"]["args"]["workspace"], "ws_b");
    assert_eq!(received[0]["params"]["focus"], true);
}

#[test]
fn tab_focus_runs_the_apps_tab_focus() {
    let (socket, app) = fake_app(vec![ok(json!({"ran": true}))]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!({"value": {"id": "tab_1", "focused": true}});
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::TabFocus), &mut reply).unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received.len(), 1, "{received:?}");
    assert_eq!(received[0]["params"]["action"], "tab.focus");
    assert_eq!(received[0]["params"]["target"], "tab_1");
}

#[test]
fn an_app_that_does_not_own_the_workspace_leaves_the_daemons_answer() {
    let (socket, app) = fake_app(vec![
        json!({"id": 1, "ok": false, "error": {"code": "not_found", "message": "no workspace"}}),
    ]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!({"value": {"id": "ws_other", "focused": true}});
    assert!(
        after_daemon_with(&mut stream, &follow_for(ResourceOperation::WorkspaceFocus), &mut reply)
            .is_ok()
    );
    drop(stream);
    app.join().unwrap();
}

#[test]
fn workspace_list_reports_the_workspace_the_app_window_shows() {
    // The daemon default moved to the created ws_new; the window shows Home.
    let (socket, app) = fake_app(vec![ok(json!({
        "topology": {"focus": {"workspace": "ws_home", "pane": "pane_1"}}
    }))]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!([
        {"id": "ws_home", "name": "Home", "focused": false},
        {"id": "ws_new", "name": "workspace-2", "focused": true}
    ]);
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::WorkspaceList), &mut reply)
        .unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received[0]["method"], "snapshot.get");
    assert_eq!(reply[0]["focused"], true, "{reply}");
    assert_eq!(reply[1]["focused"], false, "{reply}");
}

#[test]
fn focused_stays_the_daemons_when_the_app_shows_another_sessions_workspace() {
    let mut reply =
        json!({"value": [{"id": "ws_a", "focused": true}, {"id": "ws_b", "focused": false}]});
    assert!(!overlay_focused(&mut reply, "ws_elsewhere"));
    assert_eq!(reply["value"][0]["focused"], true);
    assert!(overlay_focused(&mut reply, "ws_b"));
    assert_eq!(reply["value"][0]["focused"], false);
    assert_eq!(reply["value"][1]["focused"], true);
}

#[test]
fn only_focus_and_workspace_reads_involve_the_app() {
    assert_eq!(follow_for(ResourceOperation::WorkspaceCreate), Follow::Nothing);
    assert_eq!(follow_for(ResourceOperation::PaneSplit), Follow::Nothing);
    assert_eq!(follow_for(ResourceOperation::WorkspaceList), Follow::Focused);
}
