//! The looks written only on public surfaces (`examples/looks`, docs/cmux-next/look-addons.md).
//! Each is a setup folder an outsider could have written: it must read with the setup reader
//! `cmux setup install` uses, plan for its owner, install as one layer on a fresh machine with
//! nothing to fix, keep the person's own keys, carry a theme file that reads with no key dropped,
//! and come off again leaving nothing behind. A look that needed a key, file or path cmux does not
//! offer outside its own code fails here.

use std::fs;
use std::path::{Path, PathBuf};

use cmux_config::{Domains, Schema, ThemeFile};
use cmux_customize::setup::{self, Receipt, Reference, SetupSource};
use cmux_customize::{Customize, Roots};
use serde_json::{Value, json};

fn looks() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/looks")
}

/// The add-on folders `looks.json` names, by folder name; with `whole`, only the whole looks (no
/// `"surface"`), not a part such as `codex/composer` (`"surface": "composer"`, #51713).
fn listed(whole: bool) -> Vec<String> {
    let index: Value =
        serde_json::from_str(&fs::read_to_string(looks().join("looks.json")).unwrap()).unwrap();
    let mut names: Vec<String> = index["looks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|look| !whole || look.get("surface").is_none_or(Value::is_null))
        .filter_map(|look| look["addon"].as_str().map(str::to_owned))
        .collect();
    names.sort();
    names
}

/// Every add-on folder `looks.json` names.
fn addons() -> Vec<String> {
    listed(false)
}

/// The whole looks `looks.json` names.
fn whole_looks() -> Vec<String> {
    listed(true)
}

const MINE: &str = "{\n  // my settings\n  \"appearance\": { \"accent\": \"blue\" },\n  \"terminal\": { \"fontSize\": 15 }\n}\n";

fn receipt(read: &setup::Setup, installed: &setup::Installed, name: &str) -> Receipt {
    let reference = Reference::parse(&format!("github.com/manaflow-ai/cmux-{name}-look")).unwrap();
    Receipt::new(read, installed, SetupSource::Repo { reference }, &"a".repeat(40), Vec::new(), 10)
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
        whole_looks().len() >= 2,
        "at least two looks: one recreating a built-in look, one outside-only"
    );
}

