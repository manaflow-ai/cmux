//! Unit tests that need no display. The live checks (a real Xvfb, Sway or
//! GNOME session) are `examples/linux_live.rs`.

use super::*;
use crate::desktop::Rect;
use crate::keys::{Key, KeyCombo, Modifier};

fn env(wayland: Option<&str>, display: Option<&str>) -> Env {
    Env {
        wayland_display: wayland.map(str::to_string),
        display: display.map(str::to_string),
        ..Env::default()
    }
}

const WLR: WaylandCaps =
    WaylandCaps { screencopy: true, virtual_pointer: true, virtual_keyboard: true };

#[test]
fn chooses_x11_without_wayland() {
    assert_eq!(
        choose(&env(None, Some(":0")), None, false),
        Ok(SessionKind::X11 { display: ":0".into() })
    );
    assert!(choose(&env(None, None), None, false).is_err());
}

#[test]
fn chooses_wlroots_then_portal_then_xwayland() {
    let e = env(Some("wayland-1"), Some(":1"));
    assert_eq!(choose(&e, Some(WLR), true), Ok(SessionKind::Wlroots));
    let gnome = WaylandCaps { screencopy: false, virtual_pointer: false, virtual_keyboard: false };
    assert_eq!(choose(&e, Some(gnome), true), Ok(SessionKind::Portal));
    assert_eq!(choose(&e, Some(gnome), false), Ok(SessionKind::X11 { display: ":1".into() }));
    assert!(choose(&env(Some("wayland-1"), None), Some(gnome), false).is_err());
}

#[test]
fn forced_backend_wins() {
    let mut e = env(Some("wayland-1"), Some(":1"));
    e.forced = Some("x11".into());
    assert_eq!(choose(&e, Some(WLR), true), Ok(SessionKind::X11 { display: ":1".into() }));
    e.forced = Some("portal".into());
    assert_eq!(choose(&e, Some(WLR), false), Ok(SessionKind::Portal));
    e.forced = Some("mir".into());
    assert!(choose(&e, None, false).is_err());
}

