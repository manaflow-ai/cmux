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
