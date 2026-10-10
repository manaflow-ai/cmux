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

#[test]
fn the_hint_names_the_action_run_command() {
    let message =
        super::action_hint::message("settings open-ghostty-config", "palette.openGhosttySettings");
    assert!(message.contains("cmux action run palette.openGhosttySettings"), "{message}");
    assert!(message.contains("settings open-ghostty-config"), "{message}");
    assert_eq!(super::action_hint::EXIT_CODE, 64);
}