#[test]
fn wayland_socket_from_session_type() {
    let dir = std::env::temp_dir().join(format!("cmux-cu-linux-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut e = Env {
        session_type: Some("wayland".into()),
        runtime_dir: Some(dir.display().to_string()),
        ..Env::default()
    };
    assert_eq!(e.wayland_socket(), None);
    std::fs::write(dir.join("wayland-0"), b"").unwrap();
    assert_eq!(e.wayland_socket().as_deref(), Some("wayland-0"));
    e.session_type = Some("x11".into());
    assert_eq!(e.wayland_socket(), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn desktop_entries_parse() {
    let text = "[Desktop Entry]\nType=Application\nName=Text Editor\nExec=gnome-text-editor %U\nStartupWMClass=gnome-text-editor\n[Desktop Action new]\nName=New\n";
    let e = parse_desktop_entry("org.gnome.TextEditor", text).unwrap();
    assert_eq!(e.name, "Text Editor");
    assert_eq!(e.startup_wm_class.as_deref(), Some("gnome-text-editor"));
    assert!(parse_desktop_entry("x", "[Desktop Entry]\nType=Link\n").is_none());
    assert!(parse_desktop_entry("x", "[Desktop Entry]\nType=Application\nHidden=true\n").is_none());
    let index = DesktopIndex { entries: vec![e] };
    assert_eq!(
        index.for_class("gnome-text-editor", "").map(|e| e.id.as_str()),
        Some("org.gnome.TextEditor")
    );
    assert_eq!(
        index.for_class("TextEditor", "").map(|e| e.id.as_str()),
        Some("org.gnome.TextEditor")
    );
    assert!(index.for_class("xterm", "xterm").is_none());
}

#[test]
fn exec_lines_split() {
    assert_eq!(exec_argv("gedit %U"), vec!["gedit"]);
    assert_eq!(exec_argv("\"/opt/My App/app\" --x %f"), vec!["/opt/My App/app", "--x"]);
    assert_eq!(exec_argv("sh -c \"echo 100%%\""), vec!["sh", "-c", "echo 100%"]);
}

#[test]
fn keysyms() {
    assert_eq!(keysym::of_char('a'), 0x61);
    assert_eq!(keysym::of_char('\n'), keysym::RETURN);
    assert_eq!(keysym::of_char('é'), 0xe9);
    assert_eq!(keysym::of_char('€'), 0x0100_20ac);
    assert_eq!(keysym::of_key(&Key::F(1)), 0xffbe);
    assert_eq!(keysym::of_key(&Key::F(12)), 0xffc9);
    let c = KeyCombo::parse("ctrl+shift+Left").unwrap();
    assert_eq!(keysym::of_key(&c.key), 0xff51);
    assert_eq!(keysym::of_modifier(Modifier::Fn), None);
}

#[test]
fn keymap_lists_every_key() {
    let map = keysym::keymap_for(&[keysym::CONTROL_L, 0x61, 0x0100_20ac]);
    assert!(map.contains("<K9> = 9;"));
    assert!(map.contains("key <K9> { [ Control_L ] };"));
    assert!(map.contains("key <K11> { [ 0x010020ac ] };"));
    assert!(map.contains("modifier_map Control { <K9> };"));
    assert!(map.contains("maximum = 12;"));
    assert_eq!(keysym::evdev_code(0), 1);
}

#[test]
fn crops_frames() {
    // 4x2 frame, pixel value = index.
    let rgba: Vec<u8> = (0..8u8).flat_map(|i| [i, i, i, 255]).collect();
    let (out, w, h, x, y) = crop_rgba(&rgba, 4, 2, 1, 0, 2, 5).unwrap();
    assert_eq!((w, h, x, y), (2, 2, 1, 0));
    assert_eq!(out.chunks(4).map(|p| p[0]).collect::<Vec<_>>(), vec![1, 2, 5, 6]);
    assert!(crop_rgba(&rgba, 4, 2, 5, 0, 2, 2).is_none());
}

#[test]
fn unions_rects() {
    let r = union(&[
        Rect { x: 0.0, y: 0.0, width: 100.0, height: 50.0 },
        Rect { x: 100.0, y: -20.0, width: 50.0, height: 50.0 },
    ])
    .unwrap();
    assert_eq!(r, Rect { x: 0.0, y: -20.0, width: 150.0, height: 70.0 });
}

#[test]
fn idle_ignores_own_input() {
    use idle::person_idle;
    let now = 100_000;
    assert!(person_idle(5_000, now, 0));
    // The person moved 200 ms ago and we injected nothing: not idle.
    assert!(!person_idle(200, now, 0));
    // Our own injection 210 ms ago reset the counter 200 ms ago: idle.
    assert!(person_idle(200, now, now - 210));
    // We injected 3 s ago; input 200 ms ago is the person's.
    assert!(!person_idle(200, now, now - 3_000));
}

#[test]
fn x11_pixels_convert() {
    let mut out = Vec::new();
    x11::capture::convert(&[0x30, 0x20, 0x10, 0x00], 24, 32, 1, 1, 32, &mut out).unwrap();
    assert_eq!(out, vec![0x10, 0x20, 0x30, 255]);
    let mut out = Vec::new();
    // Pure red in RGB565.
    x11::capture::convert(&0xf800u16.to_le_bytes().repeat(2), 16, 16, 1, 1, 32, &mut out).unwrap();
    assert_eq!(out, vec![255, 0, 0, 255]);
}

#[test]
fn x11_window_ids_round_trip() {
    assert_eq!(x11::window_id(0x1a00007), "0x1a00007");
    assert_eq!(x11::parse_window_id("0x1a00007"), Some(0x1a00007));
    assert_eq!(x11::parse_window_id("27262983"), Some(27262983));
    assert_eq!(x11::parse_window_id("sway:4"), None);
}

#[test]
fn sway_tree_walks() {
    let tree: serde_json::Value = serde_json::from_str(
        r#"{"type":"root","nodes":[{"type":"output","nodes":[{"type":"workspace","name":"1","nodes":[
            {"type":"con","id":4,"pid":100,"app_id":"foot","name":"foot","visible":true,"focused":false,
             "rect":{"x":0,"y":0,"width":640,"height":480},"window_rect":{"x":2,"y":2,"width":636,"height":476}}],
          "floating_nodes":[{"type":"floating_con","id":7,"pid":200,"app_id":null,"window_properties":{"class":"XTerm"},
             "name":"xterm","visible":true,"focused":true,"rect":{"x":100,"y":100,"width":200,"height":100},
             "window_rect":{"x":0,"y":0,"width":200,"height":100}}]}]}]}"#,
    )
    .unwrap();
    let mut out = Vec::new();
    wlroots::ipc::sway_walk(&tree, "", 0, true, &mut out);
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].id, "sway:4");
    assert_eq!(out[0].rect, Rect { x: 2.0, y: 2.0, width: 636.0, height: 476.0 });
    assert_eq!(out[1].app_id, "XTerm");
    assert!(out[1].layer > out[0].layer);
    assert!(wlroots::ipc::covered(&out[0], &out));
    assert!(!wlroots::ipc::covered(&out[1], &out));
}

