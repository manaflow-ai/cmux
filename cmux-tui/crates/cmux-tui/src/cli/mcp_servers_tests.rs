use super::*;

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

fn no_env(_: &str) -> Option<String> {
    None
}

fn parse_ok(s: &str) -> Verb {
    parse(&words(s), &no_env).unwrap_or_else(|e| panic!("{s}: {e}")).1
}

fn parse_err(s: &str) -> String {
    parse(&words(s), &no_env).err().unwrap_or_else(|| panic!("{s} parsed"))
}

#[test]
fn every_verb_parses_and_a_key_never_comes_from_argv() {
    assert_eq!(parse_ok("catalog"), Verb::Catalog);
    assert_eq!(
        parse_ok("connect linear --owner team --return-to cmux-nightly://settings/connections"),
        Verb::Connect {
            name: "linear".into(),
            owner: Some("team".into()),
            return_to: Some("cmux-nightly://settings/connections".into()),
            key: false
        }
    );
    assert_eq!(
        parse_ok("connect exa --key-stdin"),
        Verb::Connect { name: "exa".into(), owner: None, return_to: None, key: true }
    );
    assert_eq!(parse_ok("remove mcs_1"), Verb::Remove { id: "mcs_1".into() });
    assert_eq!(
        parse_ok("reconnect mcs_1"),
        Verb::Reconnect { id: "mcs_1".into(), return_to: None }
    );
    assert_eq!(parse_ok("enable mcs_1"), Verb::Enable { id: "mcs_1".into() });
    assert!(parse_err("connect exa --key sk_live").contains("stdin"));
    assert!(parse_err("connect exa --owner everyone").contains("me or team"));
    assert!(parse_err("connect exa --return-to https://evil.example/x").contains("cmux link"));
    assert!(parse_err("remove ../../v1/admin").contains("not a connection id"));
    assert!(parse_err("remove a b").contains("unexpected"));
    assert!(parse_err("catalog --owner me").contains("unexpected"));
    assert!(parse_err("dance").contains("unknown verb"));
}

#[test]
fn return_to_follows_the_platform_allowlist() {
    for ok in [
        "cmux://settings/connections",
        "cmux-dev://settings/connections",
        "https://cmux.com/connected",
        "https://app.cmux.com/x",
    ] {
        assert!(valid_return_to(ok), "{ok}");
    }
    for bad in [
        "https://cmux.com.evil.io/",
        "https://.cmux.com/",
        "http://cmux.com/",
        "javascript:alert(1)",
        "cmux://a b",
    ] {
        assert!(!valid_return_to(bad), "{bad}");
    }
}

#[test]
fn requests_name_the_catalog_owner_and_return_link_and_no_key() {
    let (method, path, body) =
        request_of(&parse_ok("connect linear --return-to cmux://settings/connections"));
    assert_eq!((method, path.as_str()), ("POST", "/connect"));
    assert_eq!(
        body.unwrap(),
        json!({"catalog": "linear", "owner": "me", "return_to": "cmux://settings/connections"})
    );
    assert_eq!(request_of(&Verb::Catalog), ("GET", "/catalog".into(), None));
    assert_eq!(request_of(&parse_ok("remove mcs_9")).1, "/mcs_9/remove");
    assert_eq!(request_of(&parse_ok("reconnect mcs_9")).2, Some(json!({})));
}

fn catalog() -> Value {
    json!({"entries": [
        {"name": "sentry", "title": "Sentry", "description": "Errors\nand issues", "url": "https://mcp.sentry.dev/mcp",
         "auth": "dcr", "rank": 3, "category": "dev", "available": true, "connection": null},
        {"name": "linear", "title": "Linear", "description": "Issues and projects.", "auth": "dcr", "rank": 1,
         "available": true, "connection": {"id": "mcs_1", "owner": "team", "status": "ready", "toolCount": 23}},
        {"name": "exa", "title": "Exa", "description": "Web search.", "auth": "key", "rank": 2, "available": true,
         "connection": null},
        {"name": "notion", "title": "Notion", "auth": "client", "rank": 4, "available": false,
         "unavailableReason": "not_configured", "connection": null},
        {"name": "gh", "title": "GitHub", "auth": "dcr", "rank": 5, "available": true,
         "connection": {"id": "mcs_2", "owner": "me", "status": "needs_auth", "toolCount": 1}},
        {"name": "fig", "title": "Figma", "auth": "dcr", "rank": 6, "available": true,
         "connection": {"id": "mcs_3", "owner": "me", "status": "changed", "toolCount": 4}},
        {"name": "../bad", "title": "Bad", "rank": 0}
    ]})
}

