use super::*;

const OWN_WS: &str = "ws_11111111111111111111111111111111";
const OWN_SCREEN: &str = "screen_22222222222222222222222222222222";
const OWN_PANE: &str = "pane_33333333333333333333333333333333";
const OTHER_PANE: &str = "pane_44444444444444444444444444444444";

const FRONT_WS: &str = "ws_77777777777777777777777777777777";
const FRONT_PANE: &str = "pane_88888888888888888888888888888888";

/// A chat the app places: its workspace, screen, pane and tab. The person
/// looks at another workspace.
fn placed() -> Fake {
    Fake {
        focus: Some(json!({"window": "win_a", "workspace": FRONT_WS, "pane": FRONT_PANE})),
        caller: Some(json!({
            "agent_session": "01a17599",
            "workspace": OWN_WS,
            "screen": OWN_SCREEN,
            "pane": OWN_PANE,
            "tab": "tab_55555555555555555555555555555555",
        })),
        ..Fake::default()
    }
}

fn sent_params(server: &Server<Fake>) -> Value {
    server.backend.last("resource")["request"]["params"].clone()
}

/// The repro: the person looks at another workspace while the agent's
/// script splits `current`. The split lands beside the chat.
#[test]
fn current_is_the_callers_own_place_not_the_focused_one() {
    let mut server = code_mode_server(placed());
    let result = call(
        &mut server,
        "cmux_exec",
        json!({"script": "return await cmux.pane_split({workspace: 'current', pane: 'current', direction: 'right'});"}),
    );
    assert_ne!(result["isError"], true, "{result}");
    let params = sent_params(&server);
    assert_eq!(params["workspace"], OWN_WS);
    assert_eq!(params["pane"], OWN_PANE);
}

#[test]
fn every_level_of_a_current_chain_is_the_callers() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "screen_layout_export", json!({"workspace": "current", "screen": "current"}));
    let params = sent_params(&server);
    assert_eq!(params["workspace"], OWN_WS);
    assert_eq!(params["screen"], OWN_SCREEN);
}

/// `focused` is what the app shows, not the daemon's active workspace,
/// which can differ from it.
#[test]
fn focused_is_what_the_app_shows() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "pane_list", json!({"workspace": "focused"}));
    assert_eq!(sent_params(&server)["workspace"], FRONT_WS);
    // `focused` alone needs no caller lookup.
    assert!(server.backend.sent.borrow().iter().all(|sent| sent["kind"] != "caller"));

    // The app's focus names no screen: the focused workspace's active one.
    call(
        &mut server,
        "pane_split",
        json!({"workspace": "focused", "screen": "focused", "pane": "current", "direction": "right"}),
    );
    let params = sent_params(&server);
    assert_eq!(params["workspace"], FRONT_WS);
    assert_eq!(params["screen"], "current");
    assert_eq!(params["pane"], "current");
}

/// An app that cannot report its focus leaves the daemon's `current`.
#[test]
fn focused_without_an_app_focus_is_the_daemons_current() {
    let mut server = Server::new(Fake { focus: None, ..placed() }, None);
    call(&mut server, "pane_list", json!({"workspace": "focused"}));
    assert_eq!(sent_params(&server)["workspace"], "current");
}

/// Below another object, `current` is that object's active child, as the
/// daemon has always read it.
#[test]
fn current_under_another_object_keeps_the_daemons_meaning() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "pane_split", json!({"pane": OTHER_PANE, "direction": "down"}));
    assert_eq!(sent_params(&server)["pane"], OTHER_PANE);

    let other_ws = "ws_66666666666666666666666666666666";
    call(&mut server, "screen_layout_export", json!({"workspace": other_ws, "screen": "current"}));
    let params = sent_params(&server);
    assert_eq!(params["workspace"], other_ws);
    assert_eq!(params["screen"], "current");

    call(&mut server, "pane_list", json!({"workspace": "focused", "screen": "current"}));
    let params = sent_params(&server);
    assert_eq!(params["workspace"], FRONT_WS);
    assert_eq!(params["screen"], "current");
}

/// Naming the caller's own workspace by id keeps the chain the caller's.
#[test]
fn current_under_the_callers_own_id_is_still_the_callers() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "screen_layout_export", json!({"workspace": OWN_WS, "screen": "current"}));
    assert_eq!(sent_params(&server)["screen"], OWN_SCREEN);
}

/// A unique prefix of the caller's own workspace is still the caller's.
#[test]
fn current_under_a_prefix_of_the_callers_own_id_is_still_the_callers() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "screen_layout_export", json!({"workspace": "ws_1111", "screen": "current"}));
    assert_eq!(sent_params(&server)["screen"], OWN_SCREEN);
}

/// A client with no caller identity (Claude Code in a plain terminal) keeps
/// the daemon's `current`.
#[test]
fn no_caller_identity_keeps_the_daemons_current() {
    let mut server = Server::new(Fake::default(), None);
    call(&mut server, "pane_list", json!({"workspace": "current"}));
    assert_eq!(sent_params(&server)["workspace"], "current");
}

/// A chat the app cannot place fails closed rather than act on whatever
/// workspace is in front.
#[test]
fn an_unplaced_caller_fails_closed() {
    let mut server = Server::new(Fake { caller: Some(Value::Null), ..Fake::default() }, None);
    let result = call(&mut server, "pane_list", json!({"workspace": "current"}));
    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["error"]["code"], "caller.unresolved");
    assert!(server.backend.sent.borrow().iter().all(|sent| sent["kind"] != "resource"));
}

