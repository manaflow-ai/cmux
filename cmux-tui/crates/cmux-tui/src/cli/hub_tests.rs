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
fn hub_parses_every_verb() {
    assert_eq!(parse_ok("connections"), Verb::Connections);
    assert_eq!(parse_ok("overview"), Verb::Overview { audit_limit: 20 });
    assert_eq!(
        parse_ok("link stripe --sharing team"),
        Verb::Link { provider: "stripe".into(), sharing: Some("team".into()), policy: None }
    );
    assert_eq!(
        parse_ok("link github"),
        Verb::Link { provider: "github".into(), sharing: None, policy: None }
    );
    assert_eq!(parse_ok("remove hubc_0123abcd"), Verb::Remove { id: "hubc_0123abcd".into() });
    assert_eq!(parse_ok("actions"), Verb::Actions);
    assert_eq!(
        parse_ok(
            r#"call stripe.refund.create --args {"charge":"ch_1"} --invocation-id inv-12345678"#
        ),
        Verb::Call {
            action: "stripe.refund.create".into(),
            args: Some(json!({"charge": "ch_1"})),
            connection: None,
            invocation_id: Some("inv-12345678".into()),
        }
    );
    assert_eq!(parse_ok("status hcall_abc"), Verb::Status { id: "hcall_abc".into() });
    assert_eq!(parse_ok("approvals"), Verb::Approvals);
    assert_eq!(parse_ok("policy"), Verb::Policy);
    assert_eq!(parse_ok("rule remove hubr_9"), Verb::RuleRemove { id: "hubr_9".into() });
    assert_eq!(parse_ok("pause"), Verb::Pause { paused: true });
    assert_eq!(parse_ok("resume"), Verb::Pause { paused: false });
    assert_eq!(
        parse_ok("audit --limit 5 --before 40"),
        Verb::Audit { limit: Some(5), before: Some(40) }
    );
    assert_eq!(parse_ok("audit"), Verb::Audit { limit: None, before: None });
}

#[test]
fn hub_refuses_a_key_in_argv_and_bad_arguments() {
    assert!(parse_err("link stripe --key rk_test_abc").contains("never from an argument"));
    assert!(parse_err("link stripe --key=rk_test_abc").contains("never from an argument"));
    assert!(parse_err("link slack").contains("link stripe or github"));
    assert!(parse_err("link github --policy ask").contains("--policy is for Stripe"));
    assert!(parse_err("remove ../etc").contains("not a connection id"));
    assert!(parse_err("remove hubc_a/b").contains("not a connection id"));
    // A person answers an approval in Settings; the CLI has no verb for it (a lane holds the person's token).
    for words in ["approve apr_1", "approve apr_1 --remember", "deny apr_1", "answer apr_1"] {
        assert!(parse_err(words).contains("Settings > Integrations"), "{words}");
    }
    assert!(parse_err("call stripe.* ").contains("not an action"));
    assert!(parse_err("call stripe.refund.create --args [1]").contains("JSON object"));
    assert!(parse_err("call stripe.refund.create --invocation-id abc").contains("8 to 128"));
    assert!(parse_err("audit --limit 0").contains("1 to 200"));
    assert!(parse_err("audit --limit 201").contains("1 to 200"));
    assert!(parse_err("audit --before 0").contains("seq"));
    assert!(parse_err("approvals --remember").contains("unexpected"));
    assert!(parse_err("connections extra").contains("unexpected"));
    assert!(parse_err("frobnicate").contains("unknown verb"));
    assert!(parse_err("rule").contains("rule add"));
}

#[test]
fn hub_common_flags_and_origin() {
    let env = |k: &str| (k == "CMUX_CLOUD_ACCESS_TOKEN").then(|| "t".to_owned());
    let (common, _) = parse(&words("connections --team acme"), &env).unwrap();
    assert_eq!(common.team.as_deref(), Some("acme"));
    assert_eq!(common.token, TokenSource::Env);
    assert_eq!(common.platform, None);
    let (common, _) = parse(&words("connections"), &no_env).unwrap();
    assert_eq!(common.token, TokenSource::App);
    let (common, _) = parse(
        &words("connections --platform https://cmux-platform-development.debussy.workers.dev/"),
        &no_env,
    )
    .unwrap();
    assert_eq!(
        common.platform.as_deref(),
        Some("https://cmux-platform-development.debussy.workers.dev")
    );
    assert!(parse(&words("connections --platform http://example.com"), &no_env).is_err());
}

