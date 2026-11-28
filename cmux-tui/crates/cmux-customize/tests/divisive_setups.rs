//! The divisive-defaults setups (`examples/setups`, cmuxterm-hq `docs/design/divisive-defaults.md`):
//! four opt-in bundles, one axis each. Nothing in them is a default. The design's Safe agents and
//! Autopilot are not here: every agent-autonomy key (`agents.defaultPermissionMode`,
//! `agents.autoRetry.enabled`, ...) is one only the person can change, so no setup may set it
//! (`a_setup_cannot_set_agent_autonomy`). The stacking rule the design states is checked here so
//! the files cannot drift from it: rivals (the same axis) share a key, every other pair shares
//! none, so setups on different axes stack freely; installing a rival after the other wins on the
//! keys they share; and removing a setup gives back the person's own values.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::setup::{self, Receipt, Reference, SetupSource};
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

const SETUPS: [&str; 4] = ["calm", "dense", "chat-first", "terminal-first"];
const RIVALS: [(&str, &str); 1] = [("chat-first", "terminal-first")];

fn dir(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/setups").join(name)
}

fn read(name: &str) -> setup::Setup {
    setup::read_dir(&dir(name)).unwrap_or_else(|error| panic!("{name}: not a setup: {error}"))
}

fn keys(name: &str) -> BTreeSet<String> {
    read(name).profile.settings.keys().cloned().collect()
}

fn rivals(a: &str, b: &str) -> bool {
    RIVALS.iter().any(|&(x, y)| (x == a && y == b) || (x == b && y == a))
}

/// A dotted key's value in the person's settings file (nested objects or a dotted key).
fn value(settings: &Value, key: &str) -> Option<Value> {
    if let Some(flat) = settings.get(key) {
        return Some(flat.clone());
    }
    let mut at = settings;
    for part in key.split('.') {
        at = at.get(part)?;
    }
    Some(at.clone())
}

fn settings(home: &Path) -> Value {
    let text = fs::read_to_string(home.join("config/cmux-next.json")).unwrap();
    cmux_config::jsonc::parse(&text).unwrap()
}

fn install(customize: &Customize, name: &str, at: u64) {
    let read = read(name);
    customize.plan_setup(&read, "manaflow-ai", "0.0.0").unwrap_or_else(|e| panic!("{name}: {e}"));
    let installed = customize
        .install_setup(&read, &format!("setup {}", read.manifest.id), "cli", at)
        .unwrap_or_else(|error| panic!("{name}: does not install: {error}"));
    let reference =
        Reference::parse(&format!("github.com/manaflow-ai/cmux/examples/setups/{name}")).unwrap();
    customize
        .record_setup(Receipt::new(
            &read,
            &installed,
            SetupSource::Repo { reference },
            &"0".repeat(40),
            Vec::new(),
            at,
        ))
        .unwrap();
    let status = customize.status().unwrap();
    assert!(status.problems.is_empty(), "{name}: installs with problems: {:?}", status.problems);
}

fn remove(customize: &Customize, name: &str, at: u64) {
    let id = read(name).manifest.id;
    let found = customize.setup(&id).unwrap().unwrap_or_else(|| panic!("{name}: not recorded"));
    customize.remove_setup(&found, "cli", at).unwrap();
}

#[test]
fn every_setup_is_settings_only_on_one_axis() {
    for name in SETUPS {
        let read = read(name);
        assert_eq!(read.manifest.id, format!("manaflow-ai/{name}-setup"));
        assert!(read.profile.files.is_empty(), "{name}: a setup carries no files");
        assert!(read.actions().is_empty(), "{name}: a setup runs no commands");
        assert!(read.manifest.extensions.is_empty(), "{name}: a setup installs no extensions");
        assert!(!read.profile.settings.is_empty(), "{name}: sets nothing");
        assert!(dir(name).join("README.md").is_file(), "{name}: no README");
    }
}

#[test]
fn terminal_first_starts_new_tabs_in_a_terminal() {
    assert_eq!(
        value(&json!(read("terminal-first").profile.settings), "tabs.newTabTemplate"),
        Some(json!("terminal"))
    );
}

