use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

#[test]
fn parses_list_and_info_and_leaves_other_verbs() {
    assert_eq!(parse(&words("list")), Some(Ok(Request::List { installed: false, query: None })));
    assert_eq!(
        parse(&words("list --installed --query notes")),
        Some(Ok(Request::List { installed: true, query: Some("notes".into()) }))
    );
    assert_eq!(parse(&words("info acme/x")), Some(Ok(Request::Info { app: "acme/x".into() })));
    assert!(matches!(parse(&words("info")), Some(Err(_))));
    assert!(matches!(parse(&words("list --bogus")), Some(Err(_))));
    assert_eq!(parse(&words("install acme/x")), None, "install is the app action");
    assert_eq!(parse(&words("run acme/x op")), None, "run is apps_run");
}

#[test]
fn rows_join_install_state_and_filter_installed() {
    let catalog = json!({"listings": [
        {"app": "a/one", "name": "One", "tier": "unverified", "version": "1", "install": null},
        {"app": "a/two", "name": "Two", "tier": "first-party", "version": "1",
         "install": {"installed": true, "hidden": true, "enabled": true}},
    ]});
    let all = rows(&catalog, false);
    assert_eq!(all.len(), 2);
    assert_eq!(all[0]["installed"], false);
    let installed = rows(&catalog, true);
    assert_eq!(installed.len(), 1);
    assert_eq!(installed[0]["app"], "a/two");
    let text = table(&all);
    assert!(text.contains("a/one") && text.contains("available"), "{text}");
    assert!(text.contains("installed, hidden"), "{text}");
}

#[test]
fn meters_parses_alone_and_prints_one_line_per_app() {
    assert_eq!(parse(&words("meters")), Some(Ok(Request::Meters)));
    assert!(matches!(parse(&words("meters acme/x")), Some(Err(_))));
    assert_eq!(meters_table(&json!({"meters": []})), "No extensions are installed.\n");
    let table = meters_table(&json!({"meters": [
        {"app": "local/spy", "step": "paused", "host": "running", "mounts": 2,
         "batches": {"in": 40, "out": 31}, "held": 9, "paused": "over its batch rate"},
        {"app": "a/two", "step": "normal", "host": "none", "mounts": 0,
         "batches": {"in": 0, "out": 0}, "held": 0},
    ]}));
    let lines: Vec<&str> = table.lines().collect();
    assert_eq!(lines.len(), 4, "{table}");
    assert!(lines[1].starts_with("local/spy  paused") && lines[1].ends_with("  9"), "{table}");
    assert!(lines[2].contains("paused: over its batch rate"), "{table}");
    assert!(lines[3].starts_with("a/two"), "{table}");
}
