use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{AttachFrame, CursorShape, DefaultColors, Mux, MuxEvent, Rgb, SurfaceOptions};
use ghostty_vt::RenderState;

fn wait_for<T>(mut f: impl FnMut() -> Option<T>, timeout: Duration) -> Option<T> {
    let timeout_scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|scale| *scale > 0)
        .unwrap_or(1);
    let timeout = timeout.saturating_mul(timeout_scale);
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

fn connect(path: &Path) -> Box<dyn transport::Stream> {
    transport::connect(path).unwrap()
}

fn read_json_line(reader: &mut impl BufRead) -> Option<serde_json::Value> {
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

fn rendered_rows_text(value: &serde_json::Value) -> String {
    value["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|row| row["runs"].as_array().into_iter().flatten())
        .filter_map(|run| run["text"].as_str())
        .collect()
}

fn socket_request(
    writer: &mut impl Write,
    reader: &mut impl BufRead,
    request: serde_json::Value,
) -> serde_json::Value {
    let response = socket_response(writer, reader, request);
    assert_eq!(response["ok"], true, "request failed: {response}");
    response
}

fn socket_response(
    writer: &mut impl Write,
    reader: &mut impl BufRead,
    request: serde_json::Value,
) -> serde_json::Value {
    writeln!(writer, "{request}").unwrap();
    read_json_line(reader).expect("socket response")
}

fn assert_vt_state_size(
    writer: &mut impl Write,
    reader: &mut impl BufRead,
    id: u64,
    surface: u64,
    expected: (u16, u16),
) {
    let response = socket_request(
        writer,
        reader,
        serde_json::json!({"id": id, "cmd": "vt-state", "surface": surface}),
    );
    assert_eq!(response["data"]["cols"], expected.0);
    assert_eq!(response["data"]["rows"], expected.1);
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

    assert!(!surface.resize(80, 24).unwrap());
    assert_eq!(surface.size(), (80, 24));
    assert!(surface.resize(100, 40).unwrap());
    assert_eq!(surface.size(), (100, 40));
    assert!(!surface.resize(100, 40).unwrap());
    assert!(surface.resize(0, 0).unwrap());
    assert_eq!(surface.size(), (1, 1));
    assert!(!surface.resize(0, 0).unwrap());

    mux.close_surface(surface.id);
}

#[test]
fn headless_creation_uses_legacy_default_then_latest_client_size() {
    let mux = Mux::new(unique_session("test-headless-client-size"), shell_opts("sleep 30"));
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    let first = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 1, "cmd": "new-workspace"}),
    )["data"]["surface"]
        .as_u64()
        .unwrap();
    assert_vt_state_size(&mut writer, &mut reader, 2, first, (80, 24));

    socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 3,
            "cmd": "resize-surface",
            "surface": first,
            "cols": 143,
            "rows": 40,
        }),
    );
    let inherited = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 4, "cmd": "new-workspace"}),
    )["data"]["surface"]
        .as_u64()
        .unwrap();
    assert_vt_state_size(&mut writer, &mut reader, 5, inherited, (143, 40));

    let explicit = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 6,
            "cmd": "new-workspace",
            "cols": 97,
            "rows": 31,
        }),
    )["data"]["surface"]
        .as_u64()
        .unwrap();
    assert_vt_state_size(&mut writer, &mut reader, 7, explicit, (97, 31));

    let inherited_explicit = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 8, "cmd": "new-workspace"}),
    )["data"]["surface"]
        .as_u64()
        .unwrap();
    assert_vt_state_size(&mut writer, &mut reader, 9, inherited_explicit, (97, 31));

    let clamped = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 10,
            "cmd": "new-workspace",
            "cols": 0,
            "rows": 0,
        }),
    )["data"]["surface"]
        .as_u64()
        .unwrap();
    assert_vt_state_size(&mut writer, &mut reader, 11, clamped, (1, 1));

    mux.shutdown();
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn shared_surface_uses_smallest_viewer_size_until_that_viewer_detaches() {
    let mux = Mux::new("minimum-viewer-size", SurfaceOptions::default());
    let surface = mux
        .run_command_surface(vec!["/bin/cat".to_string()], None, true, None, None, Some((80, 24)))
        .unwrap()
        .surface;

    mux.resize_surface_for_client(surface, 1, 120, 40).unwrap();
    mux.resize_surface_for_client(surface, 2, 80, 50).unwrap();
    assert_eq!(mux.surface(surface).unwrap().size(), (80, 40));

    mux.remove_surface_size_client(surface, 2);
    assert_eq!(mux.surface(surface).unwrap().size(), (120, 40));

    mux.remove_surface_size_client(surface, 1);
    assert_eq!(mux.surface(surface).unwrap().size(), (120, 40));

    mux.shutdown();
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
    // The mux reaps exited surfaces itself. Empty workspace containers are
    // durable registry state and remain visible for GUI/TUI parity.
    let reaped = wait_for(
        || {
            mux.with_state(|state| {
                (!state.surfaces.contains_key(&surface.id)
                    && state.workspaces.len() == 1
                    && state.workspaces[0].screens.is_empty())
                .then_some(())
            })
        },
        Duration::from_secs(10),
    );
    assert!(reaped.is_some(), "exited surface not reaped from tree");
}

