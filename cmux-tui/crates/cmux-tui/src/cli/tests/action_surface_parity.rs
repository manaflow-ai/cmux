//! Every app action the app offers by CLI name (`cli: "offered"` in
//! plans/cmux-next/action-surfaces.json, exported by the app's
//! `ActionSurfaceParityTests`) must reach the app: the dispatcher runs the
//! mux grammar first and asks the app only when that grammar rejects the
//! words (`run_app_action_fallback`), so a CLI name the grammar accepts is
//! shadowed and its action never runs from `cmux`.

use super::*;

fn action_surfaces() -> serde_json::Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../plans/cmux-next/action-surfaces.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_str(&text).expect("action-surfaces.json is JSON")
}

/// The CLI names of the actions the app offers to `cmux`.
fn offered_cli_names() -> Vec<String> {
    let surfaces = action_surfaces();
    let actions = surfaces["actions"].as_array().expect("actions array");
    let names = actions
        .iter()
        .filter(|action| action["cli"] == "offered")
        .filter_map(|action| action["cli_name"].as_str().map(str::to_owned))
        .collect::<Vec<_>>();
    assert!(names.len() > 300, "only {} offered CLI names; is the export stale?", names.len());
    names
}

#[test]
fn no_offered_app_cli_name_is_shadowed_by_the_mux_grammar() {
    let mut shadowed = Vec::new();
    for name in offered_cli_names() {
        let words = name.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
        // App scopes (`app`, `settings`, ...) and coderouter route before
        // the mux grammar.
        if matches!(app::parse(&words), Ok(Some(_))) || coderouter::split(&words).is_some() {
            continue;
        }
        if parse(&words, Surface::Cmux).is_ok() {
            shadowed.push(name);
        }
    }
    assert!(
        shadowed.is_empty(),
        "the mux grammar accepts these app CLI names, so `cmux` never runs their action: {shadowed:?}"
    );
}

/// `cmux servers add --code CODE --words "W1 W2 W3 W4" [--chief] [--name N]`
/// still serializes the legacy action request so old clients get the app's
/// stable person-only refusal. The mux grammar (its `server` scope is the local
/// session owner) does not take the words, and the flags arrive as the action's
/// `code`, `words`, `chief` and `name` arguments. Enrollment itself is available
/// only through the in-app Add Server flow.
#[test]
fn servers_add_runs_the_add_server_action_with_its_arguments() {
    let surfaces = action_surfaces();
    let add = surfaces["actions"]
        .as_array()
        .expect("actions array")
        .iter()
        .find(|action| action["id"] == "server.addServer")
        .expect("server.addServer is exported");
    assert_eq!(add["cli"], "offered");
    assert_eq!(add["cli_name"], "servers add");
    let words = strings(&["servers", "add"]);
    assert!(parse(&words, Surface::Cmux).is_err(), "the mux grammar must not shadow `servers add`");
    let command = app::run_action(
        "servers add",
        &strings(&[
            "--code",
            "K0Q5-1M6C",
            "--words",
            "copper lantern meadow violet",
            "--chief",
            "--name",
            "cmux-lawrence",
        ]),
        app::ActionName::Cli,
    )
    .expect("flags parse");
    let app::AppCommand::Call { method, params, .. } = command else { panic!("expected a call") };
    assert_eq!(method, "action.run");
    assert_eq!(params["action"], "servers add");
    assert_eq!(params["cli"], true);
    assert_eq!(
        params["args"],
        serde_json::json!({ "code": "K0Q5-1M6C", "words": "copper lantern meadow violet", "chief": true, "name": "cmux-lawrence" })
    );
}

/// `cmux chat create --members "Chief, Unii, aziz@manaflow.com" --title T --replies all` starts a
/// Home group with Chiefs (plans/cmux-next/chief-group-chats-DESIGN.md): the app offers
/// `home.createGroup` under that CLI name and the mux grammar leaves the words alone; `cmux chat
/// replies` is `home.setChiefReplies`.
#[test]
fn chat_create_and_replies_run_the_home_group_actions() {
    let surfaces = action_surfaces();
    let actions = surfaces["actions"].as_array().expect("actions array");
    for (id, cli) in [("home.createGroup", "chat create"), ("home.setChiefReplies", "chat replies")]
    {
        let action = actions
            .iter()
            .find(|action| action["id"] == id)
            .unwrap_or_else(|| panic!("{id} is exported"));
        assert_eq!(action["cli"], "offered", "{id}");
        assert_eq!(action["cli_name"], cli, "{id}");
        let words = cli.split(' ').map(str::to_owned).collect::<Vec<_>>();
        assert!(parse(&words, Surface::Cmux).is_err(), "the mux grammar must not shadow `{cli}`");
    }
    let command = app::run_action(
        "chat create",
        &strings(&["--members", "Chief, Unii", "--title", "Ship it", "--replies", "all"]),
        app::ActionName::Cli,
    )
    .expect("flags parse");
    let app::AppCommand::Call { params, .. } = command else { panic!("expected a call") };
    assert_eq!(params["action"], "chat create");
    assert_eq!(
        params["args"],
        serde_json::json!({ "members": "Chief, Unii", "title": "Ship it", "replies": "all" })
    );
}

