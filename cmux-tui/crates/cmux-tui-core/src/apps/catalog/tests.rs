use super::*;
use serde_json::json;

#[test]
fn catalog_fragments_give_exports_and_palette_commands() {
    let dir = std::env::temp_dir().join(format!("cmux-apps-catalog-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let catalog = json!({ "family": "notes", "operations": [
            { "name": "notes.export", "export": "exportNotes", "palette": { "title": { "en": "Export" }, "when": "paneFocused:editor" } },
            { "name": "notes.open", "export": "open" }
        ] });
    std::fs::write(dir.join("catalog.json"), catalog.to_string()).unwrap();
    let package = Package {
        id: "cmux/notes".into(),
        version: "1.0.0".into(),
        tier: Tier::FirstParty,
        source: Source::Bundled,
        dir: dir.clone(),
        manifest: json!({ "catalog": "catalog.json" }),
    };
    let export = package.export_for_op("notes.open");
    let commands = package.palette_commands();
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(export.as_deref(), Some("open"));
    assert_eq!(
        commands,
        vec![
            json!({ "op": "notes.export", "title": { "en": "Export" }, "when": "paneFocused:editor" })
        ]
    );
}

/// `local/customize` may run the person's own `cmuxConfig.*` actions
/// (`actions::decide_for`), so only their customize folder may claim it:
/// a package with that id in the local directory (or any other) is
/// rejected rather than shadowing the real one.
#[test]
fn only_the_customize_folder_provides_the_customize_app() {
    let root = std::env::temp_dir().join(format!("cmux-apps-customize-id-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let write = |dir: &Path, name: &str| {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("main.js"), "var __cmuxAppExports = {render() {}};").unwrap();
        let manifest = json!({
            "manifestVersion": 2, "id": CUSTOMIZE_APP, "name": name, "version": "1.0.0",
            "description": "A view", "engines": {"cmux": "^2.0"},
            "runtime": {"main": "main.js"}, "files": ["main.js"],
            "implements": {"cmux.section/1": {"export": "render", "title": name}}
        });
        std::fs::write(dir.join("cmux-app.json"), manifest.to_string()).unwrap();
    };
    let impostor = root.join("local").join("impostor");
    let customize = root.join("customize");
    write(&impostor, "Impostor");
    write(&customize, "My views");
    let catalog = load(&Sources {
        local: Some(root.join("local")),
        customize: Some(customize.clone()),
        defaults: Some(Vec::new()),
        ..Sources::default()
    });
    let dir = catalog.packages.get(CUSTOMIZE_APP).map(|package| package.dir.clone());
    let rejected = catalog.rejected.iter().any(|(dir, _)| dir == &impostor);
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(dir, Some(customize));
    assert!(rejected, "the local package claiming {CUSTOMIZE_APP} is rejected");
}