#[test]
fn hub_platform_follows_the_tokens_deployment() {
    use cmux_cloud_environment as env;
    let dev = env::DEVELOPMENT_DEPLOYMENT;
    assert_eq!(
        platform_for(None, Some(dev.api_origin)).unwrap(),
        dev.platform_origin.trim_end_matches('/')
    );
    assert_eq!(platform_for(None, None).unwrap(), env::PRODUCTION_PLATFORM.trim_end_matches('/'));
    assert_eq!(
        platform_for(Some("https://p.example"), Some(dev.api_origin)).unwrap(),
        "https://p.example"
    );
    assert!(platform_for(None, Some("https://unknown.example")).is_err());
}

#[test]
fn hub_builds_requests() {
    let r = request_of(&parse_ok(
        r#"call stripe.refund.create --args {"charge":"ch_1","amount":1200} --connection hubc_1"#,
    ));
    assert_eq!(r.method, "POST");
    assert_eq!(r.path, "/calls");
    assert_eq!(
        r.body,
        Some(
            json!({"action": "stripe.refund.create", "args": {"charge": "ch_1", "amount": 1200}, "connection": "hubc_1"})
        )
    );
    let r = request_of(&parse_ok("remove hubc_1"));
    assert_eq!(r.path, "/connections/hubc_1/remove");
    let r = request_of(&parse_ok("rule remove hubr_1"));
    assert_eq!(r.path, "/policy/rules/hubr_1/remove");
    let r = request_of(&parse_ok("pause"));
    assert_eq!((r.path.as_str(), r.body), ("/policy/pause", Some(json!({"paused": true}))));
    let r = request_of(&parse_ok("status hcall_1"));
    assert_eq!((r.method, r.path.as_str(), r.body), ("GET", "/calls/hcall_1", None));
    let r = request_of(&parse_ok("audit --limit 5 --before 40"));
    assert_eq!(
        url_of("https://p", &r, Some("acme team")),
        "https://p/v1/hub/audit?before=40&limit=5&team=acme%20team"
    );
    let r = request_of(&parse_ok("link stripe"));
    assert_eq!((r.method, r.path.as_str(), r.body), ("POST", "/connections", None));
    let r = request_of(&parse_ok("link github --sharing team"));
    assert_eq!((r.method, r.path.as_str(), r.body), ("POST", "/connections", None));
    let paths: Vec<String> =
        overview_requests(7).iter().map(|r| url_of("https://p", r, None)).collect();
    assert_eq!(
        paths,
        [
            "https://p/v1/hub/connections",
            "https://p/v1/hub/approvals",
            "https://p/v1/hub/policy",
            "https://p/v1/hub/audit?limit=7"
        ]
    );
}

#[test]
fn hub_rule_add_body() {
    let verb = parse_ok(
        "rule add --owner team --action stripe.refund.create --effect allow --amount-lte 5000 --currency USD \
         --agent ci --limit-window day --limit-amount 20000 --expires-at 1800000000000",
    );
    let Verb::RuleAdd { rule } = verb else { panic!("not a rule add") };
    assert_eq!(
        rule,
        json!({
            "owner": "team", "action": "stripe.refund.create", "effect": "allow", "agent": "ci",
            "when": {"amountLte": 5000, "currency": "usd"},
            "limit": {"window": "day", "amount": 20000, "over": "ask"},
            "expiresAt": 1_800_000_000_000u64,
        })
    );
    let Verb::RuleAdd { rule } = parse_ok("rule add --action stripe.* --effect block") else {
        panic!()
    };
    assert_eq!(rule, json!({"owner": "user", "action": "stripe.*", "effect": "block"}));
    assert!(parse_err("rule add --effect allow").contains("--action"));
    assert!(parse_err("rule add --action stripe.refund.create").contains("--effect"));
    assert!(parse_err("rule add --action Stripe.Refund --effect ask").contains("not an action"));
    assert!(parse_err("rule add --action * --effect maybe").contains("allow or ask or block"));
    assert!(
        parse_err("rule add --action * --effect ask --limit-amount 5").contains("--limit-window")
    );
    assert!(
        parse_err("rule add --action * --effect ask --limit-window day").contains("--limit-amount")
    );
    assert!(
        parse_err("rule add --action * --effect ask --currency dollars").contains("three-letter")
    );
    assert!(parse_err("rule add --action * --effect ask --amount-lte -1").contains("whole number"));
}

