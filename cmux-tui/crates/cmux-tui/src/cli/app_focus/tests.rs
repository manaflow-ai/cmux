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
    assert!(!overlay_focused(&mut reply, &AppWorkspaces::showing("ws_elsewhere")));
    assert_eq!(reply["value"][0]["focused"], true);
    let other_session = AppWorkspaces {
        shown: "ws_elsewhere".into(),
        known: ["ws_elsewhere".to_owned()].into_iter().collect(),
    };
    assert!(!overlay_focused(&mut reply, &other_session));
    assert_eq!(reply["value"][0]["focused"], true);
    assert!(overlay_focused(&mut reply, &AppWorkspaces::showing("ws_b")));
    assert_eq!(reply["value"][0]["focused"], false);
    assert_eq!(reply["value"][1]["focused"], true);
}

#[test]
fn workspace_show_of_a_workspace_the_window_does_not_show_is_not_focused() {
    // `workspace <new> show` right after a create: the daemon default moved
    // to ws_new, the window still shows Home. A Claude Code proof run read
    // `"focused": true` here and could not tell whether cmux stole focus.
    let (socket, app) = fake_app(vec![ok(json!({
        "topology": {"focus": {"workspace": "ws_home"},
            "workspaces": [{"id": "ws_home"}, {"id": "ws_new"}]}
    }))]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!({"id": "ws_new", "name": "proof", "focused": true});
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::WorkspaceGet), &mut reply)
        .unwrap();
    drop(stream);
    app.join().unwrap();
    assert_eq!(reply["focused"], false, "{reply}");
}

#[test]
fn only_focus_and_workspace_reads_involve_the_app() {
    assert_eq!(follow_for(ResourceOperation::WorkspaceCreate), Follow::Nothing);
    assert_eq!(follow_for(ResourceOperation::PaneSplit), Follow::Nothing);
    assert_eq!(follow_for(ResourceOperation::WorkspaceList), Follow::Focused);
}

#[test]
fn pane_focus_runs_the_apps_pane_focus() {
    let (socket, app) = fake_app(vec![ok(json!({"ran": true}))]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!({"value": {"id": "pane_1", "focused": true}});
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::PaneFocus), &mut reply).unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received.len(), 1, "{received:?}");
    assert_eq!(received[0]["params"]["action"], "pane.focus");
    assert_eq!(received[0]["params"]["target"], "pane_1");
}

#[test]
fn screen_focus_runs_the_apps_screen_focus() {
    let (socket, app) = fake_app(vec![ok(json!({"ran": true}))]);
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!({"value": {"id": "screen_1", "focused": true}});
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::ScreenFocus), &mut reply)
        .unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received.len(), 1, "{received:?}");
    assert_eq!(received[0]["params"]["action"], "screen.focus");
    assert_eq!(received[0]["params"]["target"], "screen_1");
}

/// An app whose read barrier never settles: a request with `after: "sync"`
/// gets the app's own deadline error (its main actor is busy publishing,
/// TYPING UNDER LOAD L6), any other request the window's snapshot.
fn busy_app(snapshot: Value) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
    let dir = cmux_unix_socket::short_test_dir("cmux-focus-busy");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut received = Vec::new();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            let request = serde_json::from_str::<Value>(&line).unwrap();
            line.clear();
            let response = if request["params"]["after"] == "sync" {
                json!({"id": 1, "ok": false,
                       "error": {"code": "timeout", "message": "snapshot.get timed out after 2 s"}})
            } else {
                ok(snapshot.clone())
            };
            received.push(request);
            writeln!(writer, "{response}").unwrap();
        }
        drop(dir);
        received
    });
    (socket, handle)
}

/// CLI-1 (TYPING UNDER LOAD, STATUS 6290): `workspace list` asked the app
/// which workspace its window shows with the read barrier `after: "sync"`,
/// which waits for the app's main actor to publish a snapshot past a daemon
/// round trip. Under load each try hit the app's 2 s deadline and the CLI
/// asked twice: a 4.1 s list. Which workspace a window shows is the app's
/// own state, which no daemon write of the caller changes (focus goes
/// through the app's focus actions), so the overlay reads the published
/// snapshot and never waits for the main actor.
#[test]
fn workspace_list_reads_the_window_without_waiting_for_the_apps_read_barrier() {
    let (socket, app) = busy_app(json!({
        "topology": {"focus": {"workspace": "ws_home"},
            "workspaces": [{"id": "ws_home"}, {"id": "ws_new"}]}
    }));
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!([
        {"id": "ws_home", "name": "Home", "focused": false},
        {"id": "ws_new", "name": "workspace-2", "focused": true}
    ]);
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::WorkspaceList), &mut reply)
        .unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received.len(), 1, "one snapshot read, no retry: {received:?}");
    assert_eq!(received[0]["params"]["after"], 0, "{received:?}");
    assert_eq!(reply[0]["focused"], true, "{reply}");
    assert_eq!(reply[1]["focused"], false, "{reply}");
}

/// An app whose published snapshot is older than the caller's last daemon
/// write: `after: 0` answers the old window, `after: "sync"` the new one.
fn lagging_app(published: Value, synced: Value) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
    let dir = cmux_unix_socket::short_test_dir("cmux-focus-lag");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut received = Vec::new();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            let request = serde_json::from_str::<Value>(&line).unwrap();
            line.clear();
            let snapshot = if request["params"]["after"] == "sync" {
                synced.clone()
            } else {
                published.clone()
            };
            received.push(request);
            writeln!(writer, "{}", ok(snapshot)).unwrap();
        }
        drop(dir);
        received
    });
    (socket, handle)
}

/// Review of #32201: `workspace close <shown>; workspace list`. The app's
/// last published snapshot can still show the closed workspace. A list in
/// which the window's workspace is missing is older than the caller's
/// write, so it reads the window once more with the read barrier.
#[test]
fn a_list_without_the_window_s_workspace_reads_the_window_again_with_the_barrier() {
    let (socket, app) = lagging_app(
        json!({"topology": {"focus": {"workspace": "ws_closed"},
            "workspaces": [{"id": "ws_closed"}, {"id": "ws_a"}, {"id": "ws_b"}]}}),
        json!({"topology": {"focus": {"workspace": "ws_b"},
            "workspaces": [{"id": "ws_a"}, {"id": "ws_b"}]}}),
    );
    let mut stream = UnixStream::connect(&socket).unwrap();
    let mut reply = json!([
        {"id": "ws_a", "name": "a", "focused": false},
        {"id": "ws_b", "name": "b", "focused": false}
    ]);
    after_daemon_with(&mut stream, &follow_for(ResourceOperation::WorkspaceList), &mut reply)
        .unwrap();
    drop(stream);
    let received = app.join().unwrap();
    assert_eq!(received.len(), 2, "{received:?}");
    assert_eq!(received[0]["params"]["after"], 0, "{received:?}");
    assert_eq!(received[1]["params"]["after"], "sync", "{received:?}");
    assert_eq!(reply[0]["focused"], false, "{reply}");
    assert_eq!(reply[1]["focused"], true, "{reply}");
}
