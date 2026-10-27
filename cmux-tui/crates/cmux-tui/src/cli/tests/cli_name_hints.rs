//! Every cataloged CLI name is runnable: an action the CLI offers runs as
//! `cmux <noun> <verb>`, and every other action's CLI name tells the user to
//! run it with `cmux action run <id>` (exit 64) instead of a bare usage error
//! (plans/cmux-next/actions.md; the nxdog34 preflight found
//! `cmux settings show-crash-logs` printing only usage).

fn catalog_actions() -> Vec<serde_json::Value> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../plans/cmux-next/action-surfaces.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let doc: serde_json::Value = serde_json::from_str(&text).expect("action-surfaces.json is JSON");
    doc["actions"].as_array().expect("actions array").clone()
}

#[test]
fn every_cataloged_cli_name_is_a_verb_or_names_its_action() {
    let actions = catalog_actions();
    assert!(actions.len() > 300, "only {} actions; is the export stale?", actions.len());
    let mut wrong = Vec::new();
    for action in &actions {
        let (Some(id), Some(name)) = (action["id"].as_str(), action["cli_name"].as_str()) else {
            continue;
        };
        let hint = super::action_hint::non_verb_action(name);
        let expected = if action["cli"] == "offered" { None } else { Some(id) };
        if hint != expected {
            wrong.push(format!("{name}: {hint:?} != {expected:?}"));
        }
    }
    assert!(wrong.is_empty(), "CLI names whose hint does not match the catalog: {wrong:?}");
}

/// A GUI-only action's CLI name names nothing else: no `cmux` verb parses
/// it, or its hint and the catalog (`cmux action describe`, MCP, the docs)
/// would describe one command while the CLI runs another.
/// `settings feature-flags` was both help.featureFlags, which opens Settings,
/// and the verb that lists `features.list`.
#[test]
fn no_gui_only_cli_name_is_also_a_verb() {
    let mut shadowed = Vec::new();
    for action in catalog_actions() {
        if action["cli"] != "guiOnly" {
            continue;
        }
        let (Some(id), Some(name)) = (action["id"].as_str(), action["cli_name"].as_str()) else {
            continue;
        };
        let words: Vec<String> = name.split(' ').map(str::to_owned).collect();
        if super::parse(&words, super::Surface::Cmux).is_ok() {
            shadowed.push(format!("{name} ({id}): the mux grammar parses it"));
        }
        match super::app::parse(&words) {
            Ok(Some(super::app::AppCommand::Call { method: "action.run", .. }))
            | Ok(None)
            | Err(_) => {}
            Ok(Some(command)) => {
                shadowed.push(format!("{name} ({id}): an app verb parses it as {command:?}"))
            }
        }
    }
    assert!(
        shadowed.is_empty(),
        "CLI names that are both a GUI-only action and a verb: {shadowed:?}"
    );
}

#[test]
fn the_hint_names_the_action_run_command() {
    let message =
        super::action_hint::message("settings open-ghostty-config", "palette.openGhosttySettings");
    assert!(message.contains("cmux action run palette.openGhosttySettings"), "{message}");
    assert!(message.contains("settings open-ghostty-config"), "{message}");
    assert_eq!(super::action_hint::EXIT_CODE, 64);
}