/// The app answers an agent session it has no chat for with `found: false`
/// and no ids (seen live, 2026-10-25): that fails closed too.
#[test]
fn a_caller_the_app_does_not_find_fails_closed() {
    let caller = json!({"agent_session": "01a17599", "found": false, "is_caller": true, "terminal_id": null});
    let mut server = Server::new(Fake { caller: Some(caller), ..Fake::default() }, None);
    let result = call(&mut server, "pane_list", json!({"workspace": "current"}));
    assert_eq!(result["isError"], true);
    assert_eq!(result["structuredContent"]["error"]["code"], "caller.unresolved");
    assert!(server.backend.sent.borrow().iter().all(|sent| sent["kind"] != "resource"));
}

/// Another session has no caller in it: `current` there is the daemon's.
#[test]
fn another_session_is_not_resolved_against_the_caller() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "pane_list", json!({"workspace": "current", "session": "other"}));
    assert_eq!(sent_params(&server)["workspace"], "current");
}

const RIGHT_PANE: &str = "pane_99999999999999999999999999999999";

fn sent_resources(server: &Server<Fake>) -> Vec<Value> {
    server.backend.sent.borrow().iter().filter(|sent| sent["kind"] == "resource").cloned().collect()
}

/// The repro: an agent asked to open a terminal "to the right" named no
/// pane, and the terminal opened in Home. It goes to the column right of
/// the agent's own chat.
#[test]
fn a_terminal_with_no_place_opens_in_the_column_right_of_the_chat() {
    let fake =
        Fake { beside: json!({"pane": RIGHT_PANE, "placement": "existing_column"}), ..placed() };
    let mut server = Server::new(fake, None);
    let result = call(
        &mut server,
        "tab_create_terminal",
        json!({"shell": "cmux chief", "name": "Chief TUI"}),
    );
    assert_ne!(result["isError"], true, "{result}");
    let sent = sent_resources(&server);
    assert_eq!(sent.len(), 1);
    let request = &sent[0]["request"];
    assert_eq!(request["operation"], "tab.create_terminal");
    assert_eq!(request["params"]["workspace"], OWN_WS);
    assert_eq!(request["params"]["pane"], RIGHT_PANE);
    assert_eq!(request["params"]["name"], "Chief TUI");
}

/// With no column right of the chat, a split right of the chat makes one,
/// running the command, and the new tab gets the asked name.
#[test]
fn a_terminal_with_no_place_and_no_column_makes_one_beside_the_chat() {
    let fake = Fake {
        beside: json!({"pane": null, "placement": "new_column"}),
        resource_result: Some(json!({"tab_id": "tab_new", "pane_id": "pane_new"})),
        ..placed()
    };
    let mut server = Server::new(fake, None);
    let result = call(
        &mut server,
        "tab_create_terminal",
        json!({"shell": "cmux chief", "name": "Chief TUI", "idempotency_key": "k1"}),
    );
    assert_ne!(result["isError"], true, "{result}");
    let sent = sent_resources(&server);
    let ops = sent.iter().map(|s| s["request"]["operation"].clone()).collect::<Vec<_>>();
    assert_eq!(ops, vec![json!("pane.split"), json!("tab.rename")]);
    let split = &sent[0]["request"];
    assert_eq!(split["params"]["workspace"], OWN_WS);
    assert_eq!(split["params"]["pane"], OWN_PANE);
    assert_eq!(split["params"]["direction"], "right");
    assert_eq!(split["params"]["shell"], "cmux chief");
    assert_eq!(split["idempotency_key"], "k1-beside");
    let rename = &sent[1]["request"];
    assert_eq!(rename["params"]["tab"], "tab_new");
    assert_eq!(rename["params"]["name"], "Chief TUI");
    assert_eq!(rename["idempotency_key"], "k1-name");
}

/// A link with no workspace opened in Home. An agent's link goes to the
/// app's `browser.open_split`, whose beside_caller rule places it right of
/// the chat, and never to the daemon's Home default.
#[test]
fn a_link_with_no_workspace_opens_beside_the_chat_through_the_app() {
    let mut server = Server::new(placed(), None);
    let result = call(
        &mut server,
        "workspace_open_url",
        json!({"url": "https://example.com", "idempotency_key": "u1"}),
    );
    assert_ne!(result["isError"], true, "{result}");
    assert!(sent_resources(&server).is_empty(), "the daemon got the link");
    let app = server.backend.last("app");
    assert_eq!(app["method"], "browser.open_split");
    assert_eq!(app["params"]["url"], "https://example.com");
    assert_eq!(app["params"]["focus"], false);
    assert_eq!(app["key"], "u1");
}

/// A named place, another session, or a client the app does not place
/// keeps what it asked for.
#[test]
fn a_named_place_or_an_unplaced_client_keeps_its_target() {
    let mut server = Server::new(placed(), None);
    call(&mut server, "tab_create_terminal", json!({"pane": OTHER_PANE}));
    assert_eq!(sent_params(&server)["pane"], OTHER_PANE);

    let mut server = Server::new(Fake::default(), None);
    call(&mut server, "tab_create_terminal", json!({"shell": "true"}));
    assert!(sent_params(&server).get("pane").is_none());

    let mut server = Server::new(Fake::default(), None);
    call(&mut server, "workspace_open_url", json!({"url": "https://example.com"}));
    assert!(sent_params(&server).get("workspace").is_none());
}
