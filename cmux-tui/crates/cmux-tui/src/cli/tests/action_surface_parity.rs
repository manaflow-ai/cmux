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
