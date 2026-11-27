use super::*;

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

/// Codex's `model/list` is what the account runs, so the picker keeps to it, but an older Codex
/// lists no release newer than itself: GPT-6.2 Sol stayed hidden until the person updated Codex
/// (Leo, 2026-11-20: "enable seeing new models even when ppl dont upgradetheir stuff"). A newer
/// release of a family the CLI lists is offered and leads the menu; a family it lists none of
/// (an API-only release) and a deprecated one stay out.
fn codex_catalog() -> Catalog {
    crate::catalog::schema::parse(
        &serde_json::to_vec(&json!({
            "schemaVersion": 1, "generatedAt": "2026-11-26T00:00:00.000Z", "source": "live",
            "harnesses": [{
                "id": "codex", "name": "Codex", "brand": "openai", "families": ["codex"],
                "modelSource": "catalog",
                "models": [
                    {"id": "gpt-6.2-sol", "ref": "openai/gpt-6.2-sol", "name": "GPT-6.2 Sol", "shortName": "GPT-6.2 Sol"},
                    {"id": "gpt-6.2-astra", "ref": "openai/gpt-6.2-astra", "name": "GPT-6.2 Astra", "shortName": "GPT-6.2 Astra"},
                    {"id": "gpt-6.1-sol", "ref": "openai/gpt-6.1-sol", "name": "GPT-6.1 Sol", "shortName": "GPT-6.1 Sol"},
                    {"id": "gpt-6-sol", "ref": "openai/gpt-6-sol", "name": "GPT-6 Sol", "shortName": "GPT-6 Sol"},
                    {"id": "gpt-6.1-luna", "ref": "openai/gpt-6.1-luna", "name": "GPT-6.1 Luna", "shortName": "GPT-6.1 Luna", "status": "deprecated"},
                    {"id": "gpt-6-luna", "ref": "openai/gpt-6-luna", "name": "GPT-6 Luna", "shortName": "GPT-6 Luna"}
                ]
            }],
            "models": {
                "openai/gpt-6.2-sol": {"name": "GPT-6.2 Sol", "family": "gpt-sol", "releaseDate": "2026-11-17"},
                "openai/gpt-6.2-astra": {"name": "GPT-6.2 Astra", "family": "gpt-astra", "releaseDate": "2026-11-17"},
                "openai/gpt-6.1-sol": {"name": "GPT-6.1 Sol", "family": "gpt-sol", "releaseDate": "2026-09-29"},
                "openai/gpt-6-sol": {"name": "GPT-6 Sol", "family": "gpt-sol", "releaseDate": "2026-09-22"},
                "openai/gpt-6.1-luna": {"name": "GPT-6.1 Luna", "family": "gpt-luna", "releaseDate": "2026-09-29"},
                "openai/gpt-6-luna": {"name": "GPT-6 Luna", "family": "gpt-luna", "releaseDate": "2026-09-22"}
            },
            "providers": {"openai": {"name": "OpenAI"}}
        }))
        .unwrap(),
    )
    .unwrap()
}

fn old_codex_menu() -> Vec<(String, String)> {
    [("gpt-6.1-sol", "GPT-6.1 Sol"), ("gpt-6-sol", "GPT-6 Sol"), ("gpt-6-luna", "GPT-6 Luna")]
        .map(|(id, name)| (id.to_owned(), name.to_owned()))
        .to_vec()
}

#[test]
fn an_older_codex_still_offers_the_newer_release_of_a_family_it_runs() {
    let catalog = codex_catalog();
    let curated = &catalog.harnesses[0];
    let offered = offered(&HarnessKind::Acp, Some(curated), &catalog, &old_codex_menu(), true);
    let ids: Vec<&str> = offered.iter().filter_map(|m| m["id"].as_str()).collect();
    assert_eq!(ids, ["gpt-6.2-sol", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"]);
    assert_eq!(newer_than_menu(curated, &catalog, &old_codex_menu()), ["gpt-6.2-sol"]);
}

#[test]
fn a_current_codex_menu_promotes_nothing() {
    let catalog = codex_catalog();
    let mut menu = old_codex_menu();
    menu.insert(0, ("gpt-6.2-sol".to_owned(), "GPT-6.2 Sol".to_owned()));
    assert!(newer_than_menu(&catalog.harnesses[0], &catalog, &menu).is_empty());
}
