//! Switch Automatically keeps each mode's background for every writer (Leo, 2026-11-19: "switched
//! around from the rotating to day/night/whatever but it lost the folder or something idk i couldn't
//! get back into it?"): a `settings.set` (the CLI, MCP), a `settings.edit` (the Mac app, Settings,
//! the palette) and a hand edit of the file that leave Off, Rotate or Sun record its source in
//! `appearance.backgroundModes`.

use cmux_config::{
    ConfigStore, Domains, Edit, EditKind, FileRead, ManagedPreferences, Op, Origin, Schema, State,
    Target, TeamPolicyLayer, WriteMeta, apply,
};
use serde_json::{Value, json};

const FOLDER: &str = "folder:/Users/me/Wallpapers";

fn state(root: Value) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(root.to_string()),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

fn written(state: &State, op: Op) -> Value {
    let text = apply(state, op).expect("the write applies").write.expect("the file changes");
    serde_json::from_str(&text).expect("JSON")
}

fn meta(origin: Origin) -> WriteMeta {
    WriteMeta { origin, ..WriteMeta::default() }
}

#[test]
fn a_settings_set_that_leaves_rotate_keeps_the_folder() {
    for origin in [Origin::Cli, Origin::Mcp, Origin::User] {
        let before = state(json!({ "appearance": { "background": FOLDER } }));
        let op = Op::Set {
            target: Target::Key("appearance.background".into()),
            value: json!("appearance"),
            meta: meta(origin),
        };
        let root = written(&before, op);
        assert_eq!(
            root.pointer("/appearance/background"),
            Some(&json!("appearance")),
            "{origin:?}"
        );
        assert_eq!(
            root.pointer("/appearance/backgroundModes"),
            Some(&json!({ "rotate": FOLDER })),
            "{origin:?}"
        );
    }
}

#[test]
fn an_app_edit_that_leaves_sun_and_off_keeps_both() {
    let sonoma = "system:/System/Library/Desktop Pictures/Sonoma.heic";
    let before = state(json!({
        "appearance": { "background": sonoma, "backgroundDynamic": "time", "backgroundModes": { "rotate": FOLDER } }
    }));
    // Sun to Off, the way Settings writes it: Off's picture, then the dynamic mode reset.
    let op = Op::Edit {
        edits: vec![
            Edit {
                target: Target::Key("appearance.background".into()),
                kind: EditKind::Set(json!("file:/Users/me/Harbor.png")),
            },
            Edit {
                target: Target::Key("appearance.backgroundDynamic".into()),
                kind: EditKind::Reset,
            },
        ],
        meta: meta(Origin::App),
    };
    let root = written(&before, op);
    assert_eq!(
        root.pointer("/appearance/backgroundModes"),
        Some(&json!({ "rotate": FOLDER, "sun": sonoma }))
    );
}

#[test]
fn a_write_inside_one_mode_keeps_nothing() {
    let before = state(json!({ "appearance": { "background": FOLDER } }));
    let op = Op::Set {
        target: Target::Key("appearance.background".into()),
        value: json!("daily"),
        meta: meta(Origin::Cli),
    };
    assert_eq!(written(&before, op).pointer("/appearance/backgroundModes"), None);
}

#[cfg(unix)]
#[test]
fn a_hand_edit_that_leaves_rotate_keeps_the_folder() {
    let dir = std::env::temp_dir().join(format!("cmux-backdrop-modes-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, json!({ "appearance": { "background": FOLDER } }).to_string()).unwrap();
    let reader = Box::new(cmux_config::managed::FixedManagedReader::default());
    let mut store = ConfigStore::open(config.clone(), None, None, reader);
    std::fs::write(
        &config,
        "{\n  // mine\n  \"appearance\": { \"background\": \"appearance\" }\n}\n",
    )
    .unwrap();
    let change = store.reload().expect("a change");
    assert!(change.keys.iter().any(|key| key == "appearance.backgroundModes"), "{:?}", change.keys);
    let text = std::fs::read_to_string(&config).unwrap();
    assert!(text.contains("// mine"), "the person's comment stays: {text}");
    let root = cmux_config::jsonc::parse(&text).unwrap();
    assert_eq!(root.pointer("/appearance/background"), Some(&json!("appearance")));
    assert_eq!(root.pointer("/appearance/backgroundModes"), Some(&json!({ "rotate": FOLDER })));
    // The write-back is not itself a mode change: the next reload changes nothing.
    assert_eq!(store.reload(), None);
    let _ = std::fs::remove_dir_all(&dir);
}