#[test]
fn hub_link_body_and_key_checks() {
    let body = link_body("stripe", Some("rk_test_abc123"), Some("team"), Some("ask"));
    let v: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(
        v,
        json!({"provider": "stripe", "key": "rk_test_abc123", "sharing": "team", "policy": "ask"})
    );
    let body = link_body("github", None, None, None);
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap(), json!({"provider": "github"}));
    // A live key goes to the hub, which answers `stripe.live_not_yet` in its own words (the card shows it as is).
    assert_eq!(restricted_key("  rk_live_ABC123\n").unwrap().as_str(), "rk_live_ABC123");
    let refused = restricted_key("sk_live_ABC").unwrap_err();
    assert_eq!(refused["error"]["code"], "stripe.key_refused");
    assert!(!refused.to_string().contains("sk_live_ABC"), "the key is never echoed");
    let refused = restricted_key("pk_test_x").unwrap_err();
    assert_eq!(refused["error"]["code"], "stripe.key_refused");
    assert!(!refused.to_string().contains("pk_test_x"));
    assert_eq!(restricted_key("").unwrap_err()["error"]["code"], "cli.invalid_args");
    assert!(restricted_key("rk_test_a b").is_err());
}

#[test]
fn hub_maps_errors() {
    let e = hub_error(404, &json!({"error": {"code": "hub.not_found", "message": "Not found"}}));
    assert_eq!(e["ok"], false);
    assert_eq!(e["available"], false);
    assert_eq!(e["error"]["code"], "hub.not_found");
    let e = hub_error(
        400,
        &json!({"error": {"code": "stripe.key_permission", "message": "needs Refunds: write\u{7}"}}),
    );
    assert_eq!(e["error"]["code"], "stripe.key_permission");
    assert_eq!(e["error"]["message"], "needs Refunds: write");
    assert_eq!(e["status"], 400);
    assert!(e.get("available").is_none());
    let e = hub_error(502, &json!("gateway"));
    assert_eq!(e["error"]["code"], "api.bad_answer");
    assert!(e["error"]["message"].as_str().unwrap().contains("502"));
    let long = "x".repeat(1000);
    let e = hub_error(400, &json!({"error": {"code": "hub.invalid", "message": long}}));
    assert_eq!(e["error"]["message"].as_str().unwrap().len(), 300);
    let gone = hub_error(
        409,
        &json!({"error": {"code": "approval.gone", "message": "answered"}, "call": {"id": "hcall_1", "status": "denied", "summary": "Refund"}}),
    );
    assert_eq!(gone["call"]["statusLabel"], "Denied");
    let a = answer(&Verb::Connections, 200, &json!("not an object"));
    assert_eq!(a["ok"], false);
}

#[test]
fn hub_formats_money() {
    assert_eq!(format_money(1200, "usd"), "12.00 USD");
    assert_eq!(format_money(5, "eur"), "0.05 EUR");
    assert_eq!(format_money(123_456_789, "usd"), "1,234,567.89 USD");
    assert_eq!(format_money(500, "jpy"), "500 JPY");
    assert_eq!(format_money(1_000_000, "krw"), "1,000,000 KRW");
    assert_eq!(format_money(1234, "kwd"), "1.234 KWD");
    assert_eq!(format_money(-250, "usd"), "-2.50 USD");
    assert_eq!(format_money(0, "usd"), "0.00 USD");
}

