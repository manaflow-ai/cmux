//! The three sample apps render in the native host (`samples/apps/*/dist/main.js`).

mod common;

use cmux_app_host::Limits;
use common::{Harness, sample};
use serde_json::{Value, json};

fn agents() -> Value {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock")
        .as_millis()
        .to_string();
    json!([
        { "id": "agent_1", "session_id": "s", "terminal_id": "term_1", "state": "working", "source": "hook", "updated_at_ms": now, "source_session": "agent-a" },
        { "id": "agent_2", "session_id": "s", "terminal_id": "term_2", "state": "blocked", "source": "hook", "updated_at_ms": now, "source_session": "agent-b" }
    ])
}

#[test]
fn running_agents_groups_agents_and_focuses_the_tab_on_tap() {
    let init = json!({ "app": { "id": "cmux/running-agents", "version": "1.0.0" }, "settings": { "showIdle": true } });
    let mut h = Harness::with(&sample("running-agents"), init, Limits::default());
    h.handle("agent.list", |_, _| (true, json!({ "value": agents() })));
    h.handle("terminal.get", |p, _| {
        (true, json!({ "value": { "id": p["terminal"], "tab_id": "tab_9" } }))
    });
    h.handle("tab.focus", |_, _| (true, json!({ "value": null })));
    assert_eq!(
        h.mount(
            "m",
            "renderAgents",
            json!({ "contribution": "cmux/running-agents#agents", "surface": "sidebarSection" })
        ),
        None
    );
    let texts = h.texts("m");
    for want in ["Waiting for you", "Working", "agent-a", "agent-b"] {
        assert!(texts.iter().any(|t| t == want), "{want} missing from {texts:?}");
    }
    let row = h
        .find("m", |n| n.kind == "Row" && n.props.get("title") == Some(&json!("agent-b")))
        .expect("row");
    h.dispatch("m", &row, "tap", json!({ "gesture": "g7" }));
    let focus = h.calls.iter().find(|c| c.name == "tab.focus").expect("tab.focus");
    assert_eq!(
        (focus.params.clone(), focus.options["gesture"].clone()),
        (json!({ "tab": "tab_9" }), json!("g7"))
    );
}

#[test]
fn agent_status_summarizes() {
    let mut h = Harness::new(&sample("agent-status"));
    h.handle("agent.list", |_, _| (true, json!({ "value": agents() })));
    assert_eq!(h.mount("m", "renderStatus", json!({})), None);
    assert!(h.texts("m").iter().any(|t| t == "1 working · 1 waiting"), "{:?}", h.texts("m"));
}

#[test]
fn github_prs_loads_through_net_fetch_and_opens_a_row() {
    let init = json!({ "app": { "id": "cmux/github-prs", "version": "1.0.0" }, "settings": { "login": "octo" } });
    let mut h = Harness::with(&sample("github-prs"), init, Limits::default());
    h.handle("integration.request", |_, _| {
        (false, json!({ "code": "scope.missing", "message": "no integration" }))
    });
    let body = json!({ "items": [{ "id": 1, "number": 42, "title": "Add App Store", "html_url": "https://github.com/manaflow-ai/cmux/pull/42", "draft": false, "repository_url": "https://api.github.com/repos/manaflow-ai/cmux", "updated_at": "" }] });
    h.handle("net.fetch", move |_, _| {
        (true, json!({ "value": { "status": 200, "body": body.to_string() } }))
    });
    h.handle("action.run", |_, _| (true, json!({ "value": null })));
    assert_eq!(h.mount("m", "renderPRs", json!({})), None);
    assert!(h.texts("m").iter().any(|t| t == "Add App Store"), "{:?}", h.texts("m"));
    let row = h.find("m", |n| n.kind == "Row").expect("row");
    h.dispatch("m", &row, "tap", json!({}));
    let open = h.calls.iter().find(|c| c.name == "action.run").expect("action.run");
    assert_eq!(
        open.params,
        json!({ "id": "openBrowser", "args": { "url": "https://github.com/manaflow-ai/cmux/pull/42" } })
    );
}
