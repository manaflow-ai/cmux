use serde_json::{Value, json};

use super::super::{AppCommand, parse};
use super::rows;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// A mock engine's `renderers.list`: a browser tab, an agent chat and Home
/// share no renderer; a background browser tab shares the browser tab's
/// renderer; one renderer hosts no page; one is an extension's; one page's
/// renderer has no live helper.
fn report() -> Value {
    json!({
        "interval_ms": 500,
        "pages": [
            {"browser": 1, "url": "https://example.com/a", "title": "Example", "hidden": false,
             "renderer_clients": [7],
             "owner": {"kind": "browser", "tab": "tab_b1", "tab_title": "Example", "pane": "pane_1",
                       "workspace": "ws_1", "workspace_title": "Work", "machine": "local"}},
            {"browser": 2, "url": "cmux-page://cmux.agent/", "title": "", "hidden": false,
             "renderer_clients": [9],
             "owner": {"kind": "agent", "tab": "tab_a1", "tab_title": "Fix the build", "pane": "pane_2",
                       "workspace": "ws_1", "workspace_title": "Work", "session": "s-42", "machine": "local"}},
            {"browser": 3, "url": "cmux-page://cmux.home/", "title": "Home", "hidden": true,
             "renderer_clients": [11], "owner": null},
            {"browser": 4, "url": "https://example.com/b", "title": "Background", "hidden": true,
             "renderer_clients": [7],
             "owner": {"kind": "browser", "tab": "tab_b2", "pane": "pane_1", "workspace": "ws_1"}},
            {"browser": 5, "url": "https://gone.example/", "title": "Gone", "hidden": false,
             "renderer_clients": [99], "owner": null}
        ],
        "helpers": [
            {"pid": 41606, "client": 7, "extension": false, "cpu_percent": 12.5, "memory_bytes": 1000},
            {"pid": 51630, "client": 9, "extension": false, "cpu_percent": 99.8, "memory_bytes": 2000},
            {"pid": 60001, "client": 11, "extension": false, "cpu_percent": 0.0, "memory_bytes": 10},
            {"pid": 60002, "client": 13, "extension": false, "cpu_percent": 1.0, "memory_bytes": 10},
            {"pid": 60003, "client": null, "extension": true, "cpu_percent": 0.5, "memory_bytes": 10}
        ]
    })
}

fn row(out: &Value, pid: i64) -> &Value {
    out["renderers"].as_array().unwrap().iter().find(|row| row["pid"] == pid).unwrap()
}

/// `cmux app renderers` calls the app's `renderers.list`; `--interval-ms`
/// goes as `interval_ms`.
#[test]
fn app_renderers_calls_renderers_list() {
    let command = parse(&args(&["app", "renderers"])).unwrap().unwrap();
    assert_eq!(command, AppCommand::Renderers { params: json!({}) });
    let command = parse(&args(&["app", "renderers", "--interval-ms", "250"])).unwrap().unwrap();
    assert_eq!(command, AppCommand::Renderers { params: json!({"interval_ms": 250}) });
    assert!(parse(&args(&["app", "renderers", "--interval-ms", "soon"])).is_err());
}

/// Each renderer pid names the page it hosts and the tab, pane, workspace and
/// agent session that own it; the busiest renderer comes first.
#[test]
fn renderer_rows_name_the_page_and_owner_of_each_pid() {
    let out = rows(&report());
    let pids: Vec<i64> = out["renderers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["pid"].as_i64().unwrap())
        .collect();
    assert_eq!(pids, vec![51630, 41606, 60002, 60003, 60001]);

    let agent = row(&out, 51630);
    assert_eq!(agent["kind"], "agent-pane");
    assert_eq!(agent["url"], "cmux-page://cmux.agent/");
    assert_eq!(agent["tab"], "tab_a1");
    assert_eq!(agent["tab_title"], "Fix the build");
    assert_eq!(agent["pane"], "pane_2");
    assert_eq!(agent["workspace"], "ws_1");
    assert_eq!(agent["session"], "s-42");
    assert_eq!(agent["visible"], true);
    assert_eq!(agent["cpu_percent"], 99.8);

    // A renderer shared by two tabs names the visible one and lists both.
    let browser = row(&out, 41606);
    assert_eq!(browser["kind"], "browser");
    assert_eq!(browser["url"], "https://example.com/a");
    assert_eq!(browser["tab"], "tab_b1");
    assert_eq!(browser["workspace_title"], "Work");
    let shared: Vec<&str> = browser["pages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|page| page["tab"].as_str().unwrap())
        .collect();
    assert_eq!(shared, vec!["tab_b1", "tab_b2"]);

    // A cmux page no tab owns is named by its page; no page and an extension say so.
    let home = row(&out, 60001);
    assert_eq!(home["kind"], "home");
    assert_eq!(home["visible"], false);
    assert_eq!(home["tab"], Value::Null);
    assert_eq!(row(&out, 60002)["kind"], "no-page");
    assert_eq!(row(&out, 60003)["kind"], "extension");

    // A page whose renderer is gone is listed apart.
    let unmatched = out["unmatched_pages"].as_array().unwrap();
    assert_eq!(unmatched.len(), 1);
    assert_eq!(unmatched[0]["url"], "https://gone.example/");
    assert_eq!(unmatched[0]["kind"], "page");
}

/// An app that reports nothing (no Chromium started) gives no rows, not an error.
#[test]
fn renderer_rows_of_an_empty_report_are_empty() {
    let out = rows(&json!({"interval_ms": 0, "pages": [], "helpers": []}));
    assert_eq!(out["renderers"], json!([]));
    assert_eq!(out["unmatched_pages"], json!([]));
}
