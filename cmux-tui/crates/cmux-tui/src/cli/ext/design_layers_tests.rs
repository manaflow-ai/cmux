use std::path::Path;

use serde_json::{Value, json};

use super::super::design_system::{FILE, System};
use super::{Change, Places, Resolved, Source, base, stamp};

fn source(kind: &'static str, doc: Value) -> Source {
    Source { kind, label: format!("{kind}.json"), doc: Some(Ok(doc)) }
}

fn role<'a>(system: &'a System, name: &str) -> (f64, &'a str, bool) {
    let role = system.roles.iter().find(|r| r.name == name).expect("the role");
    (role.size, role.weight.as_str(), role.monospaced)
}

fn places(dir: &Path, settings: Value) -> Places {
    Places { config_dir: dir.to_path_buf(), settings_root: settings }
}

#[test]
fn each_layer_merges_over_the_ones_under_it() {
    let resolved = Resolved::from_sources(&[
        source(
            "theme",
            json!({ "design": "cmux.design/1", "name": "Tokyo",
                    "type": { "title": { "size": 17, "weight": "bold" }, "body": { "size": 14 } } }),
        ),
        source(
            "person",
            json!({ "design": "cmux.design/1", "name": "Mine",
                    "type": { "body": { "size": 15, "monospaced": true } }, "space": [0, 4, 8, 16] }),
        ),
        source(
            "folder",
            json!({ "design": "cmux.design/1", "type": { "title": { "size": 18, "weight": "semibold" } } }),
        ),
    ]);
    assert!(resolved.problems.is_empty(), "{:?}", resolved.problems);
    let system = &resolved.system;
    assert_eq!(system.name, "Mine");
    // The folder's title over the theme's, the person's body over the theme's.
    assert_eq!(role(system, "title"), (18.0, "semibold", false));
    assert_eq!(role(system, "body"), (15.0, "regular", true));
    // What no layer sets is cmux's.
    assert_eq!(role(system, "numeral"), (34.0, "semibold", false));
    assert_eq!(system.space, [0.0, 4.0, 8.0, 16.0]);
    let kinds: Vec<_> = resolved.layers.iter().map(|l| (l.kind, l.applied)).collect();
    assert_eq!(kinds, [("cmux", true), ("theme", true), ("person", true), ("folder", true)]);
}

#[test]
fn a_layer_that_does_not_read_is_one_finding_and_the_rest_still_apply() {
    let resolved = Resolved::from_sources(&[
        source("theme", json!({ "design": "cmux.design/1", "space": [0, 4, 8] })),
        source("person", json!({ "design": "cmux.design/1", "type": { "body": { "size": 99 } } })),
        Source { kind: "folder", label: FILE.into(), doc: Some(Err("expected value".into())) },
    ]);
    assert_eq!(resolved.system.space, [0.0, 4.0, 8.0]);
    assert_eq!(role(&resolved.system, "body"), (13.0, "regular", false));
    assert_eq!(resolved.problems.len(), 2);
    let person = &resolved.problems[0];
    assert_eq!(person.check, "system");
    assert!(person.message.starts_with("person.json: type.body.size"), "{}", person.message);
    assert!(person.message.ends_with("the layers under it still apply"), "{}", person.message);
    assert!(resolved.problems[1].message.starts_with(FILE));
    let applied: Vec<_> = resolved.layers.iter().map(|l| l.applied).collect();
    assert_eq!(applied, [true, true, false, false]);
}

#[test]
fn no_layers_is_cmuxs_system_and_its_json_reads_back_as_the_same_system() {
    let resolved = Resolved::from_sources(&[]);
    assert_eq!(resolved.system, System::cmux());
    assert!(resolved.changed.is_empty());
    let mine = System::cmux()
        .merge(&json!({ "design": "cmux.design/1", "name": "Mine",
                        "type": { "code": { "size": 12, "monospaced": true } },
                        "colors": { "warm": "accent" }, "limits": { "accents": 2 } }))
        .unwrap();
    // Read back, it is the same system; only the SDK helper names drop, since a role a file sets
    // is drawn at its own size rather than by cmux's helper.
    let back = System::cmux().merge(&mine.to_json()).unwrap();
    assert_eq!(back.to_json(), mine.to_json());
    assert!(back.roles.iter().all(|r| r.helper.is_none()));
    let json = resolved.to_json();
    assert_eq!(json["system"]["type"]["numeral"], json!({ "size": 34.0, "weight": "semibold" }));
    assert_eq!(json["base"], base());
    assert_eq!(json["layers"][0], json!({ "kind": "cmux", "file": "cmux", "applied": true }));
}