#[test]
fn rivals_share_a_key_and_every_other_pair_shares_none() {
    for (i, a) in SETUPS.iter().enumerate() {
        for b in &SETUPS[i + 1..] {
            let shared: Vec<String> = keys(a).intersection(&keys(b)).cloned().collect();
            if rivals(a, b) {
                assert!(!shared.is_empty(), "{a} and {b} are rivals but share no key");
            } else {
                assert!(
                    shared.is_empty(),
                    "{a} and {b} are on different axes but share {shared:?}"
                );
            }
        }
    }
}

#[test]
fn setups_on_different_axes_stack_and_each_removes_alone() {
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let stack = ["dense", "terminal-first", "calm"];
    for (at, name) in stack.iter().enumerate() {
        install(&customize, name, 10 + at as u64);
    }
    let live = settings(home.path());
    for name in stack {
        for (key, want) in &read(name).profile.settings {
            assert_eq!(value(&live, key).as_ref(), Some(want), "{name}: {key} after the stack");
        }
    }
    remove(&customize, "terminal-first", 20);
    let live = settings(home.path());
    for name in ["dense", "calm"] {
        for (key, want) in &read(name).profile.settings {
            assert_eq!(
                value(&live, key).as_ref(),
                Some(want),
                "{name}: {key} after a neighbour left"
            );
        }
    }
}

#[test]
fn a_rival_installed_second_wins_on_the_shared_keys() {
    for (first, second) in RIVALS {
        let home = tempfile::tempdir().unwrap();
        let customize = Customize::open(Roots::under(home.path()));
        install(&customize, first, 10);
        install(&customize, second, 11);
        let live = settings(home.path());
        for (key, want) in &read(second).profile.settings {
            assert_eq!(value(&live, key).as_ref(), Some(want), "{second} over {first}: {key}");
        }
    }
}

#[test]
fn removing_a_setup_gives_back_your_own_values() {
    let home = tempfile::tempdir().unwrap();
    fs::create_dir_all(home.path().join("config")).unwrap();
    fs::write(
        home.path().join("config/cmux-next.json"),
        "{\n  // mine\n  \"appearance\": { \"density\": \"compact\" },\n  \"terminal\": { \"fontSize\": 15 }\n}\n",
    )
    .unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    install(&customize, "dense", 10);
    assert_eq!(value(&settings(home.path()), "appearance.density"), Some(json!("ultraCompact")));
    remove(&customize, "dense", 20);
    let live = settings(home.path());
    assert_eq!(value(&live, "appearance.density"), Some(json!("compact")), "yours is back");
    assert_eq!(value(&live, "terminal.fontSize"), Some(json!(15)), "your other keys stay");
    assert_eq!(value(&live, "tabs.barPosition"), None, "the setup's own key comes off");
}

/// Why the design's Safe agents and Autopilot are not setups: a profile may not grant or take an
/// agent's autonomy; the person picks it (first run, Settings). If this starts passing an install,
/// the security rule changed and the two can come back.
#[test]
fn a_setup_cannot_set_agent_autonomy() {
    let root = tempfile::tempdir().unwrap();
    fs::write(
        root.path().join(setup::SETUP_FILE),
        r#"{"cmuxSetup": 1, "id": "manaflow-ai/autopilot-setup", "name": "Autopilot", "cmuxProfile": 1,
            "settings": {"agents.defaultPermissionMode": "fullAccess"}}"#,
    )
    .unwrap();
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let refused = setup::read_dir(root.path()).map_err(|e| e.to_string()).and_then(|read| {
        customize.plan_setup(&read, "manaflow-ai", "0.0.0").map_err(|e| e.to_string())?;
        customize
            .install_setup(&read, "setup autopilot", "cli", 10)
            .map(|_| ())
            .map_err(|e| e.to_string())
    });
    let error = refused.expect_err("a setup set agents.defaultPermissionMode");
    assert!(error.contains("only you can change"), "{error}");
}