#[test]
fn hyprland_clients_parse() {
    let clients: serde_json::Value = serde_json::from_str(
        r#"[{"address":"0xabc","mapped":true,"hidden":false,"at":[10,20],"size":[300,200],"workspace":{"id":1},
             "floating":false,"class":"kitty","title":"t","pid":42},
            {"address":"0xdef","mapped":true,"hidden":false,"at":[0,0],"size":[10,10],"workspace":{"id":2},
             "floating":true,"class":"x","title":"u","pid":43}]"#,
    )
    .unwrap();
    let monitors: serde_json::Value =
        serde_json::from_str(r#"[{"activeWorkspace":{"id":1}}]"#).unwrap();
    let active: serde_json::Value = serde_json::from_str(r#"{"address":"0xabc"}"#).unwrap();
    let w = wlroots::ipc::hypr_windows(&clients, &monitors, &active);
    assert_eq!(w[0].rect, Rect { x: 10.0, y: 20.0, width: 300.0, height: 200.0 });
    assert!(w[0].visible && w[0].focused);
    assert!(!w[1].visible && !w[1].focused);
}

#[test]
fn atspi_ids_parse_and_frames_pick() {
    let o = atspi::Obj::parse(":1.42|/org/a11y/atspi/accessible/7").unwrap();
    assert_eq!(o.id(), ":1.42|/org/a11y/atspi/accessible/7");
    assert!(atspi::Obj::parse("nope").is_none());
    assert!(atspi::Obj::parse(":1.2|relative").is_none());
    let frame = |name: &str, x: f64| atspi::Frame {
        obj: atspi::Obj { bus: ":1.1".into(), path: format!("/{name}") },
        pid: 1,
        app: "app".into(),
        name: name.into(),
        role: "frame".into(),
        extents: Some(Rect { x, y: 0.0, width: 100.0, height: 100.0 }),
        active: false,
        iconified: false,
        showing: true,
    };
    let two = vec![frame("a", 0.0), frame("b", 500.0)];
    assert_eq!(atspi::pick_frame(two.clone(), "b", None).unwrap().name, "b");
    let want = Rect { x: 501.0, y: 0.0, width: 100.0, height: 100.0 };
    assert_eq!(atspi::pick_frame(two.clone(), "?", Some(want)).unwrap().name, "b");
    // Two showing frames and nothing that tells them apart: refused.
    assert!(atspi::pick_frame(two, "?", None).is_none());
}

#[test]
fn portal_uris_decode() {
    assert_eq!(
        portal::uri_path("file:///home/a/Pictures/Screenshot%20from%202026.png").as_deref(),
        Some("/home/a/Pictures/Screenshot from 2026.png")
    );
    assert_eq!(portal::uri_path("https://x"), None);
}

#[test]
fn cursor_arrow_is_cmux_blue() {
    let (px, mask) = cursor::arrow();
    let n = cursor::SIZE as usize;
    assert_eq!(px.len(), n * n * 4);
    // Inside the arrow body: cmux blue, stored BGRA.
    let i = 8 * n + 4;
    assert!(mask[i]);
    assert_eq!(&px[i * 4..i * 4 + 4], &[0xFF, 0x84, 0x0A, 255]);
    // Far corner: transparent.
    assert!(!mask[n * n - 1]);
    assert_eq!(&px[(n * n - 1) * 4..], &[0, 0, 0, 0]);
}

#[test]
fn shell_frames_are_not_app_windows() {
    assert!(is_shell_app("gnome-shell"));
    assert!(is_shell_app("plasmashell"));
    assert!(!is_shell_app("gedit"));
}

#[test]
fn apps_resolve_without_reading_processes() {
    let apps = AppResolver::default();
    assert_eq!(apps.resolve("", "").0, "unknown");
    assert_eq!(apps.resolve("cmux-test-class-zz", "").0, "cmux-test-class-zz");
    assert_eq!(apps.resolve("", "cmux-test-instance-zz").0, "cmux-test-instance-zz");
}

#[test]
fn only_old_protocol_clients_get_a_lent_focus() {
    let (take_focus, ping, delete) = (10, 11, 12);
    // Tk: WM_DELETE_WINDOW only.
    assert!(x11::tracks_focus_from_events(&[delete], take_focus, ping));
    // A bare Xlib client: no WM_PROTOCOLS at all.
    assert!(x11::tracks_focus_from_events(&[], take_focus, ping));
    // GTK, Qt: WM_TAKE_FOCUS and _NET_WM_PING.
    assert!(!x11::tracks_focus_from_events(&[delete, take_focus, ping], take_focus, ping));
    // Chromium: _NET_WM_PING without WM_TAKE_FOCUS.
    assert!(!x11::tracks_focus_from_events(&[delete, ping], take_focus, ping));
}

#[test]
fn windows_compare_by_the_connection_that_made_them() {
    // The usual mask: each client gets 0x1fffff resource ids.
    let mask = 0x001f_ffff;
    // The same Tk app: two top-levels, and a combobox dropdown it made.
    assert!(x11::same_connection(0x0140_0003, 0x0140_00a1, mask));
    assert!(x11::same_connection(0x0140_0003, 0x015f_ff2b, mask));
    // Another app, and the window manager's frame around the first app.
    assert!(!x11::same_connection(0x0140_0003, 0x0160_0003, mask));
    assert!(!x11::same_connection(0x0140_0003, 0x0020_0011, mask));
}
