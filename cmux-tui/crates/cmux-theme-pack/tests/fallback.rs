//! Garbage and crashing packs fall back cleanly: a pack with nothing to read
//! is refused whole (the look in use stays), anything else loses only the
//! values, slots or assets that are wrong, and the compiled theme file the
//! app reads never carries a value the app would refuse.

use std::path::Path;

use cmux_config::domains::Domains;
use cmux_config::schema::Schema;
use cmux_config::theme_file::{ThemeDiagnosticKind, ThemeFile};
use cmux_theme_pack::{Capability, Context, LoadError, Pack, load};
use serde_json::{Map, Value, json};

fn context(base: &Value) -> Context<'_> {
    Context { schema: Schema::embedded(), domains: domains(), base }
}

fn domains() -> &'static Domains {
    static DOMAINS: std::sync::OnceLock<Domains> = std::sync::OnceLock::new();
    DOMAINS.get_or_init(Domains::default)
}

fn write_pack(dir: &Path, manifest: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("cmux-pack.json"), manifest).unwrap();
}

fn read(dir: &Path) -> Result<Pack, LoadError> {
    let base = json!({});
    load(dir, &Map::new(), &context(&base))
}

/// The compiled file as the app reads it: no refused value may be left.
fn assert_app_clean(pack: &Pack) {
    let text = pack.theme_text();
    let file = ThemeFile::read(
        "pack",
        Some(Ok(text.as_str())),
        &json!({}),
        None,
        Schema::embedded(),
        domains(),
    );
    let refused: Vec<String> = file
        .diagnostics
        .iter()
        .filter(|d| d.kind == ThemeDiagnosticKind::InvalidValue)
        .map(|d| d.display())
        .collect();
    assert!(refused.is_empty(), "the app would refuse: {refused:?}\n{text}");
}

const GOOD: &str = r##"{
  // A pack with one value per capability.
  "cmuxPack": 1,
  "id": "cmux/test-good",
  "name": "Good",
  "capabilities": ["tokens", "colors", "backgrounds", "motion", "fonts", "components"],
  "look": {
    "appearance.theme": "Soft Blue",
    "appearance.accent": "theme",
    "appearance.backgroundOpacity": 0.9,
    "terminal.fontSize": 14,
    "sidebar": { "sectionLook": "card" }
  },
  "colors": { "background": "#101418", "foreground": "#e8eef2" },
  "slots": { "chat.thinkingIndicator": "pulse" }
}"##;

#[test]
fn a_good_pack_applies_every_value() {
    let dir = tempfile::tempdir().unwrap();
    write_pack(dir.path(), GOOD);
    let pack = read(dir.path()).unwrap();
    assert!(pack.diagnostics.is_empty(), "{:?}", pack.diagnostics);
    assert_eq!(pack.id, "cmux/test-good");
    assert_eq!(pack.theme_name(), "pack-cmux-test-good");
    for key in [
        "appearance.theme",
        "appearance.accent",
        "appearance.backgroundOpacity",
        "terminal.fontSize",
        "sidebar.sectionLook",
    ] {
        assert!(pack.theme.contains_key(key), "{key} missing from {:?}", pack.theme);
    }
    assert_eq!(pack.theme["colors"]["background"], "#101418");
    assert_eq!(pack.theme["slots"]["chat.thinkingIndicator"], "pulse");
    assert_app_clean(&pack);
}