#[test]
fn hub_shapes_connections() {
    let c = connection_view(&json!({
        "id": "hubc_1", "provider": "stripe", "account": "Acme Inc", "mode": "test", "sharing": "team",
        "status": "needs_reauth", "mine": true, "canRemove": true, "createdAt": "2026-11-23T10:00:00.000Z"
    }));
    assert_eq!(c["title"], "Stripe · Acme Inc");
    assert_eq!(c["modeLabel"], "Test mode");
    assert_eq!(c["sharingLabel"], "Shared with the team");
    assert_eq!(c["statusLabel"], "Needs a new key");
    assert_eq!(c["healthy"], false);
    let c = connection_view(
        &json!({"id": "hubc_2", "provider": "stripe", "account": "B", "sharing": "private", "status": "active"}),
    );
    assert_eq!(c["modeLabel"], Value::Null);
    assert_eq!(c["sharingLabel"], "Private to you");
    assert_eq!(c["canRemove"], false);
}

#[test]
fn hub_shapes_calls() {
    let c = call_view(&json!({
        "id": "hcall_1", "status": "approval_required", "action": "stripe.refund.create", "connection": "hubc_1",
        "summary": "Refund 12.00 USD on ch_123 (Acme Inc, test)", "amount": 1200, "currency": "usd",
        "policy": {"effect": "ask", "rule": "hubr_1", "reason": "Ask for every refund"},
        "approval": {"id": "apr_1", "expiresAt": "2026-11-24T10:00:00.000Z"},
        "requestedBy": {"kind": "agent", "user": "u_1", "agent": "claude"},
        "createdAt": "2026-11-23T10:00:00.000Z"
    }));
    assert_eq!(c["line"], "Refund 12.00 USD on ch_123 (Acme Inc, test)");
    assert_eq!(c["statusLabel"], "Waiting for you");
    assert_eq!(c["amountText"], "12.00 USD");
    assert_eq!(c["actionLabel"], "Stripe refunds");
    assert_eq!(c["requestedByText"], "agent claude");
    assert_eq!(c["approvalId"], "apr_1");
    assert_eq!(c["expiresText"], "Expires 2026-11-24 10:00 UTC");
    assert_eq!(c["policyText"], "Ask for every refund");
    let c = call_view(
        &json!({"id": "hcall_2", "status": "failed", "summary": "x", "error": {"code": "stripe.nothing_to_refund", "message": "already refunded"}}),
    );
    assert_eq!(c["errorText"], "already refunded");
    assert_eq!(c["amountText"], Value::Null);
    assert_eq!(call_status_label("outcome_unknown"), "Outcome unknown");
    assert_eq!(call_status_label("blocked"), "Blocked by a rule");
}

#[test]
fn hub_shapes_rules() {
    assert_eq!(
        rule_text(
            &json!({"action": "github.*", "effect": "block", "when": {"repo": "acme/secret"}})
        ),
        "Block any GitHub action in acme/secret"
    );
    assert_eq!(action_label("github.pulls.list"), "listing GitHub pull requests");
    assert_eq!(action_label("github.issues.list"), "listing GitHub issues");
    assert_eq!(
        rule_text(&json!({"owner": "user", "action": "stripe.refund.create", "effect": "ask"})),
        "Ask before Stripe refunds"
    );
    assert_eq!(
        rule_text(&json!({
            "action": "stripe.refund.create", "effect": "allow", "agent": "claude",
            "when": {"amountLte": 5000, "currency": "usd"},
            "limit": {"window": "day", "amount": 20000, "over": "ask"},
            "expiresAt": "2026-12-23T10:00:00.000Z"
        })),
        "Allow Stripe refunds up to 50.00 USD, for agent claude; at most 200.00 USD a day, then ask; until 2026-12-23 10:00 UTC"
    );
    assert_eq!(
        rule_text(
            &json!({"action": "stripe.*", "effect": "block", "when": {"amountGt": 100000, "currency": "jpy"}})
        ),
        "Block any Stripe action over 100,000 JPY"
    );
    assert_eq!(
        rule_text(
            &json!({"action": "*", "effect": "ask", "limit": {"window": "month", "calls": 1, "over": "block"}})
        ),
        "Ask before any action; at most 1 call a month, then block"
    );
    assert_eq!(
        rule_text(
            &json!({"action": "stripe.charges.list", "effect": "allow", "when": {"amountGt": 10, "amountLte": 99}})
        ),
        "Allow listing Stripe charges over 10 (minor units) and up to 99 (minor units)"
    );
    let r = rule_view(
        &json!({"id": "hubr_1", "owner": "team", "action": "*", "effect": "allow", "remembered": true}),
    );
    assert_eq!(r["ownerLabel"], "Team rule");
    assert_eq!(r["remembered"], true);
    assert_eq!(r["canRemove"], false);
}

