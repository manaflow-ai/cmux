use serde_json::json;

use super::super::{AppCommand, parse};
use super::{Request, explain_chat_tab, human, masked};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn command(words: &[&str]) -> AppCommand {
    parse(&args(words)).unwrap().unwrap()
}

/// `cmux app chat page --tab <tab> query [SELECTOR] [--style …] [--limit N]` and `… screenshot
/// [--out F]` call the app's read-only `agent.chat.page.*` with the tab and only what was asked.
#[test]
fn app_chat_page_parses_query_and_screenshot() {
    assert_eq!(
        command(&["app", "chat", "page", "--tab", "tab_1", "query"]),
        AppCommand::ChatPage(Request::Query(json!({"tab": "tab_1"})))
    );
    assert_eq!(
        command(&[
            "app",
            "chat",
            "page",
            "--tab",
            "tab_1",
            "query",
            "[data-turn-actions]",
            "--style",
            "opacity, visibility",
            "--style=--accent",
            "--limit",
            "20",
        ]),
        AppCommand::ChatPage(Request::Query(json!({
            "tab": "tab_1", "selector": "[data-turn-actions]",
            "styles": ["opacity", "visibility", "--accent"], "limit": 20,
        })))
    );
    assert_eq!(
        command(&["app", "chat", "page", "screenshot", "--tab=tab_2", "--out", "-"]),
        AppCommand::ChatPage(Request::Screenshot {
            params: json!({"tab": "tab_2"}),
            out: Some("-".into())
        })
    );
    for bad in [
        &["app", "chat", "page", "query"][..],
        &["app", "chat", "page", "--tab", "", "query"],
        &["app", "chat", "page", "--tab", "tab_1"],
        &["app", "chat", "page", "--tab", "tab_1", "eval", "1"],
        &["app", "chat", "page", "--tab", "tab_1", "query", "a", "b"],
        &["app", "chat", "page", "--tab", "tab_1", "query", "--limit", "0"],
        &["app", "chat", "page", "--tab", "tab_1", "query", "--limit", "1001"],
        &["app", "chat", "page", "--tab", "tab_1", "query", "--out", "x.png"],
        &["app", "chat", "page", "--tab", "tab_1", "screenshot", "--limit", "3"],
        &["app", "chat", "page", "--tab", "tab_1", "screenshot", "--focus"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?} should be refused");
    }
}

/// Every string of the answer is masked for secrets before it reaches the caller, whichever member
/// it came in; keys and numbers stay.
#[test]
fn query_answer_is_masked_for_secrets() {
    // A GitHub token's shape, built here so no scanner reads the source as a leak.
    let key = &format!("gh{}_{}", "p", "Ab3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dF3hJ5");
    let answer = json!({
        "tab": "tab_1", "count": 1,
        "elements": [{"tag": "p", "text": format!("my key is {key}"), "label": key,
                      "data": {"value": key}, "style": {"content": key}, "rect": {"x": 1.5}}],
    });
    let out = masked(answer);
    let text = out.to_string();
    assert!(!text.contains(key), "{text}");
    assert!(out["elements"][0]["text"].as_str().unwrap().starts_with("my key is "));
    assert_eq!(out["elements"][0]["rect"]["x"], json!(1.5));
    assert!(out["elements"][0]["data"].get("value").is_some());
}

#[test]
fn human_prints_one_line_per_element() {
    let answer = json!({
        "tab": "tab_1", "count": 3,
        "elements": [
            {"tag": "div", "classes": ["turn", "user"], "data": {"turn": "u1"}, "text": "hello\n  there",
             "visible": true, "style": {"opacity": "0"}},
            {"tag": "button", "classes": [], "role": "button", "label": "Copy", "text": "", "visible": false},
        ],
    });
    let english = crate::localization::catalog_for_locale("en_US.UTF-8");
    let out = human(&answer, &english.app_control.chat_page);
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines[0], "Chat tab_1: 2 of 3 elements");
    assert_eq!(lines[1], r#"div.turn.user data-turn=u1 "hello there" {opacity: 0}"#);
    assert_eq!(lines[2], r#"button (offscreen) role=button label="Copy""#);
}

/// `cmux browser <tab> …` on a chat tab names `cmux app chat page`; other refusals are untouched.
#[test]
fn browser_refusal_of_a_chat_tab_names_chat_page() {
    let mut error = json!({"code": "invalid_params", "message": "Tab tab_9 is not a browser tab of this app",
                           "data": {"tab": "tab_9", "kind": "conversation"}});
    explain_chat_tab("browser.page.eval", &mut error);
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("cmux app chat page --tab tab_9 query"), "{message}");
    let mut other = json!({"code": "invalid_params", "message": "m", "data": {"tab": "tab_9", "kind": "terminal"}});
    explain_chat_tab("browser.page.eval", &mut other);
    assert_eq!(other["message"], "m");
    let mut elsewhere = json!({"code": "invalid_params", "message": "m", "data": {"tab": "tab_9", "kind": "conversation"}});
    explain_chat_tab("tab.close", &mut elsewhere);
    assert_eq!(elsewhere["message"], "m");
}
