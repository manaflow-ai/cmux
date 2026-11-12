//! This Mac's look for its phones (`appearance-v1`, cmux-next-ios/PROTOCOL.md
//! "Appearance"): the snapshot's shape, the theme for both appearances, who
//! may set the background or read its path, and `appearance-changed`
//! (coalesced, and well under a second after a settings write).

use super::*;
use crate::mux::appearance::APPEARANCE_CAPABILITY;
use crate::mux::settings::SettingsPaths;
use cmd_subscribe::subscribed_event_json;
use std::time::{Duration, Instant};

struct Rig {
    mux: Arc<Mux>,
    dir: cmux_unix_socket::TestDir,
}

/// A mux whose settings owner has its own file and whose Ghostty config is
/// a fixture with two themes, `TestDark` and `TestLight`.
fn rig(name: &str) -> Rig {
    let dir = cmux_unix_socket::short_test_dir(&format!("apr-{name}"));
    let themes = dir.path().join("ghostty/themes");
    std::fs::create_dir_all(&themes).unwrap();
    std::fs::write(
        themes.join("TestDark"),
        "background = #101010\nforeground = #eeeeee\npalette = 1=#ff0000\ncursor-color = #abcdef\n",
    )
    .unwrap();
    std::fs::write(themes.join("TestLight"), "background = #fafafa\nforeground = #111111\n")
        .unwrap();
    let ghostty = dir.path().join("ghostty/config");
    std::fs::write(&ghostty, "font-size = 12\n").unwrap();
    let mux = test_mux();
    assert!(mux.start_settings_owner(SettingsPaths {
        config: dir.path().join("cmux-next.json"),
        seed: None,
        state_dir: Some(dir.path().to_path_buf()),
        reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
        watch: false,
    }));
    mux.set_appearance_env_for_test(cmux_theme_tokens::Env {
        home: Some(dir.path().to_path_buf()),
        xdg_config_home: Some(dir.path().to_path_buf()),
        only_file: Some(ghostty),
        ..Default::default()
    });
    Rig { mux, dir }
}

#[derive(Clone, Copy)]
enum Via {
    Local,
    MobileHost,
    App,
}

impl Rig {
    fn connection(&self, via: Via) -> (u64, MessageWriter) {
        let writer = test_writer();
        let client = self.mux.control_clients.register(ClientTransport::Unix, writer.clone());
        match via {
            Via::Local => {}
            Via::MobileHost => origin_gate::set_mobile_host_peer_for_test(&self.mux, client),
            Via::App => {
                origin_gate::set_role_for_test(&self.mux, client, "main");
                origin_gate::set_verified_app_for_test(&self.mux, client, true);
            }
        }
        (client, writer)
    }

    fn run(&self, via: Via, request: Value) -> anyhow::Result<Value> {
        let (client, writer) = self.connection(via);
        handle_command(&self.mux, client, json_command(request), &writer)
    }

    fn set(&self, key: &str, value: Value) {
        self.mux
            .settings_apply(cmux_config::Op::Set {
                target: cmux_config::Target::Key(key.to_string()),
                value,
                meta: cmux_config::WriteMeta {
                    origin: cmux_config::Origin::App,
                    idempotency_key: None,
                    if_revision: None,
                },
            })
            .unwrap_or_else(|refusal| panic!("{key}: {refusal:?}"));
    }

    fn snapshot(&self) -> Value {
        self.run(Via::Local, json!({"cmd":"get-appearance"})).unwrap()["appearance"].clone()
    }

    /// An exported background file and its `set-appearance-background` value.
    fn background(&self) -> Value {
        let file = self.dir.path().join("mobile-appearance.jpg");
        std::fs::write(&file, b"\xff\xd8\xff\xe0 not really a jpeg").unwrap();
        json!({
            "path": file.to_string_lossy(),
            "sha256": "ab".repeat(32),
            "width": 2560,
            "height": 1600,
            "luminance": 0.25,
        })
    }
}