#[test]
fn hub_shapes_audit_rows() {
    let row = audit_view(&json!({
        "seq": 12, "at": "2026-11-23T10:05:00.000Z", "event": "approval.allowed",
        "actor": {"kind": "person", "user": "leo"}, "summary": "Refund 12.00 USD on ch_123",
        "prevHash": "a", "hash": "b"
    }));
    assert_eq!(row["line"], "Approved · Refund 12.00 USD on ch_123 · by leo");
    assert_eq!(row["whenText"], "2026-11-23 10:05 UTC");
    assert_eq!(row["tone"], "good");
    let row = audit_view(
        &json!({"seq": 1, "at": "x", "event": "hub.paused", "actor": {"kind": "agent", "user": "u"}, "summary": ""}),
    );
    assert_eq!(row["line"], "Paused · by an agent");
    assert_eq!(row["tone"], "plain");
    assert_eq!(event_label("call.blocked"), "Blocked");
}

fn ok(body: Value) -> (u16, Value) {
    (200, body)
}

#[test]
fn hub_overview_shapes_the_card() {
    let o = overview([
        ok(
            json!({"connections": [{"id": "hubc_1", "provider": "stripe", "account": "Acme", "sharing": "private", "status": "active"}]}),
        ),
        ok(
            json!({"approvals": [{"id": "hcall_1", "status": "approval_required", "summary": "Refund 1.00 USD", "approval": {"id": "apr_1", "expiresAt": "2026-11-24T00:00:00Z"}}]}),
        ),
        ok(
            json!({"paused": true, "rules": [{"id": "hubr_1", "action": "stripe.refund.create", "effect": "ask"}]}),
        ),
        ok(
            json!({"audit": [{"seq": 3, "at": "2026-11-23T00:00:00Z", "event": "connection.added", "actor": {"kind": "person", "user": "leo"}, "summary": "Linked Stripe"}], "next": 2}),
        ),
    ]);
    assert_eq!(o["ok"], true);
    assert_eq!(o["available"], true);
    assert_eq!(o["paused"], true);
    assert_eq!(o["hasStripe"], true);
    assert_eq!(o["hasGithub"], false);
    assert_eq!(o["connections"][0]["title"], "Stripe · Acme");
    assert_eq!(o["approvals"][0]["approvalId"], "apr_1");
    assert_eq!(o["rules"][0]["text"], "Ask before Stripe refunds");
    assert_eq!(o["audit"][0]["line"], "Linked · Linked Stripe · by leo");
    assert_eq!(o["next"], 2);
    assert!(o.get("platform").is_none());
    let o = with_answer_target(o, "https://platform.example", None);
    assert_eq!(
        (o["platform"].as_str(), &o["team"]),
        (Some("https://platform.example"), &Value::Null)
    );
}

