//! Supervisor tests of the composer places (`composer.rs`): extension slash
//! commands and mention providers, answered by the daemon from the catalog.

use super::*;

/// Gives the app in `dir` the composer slash commands `commands`
/// (`[(name, insert)]`) and, when `version` is set, that version.
fn save_commands(dir: &Path, commands: &[(&str, &str)], version: Option<&str>) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let commands: Vec<Value> = commands
        .iter()
        .map(|(name, insert)| json!({ "name": name, "description": format!("{name} it"), "insert": insert }))
        .collect();
    manifest["implements"]["cmux.composer.command/1"] =
        json!({ "options": { "commands": commands } });
    if let Some(version) = version {
        manifest["version"] = json!(version);
    }
    std::fs::write(&path, manifest.to_string()).unwrap();
}

fn spy_dir(f: &Fixture) -> PathBuf {
    f.state.join("apps/local/spy")
}

fn list(f: &Fixture) -> Value {
    f.supervisor.store_call(CLIENT, "apps.composer.list", json!({}), Origin::User).unwrap()
}

/// `[(name, insert)]` of the listed commands.
fn commands(f: &Fixture) -> Vec<(String, String)> {
    list(f)["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["name"].as_str().unwrap().into(), c["insert"].as_str().unwrap().into()))
        .collect()
}

/// A sample slash command from an installed extension is listed with the
/// text its pick inserts, its sentence and its extension's name; a hidden
/// or uninstalled extension lists none (the composer shows only what this
/// answers, `composer/slashTokens.ts`).
#[test]
fn an_installed_extensions_slash_command_is_listed_with_its_insert_text() {
    let f = fixture();
    save_commands(&spy_dir(&f), &[("standup", "Write my standup notes.")], None);
    f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(list(&f)["commands"], json!([]), "not installed yet");

    f.install("local/spy");
    assert_eq!(
        list(&f)["commands"],
        json!([{
            "app": "local/spy", "extension": "Demo", "name": "standup",
            "description": "standup it", "insert": "Write my standup notes."
        }])
    );

    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert_eq!(list(&f)["commands"], json!([]), "a hidden extension adds nothing");
}

/// Editing the installed extension's command updates the list with no
/// restart: the local reload swaps the catalog and says `apps-changed`, on
/// which the composer lists again.
#[test]
fn a_save_of_the_installed_extensions_command_updates_the_list_live() {
    let f = fixture();
    save_commands(&spy_dir(&f), &[("standup", "Old text.")], None);
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    assert_eq!(commands(&f), [("standup".to_string(), "Old text.".to_string())]);

    save_commands(
        &spy_dir(&f),
        &[("standup", "New text."), ("retro", "Run a retro.")],
        Some("1.0.1"),
    );
    f.supervisor.reload_local_apps(&prints);
    let changed = f.wait("the reload's apps-changed", |e| {
        e["event"] == "apps-changed"
            && e["transaction"] == "local-reload"
            && e["app"] == "local/spy"
    });
    assert_eq!(changed["app"], "local/spy");
    assert_eq!(
        commands(&f),
        [
            ("standup".to_string(), "New text.".to_string()),
            ("retro".to_string(), "Run a retro.".to_string())
        ]
    );
}

/// One `/name` never means two things: the app first in id order keeps it.
#[test]
fn a_command_name_two_extensions_share_is_listed_once() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({ "workspace:read": "r" }));
    save_commands(&root.0.join("bundled/demo"), &[("standup", "From demo.")], None);
    // `fixture_with` writes neither app when the bundled one is there.
    let local = root.0.join("state/apps/local");
    write_app(&local, "spy", "local/spy", json!({ "workspace:read": "r" }));
    save_commands(&local.join("spy"), &[("standup", "From spy."), ("retro", "Retro.")], None);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/demo");
    f.install("local/spy");
    assert_eq!(
        commands(&f),
        [
            ("standup".to_string(), "From demo.".to_string()),
            ("retro".to_string(), "Retro.".to_string())
        ]
    );
}

/// Safe mode turns every extension off: the composer gets none.
#[test]
fn safe_mode_lists_no_extension_commands() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({ "workspace:read": "r" }));
    save_commands(&root.0.join("bundled/demo"), &[("standup", "From demo.")], None);
    let f = fixture_safe(&[], Duration::from_secs(60), root, true);
    f.install("cmux/demo");
    assert_eq!(list(&f)["commands"], json!([]));
}

/// Mention completions are ranked in the daemon: a prefix of the id or
/// label first, then a prefix of a word, then anywhere; `prefix` narrows to
/// one provider and `limit` caps the answer.
#[test]
fn mention_completions_are_ranked_by_the_daemon() {
    let f = fixture();
    let path = spy_dir(&f).join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.composer.mention/1"] = json!({ "options": {
        "prefix": "ticket",
        "items": [
            { "id": "ENG-3", "label": "ENG-3 Fix the login page", "detail": "Open" },
            { "id": "ENG-1", "label": "ENG-1 Slow sidebar", "insert": "ENG-1" },
            { "id": "ENG-2", "label": "ENG-2 Loginless mode" },
            { "id": "LOG-9", "label": "LOG-9 Rotate logs" }
        ]
    } });
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    assert_eq!(
        list(&f)["mentions"],
        json!([{ "app": "local/spy", "extension": "Demo", "prefix": "ticket", "items": 4 }])
    );

    let ask = |args: Value| {
        f.supervisor.store_call(CLIENT, "apps.composer.mentions", args, Origin::User).unwrap()
            ["mentions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(ask(json!({ "query": "log" })), ["LOG-9", "ENG-3", "ENG-2"]);
    assert_eq!(ask(json!({ "query": "LOG", "limit": 1 })), ["LOG-9"]);
    assert_eq!(ask(json!({ "query": "sidebar" })), ["ENG-1"]);
    assert_eq!(ask(json!({ "query": "", "prefix": "other" })), Vec::<String>::new());
    assert_eq!(ask(json!({ "query": "" })).len(), 4);
    let first = f
        .supervisor
        .store_call(CLIENT, "apps.composer.mentions", json!({ "query": "slow" }), Origin::User)
        .unwrap();
    assert_eq!(first["mentions"][0]["insert"], "ENG-1");
    let label = f
        .supervisor
        .store_call(CLIENT, "apps.composer.mentions", json!({ "query": "eng-3" }), Origin::User)
        .unwrap();
    assert_eq!(
        label["mentions"][0]["insert"], "ENG-3 Fix the login page",
        "the label when no insert"
    );
}
