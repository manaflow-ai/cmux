//! A shared file-reference contract for direct previews and setup installs.
use std::fs;

use cmux_customize::{Customize, Roots, setup};
use serde_json::{Value, json};

fn write_manifest(dir: &std::path::Path, files: Value) -> std::path::PathBuf {
    let path = dir.join("profile.json");
    fs::write(&path, json!({"cmuxProfile":1,"name":"look","files":files}).to_string()).unwrap();
    path
}

#[test]
fn referenced_profile_previews_discards_and_exports_inline() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    fs::create_dir(source.path().join("assets")).unwrap();
    let theme = "{\"name\":\"Look\"}\n";
    fs::write(source.path().join("assets/look.json"), theme).unwrap();
    let path = write_manifest(
        source.path(),
        json!({
            "themes/look.json":{"$file":"assets/look.json"},
            "keybindings.json":"[]"
        }),
    );
    let customize = Customize::open(Roots::under(target.path()));
    let profile = customize.load_profile(path.to_str().unwrap()).unwrap();
    assert_eq!(profile.files["themes/look.json"], theme);
    assert_eq!(profile.files["keybindings.json"], "[]");
    customize.preview_profile(&profile, "test", 1).unwrap();
    assert_eq!(fs::read_to_string(target.path().join("config/themes/look.json")).unwrap(), theme);
    let saved = customize.save_profile("copy", "", 2).unwrap();
    let exported: Value = serde_json::from_str(&fs::read_to_string(saved.path).unwrap()).unwrap();
    assert_eq!(exported["files"]["themes/look.json"], theme);
    customize.discard("test", 3).unwrap();
    assert!(!target.path().join("config/themes/look.json").exists());
}

#[test]
fn setup_references_plan_install_and_directly_preview_the_same_bytes() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    fs::write(source.path().join("look.json"), "{\"name\":\"Look\"}").unwrap();
    let path = source.path().join(setup::SETUP_FILE);
    fs::write(
        &path,
        r#"{
        // Setup manifests allow comments and default cmuxProfile to 1.
        "cmuxSetup":1,"id":"someone/look","name":"Look",
        "files":{"themes/look.json":{"$file":"look.json"}}
    }"#,
    )
    .unwrap();
    let customize = Customize::open(Roots::under(target.path()));
    let setup = setup::read_dir(source.path()).unwrap();
    let direct = customize.load_profile(path.to_str().unwrap()).unwrap();
    assert_eq!(direct, setup.profile);
    customize.plan_setup(&setup, "someone", "0.0.0").unwrap();
    customize.install_setup(&setup, "Look", "test", 1).unwrap();
    assert_eq!(
        fs::read_to_string(target.path().join("config/themes/look.json")).unwrap(),
        "{\"name\":\"Look\"}"
    );
    fs::write(source.path().join("look.json"), "{\"name\":\"Changed\"}").unwrap();
    assert_ne!(setup.sha256, setup::read_dir(source.path()).unwrap().sha256);
}

#[test]
fn bad_references_are_rejected_without_writing_live_state() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(target.path()));
    for reference in [
        json!({"$file":"../outside"}),
        json!({"$file":"/etc/hosts"}),
        json!({"$file":"C:\\file"}),
        json!({"$file":"missing"}),
        json!({"$file":""}),
        json!({"$file":42}),
        json!({"$file":"look.json","extra":true}),
    ] {
        let path = write_manifest(source.path(), json!({"themes/look.json":reference}));
        assert!(customize.load_profile(path.to_str().unwrap()).is_err(), "{reference}");
        assert!(!target.path().join("config").exists());
    }
}

#[test]
fn references_reject_large_binary_and_nonregular_files() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(target.path()));
    fs::write(source.path().join("large"), vec![b'x'; 2 * 1024 * 1024 + 1]).unwrap();
    fs::write(source.path().join("binary"), [0xff]).unwrap();
    fs::create_dir(source.path().join("folder")).unwrap();
    for file in ["large", "binary", "folder"] {
        let path = write_manifest(source.path(), json!({"themes/look.json":{"$file":file}}));
        assert!(customize.load_profile(path.to_str().unwrap()).is_err(), "{file}");
    }
}

#[cfg(unix)]
#[test]
fn references_reject_links_in_any_path_component() {
    let source = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("theme.json"), "{}").unwrap();
    std::os::unix::fs::symlink(outside.path(), source.path().join("linked-dir")).unwrap();
    std::os::unix::fs::symlink(
        outside.path().join("theme.json"),
        source.path().join("linked-file"),
    )
    .unwrap();
    let customize = Customize::open(Roots::under(outside.path()));
    for file in ["linked-dir/theme.json", "linked-file"] {
        let path = write_manifest(source.path(), json!({"themes/look.json":{"$file":file}}));
        assert!(customize.load_profile(path.to_str().unwrap()).is_err(), "{file}");
    }
}

#[test]
fn referenced_contents_and_destinations_still_validate_before_preview_or_install() {
    let source = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    fs::write(source.path().join("bad.json"), "not json").unwrap();
    let customize = Customize::open(Roots::under(target.path()));
    for logical in ["keybindings.json", "../outside.json"] {
        let path = write_manifest(source.path(), json!({logical:{"$file":"bad.json"}}));
        let profile = customize.load_profile(path.to_str().unwrap()).unwrap();
        assert!(customize.preview_profile(&profile, "test", 1).is_err());
        assert!(!target.path().join("config").exists());
        let mut manifest: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        manifest["cmuxSetup"] = json!(1);
        manifest["id"] = json!("someone/look");
        fs::write(source.path().join(setup::SETUP_FILE), manifest.to_string()).unwrap();
        let setup = setup::read_dir(source.path()).unwrap();
        assert!(customize.plan_setup(&setup, "someone", "0.0.0").is_err());
        assert!(customize.install_setup(&setup, "Look", "test", 2).is_err());
        assert!(!target.path().join("config").exists());
    }
}