#[test]
fn nothing_to_read_refuses_the_whole_pack() {
    let root = tempfile::tempdir().unwrap();
    let deep = format!("{}{}", "[".repeat(5000), "]".repeat(5000));
    let huge = format!("{{\"cmuxPack\":1,\"name\":\"{}\"}}", "x".repeat(600 * 1024));
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("binary", vec![0, 159, 146, 150, 255, 0, 1, 2]),
        ("truncated", br#"{"cmuxPack":1,"look":{"appearance.accent":"#.to_vec()),
        ("array", b"[1,2,3]".to_vec()),
        ("string", b"\"cmuxPack\"".to_vec()),
        ("no-format", br#"{"id":"a/b","look":{}}"#.to_vec()),
        ("format-as-text", br#"{"cmuxPack":"1"}"#.to_vec()),
        ("format-negative", br#"{"cmuxPack":-1}"#.to_vec()),
        ("deep", deep.into_bytes()),
        ("huge", huge.into_bytes()),
        ("nul", b"{\"cmuxPack\":1,\0}".to_vec()),
    ];
    for (name, bytes) in cases {
        let dir = root.path().join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("cmux-pack.json"), bytes).unwrap();
        assert!(read(&dir).is_err(), "{name} should be refused whole");
    }
    let empty = root.path().join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    assert!(matches!(read(&empty), Err(LoadError::NoManifest(_))));
    let manifest_dir = root.path().join("manifest-is-a-folder");
    std::fs::create_dir_all(manifest_dir.join("cmux-pack.json")).unwrap();
    assert!(read(&manifest_dir).is_err());
}

#[test]
fn bad_values_fall_back_one_at_a_time() {
    let dir = tempfile::tempdir().unwrap();
    write_pack(
        dir.path(),
        r##"{
          "cmuxPack": 1,
          "id": "NOT A VALID ID",
          "name": 42,
          "capabilities": ["tokens", "colors", "components", "shell", 7],
          "plugins": ["rm -rf /"],
          "look": {
            "appearance.theme": "Soft Blue",
            "appearance.accent": "theme",
            "appearance.accentt": "pink",
            "appearance.backgroundOpacity": 0.5,
            "terminal.fontSize": "big",
            "sidebar.sectionLook": "not-a-look",
            "ui.animationSpeed": 2,
            "appearance.metrics.chromeFontSize": 13,
            "agent.defaultHarness": "codex"
          },
          "colors": { "background": "#101418", "foreground": "not a color" },
          "slots": {
            "chat.thinkingIndicator": "pulse",
            "chat.jumpToBottom": "explode",
            "chat.unknownSlot": "default"
          }
        }"##,
    );
    let pack = read(dir.path()).unwrap();
    // The good values survive.
    assert_eq!(pack.theme["appearance.accent"], "theme");
    assert_eq!(pack.theme["colors"]["background"], "#101418");
    assert_eq!(pack.theme["slots"]["chat.thinkingIndicator"], "pulse");
    // Each bad one is named alone and is gone.
    let named = |key: &str| pack.diagnostics.iter().any(|d| d.key.as_deref() == Some(key));
    for key in [
        "id",
        "plugins",
        "appearance.accentt",
        "appearance.backgroundOpacity",
        "terminal.fontSize",
        "sidebar.sectionLook",
        "ui.animationSpeed",
        "appearance.metrics.chromeFontSize",
        "agent.defaultHarness",
        "foreground",
        "chat.jumpToBottom",
        "chat.unknownSlot",
    ] {
        assert!(named(key), "no diagnostic for {key}: {:#?}", pack.diagnostics);
        assert!(!pack.theme.contains_key(key), "{key} should be dropped");
    }
    assert!(pack.theme["colors"].get("foreground").is_none());
    assert!(pack.theme["slots"].get("chat.jumpToBottom").is_none());
    assert!(pack.diagnostics.iter().any(|d| d.key.as_deref() == Some("name")));
    assert_eq!(pack.theme["name"], json!(pack.id), "a bad name falls back to the id");
    assert_eq!(pack.capabilities.len(), 3);
    assert!(pack.id.starts_with("local/"));
    assert_app_clean(&pack);
}

#[test]
fn a_pack_changes_only_what_it_declares() {
    let dir = tempfile::tempdir().unwrap();
    write_pack(
        dir.path(),
        r##"{
          "cmuxPack": 1, "id": "cmux/narrow", "capabilities": ["motion"],
          "look": { "ui.animationSpeed": "fast", "appearance.accent": "theme", "appearance.backgroundOpacity": 0.5 },
          "colors": { "background": "#000000" },
          "slots": { "chat.thinkingIndicator": "pulse" }
        }"##,
    );
    let pack = read(dir.path()).unwrap();
    assert_eq!(pack.capabilities.iter().copied().collect::<Vec<_>>(), vec![Capability::Motion]);
    assert!(pack.theme.contains_key("ui.animationSpeed"), "{:?}", pack.diagnostics);
    for key in ["appearance.accent", "appearance.backgroundOpacity", "colors", "slots"] {
        assert!(!pack.theme.contains_key(key), "{key} applied without its capability");
    }
    let none = tempfile::tempdir().unwrap();
    write_pack(
        none.path(),
        r#"{"cmuxPack": 1, "id": "cmux/none", "look": {"appearance.accent": "theme"}}"#,
    );
    let pack = read(none.path()).unwrap();
    assert!(pack.keys().is_empty());
    assert!(pack.diagnostics.iter().any(|d| d.section == "capabilities"));
}

