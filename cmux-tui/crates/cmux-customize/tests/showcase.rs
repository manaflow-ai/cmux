//! The customization showcase (`examples/customize-showcase`): whole-window
//! setups, each one profile file. Every one must preview on a fresh machine
//! with nothing to fix, and each bundle must match the folder it is built from.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Roots};

fn showcase() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/customize-showcase")
}

/// The showcase folders, by name.
fn folders() -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = fs::read_dir(showcase())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.join("profile.json").is_file())
        .collect();
    folders.sort();
    folders
}

fn files_under(root: &Path, dir: &Path, files: &mut BTreeMap<String, String>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files_under(root, &path, files);
        } else {
            let rel = path.strip_prefix(root).unwrap().to_str().unwrap().replace('\\', "/");
            if rel != "profile.json" {
                files.insert(rel, fs::read_to_string(&path).unwrap());
            }
        }
    }
}

/// What `bundle.py` writes for `folder`.
fn bundled(folder: &Path) -> Profile {
    let meta: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(folder.join("profile.json")).unwrap()).unwrap();
    let mut files = BTreeMap::new();
    files_under(folder, folder, &mut files);
    Profile {
        version: 1,
        name: meta["name"].as_str().unwrap().to_owned(),
        description: meta["description"].as_str().unwrap().to_owned(),
        created_ms: 0,
        settings: serde_json::from_value(meta["settings"].clone()).unwrap(),
        files,
    }
}

#[test]
fn the_showcase_has_its_five_setups() {
    let names: Vec<String> = folders()
        .iter()
        .map(|folder| folder.file_name().unwrap().to_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, ["cockpit", "focus", "ide", "right-handed", "tiling"]);
}

#[test]
fn every_bundle_matches_its_folder() {
    for folder in folders() {
        let name = folder.file_name().unwrap().to_str().unwrap();
        let file = showcase().join(format!("{name}.json"));
        let committed: Profile = serde_json::from_str(&fs::read_to_string(&file).unwrap())
            .unwrap_or_else(|error| panic!("{}: {error}", file.display()));
        assert_eq!(
            committed,
            bundled(&folder),
            "{name}.json is stale: run examples/customize-showcase/bundle.py"
        );
        assert_eq!(committed.name, name);
    }
}

#[test]
fn every_setup_previews_on_a_fresh_machine_with_nothing_to_fix() {
    for folder in folders() {
        let name = folder.file_name().unwrap().to_str().unwrap();
        let home = tempfile::tempdir().unwrap();
        let customize = Customize::open(Roots::under(home.path()));
        let file = showcase().join(format!("{name}.json"));
        let profile = customize.load_profile(file.to_str().unwrap()).unwrap();
        assert!(
            profile.files.contains_key("customize/cmux-app.json")
                && profile.files.contains_key("customize/main.js"),
            "{name}: a showcase setup draws views of its own, not only settings"
        );
        let begun = customize
            .preview_profile(&profile, "cli", 1)
            .unwrap_or_else(|error| panic!("{name} does not preview: {error}"));
        assert_eq!(begun.draft.asks[0].text, format!("profile {name}"));
        let status = customize.status().unwrap();
        assert!(status.problems.is_empty(), "{name} would not apply: {:?}", status.problems);
        for (path, text) in &profile.files {
            let live = fs::read_to_string(home.path().join("config").join(path)).unwrap();
            assert_eq!(&live, text, "{name}: {path} is not what the profile carries");
        }
    }
}
