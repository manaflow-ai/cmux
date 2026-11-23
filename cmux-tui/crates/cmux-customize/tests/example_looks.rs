//! The looks written only on public surfaces (`examples/looks`, docs/cmux-next/look-addons.md).
//! Each is a setup folder an outsider could have written: it must read with the setup reader
//! `cmux setup install` uses, plan for its owner, install as one layer on a fresh machine with
//! nothing to fix, keep the person's own keys, carry a theme file that reads with no key dropped,
//! and come off again leaving nothing behind. A look that needed a key, file or path cmux does not
//! offer outside its own code fails here.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_config::{Domains, Schema, ThemeFile};
use cmux_customize::setup::{self, Receipt, Reference};
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

fn looks() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/looks")
}

/// The add-on folders `looks.json` names, by folder name.
fn addons() -> Vec<String> {
    let index: Value =
        serde_json::from_str(&fs::read_to_string(looks().join("looks.json")).unwrap()).unwrap();
    let mut names: Vec<String> = index["looks"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|look| look["addon"].as_str().map(str::to_owned))
        .collect();
    names.sort();
    names
}

const MINE: &str = "{\n  // my settings\n  \"appearance\": { \"accent\": \"blue\" },\n  \"terminal\": { \"fontSize\": 15 }\n}\n";

fn receipt(read: &setup::Setup, installed: &setup::Installed, name: &str) -> Receipt {
    let reference = Reference::parse(&format!("github.com/manaflow-ai/cmux-{name}-look")).unwrap();
    Receipt {
        id: read.manifest.id.clone(),
        name: read.manifest.name.clone(),
        repository: reference.repository(),
        reference,
        commit: "a".repeat(40),
        sha256: read.sha256.clone(),
        version: read.manifest.version.clone(),
        generation: installed.applied.as_ref().map(|applied| applied.generation.n),
        before: installed.before,
        library: installed.applied.as_ref().and_then(|applied| applied.library.clone()),
        library_created: installed.library_created,
        actions: read.actions().clone(),
        prior_actions: installed.prior_actions.clone(),
        extensions: Vec::new(),
        installed_ms: 10,
    }
}

/// looks.json lists the looks on public surfaces only; every whole look under examples/looks is
/// indexed by examples/gallery/gallery.json (tests/gallery.rs), so a folder may be in that index
/// and not this one.
#[test]
fn every_listed_addon_is_a_whole_look_folder() {
    for name in addons() {
        assert!(
            looks().join(&name).join(setup::SETUP_FILE).is_file(),
            "examples/looks/looks.json names {name}, which has no examples/looks/{name}/cmux-setup.json"
        );
    }
    assert!(
        addons().len() >= 2,
        "at least two looks: one recreating a built-in look, one outside-only"
    );
}

#[test]
fn every_look_is_a_whole_look_on_public_surfaces() {
    for name in addons() {
        let read = setup::read_dir(&looks().join(&name))
            .unwrap_or_else(|error| panic!("{name}: not a setup: {error}"));
        let files = &read.profile.files;
        // Color, type and density, the chat's paint, and the sidebar: every part of a look.
        let theme = format!("themes/{name}.json");
        for path in
            [theme.as_str(), "agent-pane/theme.css", "customize/cmux-app.json", "customize/main.js"]
        {
            assert!(files.contains_key(path), "{name}: a whole look carries {path}");
        }
        assert_eq!(
            read.profile.settings.get("appearance.themeFile"),
            Some(&json!(name)),
            "{name}: the look picks its own theme file"
        );
        assert!(
            read.profile.settings.keys().any(|key| key.starts_with("agentPane.display.")),
            "{name}: type and width go through agentPane.display settings, never the stylesheet"
        );
        assert!(read.actions().is_empty(), "{name}: a look runs no commands");
        assert!(read.manifest.extensions.is_empty(), "{name}: a look installs no extensions");

        let file = ThemeFile::read(
            &name,
            Some(Ok(files[&theme].as_str())),
            &json!({}),
            None,
            Schema::embedded(),
            &Domains::default(),
        );
        assert!(file.is_loaded && !file.is_unparsable, "{name}: {theme} does not read");
        let problems: Vec<String> = file.diagnostics.iter().map(|d| d.display()).collect();
        assert!(problems.is_empty(), "{name}: {theme} dropped keys: {problems:?}");
        assert!(
            file.corrected.is_empty(),
            "{name}: the contrast guard raised {:?}",
            file.corrected
        );
        // The window is the look too: without this, a person's own App Theme keeps the window,
        // sidebar and pages in its colors (a dark look in a light window).
        let text = cmux_config::jsonc::parse(&files[&theme]).unwrap();
        assert_eq!(
            text["appearance.appTheme"],
            json!("followTerminal"),
            "{name}: {theme} leaves the window on the person's App Theme"
        );
    }
}

#[test]
fn every_look_installs_as_one_layer_and_comes_off_leaving_yours() {
    for name in addons() {
        let home = tempfile::tempdir().unwrap();
        let config = |path: &str| home.path().join("config").join(path);
        fs::create_dir_all(config("")).unwrap();
        fs::write(config("cmux-next.json"), MINE).unwrap();
        let customize = Customize::open(Roots::under(home.path()));
        let read = setup::read_dir(&looks().join(&name)).unwrap();

        let plan = customize
            .plan_setup(&read, "manaflow-ai", "0.0.0")
            .unwrap_or_else(|error| panic!("{name}: does not plan: {error}"));
        assert_eq!(plan.theme.as_deref(), Some(name.as_str()));

        let installed = customize
            .install_setup(&read, &format!("setup {}", read.manifest.id), "cli", 10)
            .unwrap_or_else(|error| panic!("{name}: does not install: {error}"));
        assert!(
            installed.applied.as_ref().is_some_and(|a| a.library.is_some()),
            "{name}: one layer"
        );
        let status = customize.status().unwrap();
        assert!(
            status.problems.is_empty(),
            "{name}: installs with problems: {:?}",
            status.problems
        );
        for (path, text) in &read.profile.files {
            assert_eq!(&fs::read_to_string(config(path)).unwrap(), text, "{name}: {path}");
        }
        let settings: Value =
            cmux_config::jsonc::parse(&fs::read_to_string(config("cmux-next.json")).unwrap())
                .unwrap();
        assert_eq!(settings["appearance"]["themeFile"], json!(name));
        assert_eq!(settings["terminal"]["fontSize"], json!(15), "{name}: your own keys stay");

        customize.record_setup(receipt(&read, &installed, &name)).unwrap();
        let found = customize.setup(&read.manifest.id).unwrap().unwrap();
        customize.remove_setup(&found, "cli", 20).unwrap();
        let settings: Value =
            cmux_config::jsonc::parse(&fs::read_to_string(config("cmux-next.json")).unwrap())
                .unwrap();
        assert_eq!(settings["appearance"].get("themeFile"), None, "{name}: the theme comes off");
        assert_eq!(settings["appearance"]["accent"], json!("blue"), "{name}: yours is back");
        for path in read.profile.files.keys() {
            assert!(!config(path).exists(), "{name}: {path} outlived the remove");
        }
    }
}
