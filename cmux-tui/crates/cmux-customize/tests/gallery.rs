//! The examples gallery (`examples/gallery/gallery.json`): one index over every example look,
//! showcase profile and extension in the repo, in the shape a customization repo of its own would
//! publish. Every look it lists must read, plan and install on a fresh machine with nothing to fix,
//! remove back to nothing, and name the surfaces its folder really uses; a look that needs an
//! unmerged change (`needs`) must still read, and its particles document must hold together.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::setup::{self, Reference};
use cmux_customize::{Customize, Roots};
use serde_json::Value;

fn examples() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples")
}

fn index() -> Value {
    let text = fs::read_to_string(examples().join("gallery/gallery.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn entries(kind: &str) -> Vec<Value> {
    index()["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["kind"] == kind)
        .cloned()
        .collect()
}

/// What `cmux setup install` takes for a look in this repo.
fn install_reference(entry: &Value) -> String {
    let index = index();
    format!(
        "{}/{}/{}@{}",
        index["repository"].as_str().unwrap(),
        index["root"].as_str().unwrap(),
        entry["path"].as_str().unwrap(),
        index["ref"].as_str().unwrap()
    )
}

/// The surfaces a look's folder uses, by what it holds.
fn surfaces_of(dir: &Path, manifest: &setup::Manifest) -> Vec<&'static str> {
    let mut found = Vec::new();
    let glyph = "agentPane.display.thinking.glyph";
    if manifest.settings.keys().any(|key| key != "appearance.themeFile" && key != glyph) {
        found.push("settings");
    }
    let themes = dir.join("themes");
    if themes.is_dir()
        && fs::read_dir(&themes)
            .unwrap()
            .any(|entry| entry.unwrap().path().extension().is_some_and(|ext| ext == "json"))
    {
        found.push("theme-file");
    }
    if dir.join("customize/cmux-app.json").is_file() {
        found.push("view");
    }
    if dir.join("agent-pane/theme.css").is_file() {
        found.push("agent-pane-css");
    }
    if dir.join("markdown/theme.css").is_file() {
        found.push("markdown-css");
    }
    if !manifest.actions.is_empty() {
        found.push("actions");
    }
    if dir.join("keybindings.json").is_file() {
        found.push("keybindings");
    }
    if manifest.settings.contains_key(glyph) {
        found.push("particles");
    }
    found
}

#[test]
fn every_entry_points_at_something_in_the_repo() {
    let index = index();
    assert_eq!(index["$schema"], "cmux.gallery/1");
    let all = index["entries"].as_array().unwrap();
    let mut seen = std::collections::BTreeSet::new();
    for entry in all {
        let path = entry["path"].as_str().unwrap();
        assert!(seen.insert(path), "{path} is listed twice");
        let at = examples().join(path);
        match entry["kind"].as_str().unwrap() {
            "look" => {
                assert!(at.join(setup::SETUP_FILE).is_file(), "{path}: no cmux-setup.json");
                assert!(at.join("README.md").is_file(), "{path}: a look has a README");
            }
            "profile" => assert!(at.is_file(), "{path}: no profile file"),
            "extension" => assert!(at.join("cmux-app.json").is_file(), "{path}: no cmux-app.json"),
            other => panic!("{path}: unknown kind {other}"),
        }
    }
    // Every look folder in the repo is listed, so the gallery cannot fall behind.
    for group in ["looks", "gallery", "setups"] {
        for dir in fs::read_dir(examples().join(group)).unwrap() {
            let dir = dir.unwrap().path();
            if dir.join(setup::SETUP_FILE).is_file() {
                let rel = format!("{group}/{}", dir.file_name().unwrap().to_str().unwrap());
                assert!(seen.contains(rel.as_str()), "{rel} is not in gallery.json");
            }
        }
    }
}

#[test]
fn every_look_reads_names_its_surfaces_and_has_its_screenshots() {
    for entry in entries("look") {
        let path = entry["path"].as_str().unwrap();
        let dir = examples().join(path);
        let read = setup::read_dir(&dir).unwrap_or_else(|error| panic!("{path}: {error}"));
        let listed: Vec<&str> =
            entry["surfaces"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
        assert_eq!(listed, surfaces_of(&dir, &read.manifest), "{path}: surfaces");
        for shot in &read.manifest.screenshots {
            assert!(dir.join(shot).is_file(), "{path}: screenshot {shot} is missing");
        }
        // The install line the gallery README gives resolves to this folder.
        let reference = Reference::parse(&install_reference(&entry)).unwrap();
        assert_eq!(reference.owner, "manaflow-ai");
        assert_eq!(reference.path, format!("examples/{path}"));
        assert!(
            read.manifest.id.starts_with(&format!("{}/", reference.owner)),
            "{path}: the id must start with the repo's owner"
        );
    }
}

/// Every folder holding a cmux-setup.json under `dir`, at any depth
/// (`looks/NAME`, `looks/APP/FEATURE`).
fn setup_folders(dir: &Path, found: &mut Vec<PathBuf>) {
    if dir.join(setup::SETUP_FILE).is_file() {
        found.push(dir.to_path_buf());
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries {
        let path = entry.unwrap().path();
        if path.is_dir() {
            setup_folders(&path, found);
        }
    }
}

/// Plans, installs on a fresh machine with nothing to fix, and removes back to nothing.
fn round_trip(dir: &Path, rel: &str) {
    let read = setup::read_dir(dir).unwrap_or_else(|error| panic!("{rel}: {error}"));
    let home = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    customize
        .plan_setup(&read, "manaflow-ai", "0.0.0")
        .unwrap_or_else(|error| panic!("{rel} does not plan: {error}"));
    let installed = customize
        .install_setup(&read, &format!("setup {}", read.manifest.id), "cli", 10)
        .unwrap_or_else(|error| panic!("{rel} does not install: {error}"));
    let status = customize.status().unwrap();
    assert!(status.problems.is_empty(), "{rel} would not apply: {:?}", status.problems);
    // A look's views (`customize/...`) go to a layer of its own under the setups folder, never
    // the person's customize folder; everything else lands under config as the look names it.
    let setups = Roots::under(home.path()).setups_dir();
    let placed = |file: &str| match (file.strip_prefix("customize/"), installed.layer.as_deref()) {
        (Some(inner), Some(layer)) => setups.join(layer).join(inner),
        _ => home.path().join("config").join(file),
    };
    for (file, text) in &read.profile.files {
        if file.starts_with("customize/") {
            assert!(
                !home.path().join("config").join(file).exists(),
                "{rel}: {file} was written into the person's own customize folder"
            );
        }
        let live = fs::read_to_string(placed(file)).unwrap();
        if file.starts_with("customize/cmux-app") {
            // The layer's manifest names the layer's own app id; the look's says local/customize.
            continue;
        }
        // The installer writes a JSON file in its own layout (keybindings.json pretty-printed),
        // so a JSON file is the same when it parses to the same value (comments and all: a look's
        // keybindings.json may carry them); the rest match exactly.
        let parse = |text: &str| cmux_config::jsonc::parse(text).ok();
        let same_json =
            file.ends_with(".json") && parse(&live).is_some() && parse(&live) == parse(text);
        assert!(
            same_json || &live == text,
            "{rel}: {file} is not what the look carries\n live: {live}\n look: {text}"
        );
    }
    let reference =
        Reference::parse(&format!("github.com/manaflow-ai/cmux/examples/{rel}")).unwrap();
    customize
        .record_setup(setup::Receipt::new(
            &read,
            &installed,
            setup::SetupSource::Repo { reference },
            &"0".repeat(40),
            Vec::new(),
            10,
        ))
        .unwrap();
    let found = customize.setup(&read.manifest.id).unwrap().unwrap();
    customize.remove_setup(&found, "cli", 20).unwrap();
    for file in read.profile.files.keys() {
        assert!(!placed(file).exists(), "{rel}: remove left {file} behind");
    }
}

/// Every setup folder under examples/looks, examples/gallery and examples/setups, listed in the index or not
/// (`looks/APP/FEATURE` included), but one whose index entry `needs` an unmerged change.
#[test]
fn every_look_installs_on_a_fresh_machine_and_removes_to_nothing() {
    let waiting: Vec<String> = entries("look")
        .iter()
        .filter(|entry| entry.get("needs").is_some())
        .map(|entry| entry["path"].as_str().unwrap().to_owned())
        .collect();
    let mut folders = Vec::new();
    for group in ["looks", "gallery", "setups"] {
        setup_folders(&examples().join(group), &mut folders);
    }
    folders.sort();
    assert!(folders.len() >= 15, "found only {} setup folders", folders.len());
    for dir in folders {
        let rel = dir.strip_prefix(examples()).unwrap().to_str().unwrap().replace('\\', "/");
        if !waiting.contains(&rel) {
            round_trip(&dir, &rel);
        }
    }
}

/// The particles document of a look that needs cmux#47525: until that lands, the shape checks
/// here stand in for `cmux_app_host::particles::validate` (which then checks it on install).
#[test]
fn the_thinking_dots_document_holds_together() {
    let dir = examples().join("gallery/thinking-dots");
    let read = setup::read_dir(&dir).unwrap();
    let setting = &read.manifest.settings["agentPane.display.thinking.glyph"];
    let file = setting["$file"].as_str().expect("the glyph is a {\"$file\": PATH} reference");
    let doc = cmux_config::jsonc::parse(&fs::read_to_string(dir.join(file)).unwrap()).unwrap();
    assert_eq!(doc["$schema"], "cmux.particles/1");
    let max = doc["particle"]["max"].as_u64().unwrap() as usize;
    let phases = doc["phases"].as_object().unwrap();
    for (name, phase) in phases {
        assert!(phase["duration"].as_u64().unwrap() > 0, "{name}");
        let mut last = -1.0;
        for frame in phase["frames"].as_array().unwrap() {
            let at = frame["at"].as_f64().unwrap();
            assert!((0.0..=1.0).contains(&at) && at > last, "{name}: frames run 0..1 in order");
            last = at;
            let dots = frame["dots"].as_array().unwrap();
            assert!(dots.len() <= max, "{name}: more dots than particle.max");
            for dot in dots {
                let scale = dot[2].as_f64().unwrap();
                assert!((0.0..=4.0).contains(&scale), "{name}: scale {scale} is not from 0 to 4");
            }
        }
    }
    let names = |value: &Value| -> Vec<String> {
        match value {
            Value::Array(list) => list.iter().map(|n| n.as_str().unwrap().to_owned()).collect(),
            Value::Object(parts) => parts.values().flat_map(names_of).collect(),
            _ => panic!("a trigger is a list of phases or {{intro, loop}}"),
        }
    };
    fn names_of(value: &Value) -> Vec<String> {
        value.as_array().unwrap().iter().map(|n| n.as_str().unwrap().to_owned()).collect()
    }
    for (trigger, value) in doc["triggers"].as_object().unwrap() {
        for phase in names(value) {
            assert!(phases.contains_key(&phase), "triggers.{trigger} names {phase}, not a phase");
        }
    }
}