/// `cmux pane open-files-as` and `cmux pane open-find-as` are verbs (and so MCP
/// tools): the app offers Open Files / Find as Pane under those CLI names, the
/// mux grammar leaves the words alone, and `--path` reaches the action as an
/// absolute folder of the caller's working directory.
#[test]
fn pane_open_files_and_find_as_run_their_actions_with_a_path() {
    let surfaces = action_surfaces();
    let actions = surfaces["actions"].as_array().expect("actions array");
    for (id, cli) in [
        ("palette.openFilesPane", "pane open-files-as"),
        ("palette.openFindPane", "pane open-find-as"),
    ] {
        let action = actions
            .iter()
            .find(|action| action["id"] == id)
            .unwrap_or_else(|| panic!("{id} is exported"));
        assert_eq!(action["cli"], "offered", "{id}");
        assert_eq!(action["mcp"], "offered", "{id}");
        assert_eq!(action["cli_name"], cli, "{id}");
        let words = cli.split(' ').map(str::to_owned).collect::<Vec<_>>();
        assert!(parse(&words, Surface::Cmux).is_err(), "the mux grammar must not shadow `{cli}`");
        assert_eq!(action_hint::non_verb_action(cli), None, "`{cli}` is a verb, not a hint");
        let command = app::run_action(cli, &strings(&["--path", "src"]), app::ActionName::Cli)
            .expect("flags parse");
        let app::AppCommand::Call { method, params, .. } = command else {
            panic!("expected a call")
        };
        assert_eq!(method, "action.run");
        assert_eq!(params["action"], cli);
        assert_eq!(params["cli"], true);
        let cwd = std::env::current_dir().expect("cwd");
        assert_eq!(params["args"]["path"], cwd.join("src").to_string_lossy().as_ref());
    }
}

/// cmux#44937: every action a person can run from a menu, a right-click or the palette has a CLI
/// path. With a named verb, `cmux <cli name>` (checked above); without one, `cmux action run <id>`
/// sends exactly that id, which no other spelling (`verb_spelling`) rewrites. The app's
/// `CLISurfaceParityTests.everyGUIActionRunsFromTheCLIByID` checks the other end: each such
/// `action.run` reaches its own handler.
#[test]
fn every_gui_action_runs_by_its_id_with_action_run() {
    let surfaces = action_surfaces();
    let mut checked = 0;
    for action in surfaces["actions"].as_array().expect("actions array") {
        let gui = action["palette"] == "offered"
            || action["context_menus"].as_array().is_some_and(|menus| !menus.is_empty())
            || !action["main_menu"].is_null();
        if !gui || action["cli"] == "devOnly" {
            continue;
        }
        let id = action["id"].as_str().expect("an action id");
        let command = app::parse(&strings(&["action", "run", id]))
            .unwrap_or_else(|error| panic!("cmux action run {id}: {}", error.0))
            .unwrap_or_else(|| panic!("cmux action run {id}: no command"));
        let app::AppCommand::Call { method, params, .. } = command else {
            panic!("cmux action run {id}: not a call")
        };
        assert_eq!(method, "action.run", "{id}");
        assert_eq!(params["action"], id, "cmux action run {id} sent another action");
        checked += 1;
    }
    assert!(checked > 1000, "only {checked} GUI actions; is the export stale?");
}

/// cmux#44937: an offered verb also takes its object first, as the mux grammar spells its own
/// verbs: `cmux <noun> <id> <verb…>` is `cmux <noun> <verb…> --target <id>`, unless the mux grammar
/// has that verb itself (`workspace <ws> close`).
#[test]
fn every_offered_verb_takes_its_object_first() {
    let mut missing = Vec::new();
    for name in offered_cli_names() {
        let Some((noun, verb)) = name.split_once(' ') else { continue };
        let mut words = strings(&[noun, "obj_0123456789abcdef"]);
        words.extend(verb.split_whitespace().map(str::to_owned));
        if parse(&words, Surface::Cmux).is_ok() || matches!(app::parse(&words), Ok(Some(_))) {
            continue;
        }
        let expected = (name.clone(), strings(&["--target", "obj_0123456789abcdef"]));
        if verb_spelling::action(&words) != Some(expected) {
            missing.push(name);
        }
    }
    assert!(missing.is_empty(), "these verbs do not take their object first: {missing:?}");
}