#[test]
fn every_look_is_a_whole_look_on_public_surfaces() {
    for name in whole_looks() {
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

/// Every setup folder under examples/looks: the add-ons and the reference app profiles
/// (`codex/profile`, `claude-code/profile`, ...), which looks.json does not list.
fn every_setup_folder() -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in fs::read_dir(looks()).unwrap() {
        let dir = entry.unwrap().path();
        for folder in [dir.clone(), dir.join("profile")] {
            if folder.join(setup::SETUP_FILE).is_file() {
                found.push(folder);
            }
        }
    }
    found.sort();
    found
}

/// A look's setting this cmux's embedded schema (schemas/settings/settings-schema.json) has no row
/// for installs as nothing: `cmux setup install` leaves it out and still says Installed. Nightly
/// 4592220755201 shipped a stale export, so the Codex profile lost `agentPane.display.modelPickerStyle`
/// (its model picker kept the rail and Reasoning column) and `agentPane.composerPlaceholder`.
#[test]
fn every_look_setting_is_one_this_cmux_has() {
    let folders = every_setup_folder();
    assert!(folders.len() >= 4, "found only {folders:?}");
    for folder in folders {
        let home = tempfile::tempdir().unwrap();
        let customize = Customize::open(Roots::under(home.path()));
        let read = setup::read_dir(&folder).unwrap_or_else(|error| panic!("{folder:?}: {error}"));
        let plan = customize
            .plan_setup(&read, "manaflow-ai", "0.0.0")
            .unwrap_or_else(|error| panic!("{folder:?}: does not plan: {error}"));
        let skipped: Vec<&str> = plan.skipped.iter().map(|s| s.key.as_str()).collect();
        assert!(
            skipped.is_empty(),
            "{folder:?} sets {skipped:?}, which settings-schema.json lacks: regenerate the settings \
             exports (scripts/cmux-next/regenerate-settings-exports-linux.sh OUT)"
        );
    }
}

#[test]
fn every_look_installs_as_one_layer_and_comes_off_leaving_yours() {
    for name in whole_looks() {
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
        // A look's views (`customize/...`) go to a layer of its own under the setups folder, never
        // the person's customize folder; everything else lands under config as the look names it.
        let setups = Roots::under(home.path()).setups_dir();
        let placed =
            |path: &str| match (path.strip_prefix("customize/"), installed.layer.as_deref()) {
                (Some(inner), Some(layer)) => setups.join(layer).join(inner),
                _ => config(path),
            };
        for (path, text) in &read.profile.files {
            if path.starts_with("customize/") {
                assert!(
                    !config(path).exists(),
                    "{name}: {path} went into your own customize folder"
                );
            }
            if path.starts_with("customize/cmux-app") {
                // The layer's manifest names the layer's own app id; the look's says local/customize.
                continue;
            }
            assert_eq!(&fs::read_to_string(placed(path)).unwrap(), text, "{name}: {path}");
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
            assert!(!placed(path).exists(), "{name}: {path} outlived the remove");
        }
    }
}

/// The gallery's order on one machine, as Settings > Appearance installs them one after another
/// (hq feature flow `looks`): each install puts its own theme on, over the ones before it. The
/// NIGHTLY walk saw Linen's install leave Basalt's theme on (themeFile still `basalt`).
#[test]
fn every_look_installed_over_the_others_puts_its_theme_on() {
    let home = tempfile::tempdir().unwrap();
    let config = |path: &str| home.path().join("config").join(path);
    fs::create_dir_all(config("")).unwrap();
    fs::write(config("cmux-next.json"), MINE).unwrap();
    let customize = Customize::open(Roots::under(home.path()));
    let order = [
        "tachyon", "kerf", "prism", "hush", "basalt", "linen", "docket", "ember", "folio", "tandem",
    ];
    let mut failures = Vec::new();
    for (at, name) in order.iter().enumerate() {
        let read = setup::read_dir(&looks().join(name)).unwrap();
        let installed = match customize.install_setup(
            &read,
            &format!("setup {}", read.manifest.id),
            "cli",
            10 + at as u64,
        ) {
            Ok(installed) => installed,
            Err(error) => {
                failures.push(format!(
                    "{name} (after {}): does not install: {error}",
                    order[..at].join(", ")
                ));
                continue;
            }
        };
        customize.record_setup(receipt(&read, &installed, name)).unwrap();
        let settings: Value =
            cmux_config::jsonc::parse(&fs::read_to_string(config("cmux-next.json")).unwrap())
                .unwrap();
        if settings["appearance"]["themeFile"] != json!(name) {
            failures.push(format!(
                "{name} (after {}): themeFile reads {}",
                order[..at].join(", "),
                settings["appearance"]["themeFile"]
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// Leo, 2026-11-27: "im not a fan of the descriptions on our themes and whatnot". What the Settings
/// gallery, the Customize checklist and a look's install card show of a look (its tagline and
/// description) and of each theme it carries (the theme file's description) is one short plain
/// phrase a person reads at a glance: at most seven words, no "A look: x, y, z".
#[test]
fn every_look_and_theme_says_what_it_looks_like_in_a_few_plain_words() {
    let mut checked = 0;
    // A look's own folder, and each folder of this repo the gallery lists (the app profiles).
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let listed = setup::looks::catalog()
        .unwrap()
        .looks
        .into_iter()
        .filter_map(|look| look.reference())
        .filter(|reference| reference.owner == "manaflow-ai" && reference.repo == "cmux")
        .map(|reference| root.join(&reference.path));
    let dirs = fs::read_dir(looks()).unwrap().map(|entry| entry.unwrap().path()).chain(listed);
    for dir in dirs {
        if !dir.join(setup::SETUP_FILE).is_file() {
            continue;
        }
        let read = setup::read_dir(&dir).unwrap_or_else(|error| panic!("{dir:?}: {error}"));
        let manifest = &read.manifest;
        for words in manifest.tagline.iter().chain([&manifest.description]) {
            assert!(setup::looks::plain_phrase(words), "{dir:?}: {words:?}");
            checked += 1;
        }
        let Ok(themes) = fs::read_dir(dir.join("themes")) else { continue };
        for theme in themes {
            let path = theme.unwrap().path();
            if path.extension().is_none_or(|e| e != "json") {
                continue;
            }
            let text = fs::read_to_string(&path).unwrap();
            let value = cmux_config::jsonc::parse(&text)
                .unwrap_or_else(|error| panic!("{path:?}: {error}"));
            if let Some(words) = value["description"].as_str() {
                assert!(setup::looks::plain_phrase(words), "{path:?}: {words:?}");
                checked += 1;
            }
        }
    }
    assert!(checked >= 100, "checked only {checked} phrases");
}
