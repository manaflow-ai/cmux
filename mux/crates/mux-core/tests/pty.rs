use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use ghostty_vt::RenderState;
use mux_core::{DefaultColors, Mux, MuxEvent, Rgb, SurfaceOptions};

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

fn shell_opts(script: &str) -> SurfaceOptions {
    SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), script.to_string()]),
        ..Default::default()
    }
}

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

fn read_json_line(reader: &mut BufReader<UnixStream>) -> Option<serde_json::Value> {
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) => None,
        Ok(_) => serde_json::from_str(&line).ok(),
        Err(e)
            if matches!(
                e.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            None
        }
        Err(e) => panic!("socket read failed: {e}"),
    }
}

#[test]
fn surface_runs_command_and_screen_updates() {
    let mux = Mux::new("test-pty", shell_opts("printf 'marker-42\\n'; sleep 30"));
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, None).unwrap();

    // Output event arrives...
    let got = wait_for(
        || {
            events
                .try_iter()
                .find(|e| matches!(e, MuxEvent::SurfaceOutput(id) if *id == surface.id))
        },
        Duration::from_secs(10),
    );
    assert!(got.is_some(), "no SurfaceOutput event");

    // ...and the ghostty-backed screen contains the marker.
    let text = wait_for(
        || {
            let text = surface.with_terminal(|t| t.plain_text()).unwrap().unwrap();
            text.contains("marker-42").then_some(text)
        },
        Duration::from_secs(10),
    );
    assert!(text.is_some(), "marker never appeared on screen");

    mux.close_surface(surface.id);
}

#[test]
fn surface_resize_reports_whether_the_size_changed() {
    let mux = Mux::new(unique_session("test-resize-bool"), shell_opts("sleep 30"));
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    assert!(!surface.resize(80, 24));
    assert_eq!(surface.size(), (80, 24));
    assert!(surface.resize(100, 40));
    assert_eq!(surface.size(), (100, 40));
    assert!(!surface.resize(100, 40));
    assert!(surface.resize(0, 0));
    assert_eq!(surface.size(), (1, 1));
    assert!(!surface.resize(0, 0));

    mux.close_surface(surface.id);
}

#[test]
fn surface_exit_reaps_tree_and_emits_event() {
    let opts =
        SurfaceOptions { command: Some(vec!["/usr/bin/true".to_string()]), ..Default::default() };
    let mux = Mux::new("test-exit", opts);
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, None).unwrap();

    let got = wait_for(
        || {
            events
                .try_iter()
                .find(|e| matches!(e, MuxEvent::SurfaceExited(id) if *id == surface.id))
        },
        Duration::from_secs(10),
    );
    assert!(got.is_some(), "no SurfaceExited event");
    assert!(surface.is_dead());
    // The mux reaps exited surfaces itself; the emptied workspace is gone.
    let reaped = wait_for(
        || mux.with_state(|s| s.workspaces.is_empty().then_some(())),
        Duration::from_secs(10),
    );
    assert!(reaped.is_some(), "exited surface not reaped from tree");
}

