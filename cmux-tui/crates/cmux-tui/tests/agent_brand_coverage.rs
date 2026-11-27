//! Every agent-hook provider cmux-tui installs is known to the agent brand catalog
//! (design/agent-icons/manifest.json, R79), so every client can draw its mark or knows
//! it has none. A new provider fails here until the manifest lists it, then
//! scripts/agent-icons/generate.py regenerates the Swift and TypeScript catalogs.

use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;

fn manifest_ids() -> BTreeSet<String> {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../design/agent-icons/manifest.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let manifest: serde_json::Value = serde_json::from_str(&text).unwrap();
    let mut ids = BTreeSet::new();
    for agent in manifest["agents"].as_array().unwrap() {
        ids.insert(agent["id"].as_str().unwrap().to_lowercase());
        for alias in agent["aliases"].as_array().unwrap() {
            ids.insert(alias.as_str().unwrap().to_lowercase());
        }
    }
    for key in ["providers", "brands"] {
        for entry in manifest[key].as_array().unwrap() {
            ids.insert(entry["id"].as_str().unwrap().to_lowercase());
        }
    }
    ids
}

/// The provider ids `cmux agent hook status` reports, run against an empty home so it
/// only reads (nothing is installed there).
fn hook_provider_ids() -> Vec<String> {
    let home = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "agent", "hook", "status"])
        .env("HOME", home.path())
        .env("LC_ALL", "C")
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let start = stdout.find('{').unwrap_or_else(|| {
        panic!("no JSON in output: {stdout} {}", String::from_utf8_lossy(&output.stderr))
    });
    let value: serde_json::Value = serde_json::from_str(&stdout[start..]).unwrap();
    let mut ids: Vec<String> = value["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["provider"].as_str().unwrap().to_owned())
        .collect();
    // A provider whose status check errors is reported as "<id>: <error>".
    for error in value["errors"].as_array().into_iter().flatten() {
        if let Some((id, _)) = error.as_str().and_then(|text| text.split_once(':')) {
            ids.push(id.trim().to_owned());
        }
    }
    ids
}

#[test]
fn every_hook_provider_is_in_the_agent_brand_manifest() {
    let known = manifest_ids();
    let providers = hook_provider_ids();
    assert!(providers.len() >= 15, "status listed too few providers: {providers:?}");
    let missing: Vec<&String> =
        providers.iter().filter(|id| !known.contains(&id.to_lowercase())).collect();
    assert!(
        missing.is_empty(),
        "add these hook providers to design/agent-icons/manifest.json: {missing:?}"
    );
}
