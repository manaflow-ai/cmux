use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use mux_core::{Mux, MuxEvent, PaneOptions};

fn wait_for<T>(mut f: impl FnMut() -> Option<T>, timeout: Duration) -> Option<T> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Some(v) = f() {
            return Some(v);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

#[test]
fn pane_runs_command_and_screen_updates() {
    let mut opts = PaneOptions::default();
    opts.command = Some(vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        "printf 'marker-42\\n'; sleep 30".to_string(),
    ]);
    let mux = Mux::new("test-pty", opts);
    let events = mux.subscribe();
    let pane = mux.new_workspace(None).unwrap();

    // Output event arrives...
    let got = wait_for(
        || {
            events
                .try_iter()
                .find(|e| matches!(e, MuxEvent::PaneOutput(id) if *id == pane.id))
        },
        Duration::from_secs(10),
    );
    assert!(got.is_some(), "no PaneOutput event");

    // ...and the ghostty-backed screen contains the marker.
    let text = wait_for(
        || {
            let text = pane.with_terminal(|t| t.plain_text()).unwrap();
            text.contains("marker-42").then_some(text)
        },
        Duration::from_secs(10),
    );
    assert!(text.is_some(), "marker never appeared on screen");

    mux.close_pane(pane.id);
}

#[test]
fn pane_exit_emits_event() {
    let mut opts = PaneOptions::default();
    opts.command = Some(vec!["/usr/bin/true".to_string()]);
    let mux = Mux::new("test-exit", opts);
    let events = mux.subscribe();
    let pane = mux.new_workspace(None).unwrap();

    let got = wait_for(
        || {
            events
                .try_iter()
                .find(|e| matches!(e, MuxEvent::PaneExited(id) if *id == pane.id))
        },
        Duration::from_secs(10),
    );
    assert!(got.is_some(), "no PaneExited event");
    assert!(pane.is_dead());
}

#[test]
fn control_socket_round_trip() {
    let mut opts = PaneOptions::default();
    opts.command = Some(vec![
        "/bin/sh".to_string(),
        "-c".to_string(),
        "printf 'socket-check\\n'; sleep 30".to_string(),
    ]);
    let mux = Mux::new(format!("test-sock-{}", std::process::id()), opts);
    let pane = mux.new_workspace(None).unwrap();

    let sock_path = mux_core::server::serve(mux.clone(), None).unwrap();
    let stream = UnixStream::connect(&sock_path).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let mut reader = BufReader::new(stream);

    let mut line = String::new();

    writeln!(writer, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["app"], "cmux-mux");

    line.clear();
    writeln!(writer, r#"{{"id":2,"cmd":"list-workspaces"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(
        v["data"]["workspaces"][0]["tabs"][0]["panes"][0]["id"],
        pane.id
    );

    // Wait for the marker to hit the screen, then read it over the socket.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        line.clear();
        writeln!(writer, r#"{{"id":3,"cmd":"read-screen","pane":{}}}"#, pane.id).unwrap();
        reader.read_line(&mut line).unwrap();
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["ok"], true, "read-screen failed: {line}");
        if v["data"]["text"].as_str().unwrap_or("").contains("socket-check") {
            break;
        }
        assert!(Instant::now() < deadline, "marker never visible via socket");
        std::thread::sleep(Duration::from_millis(50));
    }

    mux.close_pane(pane.id);
    mux_core::server::cleanup(&sock_path);
}

#[test]
fn new_tab_on_empty_headless_session_creates_workspace() {
    // A headless session receives new-tab before any workspace exists;
    // this used to index workspaces[0] and panic.
    let mut opts = PaneOptions::default();
    opts.command = Some(vec!["/bin/cat".to_string()]);
    let mux = Mux::new("test-headless", opts);
    let pane = mux.new_tab(None, None).unwrap();
    mux.with_tree(|ws, _| {
        assert_eq!(ws.len(), 1);
        assert_eq!(ws[0].tabs.len(), 1);
    });

    // Unknown workspace ids error without leaking a pane.
    let before = mux.pane_count();
    assert!(mux.new_tab(Some(9999), None).is_err());
    assert_eq!(mux.pane_count(), before);

    mux.close_pane(pane.id);
}
