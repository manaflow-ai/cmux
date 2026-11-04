//! `cmux browser right <verb>` (user, 2026-10-20): every Chief, local or
//! cloud, drives the browser in the column right of the Home chat by one
//! name. The CLI asks the app which tab that is (`browser.page.right`, which
//! may open the agent's own tab there), then runs the verb on that tab.

use serde_json::json;

use super::super::{parse, run};
use super::{args, fake_app, global_for};

#[test]
fn a_verb_on_right_resolves_the_tab_then_runs_on_it() {
    let resolved = json!({ "id": 1, "ok": true, "result": { "tab": "tab_r1", "pane": "pane_r", "created": false, "navigated": false } });
    let clicked = json!({ "id": 2, "ok": true, "result": { "tab": "tab_r1", "value": true } });
    let (socket, app) = fake_app(vec![resolved, clicked]);
    let command =
        parse(&args(&["browser", "right", "click", "#go", "--agent", "Chief"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [first, second] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(first["method"], "browser.page.right");
    assert_eq!(first["params"]["agent"], "Chief");
    assert!(first["params"].get("url").is_none(), "only navigate sends a URL");
    assert_eq!(second["method"], "browser.page.click");
    assert_eq!(second["params"]["tab"], "tab_r1");
    assert_eq!(second["params"]["selector"], "#go");
    assert_eq!(second["params"]["agent"], "Chief");
}

#[test]
fn navigate_on_right_sends_the_url_and_skips_a_second_load_of_a_new_tab() {
    let opened = json!({ "id": 1, "ok": true, "result": { "tab": "tab_new", "created": true, "navigated": true } });
    let (socket, app) = fake_app(vec![opened]);
    let command = parse(&args(&[
        "browser",
        "right",
        "navigate",
        "https://cmux.com",
        "--agent",
        "Cloud Chief",
    ]))
    .unwrap()
    .unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [only] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(only["method"], "browser.page.right");
    assert_eq!(only["params"]["url"], "https://cmux.com");
    assert_eq!(only["params"]["agent"], "Cloud Chief");
}

#[test]
fn navigate_on_an_own_tab_loads_the_url_there() {
    let own = json!({ "id": 1, "ok": true, "result": { "tab": "tab_own", "created": false, "navigated": false } });
    let loaded = json!({ "id": 2, "ok": true, "result": { "tab": "tab_own" } });
    let (socket, app) = fake_app(vec![own, loaded]);
    let command = parse(&args(&[
        "browser",
        "right",
        "navigate",
        "https://cmux.com/docs",
        "--agent",
        "Chief",
    ]))
    .unwrap()
    .unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [_, second] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(second["method"], "browser.page.navigate");
    assert_eq!(second["params"]["tab"], "tab_own");
    assert_eq!(second["params"]["url"], "https://cmux.com/docs");
}

#[test]
fn a_held_tab_is_reported_and_no_verb_runs() {
    let held = json!({ "id": 1, "ok": false, "error": { "code": "lease_held", "message": "Chief drives this tab", "data": { "holder": "Chief" } } });
    let (socket, app) = fake_app(vec![held]);
    let command = parse(&args(&["browser", "right", "click", "#go", "--agent", "Cloud Chief"]))
        .unwrap()
        .unwrap();
    assert_eq!(run(&global_for(&socket), command), 1);
    let connections = app.join().unwrap();
    assert_eq!(connections[0].len(), 1, "{connections:?}");
}

#[test]
fn release_gives_the_agents_tabs_back() {
    let released = json!({ "id": 1, "ok": true, "result": { "released": ["tab_r1"] } });
    let (socket, app) = fake_app(vec![released]);
    let command =
        parse(&args(&["browser", "right", "release", "--agent", "Chief"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [only] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(only["method"], "browser.page.right");
    assert_eq!(only["params"]["agent"], "Chief");
    assert_eq!(only["params"]["release"], true);
}

/// The app lets only reads run on the person's shown tab, so the CLI names the
/// verb it will run (plans/cmux-next/agent-browser-passkey-DESIGN.md).
#[test]
fn right_names_the_verb_so_the_app_can_keep_writes_off_the_persons_tab() {
    let resolved = json!({ "id": 1, "ok": true, "result": { "tab": "tab_r1", "created": false, "navigated": false } });
    let snap = json!({ "id": 2, "ok": true, "result": { "tab": "tab_r1" } });
    let (socket, app) = fake_app(vec![resolved, snap]);
    let command =
        parse(&args(&["browser", "right", "snapshot", "--agent", "Chief"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let first = &connections[0][0];
    assert_eq!(first["params"]["verb"], "browser.page.snapshot");
    assert!(first["params"].get("take").is_none(), "no takeover unless asked");
}

#[test]
fn take_hands_the_persons_tab_over_only_when_given() {
    let resolved = json!({ "id": 1, "ok": true, "result": { "tab": "tab_user", "created": false, "navigated": false } });
    let clicked = json!({ "id": 2, "ok": true, "result": { "tab": "tab_user" } });
    let (socket, app) = fake_app(vec![resolved, clicked]);
    let command = parse(&args(&["browser", "right", "click", "#go", "--take", "--agent", "Chief"]))
        .unwrap()
        .unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [first, second] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(first["params"]["verb"], "browser.page.click");
    assert_eq!(first["params"]["take"], true);
    assert_eq!(second["method"], "browser.page.click");
    assert!(second["params"].get("take").is_none());
}

#[test]
fn passkey_on_right_asks_the_app_to_hand_the_ceremony_to_the_person() {
    let resolved = json!({ "id": 1, "ok": true, "result": { "tab": "tab_own", "created": false, "navigated": false } });
    let asked = json!({ "id": 2, "ok": true, "result": { "tab": "tab_own", "request": "r1", "status": "pending" } });
    let (socket, app) = fake_app(vec![resolved, asked]);
    let command =
        parse(&args(&["browser", "right", "passkey", "e11", "--agent", "Chief"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [first, second] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(first["params"]["verb"], "browser.page.passkey");
    assert_eq!(second["method"], "browser.page.passkey");
    assert_eq!(second["params"]["selector"], "e11");
    assert_eq!(second["params"]["tab"], "tab_own");
    assert_eq!(second["params"]["agent"], "Chief");
}

/// cmux https://github.com/manaflow-ai/cmux/issues/25830: `right fill-login` is a write verb (the
/// agent's own tab), and the fill runs on the tab the app named.
#[test]
fn fill_login_on_right_runs_on_the_agents_own_tab() {
    let resolved = json!({ "id": 1, "ok": true, "result": { "tab": "tab_own", "created": false, "navigated": false } });
    let filled = json!({ "id": 2, "ok": true, "result": { "tab": "tab_own", "filled": true, "site": "example.com" } });
    let (socket, app) = fake_app(vec![resolved, filled]);
    let command = parse(&args(&["browser", "right", "fill-login", "--submit", "--agent", "Chief"]))
        .unwrap()
        .unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [first, second] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(first["method"], "browser.page.right");
    assert_eq!(first["params"]["verb"], "browser.page.fill_login");
    assert_eq!(second["method"], "browser.page.fill_login");
    assert_eq!(second["params"]["tab"], "tab_own");
    assert_eq!(second["params"]["submit"], true);
    assert_eq!(second["params"]["agent"], "Chief");
}