#[test]
fn hub_overview_not_available_is_calm() {
    let missing = (404, json!({"error": {"code": "hub.not_found", "message": "Not found"}}));
    let o = overview([missing.clone(), missing.clone(), missing.clone(), missing]);
    assert_eq!(o["ok"], true);
    assert_eq!(o["available"], false);
    assert_eq!(o["connections"], json!([]));
    assert!(with_answer_target(o, "https://p", Some("t")).get("platform").is_none());
    let o = overview([
        ok(json!({"connections": []})),
        (401, json!({"error": {"code": "hub.unauthorized", "message": "sign in"}})),
        ok(json!({"paused": false, "rules": []})),
        ok(json!({"audit": []})),
    ]);
    assert_eq!(o["ok"], false);
    assert_eq!(o["error"]["code"], "hub.unauthorized");
}

#[test]
fn hub_answers_keep_the_hub_fields() {
    let a = answer(
        &parse_ok("rule add --action * --effect ask"),
        201,
        &json!({"rule": {"id": "hubr_2", "action": "*", "effect": "ask", "canRemove": true}}),
    );
    assert_eq!(a["rule"]["id"], "hubr_2");
    assert_eq!(a["rule"]["text"], "Ask before any action");
    let a = answer(
        &parse_ok("status hcall_1"),
        200,
        &json!({"call": {"id": "hcall_1", "status": "succeeded", "summary": "Refund"}}),
    );
    assert_eq!(a["call"]["statusLabel"], "Done");
    let a = answer(
        &parse_ok("link github"),
        409,
        &json!({"error": {"code": "github.not_connected", "message": "connect GitHub first"}}),
    );
    assert_eq!(
        (a["error"]["code"].as_str(), a["error"]["message"].as_str()),
        (Some("github.not_connected"), Some("connect GitHub first"))
    );
    let a = answer(
        &parse_ok("link stripe"),
        400,
        &json!({"error": {"code": "stripe.live_not_yet", "message": "live keys are not linked yet"}}),
    );
    assert_eq!(a["error"]["message"], "live keys are not linked yet");
    let a = answer(&parse_ok("remove hubc_1"), 200, &json!({"removed": true, "id": "hubc_1"}));
    assert_eq!(human_lines(&a), ["removed hubc_1"]);
    let a = answer(
        &parse_ok("actions"),
        200,
        &json!({"actions": [{"name": "stripe.refund.create", "title": "Refund a charge", "risk": "money", "linked": false}]}),
    );
    assert_eq!(a["actions"][0]["riskLabel"], "Moves money");
    assert_eq!(
        human_lines(&a),
        ["stripe.refund.create  Refund a charge (Moves money, not linked)"]
    );
    let a = answer(&parse_ok("audit"), 200, &json!({"audit": [], "next": null}));
    assert!(a.get("next").is_none());
}

