use super::*;
use serde_json::json;

#[test]
fn catalog_fragments_give_exports_and_palette_commands() {
    let dir = std::env::temp_dir().join(format!("cmux-apps-catalog-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let catalog = json!({ "family": "notes", "operations": [
        { "name": "notes.export", "export": "exportNotes", "palette": { "title": { "en": "Export" }, "when": "paneFocused:editor" },
          "keyboard": [{ "key": "cmd+shift+e", "when": "browserFocused" }, { "key": "f", "when": "browserFocused" }] },
        { "name": "notes.open", "export": "open", "keyboard": [{ "key": "cmd+shift+o" }] }
    ] });
    std::fs::write(dir.join("catalog.json"), catalog.to_string()).unwrap();
    let package = Package {
        id: "cmux/notes".into(),
        version: "1.0.0".into(),
        tier: Tier::FirstParty,
        source: Source::Bundled,
        dir: dir.clone(),
        manifest: json!({ "catalog": "catalog.json" }),
        fragment: Some(std::sync::Arc::new(catalog)),
    };
    let export = package.export_for_op("notes.open");
    let commands = package.palette_commands(None);
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(export.as_deref(), Some("open"));
    assert_eq!(
        commands,
        vec![
            json!({ "op": "notes.export", "title": { "en": "Export" }, "when": "paneFocused:editor",
                    "keys": [{ "key": "cmd+shift+e", "when": "browserFocused" }],
                    "page_keys": ["f", "shift+f"],
                    "page_key_when": { "f": "browserFocused", "shift+f": "browserFocused && !readOnly" } })
        ],
        "keys ride on palette commands only; a page key (`f`) stays out of the app layer"
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

/// Setups stack as layers of their own (`cmux setup install`): the
/// setups folder's `layers.json` names which load and in what order, a
/// folder it does not name (a layer turned off) stays unloaded, and a
/// `local/setup-*` id anywhere else is refused, as is the person's own
/// customize app staying theirs beside them.
#[test]
fn setup_layers_load_from_the_index_in_its_order_only() {
    let root = std::env::temp_dir().join(format!("cmux-apps-setup-layers-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let write = |dir: &Path, id: &str| {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("main.js"), "var __cmuxAppExports = {render() {}};").unwrap();
        let manifest = json!({
            "manifestVersion": 2, "id": id, "name": "Views", "version": "1.0.0",
            "description": "A view", "engines": {"cmux": "^2.0"},
            "runtime": {"main": "main.js"}, "files": ["main.js"],
            "implements": {"cmux.section/1": {"export": "render", "title": "Views"}}
        });
        std::fs::write(dir.join("cmux-app.json"), manifest.to_string()).unwrap();
    };
    let setups = root.join("setups");
    write(&root.join("customize"), CUSTOMIZE_APP);
    write(&setups.join("setup-leo-dusk"), "local/setup-leo-dusk");
    write(&setups.join("setup-leo-dawn"), "local/setup-leo-dawn");
    write(&setups.join("setup-leo-off"), "local/setup-leo-off");
    let impostor = root.join("local").join("impostor");
    write(&impostor, "local/setup-leo-dusk");
    let index = json!({"cmuxSetupLayers": 1, "layers": [
        {"id": "leo/dawn", "app": "local/setup-leo-dawn", "dir": "setup-leo-dawn"},
        {"id": "leo/dusk", "app": "local/setup-leo-dusk", "dir": "setup-leo-dusk"},
        {"id": "leo/x", "app": "local/setup-x", "dir": "../customize"}
    ]});
    std::fs::write(setups.join(SETUP_LAYERS_INDEX), index.to_string()).unwrap();
    let catalog = load(&Sources {
        local: Some(root.join("local")),
        customize: Some(root.join("customize")),
        setups: Some(setups.clone()),
        defaults: Some(Vec::new()),
        ..Sources::default()
    });
    let dusk = catalog.packages.get("local/setup-leo-dusk").map(|p| p.dir.clone());
    let impostor_refused = catalog.rejected.iter().any(|(dir, _)| dir == &impostor);
    let escape_refused = catalog.rejected.iter().any(|(_, why)| why.contains("not a setup layer"));
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(catalog.setup_layers, ["local/setup-leo-dawn", "local/setup-leo-dusk"]);
    assert_eq!(dusk, Some(setups.join("setup-leo-dusk")));
    assert!(!catalog.packages.contains_key("local/setup-leo-off"), "off: not in the index");
    assert!(catalog.packages.contains_key(CUSTOMIZE_APP), "the person's own app stays");
    assert!(impostor_refused, "a setup layer id outside the setups folder is refused");
    assert!(escape_refused, "a row naming a folder outside the setups folder is refused");
}

#[test]
fn contributed_keybindings_list_in_keybindings_json_form() {
    let package = Package {
        id: "local/branchy".into(),
        version: "1.0.0".into(),
        tier: Tier::Unverified,
        source: Source::Local,
        dir: std::env::temp_dir(),
        manifest: json!({ "activation": ["onKeybinding"], "contributes": { "keybindings": [
            { "key": "Cmd+Shift+B", "command": "local.branchy.copy_branch", "when": "terminalFocused" },
            { "key": "ctrl+k s", "command": "newTab", "args": { "name": "scratch" } },
            { "key": "b", "command": "newTab" }
        ] } }),
        fragment: None,
    };
    assert_eq!(
        package.keybindings(),
        vec![
            json!({ "key": "cmd+shift+b", "command": "app.command.run",
                    "args": { "app": "local/branchy", "command": "local.branchy.copy_branch" }, "when": "terminalFocused" }),
            json!({ "key": "ctrl+k s", "command": "newTab", "args": { "name": "scratch" } }),
        ],
        "a bare first stroke the validator refuses is left out"
    );
    assert_eq!(
        super::super::activation::Activation::of(&package),
        Default::default(),
        "onKeybinding keeps no host up"
    );
}