#[test]
fn a_recorded_base_lists_each_value_cmux_changed_and_whether_yours_holds() {
    // Written when cmux's numeral was 32 pt, heading 22 pt, and its scale ended at 40.
    let mut written = base();
    written["type"]["numeral"] = json!({ "size": 32, "weight": "semibold" });
    written["type"]["heading"] = json!({ "size": 22, "weight": "semibold" });
    written["space"] = json!([0, 2, 4, 8, 16, 40]);
    written["limits"]["accents"] = json!(3);
    let resolved = Resolved::from_sources(&[source(
        "person",
        json!({ "design": "cmux.design/1", "base": written,
                "type": { "heading": { "size": 22, "weight": "semibold" } } }),
    )]);
    let mut keys: Vec<_> = resolved.changed.iter().map(|c| (c.key.as_str(), c.kept)).collect();
    keys.sort();
    assert_eq!(
        keys,
        [
            ("limits.accents", false),
            ("space", false),
            ("type.heading", true),
            ("type.numeral", false)
        ]
    );
    let numeral = resolved.changed.iter().find(|c| c.key == "type.numeral").unwrap();
    assert_eq!(numeral.now["size"], json!(34.0));
    assert_eq!(numeral.file, "person.json");
    assert_eq!(
        numeral.text(),
        "type.numeral: cmux changed it from 32 pt semibold to 34 pt semibold (you get the new one)"
    );
    assert_eq!(resolved.to_json()["changed"].as_array().map(Vec::len), Some(4));
}

#[test]
fn a_base_that_matches_cmux_lists_nothing() {
    let resolved = Resolved::from_sources(&[source(
        "person",
        json!({ "design": "cmux.design/1", "base": base() }),
    )]);
    assert_eq!(resolved.changed, Vec::<Change>::new());
}

#[test]
fn the_active_theme_files_design_key_is_the_theme_layer() {
    let dir = tempfile::tempdir().unwrap();
    let theme = cmux_config::theme_file::path(dir.path(), "dusk");
    std::fs::create_dir_all(theme.parent().unwrap()).unwrap();
    std::fs::write(
        &theme,
        r#"{ "appearance.accent": "blue", // a look
             "design": { "design": "cmux.design/1", "space": [0, 3, 6, 12] } }"#,
    )
    .unwrap();
    let active = places(dir.path(), json!({ "appearance": { "themeFile": "dusk" } }));
    let resolved = Resolved::from_sources(&active.sources(None, None));
    assert_eq!(resolved.system.space, [0.0, 3.0, 6.0, 12.0]);
    assert_eq!(resolved.layers[1].label, "theme dusk");
    // No theme file active, or one without a design key: no theme layer.
    let none = Source::theme(dir.path(), &json!({}));
    assert_eq!(none.doc, None);
    std::fs::write(&theme, r#"{ "appearance.accent": "blue" }"#).unwrap();
    assert_eq!(
        Source::theme(dir.path(), &json!({ "appearance": { "themeFile": "dusk" } })).doc,
        None
    );
}