#[test]
fn control_socket_round_trip() {
    let mux =
        Mux::new(unique_session("test-sock"), shell_opts("printf 'socket-check\\n'; sleep 30"));
    let surface = mux.new_workspace(None, None).unwrap();

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
    let screen = &v["data"]["workspaces"][0]["screens"][0];
    assert_eq!(screen["panes"][0]["tabs"][0]["surface"], surface.id);
    assert_eq!(screen["active"], true);

    // Rename the workspace, its screen, and its pane over the socket.
    let ws_id = v["data"]["workspaces"][0]["id"].as_u64().unwrap();
    let screen_id = screen["id"].as_u64().unwrap();
    let pane_id = screen["panes"][0]["id"].as_u64().unwrap();
    let surface_id = screen["panes"][0]["tabs"][0]["surface"].as_u64().unwrap();
    for (id, cmd) in [
        (
            3,
            format!(
                r#"{{"id":3,"cmd":"rename-workspace","workspace":{ws_id},"name":"renamed-ws"}}"#
            ),
        ),
        (4, format!(r#"{{"id":4,"cmd":"rename-pane","pane":{pane_id},"name":"renamed-pane"}}"#)),
        (
            5,
            format!(
                r#"{{"id":5,"cmd":"rename-screen","screen":{screen_id},"name":"renamed-screen"}}"#
            ),
        ),
        (
            6,
            format!(
                r#"{{"id":6,"cmd":"rename-surface","surface":{surface_id},"name":"renamed-tab"}}"#
            ),
        ),
    ] {
        line.clear();
        writeln!(writer, "{cmd}").unwrap();
        reader.read_line(&mut line).unwrap();
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["ok"], true, "request {id} failed: {line}");
    }
    line.clear();
    writeln!(writer, r#"{{"id":7,"cmd":"list-workspaces"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["data"]["workspaces"][0]["name"], "renamed-ws");
    let screen = &v["data"]["workspaces"][0]["screens"][0];
    assert_eq!(screen["name"], "renamed-screen");
    assert_eq!(screen["panes"][0]["name"], "renamed-pane");
    assert_eq!(screen["panes"][0]["tabs"][0]["name"], "renamed-tab");

    // New tab in the pane: two tabs, second active.
    line.clear();
    writeln!(writer, r#"{{"id":8,"cmd":"new-tab","pane":{pane_id}}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "new-tab failed: {line}");

    // Split and resize the split ratio over the socket.
    line.clear();
    writeln!(writer, r#"{{"id":9,"cmd":"split","pane":{pane_id},"dir":"right"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "split failed: {line}");

    line.clear();
    writeln!(writer, r#"{{"id":10,"cmd":"set-ratio","pane":{pane_id},"dir":"right","ratio":0.7}}"#)
        .unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "set-ratio failed: {line}");

    // New screen in the workspace: two screens, second active.
    line.clear();
    writeln!(writer, r#"{{"id":11,"cmd":"new-screen"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "new-screen failed: {line}");

    line.clear();
    writeln!(writer, r#"{{"id":11,"cmd":"list-workspaces"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    let ws = &v["data"]["workspaces"][0];
    let pane = &ws["screens"][0]["panes"][0];
    assert_eq!(pane["tabs"].as_array().unwrap().len(), 2);
    assert_eq!(pane["active_tab"], 1);
    let ratio = ws["screens"][0]["layout"]["ratio"].as_f64().unwrap();
    assert!((ratio - 0.7).abs() < 0.0001, "layout ratio was {ratio}");
    assert_eq!(ws["screens"].as_array().unwrap().len(), 2);
    assert_eq!(ws["screens"][1]["active"], true);

    // Wait for the marker to hit the screen, then read it over the socket.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        line.clear();
        writeln!(writer, r#"{{"id":12,"cmd":"read-screen","surface":{}}}"#, surface.id).unwrap();
        reader.read_line(&mut line).unwrap();
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["ok"], true, "read-screen failed: {line}");
        if v["data"]["text"].as_str().unwrap_or("").contains("socket-check") {
            break;
        }
        assert!(Instant::now() < deadline, "marker never visible via socket");
        std::thread::sleep(Duration::from_millis(50));
    }

    mux.close_workspace(ws_id);
    mux_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_set_default_colors_merges_fields() {
    let opts = SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new(format!("test-colors-{}", std::process::id()), opts);
    let sock_path = mux_core::server::serve(mux.clone(), None).unwrap();
    let stream = UnixStream::connect(&sock_path).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    writeln!(writer, r##"{{"id":1,"cmd":"set-default-colors","fg":"#010203"}}"##).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "set-default-colors failed: {line}");
    assert_eq!(
        mux.default_colors(),
        DefaultColors { fg: Some(Rgb { r: 1, g: 2, b: 3 }), bg: None }
    );

    line.clear();
    writeln!(writer, r##"{{"id":2,"cmd":"set-default-colors","bg":"#131415"}}"##).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "set-default-colors failed: {line}");
    assert_eq!(
        mux.default_colors(),
        DefaultColors {
            fg: Some(Rgb { r: 1, g: 2, b: 3 }),
            bg: Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }),
        }
    );

    line.clear();
    writeln!(writer, r##"{{"id":3,"cmd":"set-default-colors","bg":"#bad"}}"##).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], false, "bad color unexpectedly accepted: {line}");

    mux_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_broadcasts_surface_resized_once_per_changed_size() {
    let mux = Mux::new(unique_session("test-resize-event"), shell_opts("sleep 30"));
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    let sock_path = mux_core::server::serve(mux.clone(), None).unwrap();
    let subscribe_stream = UnixStream::connect(&sock_path).unwrap();
    subscribe_stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut subscribe_writer = subscribe_stream.try_clone().unwrap();
    let mut subscribe_reader = BufReader::new(subscribe_stream);

    let command_stream = UnixStream::connect(&sock_path).unwrap();
    let mut command_writer = command_stream.try_clone().unwrap();
    let mut command_reader = BufReader::new(command_stream);

    writeln!(subscribe_writer, r#"{{"id":1,"cmd":"subscribe"}}"#).unwrap();
    let response = wait_for(|| read_json_line(&mut subscribe_reader), Duration::from_secs(5))
        .expect("subscribe response");
    assert_eq!(response["ok"], true, "subscribe failed: {response}");

    writeln!(
        command_writer,
        r#"{{"id":2,"cmd":"resize-surface","surface":{},"cols":103,"rows":29}}"#,
        surface.id
    )
    .unwrap();
    let mut line = String::new();
    command_reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "resize failed: {line}");

    let event = wait_for(
        || {
            while let Some(value) = read_json_line(&mut subscribe_reader) {
                if value.get("event").and_then(|v| v.as_str()) == Some("surface-resized") {
                    return Some(value);
                }
            }
            None
        },
        Duration::from_secs(5),
    )
    .expect("no surface-resized event");
    assert_eq!(event["surface"], surface.id);
    assert_eq!(event["cols"], 103);
    assert_eq!(event["rows"], 29);
    assert_eq!(surface.size(), (103, 29));

    line.clear();
    writeln!(
        command_writer,
        r#"{{"id":3,"cmd":"resize-surface","surface":{},"cols":103,"rows":29}}"#,
        surface.id
    )
    .unwrap();
    command_reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "repeated resize failed: {line}");

    let repeated = wait_for(
        || {
            while let Some(value) = read_json_line(&mut subscribe_reader) {
                if value.get("event").and_then(|v| v.as_str()) == Some("surface-resized") {
                    return Some(value);
                }
            }
            None
        },
        Duration::from_millis(300),
    );
    assert!(repeated.is_none(), "same-size resize emitted another event: {repeated:?}");

    mux.close_surface(surface.id);
    mux_core::server::cleanup(&sock_path);
}

#[test]
fn default_colors_apply_to_existing_and_future_surfaces() {
    let opts = SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new("test-default-colors", opts);
    let first = mux.new_workspace(None, None).unwrap();

    let colors = DefaultColors {
        fg: Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }),
        bg: Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }),
    };
    mux.set_default_colors(colors);

    let mut first_state = RenderState::new().unwrap();
    first.snapshot(&mut first_state).unwrap();
    assert_eq!(
        first_state.default_colors(),
        (Rgb { r: 0x13, g: 0x14, b: 0x15 }, Rgb { r: 0x01, g: 0x02, b: 0x03 })
    );

    let second = mux.new_tab(None, None, None).unwrap();
    let mut second_state = RenderState::new().unwrap();
    second.snapshot(&mut second_state).unwrap();
    assert_eq!(
        second_state.default_colors(),
        (Rgb { r: 0x13, g: 0x14, b: 0x15 }, Rgb { r: 0x01, g: 0x02, b: 0x03 })
    );

    mux.close_surface(first.id);
    mux.close_surface(second.id);
}

#[test]
fn attach_stream_replays_then_streams_without_duplication() {
    let mux = Mux::new(
        "test-attach",
        shell_opts(
            "printf 'before-attach\\n'; read line; printf 'after-%s\\n' \"$line\"; sleep 30",
        ),
    );
    let surface = mux.new_workspace(None, None).unwrap();

    // Wait until the pre-attach output landed in the terminal.
    let ok = wait_for(
        || {
            surface
                .with_terminal(|t| t.plain_text())
                .unwrap()
                .unwrap()
                .contains("before-attach")
                .then_some(())
        },
        Duration::from_secs(10),
    );
    assert!(ok.is_some());

    let attach = surface.attach_stream().unwrap();
    assert!(attach.cols > 0 && attach.rows > 0);

    // The replay reproduces pre-attach content in a fresh terminal.
    let mut mirror =
        ghostty_vt::Terminal::new(attach.cols, attach.rows, 1000, ghostty_vt::Callbacks::default())
            .unwrap();
    mirror.vt_write(&attach.replay);
    assert!(mirror.plain_text().unwrap().contains("before-attach"));

    // Post-attach output arrives on the stream, not duplicated in the
    // replay we already applied.
    surface.write_bytes(b"attach\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match attach.stream.recv_timeout(Duration::from_millis(200)) {
            Ok(chunk) => {
                mirror.vt_write(&chunk);
                if mirror.plain_text().unwrap().contains("after-attach") {
                    break;
                }
            }
            Err(_) => assert!(Instant::now() < deadline, "stream never delivered output"),
        }
    }
    let text = mirror.plain_text().unwrap();
    assert_eq!(text.matches("before-attach").count(), 1, "duplicated replay: {text}");

    mux.close_surface(surface.id);
}

#[test]
fn new_tab_on_empty_headless_session_creates_workspace() {
    // A headless session receives new-tab before any workspace exists;
    // it must create a workspace around the new tab instead of panicking.
    let opts = SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new("test-headless", opts);
    let surface = mux.new_tab(None, None, None).unwrap();
    mux.with_state(|s| {
        assert_eq!(s.workspaces.len(), 1);
        assert_eq!(s.panes.len(), 1);
    });

    // Unknown pane ids error without leaking a surface.
    let before = mux.surface_count();
    assert!(mux.new_tab(Some(9999), None, None).is_err());
    assert_eq!(mux.surface_count(), before);

    mux.close_surface(surface.id);
}
