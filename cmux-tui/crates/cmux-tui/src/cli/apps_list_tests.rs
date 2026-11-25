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
    assert_eq!(
        parse(&words("update github.com/acme/x")),
        Some(Ok(Request::Update { app: "github.com/acme/x".into() }))
    );
    assert!(matches!(parse(&words("update")), Some(Err(_))));
    assert_eq!(
        install_args(&words("--json apps update acme/x"), "github.com/acme/x@dev"),
        words("--json apps install github.com/acme/x@dev")
    );
    assert_eq!(parse(&words("run acme/x op")), None, "run is apps_run");
}

#[test]
fn info_names_a_git_apps_source_and_review_state() {
    let detail = json!({"app": "acme/x", "name": "X", "version": "1.2.0", "summary": "s", "tier": "unverified",
        "repository": "https://github.com/acme/tools", "path": "apps/x", "tag": "1.2.0",
        "commit": "0123456789abcdef0123456789abcdef01234567", "reviewed": false, "scopes": []});
    let text = info_text(&detail);
    assert!(text.contains("source: github.com/acme/tools/apps/x at 1.2.0 (0123456)"), "{text}");
    assert!(text.contains("not reviewed by cmux"), "{text}");
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