#[test]
fn assets_stay_inside_the_pack() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("pack");
    std::fs::create_dir_all(dir.join("assets/folder")).unwrap();
    std::fs::write(dir.join("assets/ok.png"), b"\x89PNG").unwrap();
    std::fs::write(dir.join("assets/run.sh"), b"#!/bin/sh").unwrap();
    std::fs::write(root.path().join("secret.png"), b"\x89PNG").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(root.path().join("secret.png"), dir.join("assets/escape.png"))
        .unwrap();
    let cases = [
        ("file:assets/ok.png", true),
        ("folder:assets/folder", true),
        ("file:../secret.png", false),
        ("file:assets/../../secret.png", false),
        ("file:/etc/passwd", false),
        ("file:~/secret.png", false),
        ("file:assets/missing.png", false),
        ("file:assets/run.sh", false),
        ("file:secret.png", false),
        ("file:", false),
        #[cfg(unix)]
        ("file:assets/escape.png", false),
    ];
    for (value, kept) in cases {
        let manifest = json!({
            "cmuxPack": 1, "id": "cmux/assets", "capabilities": ["backgrounds"],
            "look": { "appearance.background": value, "appearance.backgroundOpacity": 0.8 }
        });
        write_pack(&dir, &manifest.to_string());
        let pack = read(&dir).unwrap();
        assert!(
            pack.theme.contains_key("appearance.backgroundOpacity"),
            "{value}: the rest still applies"
        );
        let applied =
            pack.theme.get("appearance.background").and_then(Value::as_str).map(str::to_string);
        if kept {
            let applied =
                applied.unwrap_or_else(|| panic!("{value} dropped: {:?}", pack.diagnostics));
            let path = applied.split_once(':').unwrap().1;
            assert!(Path::new(path).is_absolute() && path.contains("/assets/"), "{applied}");
        } else {
            assert_eq!(applied, None, "{value} should be dropped");
            assert!(
                pack.diagnostics.iter().any(|d| d.section == "assets"),
                "{value}: {:?}",
                pack.diagnostics
            );
        }
    }
}

/// A small deterministic generator, so a failure reproduces from its seed.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

fn junk(rng: &mut Lcg) -> Value {
    match rng.below(12) {
        0 => Value::Null,
        1 => json!(rng.next() as f64 * -1e300),
        2 => json!(u64::MAX),
        3 => json!("\u{0}\u{7}\u{202e}evil"),
        4 => json!("x".repeat(rng.below(70_000))),
        5 => json!([[[[[[[[[[1]]]]]]]]]]),
        6 => json!({"nested": {"deeper": {"deepest": true}}}),
        7 => json!("file:../../../../etc/passwd"),
        8 => json!(true),
        9 => json!("#zzzzzz"),
        10 => json!(-0.0),
        _ => json!(rng.below(1000)),
    }
}

const KEYS: [&str; 10] = [
    "appearance.accent",
    "appearance.backgroundOpacity",
    "appearance.background",
    "terminal.fontSize",
    "sidebar.sectionLook",
    "ui.animationSpeed",
    "appearance",
    "no.such.key",
    "",
    "appearance.metrics.tabHeight",
];

