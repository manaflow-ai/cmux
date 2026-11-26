use super::*;
use std::collections::BTreeMap;

#[test]
fn harness_picker_order_survives_catalog_order_and_aliases() {
    let models = vec![
        json!({"id": "release-b", "aliases": ["b"]}),
        json!({"id": "release-a", "aliases": ["a"]}),
        json!({"id": "older"}),
    ];
    let reported = [("default", "Default"), ("a", "A"), ("b", "B"), ("a", "A")]
        .map(|(id, name)| (id.to_owned(), name.to_owned()));
    assert_eq!(picker_models(&reported, &models), vec!["release-a", "release-b"]);
}

/// Gemini CLI's ACP menu is fixed in each release (0.69.0 names no Gemini 4 model) while it
/// runs any Gemini API id: its catalog models are offered, and the ones newer than its whole
/// menu lead it (user 2026-11-19: "gemini neon didn't automatically appear in model picker").
fn gemini_catalog(runs_any_model: bool) -> Catalog {
    crate::catalog::schema::parse(
        &serde_json::to_vec(&json!({
            "schemaVersion": 1, "generatedAt": "2026-11-19T00:00:00.000Z", "source": "live",
            "harnesses": [{
                "id": "gemini", "name": "Gemini CLI", "brand": "gemini", "families": ["gemini"],
                "modelSource": "catalog", "runsAnyModel": runs_any_model,
                "models": [
                    {"id": "gemini-4-neon", "ref": "google/gemini-4-neon", "name": "Gemini 4 Neon", "shortName": "4 Neon"},
                    {"id": "gemini-3.1-pro-preview", "ref": "google/gemini-3.1-pro-preview", "name": "Gemini 3.1 Pro Preview", "shortName": "3.1 Pro Preview"},
                    {"id": "gemini-2.5-pro", "ref": "google/gemini-2.5-pro", "name": "Gemini 2.5 Pro", "shortName": "2.5 Pro"}
                ]
            }],
            "models": {
                "google/gemini-4-neon": {"name": "Gemini 4 Neon", "releaseDate": "2026-11-18"},
                "google/gemini-3.1-pro-preview": {"name": "Gemini 3.1 Pro Preview", "releaseDate": "2026-02-19"},
                "google/gemini-2.5-pro": {"name": "Gemini 2.5 Pro", "releaseDate": "2025-06-17"}
            },
            "providers": {"google": {"name": "Google"}}
        }))
        .unwrap(),
    )
    .unwrap()
}

#[test]
fn a_disabled_model_never_shows_even_when_the_harness_reports_it() {
    let mut models = vec![
        json!({"id": "gemini-4-neon", "name": "Gemini 4 Neon"}),
        json!({"id": "gemini-3.1-pro-preview", "name": "Gemini 3.1 Pro Preview"}),
    ];
    drop_disabled(&mut models, &["gemini-4-neon".to_owned()]);
    let ids: Vec<&str> = models.iter().filter_map(|m| m["id"].as_str()).collect();
    assert_eq!(ids, ["gemini-3.1-pro-preview"]);
}

fn gemini_menu() -> Vec<(String, String)> {
    [
        ("auto-gemini-3", "Auto (Gemini 3)"),
        ("gemini-3.1-pro-preview", "Gemini 3.1 Pro Preview"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
    ]
    .map(|(id, name)| (id.to_owned(), name.to_owned()))
    .to_vec()
}

#[test]
fn a_harness_that_runs_any_model_offers_catalog_models_its_menu_lacks() {
    let catalog = gemini_catalog(true);
    let curated = &catalog.harnesses[0];
    let offered = offered(&HarnessKind::Acp, Some(curated), &catalog, &gemini_menu(), false);
    let ids: Vec<&str> = offered.iter().filter_map(|m| m["id"].as_str()).collect();
    assert!(ids.contains(&"gemini-4-neon"), "{ids:?}");
    assert!(ids.contains(&"auto-gemini-3"), "the harness's own choices stay: {ids:?}");
    assert_eq!(newer_than_menu(curated, &catalog, &gemini_menu()), ["gemini-4-neon"]);
}

#[test]
fn a_harness_whose_menu_is_the_account_list_keeps_only_what_it_reports() {
    let catalog = gemini_catalog(false);
    let curated = &catalog.harnesses[0];
    let offered = offered(&HarnessKind::Acp, Some(curated), &catalog, &gemini_menu(), false);
    assert!(!offered.iter().any(|m| m["id"] == "gemini-4-neon"));
    assert!(newer_than_menu(curated, &catalog, &gemini_menu()).is_empty());
}

/// A menu with no dated model gives nothing to compare: no catalog model is promoted.
#[test]
fn an_undated_menu_promotes_nothing() {
    let catalog = gemini_catalog(true);
    let menu = vec![("auto-gemini-3".to_owned(), "Auto".to_owned())];
    assert!(newer_than_menu(&catalog.harnesses[0], &catalog, &menu).is_empty());
}

#[test]
fn a_new_harness_model_needs_no_cmux_top_list_update() {
    let models = vec![json!({"id": "new-family"}), json!({"id": "existing"})];
    let reported = [("existing", "Existing"), ("new-family", "New")]
        .map(|(id, name)| (id.to_owned(), name.to_owned()));
    assert_eq!(picker_models(&reported, &models), vec!["existing", "new-family"]);
}