#[test]
fn control_socket_round_trip() {
    let mux =
        Mux::new(unique_session("test-sock"), shell_opts("printf 'socket-check\\n'; sleep 30"));
    let surface = mux.new_workspace(None, None).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    let mut line = String::new();

    writeln!(writer, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["app"], "cmux-tui");

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
    let second_tab = v["data"]["surface"].as_u64().unwrap();

    line.clear();
    writeln!(
        writer,
        r#"{{"id":81,"cmd":"move-tab","surface":{surface_id},"pane":{pane_id},"index":2}}"#
    )
    .unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "move-tab failed: {line}");

    line.clear();
    writeln!(writer, r#"{{"id":82,"cmd":"list-workspaces"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    let tabs = v["data"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"].as_array().unwrap();
    assert_eq!(tabs[0]["surface"], second_tab);
    assert_eq!(tabs[1]["surface"], surface_id);

    line.clear();
    writeln!(
        writer,
        r#"{{"id":83,"cmd":"move-tab","surface":{surface_id},"pane":{pane_id},"index":2}}"#
    )
    .unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "same-position move-tab failed: {line}");

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

    line.clear();
    writeln!(writer, r#"{{"id":12,"cmd":"new-workspace","name":"second"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "new-workspace failed: {line}");

    line.clear();
    writeln!(writer, r#"{{"id":13,"cmd":"move-workspace","workspace":{ws_id},"index":2}}"#)
        .unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "move-workspace failed: {line}");

    line.clear();
    writeln!(writer, r#"{{"id":14,"cmd":"list-workspaces"}}"#).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    let workspaces = v["data"]["workspaces"].as_array().unwrap();
    assert_eq!(workspaces.len(), 2);
    assert_eq!(workspaces[1]["id"], ws_id);

    line.clear();
    writeln!(writer, r#"{{"id":15,"cmd":"move-workspace","workspace":{ws_id},"index":1}}"#)
        .unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "same-position move-workspace failed: {line}");

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
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_read_screen_reports_rendered_viewport_after_scrollback_clear() {
    let mut output = String::new();
    for row in 0..12 {
        output.push_str(&format!("row{row:02}\\r\\n"));
    }
    let script = format!("printf '{output}'; printf '\\033[H\\033[2Jprompt$ '; sleep 30");
    let mux = Mux::new(unique_session("test-read-screen-viewport"), shell_opts(&script));
    let surface = mux.new_workspace(None, Some((17, 5))).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    let text = wait_for(
        || {
            line.clear();
            writeln!(writer, r#"{{"id":1,"cmd":"read-screen","surface":{}}}"#, surface.id).unwrap();
            reader.read_line(&mut line).unwrap();
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(value["ok"], true, "read-screen failed: {line}");
            let text = value["data"]["text"].as_str().unwrap_or_default().to_string();
            text.contains("prompt$").then_some(text)
        },
        Duration::from_secs(10),
    )
    .expect("prompt never reached rendered screen");
    let first_line = text.lines().next().unwrap_or_default();
    assert!(
        first_line.contains("prompt$"),
        "read-screen should report the rendered viewport, got {text:?}"
    );

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_wait_for_matches_one_shot_output_already_on_screen() {
    let mux = Mux::new(
        unique_session("test-wait-for-one-shot"),
        shell_opts("printf 'one-shot-ready\\n'; sleep 30"),
    );
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    let appeared = wait_for(
        || {
            line.clear();
            writeln!(writer, r#"{{"id":1,"cmd":"read-screen","surface":{}}}"#, surface.id).unwrap();
            reader.read_line(&mut line).unwrap();
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(value["ok"], true, "read-screen failed: {line}");
            value["data"]["text"]
                .as_str()
                .unwrap_or_default()
                .contains("one-shot-ready")
                .then_some(())
        },
        Duration::from_secs(10),
    );
    assert!(appeared.is_some(), "one-shot output never appeared");

    line.clear();
    writeln!(
        writer,
        r#"{{"id":2,"cmd":"wait-for","surface":{},"pattern":"one-shot-ready","timeout_ms":1000}}"#,
        surface.id
    )
    .unwrap();
    reader.read_line(&mut line).unwrap();
    let value: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["ok"], true, "wait-for failed after one-shot output: {line}");
    assert_eq!(value["data"]["matched"], true);

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_set_default_colors_merges_fields() {
    let opts = SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new(format!("test-colors-{}", std::process::id()), opts);
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    writeln!(writer, r##"{{"id":1,"cmd":"set-default-colors","fg":"#010203"}}"##).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], true, "set-default-colors failed: {line}");
    assert_eq!(
        mux.default_colors(),
        DefaultColors { fg: Some(Rgb { r: 1, g: 2, b: 3 }), bg: None, ..Default::default() }
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
            ..Default::default()
        }
    );

    line.clear();
    writeln!(writer, r##"{{"id":3,"cmd":"set-default-colors","bg":"#bad"}}"##).unwrap();
    reader.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["ok"], false, "bad color unexpectedly accepted: {line}");

    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_attach_vt_state_includes_effective_colors() {
    let mux = Mux::new(unique_session("test-attach-colors"), shell_opts("cat"));
    mux.set_default_colors(DefaultColors {
        fg: Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }),
        bg: Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }),
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(false),
        ..Default::default()
    });
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.try_with_terminal(|term| term.vt_write(b"\x1b]12;rgb:20/40/60\x07")).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    writeln!(writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id).unwrap();
    let vt_state = read_json_line(&mut reader).expect("vt-state event");
    assert_eq!(vt_state["event"], "vt-state");
    assert_eq!(vt_state["surface"], surface.id);
    assert_eq!(
        vt_state["colors"],
        serde_json::json!({
            "fg": "#010203",
            "bg": "#131415",
            "cursor": "#204060",
            "selection_bg": null,
            "selection_fg": null,
            "cursor_style": "bar",
            "cursor_blink": false,
            "palette": {},
        })
    );

    let response = read_json_line(&mut reader).expect("attach response");
    assert_eq!(response["id"], 1);
    assert_eq!(response["ok"], true, "attach failed: {response}");

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_attach_vt_state_cursor_is_null_without_config_or_decscusr() {
    let mux = Mux::new(unique_session("test-attach-cursor-null"), shell_opts("cat"));
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    writeln!(writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id).unwrap();
    let vt_state = read_json_line(&mut reader).expect("vt-state event");
    assert_eq!(vt_state["colors"]["cursor_style"], serde_json::Value::Null);
    assert_eq!(vt_state["colors"]["cursor_blink"], serde_json::Value::Null);

    let response = read_json_line(&mut reader).expect("attach response");
    assert_eq!(response["ok"], true, "attach failed: {response}");

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_attach_vt_state_prefers_surface_decscusr_cursor() {
    let mux = Mux::new(unique_session("test-attach-cursor-override"), shell_opts("cat"));
    mux.set_default_colors(DefaultColors {
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(false),
        ..Default::default()
    });
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.try_with_terminal(|term| term.vt_write(b"\x1b[3 q")).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    writeln!(writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id).unwrap();
    let vt_state = read_json_line(&mut reader).expect("vt-state event");
    assert_eq!(vt_state["colors"]["cursor_style"], "underline");
    assert_eq!(vt_state["colors"]["cursor_blink"], true);

    let response = read_json_line(&mut reader).expect("attach response");
    assert_eq!(response["ok"], true, "attach failed: {response}");

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_attach_stream_receives_merged_colors_changed() {
    let mux = Mux::new(unique_session("test-colors-changed"), shell_opts("cat"));
    mux.set_default_colors(DefaultColors {
        fg: Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }),
        bg: None,
        cursor_style: Some(CursorShape::Bar),
        cursor_blink: Some(false),
        ..Default::default()
    });
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let attach_stream = connect(&sock_path);
    attach_stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut attach_writer = attach_stream.try_clone_box().unwrap();
    let mut attach_reader = BufReader::new(attach_stream);

    writeln!(attach_writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id)
        .unwrap();
    let vt_state = wait_for(|| read_json_line(&mut attach_reader), Duration::from_secs(5))
        .expect("vt-state event");
    assert_eq!(vt_state["event"], "vt-state");
    let response = wait_for(|| read_json_line(&mut attach_reader), Duration::from_secs(5))
        .expect("attach response");
    assert_eq!(response["ok"], true, "attach failed: {response}");

    let command_stream = connect(&sock_path);
    let mut command_writer = command_stream.try_clone_box().unwrap();
    let mut command_reader = BufReader::new(command_stream);
    writeln!(command_writer, r##"{{"id":2,"cmd":"set-default-colors","bg":"#131415"}}"##).unwrap();
    let response = read_json_line(&mut command_reader).expect("set-default-colors response");
    assert_eq!(response["ok"], true, "set-default-colors failed: {response}");

    let event = wait_for(
        || {
            while let Some(value) = read_json_line(&mut attach_reader) {
                if value.get("event").and_then(|value| value.as_str()) == Some("colors-changed") {
                    return Some(value);
                }
            }
            None
        },
        Duration::from_secs(5),
    )
    .expect("colors-changed event");
    assert_eq!(
        event,
        serde_json::json!({
            "event": "colors-changed",
            "surface": surface.id,
            "fg": "#010203",
            "bg": "#131415",
            "cursor": null,
            "selection_bg": null,
            "selection_fg": null,
            "cursor_style": "bar",
            "cursor_blink": false,
            "palette": {},
        })
    );

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_attach_palette_is_full_sparse_state_and_reset_clears_all_256() {
    let mux = Mux::new(unique_session("test-attach-palette"), shell_opts("cat"));
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut set_palette = Vec::new();
    for index in 0..=255u8 {
        set_palette.extend_from_slice(
            format!("\x1b]4;{index};#{:02x}{:02x}{:02x}\x07", index, 255 - index, index ^ 0x55)
                .as_bytes(),
        );
    }
    surface.try_with_terminal(|term| term.vt_write(&set_palette)).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let attach_stream = connect(&sock_path);
    attach_stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut attach_writer = attach_stream.try_clone_box().unwrap();
    let mut attach_reader = BufReader::new(attach_stream);
    writeln!(attach_writer, r#"{{"id":1,"cmd":"attach-surface","surface":{}}}"#, surface.id)
        .unwrap();
    let vt_state = wait_for(|| read_json_line(&mut attach_reader), Duration::from_secs(5))
        .expect("vt-state event");
    let palette = vt_state["colors"]["palette"].as_object().expect("palette object");
    assert_eq!(palette.len(), 256);
    assert_eq!(palette["0"], "#00ff55");
    assert_eq!(palette["255"], "#ff00aa");
    let response = wait_for(|| read_json_line(&mut attach_reader), Duration::from_secs(5))
        .expect("attach response");
    assert_eq!(response["ok"], true, "attach failed: {response}");

    surface.write_bytes(b"\x1b]104\x07\n").unwrap();
    let reset = wait_for(
        || {
            while let Some(value) = read_json_line(&mut attach_reader) {
                if value.get("event").and_then(|value| value.as_str()) == Some("colors-changed") {
                    return Some(value);
                }
            }
            None
        },
        Duration::from_secs(5),
    )
    .expect("palette reset colors-changed event");
    assert_eq!(reset["palette"], serde_json::json!({}));

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn control_socket_broadcasts_surface_resized_once_per_changed_size() {
    let mux = Mux::new(unique_session("test-resize-event"), shell_opts("sleep 30"));
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let subscribe_stream = connect(&sock_path);
    subscribe_stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut subscribe_writer = subscribe_stream.try_clone_box().unwrap();
    let mut subscribe_reader = BufReader::new(subscribe_stream);

    let command_stream = connect(&sock_path);
    let mut command_writer = command_stream.try_clone_box().unwrap();
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
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn default_colors_apply_to_existing_and_future_surfaces() {
    let opts = SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
    let mux = Mux::new("test-default-colors", opts);
    let first = mux.new_workspace(None, None).unwrap();

    let colors = DefaultColors {
        fg: Some(Rgb { r: 0x01, g: 0x02, b: 0x03 }),
        bg: Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }),
        cursor_style: Some(CursorShape::Underline),
        cursor_blink: Some(true),
        ..Default::default()
    };
    mux.set_default_colors(colors);

    let mut first_state = RenderState::new().unwrap();
    first.snapshot(&mut first_state).unwrap();
    assert_eq!(
        first_state.default_colors(),
        (Rgb { r: 0x13, g: 0x14, b: 0x15 }, Rgb { r: 0x01, g: 0x02, b: 0x03 })
    );
    assert_eq!(first_state.cursor_visual().unwrap(), (CursorShape::Underline, true));

    let second = mux.new_tab(None, None, None).unwrap();
    let mut second_state = RenderState::new().unwrap();
    second.snapshot(&mut second_state).unwrap();
    assert_eq!(
        second_state.default_colors(),
        (Rgb { r: 0x13, g: 0x14, b: 0x15 }, Rgb { r: 0x01, g: 0x02, b: 0x03 })
    );
    assert_eq!(second_state.cursor_visual().unwrap(), (CursorShape::Underline, true));

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
            Ok(AttachFrame::Output(chunk))
            | Ok(AttachFrame::OutputWithColors { output: chunk, .. }) => {
                mirror.vt_write(&chunk);
                if mirror.plain_text().unwrap().contains("after-attach") {
                    break;
                }
            }
            Ok(AttachFrame::Resized { cols, rows, replay })
            | Ok(AttachFrame::ResizedWithColors { cols, rows, replay, .. }) => {
                assert!(!replay.is_empty());
                mirror =
                    ghostty_vt::Terminal::new(cols, rows, 1000, ghostty_vt::Callbacks::default())
                        .unwrap();
                mirror.vt_write(&replay);
            }
            Ok(AttachFrame::ColorsChanged(_)) => {}
            Err(_) => assert!(Instant::now() < deadline, "stream never delivered output"),
        }
    }
    let text = mirror.plain_text().unwrap();
    assert_eq!(text.matches("before-attach").count(), 1, "duplicated replay: {text}");

    mux.close_surface(surface.id);
}

#[test]
fn attach_stream_orders_resize_between_output_frames() {
    let mux = Mux::new(unique_session("test-attach-resize"), shell_opts("cat"));
    let surface = mux.new_workspace(None, None).unwrap();
    let attach = surface.attach_stream().unwrap();

    surface.write_bytes(b"before-resize\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match attach.stream.recv_timeout(Duration::from_millis(200)) {
            Ok(AttachFrame::Output(bytes))
            | Ok(AttachFrame::OutputWithColors { output: bytes, .. })
                if bytes.windows(b"before-resize".len()).any(|w| w == b"before-resize") =>
            {
                break;
            }
            Ok(_) => {}
            Err(_) => assert!(Instant::now() < deadline, "before output never arrived"),
        }
    }

    mux.resize_surface(surface.id, 100, 40).unwrap();
    let resized = wait_for(
        || match attach.stream.recv_timeout(Duration::from_millis(200)) {
            Ok(AttachFrame::Resized { cols, rows, replay })
            | Ok(AttachFrame::ResizedWithColors { cols, rows, replay, .. }) => {
                assert!(!replay.is_empty());
                Some((cols, rows))
            }
            Ok(_) | Err(_) => None,
        },
        Duration::from_secs(5),
    )
    .expect("resize marker");
    assert_eq!(resized, (100, 40));

    surface.write_bytes(b"after-resize\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match attach.stream.recv_timeout(Duration::from_millis(200)) {
            Ok(AttachFrame::Output(bytes))
            | Ok(AttachFrame::OutputWithColors { output: bytes, .. })
                if bytes.windows(b"after-resize".len()).any(|w| w == b"after-resize") =>
            {
                break;
            }
            Ok(AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. }) => {
                panic!("unexpected second resize marker")
            }
            Ok(AttachFrame::ColorsChanged(_)) => {}
            Ok(_) => {}
            Err(_) => assert!(Instant::now() < deadline, "after output never arrived"),
        }
    }

    mux.close_surface(surface.id);
}

#[test]
fn render_attach_headless_fans_one_frame_to_render_and_byte_consumers() {
    let mux = Mux::new(
        unique_session("test-render-multi"),
        shell_opts("stty -echo -icanon; printf ready; cat"),
    );
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    wait_for(
        || {
            surface
                .with_terminal(|term| {
                    term.viewport_text().ok().filter(|text| text.contains("ready"))
                })
                .flatten()
        },
        Duration::from_secs(10),
    )
    .expect("raw echo reader ready");
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();

    let render_stream = connect(&sock_path);
    render_stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut render_writer = render_stream.try_clone_box().unwrap();
    let mut render_reader = BufReader::new(render_stream);
    writeln!(
        render_writer,
        r#"{{"id":1,"cmd":"attach-surface","surface":{},"mode":"render"}}"#,
        surface.id
    )
    .unwrap();
    let initial = wait_for(|| read_json_line(&mut render_reader), Duration::from_secs(5))
        .expect("render-state event");
    assert_eq!(initial["event"], "render-state");
    assert_eq!(initial["surface"], surface.id);
    assert_eq!(initial["size"], serde_json::json!({"cols": 20, "rows": 4}));
    assert_eq!(initial["rows"].as_array().unwrap().len(), 4);
    assert!(initial["cursor"].get("visible").is_some());
    let response = wait_for(|| read_json_line(&mut render_reader), Duration::from_secs(5))
        .expect("render attach response");
    assert_eq!(response["id"], 1);
    assert_eq!(response["ok"], true);

    let byte_stream = connect(&sock_path);
    byte_stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut byte_writer = byte_stream.try_clone_box().unwrap();
    let mut byte_reader = BufReader::new(byte_stream);
    writeln!(byte_writer, r#"{{"id":2,"cmd":"attach-surface","surface":{}}}"#, surface.id).unwrap();
    assert_eq!(
        wait_for(|| read_json_line(&mut byte_reader), Duration::from_secs(5)).unwrap()["event"],
        "vt-state"
    );
    assert_eq!(
        wait_for(|| read_json_line(&mut byte_reader), Duration::from_secs(5)).unwrap()["ok"],
        true
    );

    surface.write_bytes(b"render-multi").unwrap();
    let delta = wait_for(
        || {
            while let Some(value) = read_json_line(&mut render_reader) {
                if value["event"] == "render-delta"
                    && rendered_rows_text(&value).contains("render-multi")
                {
                    return Some(value);
                }
            }
            None
        },
        Duration::from_secs(10),
    )
    .expect("headless render delta");
    assert_eq!(delta["full"], false);
    assert_eq!(delta["rows"].as_array().unwrap().len(), 1);
    assert!(delta.get("cursor").is_some());

    let output = wait_for(
        || {
            while let Some(value) = read_json_line(&mut byte_reader) {
                if value["event"] == "output" {
                    let bytes = base64::engine::general_purpose::STANDARD
                        .decode(value["data"].as_str().unwrap())
                        .unwrap();
                    if bytes.windows(b"render-multi".len()).any(|part| part == b"render-multi") {
                        return Some(bytes);
                    }
                }
            }
            None
        },
        Duration::from_secs(10),
    );
    assert!(output.is_some(), "byte attachment stopped while render attachment was active");

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn render_attach_snapshot_and_raced_write_have_no_gap_or_duplicate_frame() {
    let mux = Mux::new(unique_session("test-render-race"), shell_opts("stty -echo; cat"));
    let surface = mux.new_workspace(None, Some((24, 3))).unwrap();
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    let raced_surface = surface.clone();
    let raced = std::thread::spawn(move || raced_surface.write_bytes(b"race-v7\n").unwrap());
    writeln!(
        writer,
        r#"{{"id":1,"cmd":"attach-surface","surface":{},"mode":"render"}}"#,
        surface.id
    )
    .unwrap();
    raced.join().unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut marker_events = 0;
    let mut saw_response = false;
    while Instant::now() < deadline && (!saw_response || marker_events == 0) {
        if let Some(value) = read_json_line(&mut reader) {
            if value["id"] == 1 {
                assert_eq!(value["ok"], true);
                saw_response = true;
            }
            if matches!(value["event"].as_str(), Some("render-state" | "render-delta"))
                && rendered_rows_text(&value).contains("race-v7")
            {
                marker_events += 1;
            }
        }
    }
    assert!(saw_response, "render attach response was not delivered");
    assert_eq!(marker_events, 1, "raced output was missing or duplicated across snapshot/delta");

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn render_attach_resize_is_a_full_replacement_at_the_new_size() {
    let mux = Mux::new(unique_session("test-render-resize"), shell_opts("cat"));
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        r#"{{"id":1,"cmd":"attach-surface","surface":{},"mode":"render"}}"#,
        surface.id
    )
    .unwrap();
    assert_eq!(
        wait_for(|| read_json_line(&mut reader), Duration::from_secs(5)).unwrap()["event"],
        "render-state"
    );
    assert_eq!(
        wait_for(|| read_json_line(&mut reader), Duration::from_secs(5)).unwrap()["ok"],
        true
    );

    let command = connect(&sock_path);
    let mut command_writer = command.try_clone_box().unwrap();
    let mut command_reader = BufReader::new(command);
    socket_request(
        &mut command_writer,
        &mut command_reader,
        serde_json::json!({
            "id": 2,
            "cmd": "resize-surface",
            "surface": surface.id,
            "cols": 31,
            "rows": 6,
        }),
    );

    let delta = wait_for(
        || {
            while let Some(value) = read_json_line(&mut reader) {
                if value["event"] == "render-delta" && value["size"]["cols"] == 31 {
                    return Some(value);
                }
            }
            None
        },
        Duration::from_secs(5),
    )
    .expect("resize render delta");
    assert_eq!(delta["full"], true);
    assert_eq!(delta["size"], serde_json::json!({"cols": 31, "rows": 6}));
    assert_eq!(delta["rows"].as_array().unwrap().len(), 6);

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn read_scrollback_pages_oldest_rows_and_clamps_bounds() {
    let script =
        "i=0; while [ $i -lt 30 ]; do printf 'history-%02d\\n' $i; i=$((i+1)); done; sleep 30";
    let mux = Mux::new(unique_session("test-read-scrollback"), shell_opts(script));
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
    wait_for(
        || surface.with_terminal(|term| (term.history_rows() >= 20).then_some(())).flatten(),
        Duration::from_secs(10),
    )
    .expect("history rows");
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    let page = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 1,
            "cmd": "read-scrollback",
            "surface": surface.id,
            "start": 0,
            "count": 3,
        }),
    )["data"]
        .clone();
    assert_eq!(page["start"], 0);
    assert_eq!(page["rows"].as_array().unwrap().len(), 3);
    assert!(page["total"].as_u64().unwrap() >= 20);
    assert!(rendered_rows_text(&page).contains("history-00"));

    let total = page["total"].as_u64().unwrap();
    let past_end = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 2,
            "cmd": "read-scrollback",
            "surface": surface.id,
            "start": u32::MAX,
            "count": 10,
        }),
    );
    assert_eq!(past_end["data"]["start"].as_u64(), Some(total));
    assert!(past_end["data"]["rows"].as_array().unwrap().is_empty());
    let empty = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 3,
            "cmd": "read-scrollback",
            "surface": surface.id,
            "start": 0,
            "count": 0,
        }),
    );
    assert!(empty["data"]["rows"].as_array().unwrap().is_empty());

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn tree_event_modes_receive_delta_or_exact_coarse_fallback() {
    let mux = Mux::new(unique_session("test-tree-event-modes"), shell_opts("sleep 30"));
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();

    let coarse = connect(&sock_path);
    coarse.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut coarse_writer = coarse.try_clone_box().unwrap();
    let mut coarse_reader = BufReader::new(coarse);
    coarse_writer.write_all(br#"{"id":1,"cmd":"subscribe"}"#).unwrap();
    coarse_writer.write_all(b"\n").unwrap();
    assert_eq!(
        wait_for(|| read_json_line(&mut coarse_reader), Duration::from_secs(5)).unwrap()["ok"],
        true
    );

    let deltas = connect(&sock_path);
    deltas.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
    let mut deltas_writer = deltas.try_clone_box().unwrap();
    let mut deltas_reader = BufReader::new(deltas);
    deltas_writer.write_all(br#"{"id":2,"cmd":"subscribe","tree_events":"deltas"}"#).unwrap();
    deltas_writer.write_all(b"\n").unwrap();
    assert_eq!(
        wait_for(|| read_json_line(&mut deltas_reader), Duration::from_secs(5)).unwrap()["ok"],
        true
    );

    let commands = connect(&sock_path);
    let mut command_writer = commands.try_clone_box().unwrap();
    let mut command_reader = BufReader::new(commands);
    let created = socket_request(
        &mut command_writer,
        &mut command_reader,
        serde_json::json!({"id": 3, "cmd": "new-workspace", "name": "delta"}),
    );
    let surface = created["data"]["surface"].as_u64().unwrap();

    let coarse_event = wait_for(|| read_json_line(&mut coarse_reader), Duration::from_secs(5))
        .expect("coarse tree event");
    assert_eq!(coarse_event, serde_json::json!({"event": "tree-changed"}));
    let delta = wait_for(|| read_json_line(&mut deltas_reader), Duration::from_secs(5))
        .expect("workspace-added event");
    assert_eq!(delta["event"], "workspace-added");
    assert_eq!(delta["workspace"], delta["entity"]["id"]);
    assert_eq!(delta["index"], 0);
    assert_eq!(delta["workspace_revision"], 1);
    assert_eq!(delta["origin"], "cmux-tui");
    assert!(delta["mutation_id"].as_str().is_some());
    assert!(delta["registry_id"].as_str().is_some());
    assert!(delta["generation"].as_str().is_some());
    assert!(delta["entity"]["key"].as_str().is_some_and(|key| key.len() == 36));
    assert_eq!(delta["entity"]["name"], "delta");
    assert!(
        delta["entity"]["screens"][0]["panes"][0]["tabs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|tab| tab["surface"] == surface)
    );

    mux.close_surface(surface);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn create_empty_workspace_is_visible_and_materialized_in_place() {
    let mux = Mux::new(unique_session("test-empty-workspace"), shell_opts("sleep 30"));
    let sock_path = cmux_tui_core::server::serve(mux, None).unwrap();
    let commands = connect(&sock_path);
    let mut writer = commands.try_clone_box().unwrap();
    let mut reader = BufReader::new(commands);
    let key = "018f6e21-7b70-7e70-8000-000000000042";

    let created = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 1,
            "cmd": "create-workspace",
            "name": "from-gui",
            "key": key,
            "expected_revision": 0,
        }),
    );
    assert_eq!(created["ok"], true, "create-workspace failed: {created}");
    assert_eq!(created["data"]["key"], key);
    assert_eq!(created["data"]["workspace_revision"], 1);
    let workspace = created["data"]["workspace"].as_u64().unwrap();

    let snapshot = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 2, "cmd": "list-workspaces"}),
    );
    assert_eq!(snapshot["data"]["workspace_revision"], 1);
    assert_eq!(snapshot["data"]["workspaces"][0]["id"], workspace);
    assert_eq!(snapshot["data"]["workspaces"][0]["key"], key);
    assert!(snapshot["data"]["workspaces"][0]["screens"].as_array().unwrap().is_empty());

    let stale = socket_response(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 21,
            "cmd": "create-workspace",
            "name": "stale",
            "expected_revision": 0,
        }),
    );
    assert_eq!(stale["ok"], false);
    assert_eq!(stale["error"], "workspace revision conflict: expected 0, current 1");

    let renamed = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 22,
            "cmd": "rename-workspace",
            "key": key,
            "name": "renamed-from-gui",
            "expected_revision": 1,
        }),
    );
    assert_eq!(renamed["ok"], true, "rename by key failed: {renamed}");
    assert_eq!(renamed["data"]["workspace"], workspace);
    assert_eq!(renamed["data"]["key"], key);
    assert_eq!(renamed["data"]["workspace_revision"], 2);

    let tab = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 3,
            "cmd": "create-terminal",
            "key": key,
            "cols": 80,
            "rows": 24,
        }),
    );
    assert_eq!(tab["ok"], true, "create-terminal failed: {tab}");
    assert_eq!(tab["data"]["workspace"], workspace);
    assert_eq!(tab["data"]["key"], key);
    let snapshot = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 4, "cmd": "list-workspaces"}),
    );
    assert_eq!(snapshot["data"]["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["data"]["workspaces"][0]["id"], workspace);
    assert_eq!(snapshot["data"]["workspaces"][0]["name"], "renamed-from-gui");
    assert_eq!(snapshot["data"]["workspace_revision"], 2);
    assert_eq!(
        snapshot["data"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["surface"],
        tab["data"]["surface"]
    );

    let closed = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 5,
            "cmd": "close-workspace",
            "key": key,
            "expected_revision": 2,
        }),
    );
    assert_eq!(closed["ok"], true, "close by key failed: {closed}");
    assert_eq!(closed["data"]["workspace_revision"], 3);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn workspace_mutations_are_exactly_once_before_guards_and_close_resolution() {
    let mux = Mux::new(unique_session("test-workspace-dedupe"), SurfaceOptions::default());
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let request = serde_json::json!({
        "id": 1,
        "cmd": "create-workspace",
        "name": "once",
        "key": "stable-once",
        "origin": "browser-profile-a",
        "mutation_id": "create-once",
        "expected_revision": 0,
    });

    // Commit the mutation, then throw away the connection without consuming
    // its response to model a frontend losing the reply.
    {
        let stream = connect(&sock_path);
        let mut writer = stream.try_clone_box().unwrap();
        writeln!(writer, "{request}").unwrap();
        writer.flush().unwrap();
        wait_for(
            || mux.with_state(|state| (state.workspace_revision == 1).then_some(())),
            Duration::from_secs(10),
        )
        .expect("create mutation was not committed");
        // Deliberately drop both halves without reading the queued response.
        drop(stream);
    }

    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let retry = socket_request(&mut writer, &mut reader, request);
    assert_eq!(retry["data"]["workspace_revision"], 1);
    assert_eq!(retry["data"]["replayed"], true);
    mux.with_state(|state| {
        assert_eq!(state.workspace_revision, 1);
        assert_eq!(state.workspaces.len(), 1);
    });

    let mismatch = socket_response(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 2,
            "cmd": "create-workspace",
            "name": "different",
            "key": "stable-once",
            "origin": "browser-profile-a",
            "mutation_id": "create-once",
            "expected_revision": 1,
        }),
    );
    assert_eq!(mismatch["ok"], false);
    assert!(mismatch["error"].as_str().unwrap().contains("different payload"));

    let generation = retry["data"]["generation"].as_str().unwrap().to_string();
    let close = serde_json::json!({
        "id": 3,
        "cmd": "close-workspace",
        "key": "stable-once",
        "origin": "browser-profile-a",
        "mutation_id": "close-once",
        "expected_generation": generation,
        "expected_revision": 1,
    });
    let first_close = socket_request(&mut writer, &mut reader, close.clone());
    assert_eq!(first_close["data"]["workspace_revision"], 2);
    assert_eq!(first_close["data"]["replayed"], false);
    let mut stale_guard_retry = close;
    stale_guard_retry["expected_generation"] = serde_json::json!("stale-generation");
    stale_guard_retry["expected_revision"] = serde_json::json!(0);
    let close_retry = socket_request(&mut writer, &mut reader, stale_guard_retry);
    assert_eq!(close_retry["data"]["workspace_revision"], 2);
    assert_eq!(close_retry["data"]["replayed"], true);
    assert_eq!(close_retry["data"]["key"], "stable-once");
    mux.with_state(|state| assert!(state.workspaces.is_empty()));

    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn frontend_projection_round_trips_without_advancing_workspace_revision() {
    let mux = Mux::new(unique_session("test-projection"), SurfaceOptions::default());
    let sock_path = cmux_tui_core::server::serve(mux, None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let put = serde_json::json!({
        "id": 1,
        "cmd": "put-frontend-projection",
        "frontend": "cmux-browser",
        "scope": "window-group",
        "subject_key": "profile-a:window-a",
        "schema_version": 1,
        "expected_projection_revision": 0,
        "projection": {"columns":[{"workspace":"stable-one"}]},
        "origin": "browser-profile-a",
        "mutation_id": "projection-one",
    });
    let first = socket_request(&mut writer, &mut reader, put.clone());
    assert_eq!(first["data"]["projection_revision"], 1);
    assert_eq!(first["data"]["replayed"], false);
    let retry = socket_request(&mut writer, &mut reader, put);
    assert_eq!(retry["data"]["projection_revision"], 1);
    assert_eq!(retry["data"]["replayed"], true);
    let get = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 2,
            "cmd": "get-frontend-projection",
            "frontend": "cmux-browser",
            "scope": "window-group",
            "subject_key": "profile-a:window-a",
        }),
    );
    assert_eq!(get["data"]["projection"]["columns"][0]["workspace"], "stable-one");
    let list = socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id":3,"cmd":"list-workspaces"}),
    );
    assert_eq!(list["data"]["workspace_revision"], 0);
    cmux_tui_core::server::cleanup(&sock_path);
}