/// Waits for the next `appearance-changed` on `events`.
fn next_appearance_event(events: &crate::MuxEventReceiver, within: Duration) -> Option<u64> {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        match events.recv_timeout(left) {
            Ok(MuxEvent::AppearanceChanged { revision }) => return Some(revision),
            Ok(_) => continue,
            Err(_) => return None,
        }
    }
}

#[test]
fn appearance_is_advertised_and_its_event_has_the_wire_shape() {
    assert!(capabilities::build_capabilities().contains(&APPEARANCE_CAPABILITY));
    assert_eq!(
        subscribed_event_json(&MuxEvent::AppearanceChanged { revision: 7 }),
        json!({"event":"appearance-changed","revision":7})
    );
}

#[test]
fn appearance_snapshot_has_the_protocol_shape() {
    let rig = rig("shape");
    rig.set("appearance.chromeStyle", json!("two-tone"));
    rig.set("terminal.fontSize", json!(15));
    rig.set("home.bubbleColors.sent", json!("#336699"));
    let snapshot = rig.snapshot();
    for key in [
        "revision",
        "theme",
        "accent",
        "chrome_style",
        "hue",
        "saturation",
        "glass_transparency",
        "sidebar_surface",
        "terminal",
        "chat",
        "groups",
        "background",
    ] {
        assert!(snapshot.get(key).is_some(), "missing {key}: {snapshot}");
    }
    assert!(snapshot["revision"].as_u64().unwrap() >= 3);
    assert_eq!(snapshot["chrome_style"], "two-tone");
    assert_eq!(snapshot["terminal"]["font_size"], 15);
    assert_eq!(snapshot["chat"]["sent"], "#336699");
    for key in ["sent_text", "received", "received_text"] {
        assert!(snapshot["chat"].get(key).is_some());
    }
    assert!(snapshot["groups"].get("palette").is_some());
    assert!(snapshot["groups"].get("gradient").is_some());
    assert_eq!(snapshot["background"], Value::Null);
    let input = &snapshot["theme"]["dark"]["input"];
    for key in ["background", "foreground", "palette", "background_opacity", "background_blur"] {
        assert!(input.get(key).is_some(), "missing input {key}: {input}");
    }
    assert_eq!(input["palette"].as_array().unwrap().len(), 16);
    assert!(input.get("accent").is_none());
}

#[test]
fn appearance_theme_resolves_both_appearances() {
    let rig = rig("pair");
    rig.set("appearance.theme", json!("light:TestLight,dark:TestDark"));
    let theme = rig.snapshot()["theme"].clone();
    assert_eq!(theme["dark"]["name"], "TestDark", "{theme}");
    assert_eq!(theme["dark"]["input"]["background"], "#101010");
    assert_eq!(theme["dark"]["input"]["palette"][1], "#FF0000");
    assert_eq!(theme["dark"]["input"]["cursor"], "#ABCDEF");
    assert_eq!(theme["light"]["name"], "TestLight");
    assert_eq!(theme["light"]["input"]["background"], "#FAFAFA");
    assert!(theme["light"]["input"].get("cursor").is_none());
    assert_eq!(theme["follows_system"], true);
    // One theme: the same input twice, not following the system.
    rig.set("appearance.theme", json!("TestDark"));
    let theme = rig.snapshot()["theme"].clone();
    assert_eq!(theme["dark"], theme["light"]);
    assert_eq!(theme["light"]["input"]["background"], "#101010");
    assert_eq!(theme["follows_system"], false);
    // A theme edit of the app (`appearance.themeEdits`) is applied.
    rig.set(
        "appearance.themeEdits",
        json!({"TestDark/background": "#202020", "TestDark/accent": "#00ff00"}),
    );
    let input = rig.snapshot()["theme"]["dark"]["input"].clone();
    assert_eq!(input["background"], "#202020");
    assert_eq!(input["accent_color"], "#00FF00");
}