#[test]
fn the_catalog_is_shaped_in_rank_order_with_one_button_each() {
    let view = answer(&Verb::Catalog, 200, &catalog());
    assert_eq!(view["ok"], json!(true));
    let entries = view["entries"].as_array().unwrap();
    let names: Vec<_> = entries.iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["linear", "exa", "sentry", "notion", "gh", "fig"]);
    assert_eq!(view["connected"], json!(3));

    let linear = &entries[0];
    assert_eq!(linear["state"], json!("connected"));
    assert_eq!(linear["statusLabel"], json!("Connected · 23 tools"));
    assert_eq!(linear["ownerLabel"], json!("Team"));
    assert_eq!(linear["connectionId"], json!("mcs_1"));

    let exa = &entries[1];
    assert_eq!((exa["state"].clone(), exa["keyField"].clone()), (json!("connect"), json!(true)));
    let sentry = &entries[2];
    assert_eq!(sentry["line"], json!("Errors and issues"));
    assert_eq!(sentry["keyField"], json!(false));
    let notion = &entries[3];
    assert_eq!(notion["state"], json!("unavailable"));
    assert_eq!(notion["statusLabel"], json!("Not set up on this deployment yet."));
    assert_eq!(notion["buttonLabel"], Value::Null);
    let gh = &entries[4];
    assert_eq!(
        (gh["state"].clone(), gh["buttonLabel"].clone()),
        (json!("reconnect"), json!("Reconnect"))
    );
    assert_eq!(gh["toolsLabel"], json!("1 tool"));
    assert_eq!(entries[5]["state"], json!("enable"));
}

#[test]
fn connect_answers_a_sign_in_page_or_connects_at_once() {
    let connect = parse_ok("connect linear");
    let page =
        answer(&connect, 200, &json!({"authorize_url": "https://linear.app/oauth/authorize?x=1"}));
    assert_eq!(page, json!({"ok": true, "authorizeUrl": "https://linear.app/oauth/authorize?x=1"}));
    let plain = answer(&connect, 200, &json!({"authorize_url": "javascript:alert(1)"}));
    assert_eq!(plain["error"]["code"], json!("api.bad_answer"));
    let held = answer(&connect, 201, &json!({"server": {"id": "mcs_4"}, "held": false}));
    assert_eq!(held["connected"], json!(true));
    let refused =
        answer(&connect, 409, &json!({"error": {"code": "mcp_servers.already_connected"}}));
    assert_eq!(refused["error"]["code"], json!("mcp_servers.already_connected"));
    assert_eq!(refused["error"]["message"], json!("That server is already connected."));
}

#[test]
fn a_deployment_without_the_catalog_is_calm() {
    let view = answer(&Verb::Catalog, 404, &json!({}));
    assert_eq!(view["ok"], json!(true));
    assert_eq!(view["available"], json!(false));
}

#[test]
fn slack_and_google_come_through_the_hub_not_the_catalog() {
    let body = json!({"entries": [
        {"name": "slack", "title": "Slack", "auth": "client", "rank": 1, "available": true, "connection": null},
        {"name": "google-drive", "title": "Google Drive", "auth": "client", "rank": 2, "available": true, "connection": null},
        {"name": "gmail", "title": "Gmail", "auth": "client", "rank": 3, "available": true, "connection": null},
        {"name": "google-calendar", "title": "Google Calendar", "auth": "client", "rank": 4, "available": true,
         "connection": {"id": "mcs_7", "owner": "me", "status": "ready", "toolCount": 2}},
        {"name": "linear", "title": "Linear", "auth": "dcr", "rank": 5, "available": true, "connection": null}
    ]});
    let view = answer(&Verb::Catalog, 200, &body);
    let names: Vec<_> =
        view["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["google-calendar", "linear"], "a connected one stays, to be disconnected");
}

/// tests/egress_seeded.json's test for the `cmux_tui::cli::mcp_servers` gate site: the cmux
/// token rides only in `Authorization` and a key-auth server's key only in the body
/// (cmux_egress::capture answers 200 `{}`).
#[tokio::test]
async fn the_seeded_token_and_key_ride_only_in_their_header_and_body() {
    use cmux_egress::capture;
    capture::install().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("token");
    std::fs::write(&file, "SEEDmcpToken-4b7e").unwrap();
    let platform = cmux_cloud_environment::PRODUCTION_PLATFORM.trim_end_matches('/').to_owned();
    let common = Common {
        platform: Some(platform),
        team: Some("SEEDmcpTeam".into()),
        token: TokenSource::File(file),
    };
    let verb = Verb::Connect { name: "linear".into(), owner: None, return_to: None, key: true };
    let _ = run(&common, &verb, Some(Zeroizing::new("SEEDmcpKey-c3d9".to_owned()))).await;

    let places = capture::leaks("SEEDmcpToken-4b7e");
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(": header authorization"), "{places:?}");
    let places = capture::leaks("SEEDmcpKey-c3d9");
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(": body"), "{places:?}");
}