#[test]
fn send_paste_wraps_only_while_dec_mode_2004_is_enabled() {
    let script = "stty -echo -icanon min 1 time 0; printf 'paste-ready\\n'; od -An -tx1 -N 14; od -An -tx1 -N 3; sleep 30";
    let mux = Mux::new(unique_session("test-paste-mode"), shell_opts(script));
    let surface = mux.new_workspace(None, Some((80, 8))).unwrap();
    wait_for(
        || {
            surface
                .with_terminal(|term| {
                    term.viewport_text().ok().filter(|text| text.contains("paste-ready"))
                })
                .flatten()
        },
        Duration::from_secs(10),
    )
    .expect("paste reader ready");
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = connect(&sock_path);
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);

    surface.try_with_terminal(|term| term.vt_write(b"\x1b[?2004h")).unwrap();
    wait_for(
        || surface.with_terminal(|term| term.mode(2004, false).then_some(())).flatten(),
        Duration::from_secs(10),
    )
    .expect("DEC mode 2004 enabled");
    socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 1,
            "cmd": "send",
            "surface": surface.id,
            "text": "hi",
            "paste": true,
        }),
    );
    wait_for(
        || {
            surface
                .with_terminal(|term| {
                    term.viewport_text()
                        .ok()
                        // od's hex spacing differs across platforms; compare
                        // with whitespace collapsed.
                        .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
                        .filter(|text| text.contains("1b 5b 32 30 30 7e 68 69 1b 5b 32 30 31 7e"))
                })
                .flatten()
        },
        Duration::from_secs(10),
    )
    .unwrap_or_else(|| {
        let state = surface.with_terminal(|term| {
            (term.mode(2004, false), term.viewport_text().unwrap_or_default())
        });
        panic!("bracketed bytes; terminal state: {state:?}");
    });

    surface.try_with_terminal(|term| term.vt_write(b"\x1b[?2004l")).unwrap();
    wait_for(
        || surface.with_terminal(|term| (!term.mode(2004, false)).then_some(())).flatten(),
        Duration::from_secs(10),
    )
    .expect("DEC mode 2004 disabled");
    socket_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": 2,
            "cmd": "send",
            "surface": surface.id,
            "text": "raw",
            "paste": true,
        }),
    );
    wait_for(
        || {
            surface
                .with_terminal(|term| {
                    term.viewport_text()
                        .ok()
                        .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
                        .filter(|text| text.contains("72 61 77"))
                })
                .flatten()
        },
        Duration::from_secs(10),
    )
    .expect("raw paste bytes");

    mux.close_surface(surface.id);
    cmux_tui_core::server::cleanup(&sock_path);
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
