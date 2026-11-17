//! The Leo collection's look (`examples/customize/leo`): three variants, each one
//! profile file. Every one must preview on a fresh machine with nothing to fix, its
//! theme file must read with no key dropped, and each bundle must match its sources.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_config::{Domains, Schema, ThemeFile};
use cmux_customize::profile::Profile;
use cmux_customize::{Customize, Roots};
use serde_json::json;

fn leo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/customize/leo")
}

fn variants() -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(leo())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.join("profile.json").is_file())
        .map(|path| path.file_name().unwrap().to_str().unwrap().to_owned())
        .collect();
    names.sort();
    names
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

/// What `bundle.py` writes for `variant`: shared/ under the variant's own files.
fn bundled(variant: &str) -> Profile {
    let folder = leo().join(variant);
    let meta: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(folder.join("profile.json")).unwrap()).unwrap();
    let mut files = BTreeMap::new();
    files_under(&leo().join("shared"), &leo().join("shared"), &mut files);
    files_under(&folder, &folder, &mut files);
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
fn the_leo_look_has_three_variants() {
    assert_eq!(variants(), ["daylight", "dusk", "neon"]);
}

#[test]
fn every_bundle_matches_its_sources() {
    for variant in variants() {
        let file = leo().join(format!("{variant}.json"));
        let committed: Profile = serde_json::from_str(&fs::read_to_string(&file).unwrap())
            .unwrap_or_else(|error| panic!("{}: {error}", file.display()));
        assert_eq!(
            committed,
            bundled(&variant),
            "{variant}.json is stale: run examples/customize/leo/bundle.py"
        );
        assert_eq!(committed.name, format!("leo-{variant}"));
    }
}

#[test]
fn every_theme_file_reads_with_no_key_dropped() {
    for variant in variants() {
        let name = format!("leo-{variant}");
        let text =
            fs::read_to_string(leo().join(&variant).join(format!("themes/{name}.json"))).unwrap();
        let file = ThemeFile::read(
            &name,
            Some(Ok(text.as_str())),
            &json!({}),
            None,
            Schema::embedded(),
            &Domains::default(),
        );
        assert!(file.is_loaded && !file.is_unparsable, "{name} does not read");
        let problems: Vec<String> = file.diagnostics.iter().map(|d| d.display()).collect();
        assert!(problems.is_empty(), "{name}: {problems:?}");
        assert!(
            file.corrected.is_empty(),
            "{name}: the contrast guard raised {:?}",
            file.corrected
        );
    }
}

#[test]
fn every_variant_previews_on_a_fresh_machine_with_nothing_to_fix() {
    for variant in variants() {
        let home = tempfile::tempdir().unwrap();
        let customize = Customize::open(Roots::under(home.path()));
        let file = leo().join(format!("{variant}.json"));
        let profile = customize.load_profile(file.to_str().unwrap()).unwrap();
        let begun = customize
            .preview_profile(&profile, "cli", 1)
            .unwrap_or_else(|error| panic!("{variant} does not preview: {error}"));
        assert_eq!(begun.draft.asks[0].text, format!("profile leo-{variant}"));
        let status = customize.status().unwrap();
        assert!(status.problems.is_empty(), "{variant} would not apply: {:?}", status.problems);
        for (path, text) in &profile.files {
            let live = fs::read_to_string(home.path().join("config").join(path)).unwrap();
            assert_eq!(&live, text, "{variant}: {path} is not what the profile carries");
        }
        // Discard puts the machine back: no theme file and no setting left behind.
        customize.discard("cli", 2).unwrap();
        for path in profile.files.keys() {
            assert!(
                !home.path().join("config").join(path).exists(),
                "{variant}: {path} outlived the discard"
            );
        }
    }
}