/// Thousands of mangled packs: none panics, none is refused when it still
/// parses as a pack, and none leaves the app a value it would refuse.
#[test]
fn mangled_packs_never_crash_and_never_leak_a_bad_value() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("fuzz");
    let mut rng = Lcg(0x5eed_cafe);
    let good: Value = cmux_config::jsonc::parse(GOOD).unwrap();
    let mut loaded = 0;
    for round in 0..1500 {
        let mut manifest = good.clone();
        let edits = 1 + rng.below(6);
        for _ in 0..edits {
            let object = manifest.as_object_mut().unwrap();
            match rng.below(5) {
                0 => {
                    let key = KEYS[rng.below(KEYS.len())];
                    if let Some(Value::Object(look)) = object.get_mut("look") {
                        look.insert(key.to_string(), junk(&mut rng));
                    }
                }
                1 => {
                    let section =
                        ["look", "colors", "slots", "capabilities", "id", "name"][rng.below(6)];
                    object.insert(section.to_string(), junk(&mut rng));
                }
                2 => {
                    if let Some(Value::Object(colors)) = object.get_mut("colors") {
                        colors.insert(
                            ["background", "foreground", "0", "zz"][rng.below(4)].into(),
                            junk(&mut rng),
                        );
                    }
                }
                3 => {
                    if let Some(Value::Object(slots)) = object.get_mut("slots") {
                        slots.insert(
                            ["chat.thinkingIndicator", "x"][rng.below(2)].into(),
                            junk(&mut rng),
                        );
                    }
                }
                _ => {
                    object.insert(format!("junk{}", rng.below(5)), junk(&mut rng));
                }
            }
        }
        let mut text = manifest.to_string();
        if rng.below(10) == 0 {
            // Byte damage: a cut or a flipped byte.
            let at = rng.below(text.len());
            if rng.below(2) == 0 {
                text.truncate(at);
            } else {
                let mut bytes = text.into_bytes();
                bytes[at] ^= 0x5a;
                text = String::from_utf8_lossy(&bytes).into_owned();
            }
        }
        write_pack(&dir, &text);
        let outcome = std::panic::catch_unwind(|| read(&dir));
        let Ok(result) = outcome else { panic!("round {round} panicked on {text}") };
        if let Ok(pack) = result {
            loaded += 1;
            assert_app_clean(&pack);
        }
    }
    assert!(loaded > 1000, "only {loaded} of 1500 mangled packs loaded");
}

fn example(name: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/theme-packs").join(name)
}

/// The shipped examples: Sakura loads with nothing dropped, Garbage loads
/// with each of its marked lines dropped alone and its good values kept.
#[test]
fn the_example_packs_read_as_documented() {
    let sakura = read(&example("sakura")).unwrap();
    assert!(sakura.diagnostics.is_empty(), "{:#?}", sakura.diagnostics);
    assert_eq!(sakura.theme["slots"]["chat.thinkingIndicator"], "pulse");
    assert_app_clean(&sakura);

    let garbage = read(&example("garbage")).unwrap();
    for key in
        ["appearance.accent", "appearance.chromeStyle", "ui.animationSpeed", "sidebar.sectionLook"]
    {
        assert!(garbage.theme.contains_key(key), "{key} lost: {:#?}", garbage.diagnostics);
    }
    assert_eq!(garbage.theme["colors"]["background"], "#1f1419");
    assert_eq!(garbage.theme["slots"]["chat.thinkingIndicator"], "pulse");
    let named = |key: &str| garbage.diagnostics.iter().any(|d| d.key.as_deref() == Some(key));
    for key in [
        "id",
        "scripts",
        "terminal.fontSize",
        "appearance.noSuchKey",
        "appearance.density",
        "appearance.glassTransparency",
        "appearance.borders",
        "appearance.wallpaper",
        "appearance.backgroundLight",
        "appearance.backgroundDark",
        "cursor",
        "chat.noSuchSlot",
        "chat.jumpToBottom",
    ] {
        assert!(named(key), "no diagnostic for {key}: {:#?}", garbage.diagnostics);
    }
    assert_app_clean(&garbage);
}