#[test]
fn hub_overview_shapes_one_chief_card_per_waiting_approval() {
    let refund = json!({
        "id": "hcall_1", "status": "approval_required", "action": "stripe.refund.create", "connection": "hubc_1",
        "summary": "Refund 12.00 USD of 25.00 USD on Stripe charge ch_1", "amount": 1200, "currency": "usd",
        "policy": {"effect": "ask", "rule": "hubr_1", "reason": "rule hubr_1 says ask"},
        "approval": {"id": "apr_000000000000000000000001", "expiresAt": "2026-11-24T09:30:00Z"},
        "requestedBy": {"kind": "agent", "user": "leo", "agent": "support-bot"},
    });
    let over_limit = json!({
        "id": "hcall_2", "status": "approval_required", "action": "stripe.refund.create", "connection": "hubc_gone",
        "summary": "Refund 80.00 USD on Stripe charge ch_2", "amount": 8000, "currency": "usd",
        "policy": {"effect": "ask", "rule": "hubr_2", "reason": "over the limit of 100.00 USD a day (40.00 USD so far)"},
        "approval": {"id": "apr_000000000000000000000002", "expiresAt": "2026-11-24T10:00:00Z"},
        "requestedBy": {"kind": "agent", "user": "leo"},
    });
    let by_default = json!({
        "id": "hcall_3", "status": "approval_required", "action": "github.issues.comment", "summary": "Comment on o/r#4",
        "policy": {"effect": "ask", "reason": "no rule for github.issues.comment; send-external actions ask a person by default"},
        "approval": {"id": "apr_000000000000000000000003", "expiresAt": "2026-11-24T10:00:00Z"},
    });
    let o = overview([
        ok(
            json!({"connections": [{"id": "hubc_1", "provider": "stripe", "account": "Acme", "status": "active"}]}),
        ),
        ok(
            json!({"approvals": [refund, over_limit, by_default, {"id": "hcall_4", "status": "succeeded"}]}),
        ),
        ok(json!({"paused": false, "rules": [
            {"id": "hubr_1", "owner": "team", "action": "stripe.refund.create", "effect": "ask",
             "when": {"amountGt": 1000, "currency": "usd"}},
            {"id": "hubr_2", "owner": "user", "action": "stripe.refund.create", "effect": "allow",
             "limit": {"amount": 10000, "window": "day", "over": "ask"}},
        ]})),
        ok(json!({"audit": []})),
    ]);
    let cards = o["approvalCards"].as_array().expect("cards");
    assert_eq!(cards.len(), 3, "only calls that wait get a card: {cards:?}");
    let c = &cards[0];
    assert_eq!(c["approvalId"], "apr_000000000000000000000001");
    assert_eq!(c["callId"], "hcall_1");
    assert_eq!(c["agentText"], "agent support-bot");
    assert_eq!(c["integrationText"], "Stripe · Acme");
    assert_eq!(c["actionText"], "Refund");
    assert_eq!(c["amountText"], "12.00 USD");
    assert_eq!(c["line"], "Refund 12.00 USD of 25.00 USD on Stripe charge ch_1");
    assert_eq!(c["ruleText"], "Team rule: Ask before Stripe refunds over 10.00 USD");
    assert_eq!(c["expiresText"], "Expires 2026-11-24 09:30 UTC");
    // A connection the overview did not list still names its integration; a limit says why it asked.
    assert_eq!(cards[1]["integrationText"], "Stripe");
    assert_eq!(cards[1]["agentText"], "an agent");
    assert_eq!(
        cards[1]["ruleText"],
        "Your rule: Allow Stripe refunds; at most 10000 (minor units) a day, then ask; \
         over the limit of 100.00 USD a day (40.00 USD so far)"
    );
    // No rule: the hub's default decided, and its reason says so.
    assert_eq!(cards[2]["integrationText"], "GitHub");
    assert_eq!(cards[2]["actionText"], "comment");
    assert_eq!(
        cards[2]["ruleText"],
        "Rule: no rule for github.issues.comment; send-external actions ask a person by default"
    );
    assert_eq!(cards[2]["amountText"], Value::Null);
}

#[test]
fn hub_call_view_says_what_an_answer_did() {
    let outcome = |call: Value| {
        let v = call_view(&call);
        (v["outcomeText"].as_str().map(str::to_owned), v["outcomeTone"].as_str().map(str::to_owned))
    };
    let pair = |t: &str, tone: &str| (Some(t.to_owned()), Some(tone.to_owned()));
    assert_eq!(
        outcome(json!({"status": "succeeded", "providerRef": "re_123"})),
        pair("Approved. It ran (re_123).", "done")
    );
    assert_eq!(outcome(json!({"status": "succeeded"})), pair("Approved. It ran.", "done"));
    assert_eq!(outcome(json!({"status": "denied"})), pair("Denied. Nothing ran.", "denied"));
    assert_eq!(
        outcome(
            json!({"status": "failed", "error": {"code": "stripe.error", "message": "charge already refunded"}})
        ),
        pair("Approved, but it failed: charge already refunded", "failed")
    );
    assert_eq!(outcome(json!({"status": "outcome_unknown"})).1, Some("failed".to_owned()));
    assert_eq!(outcome(json!({"status": "expired"})).1, Some("denied".to_owned()));
    assert_eq!(outcome(json!({"status": "approval_required"})), (None, None));
    assert_eq!(outcome(json!({"status": "running"})), (None, None));
}
