//! Two builds on the one shared settings file (NIGHTLY and Release) each keep their own cmux
//! tools answer and Computer Use permissions (`cmux_config::build_scope`): a write through one
//! build's owner (the palette, `cmux settings`, the MCP `settings_*` tools, the app) changes only
//! that build's file, and every other preference stays shared.

use std::path::Path;

use cmux_config::managed::FixedManagedReader;
use cmux_config::{ConfigStore, ManagedPreferences, Op, Origin, Target, WriteMeta};
use serde_json::{Value, json};

fn open(config: &Path, build_file: &Path) -> ConfigStore {
    let reader = Box::new(FixedManagedReader(ManagedPreferences::default()));
    ConfigStore::open_with_build_file(
        config.to_path_buf(),
        None,
        None,
        reader,
        Some(build_file.to_path_buf()),
    )
}

fn set(store: &mut ConfigStore, key: &str, value: Value) {
    let meta = WriteMeta { origin: Origin::User, ..Default::default() };
    let applied = store.apply(Op::Set { target: Target::Key(key.into()), value, meta });
    applied.result.unwrap_or_else(|refusal| panic!("{key}: {refusal:?}"));
}

fn effective(store: &ConfigStore, pointer: &str) -> Option<Value> {
    store.state().effective().root.pointer(pointer).cloned()
}

fn file(path: &Path) -> Value {
    cmux_config::jsonc::parse(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn each_build_keeps_its_own_cmux_tools_and_computer_use_permissions() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("cmux-next.json");
    let nightly_file = root.path().join("builds/com.cmuxterm.app.nightly/build-settings.json");
    let release_file = root.path().join("builds/com.cmuxterm.app/build-settings.json");
    // What the person chose before the split, in the one shared file.
    std::fs::write(
        &config,
        "{\n  // mine\n  \"computerUse\": {\"mode\": \"fullAccess\"},\n  \"agents\": {\"cmuxMcp\": \"on\"}\n}\n",
    )
    .unwrap();
    let mut nightly = open(&config, &nightly_file);
    let mut release = open(&config, &release_file);
    // Both start from it.
    for store in [&nightly, &release] {
        assert_eq!(effective(store, "/computerUse/mode"), Some(json!("fullAccess")));
    }

    // NIGHTLY narrows Computer Use and turns cmux's tools off.
    set(&mut nightly, "computerUse.mode", json!("approvedApps"));
    set(&mut nightly, "agents.cmuxMcp", json!("off"));
    assert_eq!(effective(&nightly, "/computerUse/mode"), Some(json!("approvedApps")));
    assert_eq!(file(&nightly_file)["computerUse"]["mode"], "approvedApps");
    assert_eq!(file(&nightly_file)["agents"]["cmuxMcp"], "off");
    // The shared file was not touched: it keeps its comment and its own copy.
    let shared = std::fs::read_to_string(&config).unwrap();
    assert!(shared.contains("// mine"), "{shared}");
    assert_eq!(file(&config)["computerUse"]["mode"], "fullAccess");

    // Release, reading after the change, keeps its own.
    assert!(release.reload().is_none(), "NIGHTLY's change reached Release");
    assert_eq!(effective(&release, "/computerUse/mode"), Some(json!("fullAccess")));
    assert_eq!(effective(&release, "/agents/cmuxMcp"), Some(json!("on")));
    let reopened = open(&config, &release_file);
    assert_eq!(effective(&reopened, "/computerUse/mode"), Some(json!("fullAccess")));

    // An ordinary preference stays shared: Release writes it, NIGHTLY sees it, and NIGHTLY's
    // permission values stay NIGHTLY's.
    set(&mut release, "app.language", json!("ja"));
    assert_eq!(file(&config)["app"]["language"], "ja");
    assert_eq!(file(&config)["computerUse"]["mode"], "fullAccess");
    nightly.reload();
    assert_eq!(effective(&nightly, "/app/language"), Some(json!("ja")));
    assert_eq!(effective(&nightly, "/computerUse/mode"), Some(json!("approvedApps")));
    assert_eq!(effective(&nightly, "/agents/cmuxMcp"), Some(json!("off")));
}

/// A hand-broken build file is never overwritten by a settings write: the write is refused and
/// the file stays for the person to fix.
#[test]
fn a_write_never_replaces_a_broken_build_file() {
    let root = tempfile::tempdir().unwrap();
    let config = root.path().join("cmux-next.json");
    let build_file = root.path().join("build-settings.json");
    std::fs::write(&config, "{}\n").unwrap();
    std::fs::write(&build_file, "{\"computerUse\": ").unwrap();
    let mut store = open(&config, &build_file);
    let meta = WriteMeta { origin: Origin::User, ..Default::default() };
    let applied = store.apply(Op::Set {
        target: Target::Key("computerUse.mode".into()),
        value: json!("approvedApps"),
        meta,
    });
    assert!(applied.result.is_err(), "the broken build file was written over");
    assert_eq!(std::fs::read_to_string(&build_file).unwrap(), "{\"computerUse\": ");
}