#[test]
fn the_person_file_sits_beside_the_settings_and_the_folder_or_system_file_goes_last() {
    let dir = tempfile::tempdir().unwrap();
    let ext = tempfile::tempdir().unwrap();
    let mine = places(dir.path(), json!({}));
    assert_eq!(mine.person_file(), dir.path().join("design.json"));
    std::fs::write(mine.person_file(), r#"{ "design": "cmux.design/1", "space": [0, 4, 8] }"#)
        .unwrap();
    std::fs::write(ext.path().join(FILE), r#"{ "design": "cmux.design/1", "space": [0, 8] }"#)
        .unwrap();
    let alone = Resolved::from_sources(&mine.sources(None, None));
    assert_eq!(alone.system.space, [0.0, 4.0, 8.0]);
    let folder = Resolved::from_sources(&mine.sources(Some(ext.path()), None));
    assert_eq!(folder.system.space, [0.0, 8.0]);
    assert_eq!(folder.layers.last().unwrap().label, FILE);
    let file = ext.path().join("other.json");
    std::fs::write(&file, r#"{ "design": "cmux.design/1", "space": [0, 6] }"#).unwrap();
    let system = Resolved::from_sources(&mine.sources(Some(ext.path()), Some(&file)));
    assert_eq!(system.system.space, [0.0, 6.0]);
}

#[test]
fn stamp_records_cmuxs_base_and_keeps_what_the_file_sets() {
    let dir = tempfile::tempdir().unwrap();
    let mine = places(&dir.path().join("cmux"), json!({}));
    assert_eq!(stamp(&mine, true), super::super::exit::OK);
    let written: Value =
        serde_json::from_str(&std::fs::read_to_string(mine.person_file()).unwrap()).unwrap();
    assert_eq!(written["design"], "cmux.design/1");
    assert_eq!(written["base"], base());
    std::fs::write(
        mine.person_file(),
        r#"{ "design": "cmux.design/1", "space": [0, 4], "base": { "space": [0, 1] } }"#,
    )
    .unwrap();
    assert_eq!(stamp(&mine, true), super::super::exit::OK);
    let written: Value =
        serde_json::from_str(&std::fs::read_to_string(mine.person_file()).unwrap()).unwrap();
    assert_eq!(written["space"], json!([0, 4]));
    assert_eq!(written["base"], base());
    std::fs::write(mine.person_file(), "[1]").unwrap();
    assert_eq!(stamp(&mine, true), super::super::exit::MANIFEST_INVALID);
}

/// The texts and badges a scene's create ops draw.
fn drawn(ops: &Value, kind: &str) -> Vec<String> {
    let ops = ops.as_array().expect("a batch of ops");
    ops.iter()
        .filter(|op| op["op"] == "create" && op["type"] == kind)
        .filter_map(|op| op["props"]["text"].as_str().map(str::to_string))
        .collect()
}

#[cfg(unix)]
#[test]
fn the_settings_scene_is_the_sdks_viewer_of_the_resolved_system_with_changes_marked() {
    if super::DESIGN_VIEW.is_empty() {
        eprintln!("SKIPPED: this build had no bun, so it packed no design view");
        return;
    }
    let cmux = Resolved::from_sources(&[]);
    let ops = cmux.scene().expect("the view draws");
    let texts = drawn(&ops, "Text");
    for title in ["cmux", "Type", "Spacing", "Color", "Components", "Limits"] {
        assert!(texts.iter().any(|t| t == title), "{title} in {texts:?}");
    }
    assert!(texts.iter().any(|t| t.starts_with("cmux's own design system")), "{texts:?}");
    assert!(!texts.iter().any(|t| t == "Changed in cmux"));

    let mut written = base();
    written["type"]["numeral"] = json!({ "size": 32, "weight": "semibold" });
    let mine = Resolved::from_sources(&[Source {
        kind: "person",
        label: "/home/me/.config/cmux/design.json".into(),
        doc: Some(Ok(json!({ "design": "cmux.design/1", "name": "Mine", "base": written,
                             "type": { "code": { "size": 12, "monospaced": true } } }))),
    }]);
    assert_eq!(mine.note(), "Built on cmux, then design.json");
    let ops = mine.scene().expect("the view draws");
    let texts = drawn(&ops, "Text");
    assert!(texts.iter().any(|t| t == "Mine"));
    assert!(texts.iter().any(|t| t == "Changed in cmux"), "{texts:?}");
    assert!(texts.iter().any(|t| t.starts_with("type.numeral: cmux changed it from 32 pt")));
    let badges = drawn(&ops, "Badge");
    assert!(badges.iter().any(|b| b == "cmux changed"), "{badges:?}");
    assert!(badges.iter().any(|b| b == "adds"), "{badges:?}");
}