#[test]
fn appearance_background_is_the_apps_only_and_its_path_stays_on_the_mac() {
    let rig = rig("forbidden");
    let background = rig.background();
    let set = json!({"cmd":"set-appearance-background","background":background});
    for via in [Via::MobileHost, Via::Local] {
        let error = rig.run(via, set.clone()).unwrap_err().to_string();
        assert!(error.starts_with("forbidden"), "{error}");
    }
    assert_eq!(rig.snapshot()["background"], Value::Null);
    let before = rig.mux.appearance_revision();
    rig.run(Via::App, set.clone()).unwrap();
    assert!(rig.mux.appearance_revision() > before);
    let shown = rig.snapshot()["background"].clone();
    assert_eq!(shown["sha256"], "ab".repeat(32));
    assert_eq!(shown["width"], 2560);
    assert_eq!(shown["luminance"], 0.25);
    assert!(shown["bytes"].as_u64().unwrap() > 0);
    assert!(shown.get("path").is_none(), "{shown}");
    // Only the app and cmux-mobile-host read the path.
    let error = rig
        .run(Via::Local, json!({"cmd":"get-appearance","include_path":true}))
        .unwrap_err()
        .to_string();
    assert!(error.starts_with("forbidden"), "{error}");
    for via in [Via::MobileHost, Via::App] {
        let read = rig.run(via, json!({"cmd":"get-appearance","include_path":true})).unwrap();
        assert_eq!(read["appearance"]["background"]["path"], background["path"]);
    }
    // The same value again changes nothing; a missing file is refused.
    let revision = rig.mux.appearance_revision();
    rig.run(Via::App, set).unwrap();
    assert_eq!(rig.mux.appearance_revision(), revision);
    let mut missing = background;
    missing["path"] = json!(rig.dir.path().join("gone.jpg").to_string_lossy());
    let error = rig
        .run(Via::App, json!({"cmd":"set-appearance-background","background":missing}))
        .unwrap_err()
        .to_string();
    assert!(error.starts_with("bad request"), "{error}");
    rig.run(Via::App, json!({"cmd":"set-appearance-background","background":null})).unwrap();
    assert_eq!(rig.snapshot()["background"], Value::Null);
}

#[test]
fn appearance_changed_is_coalesced_to_one_per_window() {
    let rig = rig("coalesce");
    let events = rig.mux.subscribe();
    let mut last = 0;
    for _ in 0..500 {
        last = rig.mux.note_appearance_changed();
    }
    let mut seen = Vec::new();
    while let Some(revision) = next_appearance_event(&events, Duration::from_millis(300)) {
        seen.push((Instant::now(), revision));
    }
    assert!(!seen.is_empty() && seen.len() <= 3, "{} events for one burst", seen.len());
    assert_eq!(seen.last().unwrap().1, last, "the last event carries the newest revision");
    for pair in seen.windows(2) {
        let gap = pair[1].0.duration_since(pair[0].0);
        assert!(gap >= Duration::from_millis(40), "two events {gap:?} apart");
        assert!(pair[1].1 > pair[0].1);
    }
    // A settings key outside the appearance sends nothing.
    rig.set("workspaces.freeing.enabled", json!(true));
    assert_eq!(next_appearance_event(&events, Duration::from_millis(150)), None);
}

#[test]
fn appearance_changed_follows_a_settings_write_well_under_a_second() {
    let rig = rig("latency");
    // Resolve once, as a phone that already holds a snapshot did.
    rig.snapshot();
    let events = rig.mux.subscribe();
    let mut samples = Vec::new();
    for (index, hue) in [0.1, 0.2, 0.3, 0.4, 0.6].into_iter().enumerate() {
        // Past the coalescing window, so each write is a leading event.
        std::thread::sleep(crate::mux::appearance::COALESCE_WINDOW * 2);
        let start = Instant::now();
        rig.set("appearance.hue", json!(hue));
        let revision = next_appearance_event(&events, Duration::from_secs(1))
            .unwrap_or_else(|| panic!("no appearance-changed for write {index}"));
        samples.push(start.elapsed());
        assert_eq!(rig.snapshot()["hue"], json!(hue));
        assert!(revision > 0);
    }
    let worst = samples.iter().max().unwrap();
    println!("appearance-v1: settings write -> appearance-changed: {samples:?} (worst {worst:?})");
    assert!(*worst < Duration::from_millis(250), "settings write to event took {worst:?}");
}