/// Every string in a value is checked, not only a top-level `file:` one: a
/// `system:` picture, an absolute path and a `file:` outside the pack inside
/// a schedule object are all dropped, per key; a schedule of the pack's own
/// pictures is resolved into its assets.
#[test]
fn nested_and_system_paths_are_refused() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("pack");
    std::fs::create_dir_all(dir.join("assets")).unwrap();
    std::fs::write(dir.join("assets/ok.png"), b"\x89PNG").unwrap();
    let refused = [
        ("appearance.background", json!("system:/Library/Desktop Pictures/secret.png")),
        ("appearance.background", json!("/Users/me/secret.png")),
        ("appearance.backgroundSchedule", json!({ "07:00": "file:/Users/me/secret.png" })),
        ("appearance.backgroundSchedule", json!({ "07:00": "system:/Users/me/secret.png" })),
        ("appearance.backgroundSchedule", json!({ "07:00": ["file:../secret.png"] })),
    ];
    for (key, value) in refused {
        let manifest = json!({
            "cmuxPack": 1, "id": "cmux/nested", "capabilities": ["backgrounds"],
            "look": { key: value, "appearance.backgroundOpacity": 0.8 }
        });
        write_pack(&dir, &manifest.to_string());
        let pack = read(&dir).unwrap();
        assert!(!pack.theme.contains_key(key), "{key} = {value} should be dropped");
        assert!(
            pack.diagnostics.iter().any(|d| d.section == "assets" && d.key.as_deref() == Some(key)),
            "{key} = {value}: {:?}",
            pack.diagnostics
        );
        assert!(pack.theme.contains_key("appearance.backgroundOpacity"), "the rest still applies");
    }
    // The pack's own picture in a schedule resolves into its assets.
    let manifest = json!({
        "cmuxPack": 1, "id": "cmux/nested", "capabilities": ["backgrounds"],
        "look": { "appearance.backgroundSchedule": { "07:00": "file:assets/ok.png" } }
    });
    write_pack(&dir, &manifest.to_string());
    let pack = read(&dir).unwrap();
    assert!(!pack.diagnostics.iter().any(|d| d.section == "assets"), "{:?}", pack.diagnostics);
    if let Some(picture) =
        pack.theme.get("appearance.backgroundSchedule").and_then(|s| s["07:00"].as_str())
    {
        let path = picture.strip_prefix("file:").unwrap();
        assert!(Path::new(path).is_absolute() && path.ends_with("/assets/ok.png"), "{picture}");
    }
}

/// An `assets` folder that is a link out of the pack (here to the folder
/// holding the pack; `/` is the same) holds nothing the pack may name.
#[cfg(unix)]
#[test]
fn an_assets_link_out_of_the_pack_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join("pack");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(root.path().join("secret.png"), b"\x89PNG").unwrap();
    std::os::unix::fs::symlink(root.path(), dir.join("assets")).unwrap();
    let manifest = json!({
        "cmuxPack": 1, "id": "cmux/link", "capabilities": ["backgrounds"],
        "look": { "appearance.background": "file:assets/secret.png" }
    });
    write_pack(&dir, &manifest.to_string());
    let pack = read(&dir).unwrap();
    assert!(!pack.theme.contains_key("appearance.background"), "{:?}", pack.theme);
    assert!(pack.diagnostics.iter().any(|d| d.section == "assets"), "{:?}", pack.diagnostics);
}

/// The terminal palette needs the colors capability however a pack writes
/// it: a `ghostty` block or `appearance.themeEdits` in `look` is no token.
#[test]
fn palette_keys_in_look_need_the_colors_capability() {
    let dir = tempfile::tempdir().unwrap();
    write_pack(
        dir.path(),
        r##"{
          "cmuxPack": 1, "id": "cmux/palette", "capabilities": ["tokens"],
          "look": {
            "appearance.accent": "theme",
            "ghostty": ["background = #2e3440"],
            "appearance.themeEdits": { "Nord/background": "#2e3440" }
          }
        }"##,
    );
    let pack = read(dir.path()).unwrap();
    assert!(pack.theme.contains_key("appearance.accent"));
    for key in ["ghostty", "appearance.themeEdits"] {
        assert!(!pack.theme.contains_key(key), "{key} applied without colors: {:?}", pack.theme);
    }
    assert!(
        pack.diagnostics.iter().any(|d| d.message.contains("colors capability")),
        "{:?}",
        pack.diagnostics
    );
}
