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

#[test]
fn model_picker_layout_follows_the_installed_visible_app() {
    let f = fixture();
    let path = spy_dir(&f).join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let options = json!({ "modelMenu": "search", "reasoningMenu": "column" });
    manifest
        .get_mut("implements")
        .and_then(Value::as_object_mut)
        .expect("the spy manifest implements interfaces")
        .insert("cmux.composer.model.picker/1".to_owned(), json!({ "options": options }));
    std::fs::write(path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&Default::default());
    assert!(list(&f).get("modelPicker").is_none());
    f.install("local/spy");
    assert_eq!(list(&f).get("modelPicker"), Some(&options));
    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert!(list(&f).get("modelPicker").is_none());
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

/// A prompt saved with `cmux agent-config commands add --agent cmux` is in the composer's `/`
/// list on the next call, before the extensions' commands and taking its name from them, with
/// the prompt as the text its pick writes; removing it takes it out again.
#[test]
fn a_saved_prompt_is_listed_in_the_slash_menu() {
    use cmux_agent_customize::commands::{self, NewCommand, Target};
    let f = fixture();
    save_commands(&spy_dir(&f), &[("standup", "From spy."), ("retro", "Retro.")], None);
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    let mut homes = cmux_agent_customize::Homes::under(f._root.0.join("home"));
    homes.cmux_commands = f._root.0.join("saved-prompts");
    let saved = commands::add(
        &homes,
        &NewCommand {
            agent: Target::Cmux,
            name: "standup".into(),
            description: "My standup".into(),
            prompt: "Write my standup from today's commits.".into(),
            replace: false,
        },
    )
    .unwrap();
    assert_eq!(saved.path, f._root.0.join("saved-prompts/standup.md"));
    let listed = list(&f)["commands"].clone();
    assert_eq!(
        listed[0],
        json!({
            "app": "cmux/saved-prompts", "extension": "cmux", "name": "standup",
            "description": "My standup", "insert": "Write my standup from today's commits."
        })
    );
    assert_eq!(
        commands(&f),
        vec![
            ("standup".to_string(), "Write my standup from today's commits.".to_string()),
            ("retro".to_string(), "Retro.".to_string())
        ],
        "the saved prompt takes /standup from the extension"
    );
    commands::remove(&homes, Target::Cmux, "standup").unwrap();
    assert_eq!(
        commands(&f),
        vec![
            ("standup".to_string(), "From spy.".to_string()),
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

#[test]
fn composer_toolbar_is_opt_in_and_follows_installed_app_visibility() {
    let f = fixture();
    let path = spy_dir(&f).join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let buttons = json!([{ "action": "composer.attachFiles" }, { "action": "composer.commands", "label": "Commands" }]);
    manifest["implements"]["cmux.composer.toolbar/1"] =
        json!({ "options": { "buttons": buttons } });
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(list(&f)["toolbarButtons"], json!([]));
    f.install("local/spy");
    assert_eq!(list(&f)["toolbarButtons"], buttons);
}

/// Gives the app in `dir` the mention provider `prefix` with `items`
/// (`[(id, label)]`) and, when `version` is set, that version.
fn save_mentions(dir: &Path, prefix: &str, items: &[(&str, &str)], version: Option<&str>) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let items: Vec<Value> =
        items.iter().map(|(id, label)| json!({ "id": id, "label": label })).collect();
    manifest["implements"]["cmux.composer.mention/1"] =
        json!({ "options": { "prefix": prefix, "items": items } });
    if let Some(version) = version {
        manifest["version"] = json!(version);
    }
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// Saving the installed extension's mention items changes what the `@` menu
/// is answered with no restart and no rebuild: the local reload swaps the
/// catalog and says `apps-changed`, and the next `apps.composer.mentions`
/// (the page asks on every keystroke of an `@` word) answers the new items.
#[test]
fn a_save_of_the_installed_extensions_mentions_updates_the_at_menu_live() {
    let f = fixture();
    save_mentions(&spy_dir(&f), "pr", &[("441", "441 Old title")], None);
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    let ask = || {
        f.supervisor
            .store_call(
                CLIENT,
                "apps.composer.mentions",
                json!({ "query": "", "prefix": "pr" }),
                Origin::User,
            )
            .unwrap()["mentions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| {
                (m["id"].as_str().unwrap().to_string(), m["label"].as_str().unwrap().to_string())
            })
            .collect::<Vec<_>>()
    };
    assert_eq!(ask(), [("441".to_string(), "441 Old title".to_string())]);

    save_mentions(
        &spy_dir(&f),
        "pr",
        &[("441", "441 New title"), ("442", "442 Another")],
        Some("1.0.1"),
    );
    f.supervisor.reload_local_apps(&prints);
    f.wait("the reload's apps-changed", |e| {
        e["event"] == "apps-changed"
            && e["transaction"] == "local-reload"
            && e["app"] == "local/spy"
    });
    assert_eq!(
        ask(),
        [
            ("441".to_string(), "441 New title".to_string()),
            ("442".to_string(), "442 Another".to_string())
        ]
    );
    assert_eq!(list(&f)["mentions"][0]["items"], 2, "the provider's count follows the save");
}

/// Gives `local/spy` the context chips `chips` (`[(id, label, insert)]`) at
/// `version`, written in place as an editor saves.
fn save_chips(f: &Fixture, chips: &[(&str, &str, &str)], version: &str) {
    let path = spy_dir(f).join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let chips: Vec<Value> = chips
        .iter()
        .map(|(id, label, insert)| json!({ "id": id, "label": label, "insert": insert }))
        .collect();
    manifest["implements"]["cmux.composer.chip/1"] = json!({ "options": { "chips": chips } });
    manifest["version"] = json!(version);
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// `[(id, insert)]` of the listed chips.
fn chips(f: &Fixture) -> Vec<(String, String)> {
    list(f)["chips"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["id"].as_str().unwrap().into(), c["insert"].as_str().unwrap().into()))
        .collect()
}

/// Waits (10 s at most) until the listed chips are `want`.
fn wait_for_chips(f: &Fixture, what: &str, want: &[(&str, &str)]) {
    let want: Vec<(String, String)> =
        want.iter().map(|(id, insert)| (id.to_string(), insert.to_string())).collect();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let now = chips(f);
        if now == want {
            return;
        }
        assert!(Instant::now() < deadline, "{what}: chips stayed {now:?}, want {want:?}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// A chip saved in the installed extension's manifest shows in
/// `apps.composer.list` through the real file watch, with no restart and no
/// rebuild; each later save replaces it; a hidden extension offers none.
#[test]
fn a_saved_chip_shows_in_the_list() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    assert_eq!(list(&f)["chips"], json!([]), "no chip place yet");
    f.supervisor.start_local_watch_for_test();
    // The watch reads once as it starts; let that settle.
    std::thread::sleep(Duration::from_millis(500));

    save_chips(&f, &[("branch", "Branch", "Work on the current git branch.")], "1.0.1");
    wait_for_chips(&f, "the first save", &[("branch", "Work on the current git branch.")]);
    assert_eq!(
        list(&f)["chips"],
        json!([{
            "app": "local/spy", "extension": "Demo", "id": "branch", "label": "Branch",
            "insert": "Work on the current git branch."
        }])
    );

    save_chips(
        &f,
        &[("branch", "Branch", "Use branch main."), ("tests", "Tests", "Run the tests first.")],
        "1.0.2",
    );
    wait_for_chips(
        &f,
        "the second save",
        &[("branch", "Use branch main."), ("tests", "Run the tests first.")],
    );

    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert_eq!(list(&f)["chips"], json!([]), "a hidden extension adds no chip");
}

/// A chip that breaks `cmux.composer.chip/1` (no insert text, a duplicate
/// id) is refused when saved: the reload names the folder and why, and the
/// composer gets no chip from that save, never half of it. The next good
/// save shows its chips again.
#[test]
fn a_chip_that_breaks_the_interface_is_refused() {
    let f = fixture();
    save_chips(&f, &[("branch", "Branch", "Use branch main.")], "1.0.0");
    f.supervisor.reload_local_apps_now();
    f.install("local/spy");
    assert_eq!(chips(&f), [("branch".to_string(), "Use branch main.".to_string())]);

    let path = spy_dir(&f).join("cmux-app.json");
    for (why, bad) in [
        ("no insert", json!([{ "id": "branch", "label": "Branch" }])),
        (
            "an id twice",
            json!([
                { "id": "branch", "label": "A", "insert": "a" },
                { "id": "branch", "label": "B", "insert": "b" }
            ]),
        ),
        ("an id with spaces", json!([{ "id": "my chip", "label": "A", "insert": "a" }])),
    ] {
        let mut manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        manifest["implements"]["cmux.composer.chip/1"] = json!({ "options": { "chips": bad } });
        std::fs::write(&path, manifest.to_string()).unwrap();
        let answer = f.supervisor.reload_local_apps_now();
        let rejected = answer["rejected"].as_array().unwrap();
        assert!(
            rejected.iter().any(|r| r["dir"] == spy_dir(&f).display().to_string()
                && r["issue"].as_str().is_some_and(|i| i.contains("cmux.composer.chip"))),
            "{why}: {answer}"
        );
        assert_eq!(list(&f)["chips"], json!([]), "{why}: the refused save adds no chip");
    }

    save_chips(&f, &[("tests", "Tests", "Run the tests first.")], "1.0.1");
    f.supervisor.reload_local_apps_now();
    assert_eq!(chips(&f), [("tests".to_string(), "Run the tests first.".to_string())]);
}

/// Two extensions offering the same insert text show one chip, the app
/// first in id order keeps it.
#[test]
fn a_chip_two_extensions_share_is_listed_once() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({ "workspace:read": "r" }));
    let local = root.0.join("state/apps/local");
    write_app(&local, "spy", "local/spy", json!({ "workspace:read": "r" }));
    for (dir, chips) in [
        (
            root.0.join("bundled/demo"),
            json!([{ "id": "tests", "label": "Tests", "insert": "Run the tests." }]),
        ),
        (
            local.join("spy"),
            json!([
                { "id": "check", "label": "Check", "insert": "Run the tests." },
                { "id": "lint", "label": "Lint", "insert": "Run the linter." }
            ]),
        ),
    ] {
        let path = dir.join("cmux-app.json");
        let mut manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        manifest["implements"]["cmux.composer.chip/1"] = json!({ "options": { "chips": chips } });
        std::fs::write(&path, manifest.to_string()).unwrap();
    }
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/demo");
    f.install("local/spy");
    let listed: Vec<(String, String)> = list(&f)["chips"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["app"].as_str().unwrap().into(), c["id"].as_str().unwrap().into()))
        .collect();
    assert_eq!(
        listed,
        [
            ("cmux/demo".to_string(), "tests".to_string()),
            ("local/spy".to_string(), "lint".to_string())
        ]
    );
}
