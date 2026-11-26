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

fn ci_fix_spec() -> Value {
    let mut spec = templates()[0]["spec"].clone();
    spec["trigger"]["repository"] = json!("acme/web");
    spec["action"]["repo"] = json!("acme/web");
    spec
}

#[test]
fn autocloud_parses_every_verb() {
    assert_eq!(parse_ok("overview"), Verb::Overview);
    assert_eq!(parse_ok("list"), Verb::Overview);
    assert_eq!(parse_ok("runs auto_1"), Verb::Runs { id: "auto_1".into(), limit: 50 });
    assert_eq!(parse_ok("runs auto_1 --limit 5"), Verb::Runs { id: "auto_1".into(), limit: 5 });
    assert_eq!(parse_ok("create"), Verb::Create);
    assert_eq!(parse_ok("update auto_1"), Verb::Update { id: "auto_1".into() });
    assert_eq!(
        parse_ok("enable auto_1 --revision 3"),
        Verb::Enable { id: "auto_1".into(), enabled: true, revision: 3 }
    );
    assert_eq!(
        parse_ok("disable auto_1 --revision=4"),
        Verb::Enable { id: "auto_1".into(), enabled: false, revision: 4 }
    );
    assert_eq!(parse_ok("remove auto_1"), Verb::Remove { id: "auto_1".into() });
    assert_eq!(parse_ok("preview"), Verb::Preview);
    assert_eq!(parse_ok("templates"), Verb::Templates);
}

#[test]
fn autocloud_refuses_bad_arguments() {
    assert!(parse_err("runs").contains("name the automation"));
    assert!(parse_err("runs ../etc").contains("not an automation id"));
    assert!(parse_err("runs a --limit 0").contains("1 to 200"));
    assert!(parse_err("enable auto_1").contains("--revision"));
    assert!(parse_err("create --secret x").contains("stdin"));
    assert!(parse_err("create --spec {}").contains("stdin"));
    assert!(parse_err("overview extra").contains("unexpected"));
    assert!(parse_err("launch").contains("unknown verb"));
    assert!(parse(&words("overview --platform http://evil.example"), &no_env).is_err());
}

#[test]
fn autocloud_picks_the_token_and_platform() {
    let env = |k: &str| match k {
        "CMUX_CLOUD_ACCESS_TOKEN" => Some("t".into()),
        "CMUX_PLATFORM_URL" => Some("https://platform.example.com".into()),
        _ => None,
    };
    let (common, _) = parse(&words("overview --team acme"), &env).unwrap();
    assert_eq!(common.token, TokenSource::Env);
    assert_eq!(common.team.as_deref(), Some("acme"));
    assert_eq!(common.platform.as_deref(), Some("https://platform.example.com"));
    let (common, _) = parse(&words("overview"), &no_env).unwrap();
    assert_eq!(common.token, TokenSource::App);
    assert_eq!(common.platform, None);
}

#[test]
fn autocloud_checks_a_spec() {
    let checked = check_spec(&ci_fix_spec()).unwrap();
    assert_eq!(
        checked["trigger"],
        json!({"type": "github", "events": ["ci_failure"], "repository": "acme/web"})
    );
    assert_eq!(checked["conditions"].as_array().unwrap().len(), 2);
    assert_eq!(
        checked["conditions"][1],
        json!({"path": "workflow_run.pull_requests.0.number", "op": "exists"})
    );
    assert_eq!(checked["action"]["harness"], "claude");
    assert_eq!(checked["guardrails"]["maxRunsPerDay"], 10);

    let bad = |edit: &dyn Fn(&mut Value), want: &str| {
        let mut spec = ci_fix_spec();
        edit(&mut spec);
        let err = check_spec(&spec).unwrap_err();
        assert!(err.contains(want), "{err} lacks {want}");
    };
    bad(&|s| s["name"] = json!(""), "name");
    bad(&|s| s["trigger"]["repository"] = json!("acme"), "owner/name");
    bad(&|s| s["trigger"]["events"] = json!(["deploy"]), "not a GitHub event");
    bad(&|s| s["trigger"] = json!({"type": "schedule", "cron": "every day"}), "cron");
    bad(&|s| s["trigger"] = json!({"type": "Email!"}), "github, webhook, schedule");
    // The union stays open: a type the platform adds later passes through.
    let mut slack = ci_fix_spec();
    slack["trigger"] = json!({"type": "slack", "channel": "C123"});
    assert_eq!(check_spec(&slack).unwrap()["trigger"], json!({"type": "slack", "channel": "C123"}));
    assert_eq!(trigger_text(&json!({"type": "linear_issue"})), "Linear issue");
    bad(
        &|s| s["conditions"] = json!([{"path": "a..b", "op": "equals", "value": "x"}]),
        "event path",
    );
    bad(&|s| s["conditions"] = json!([{"path": "a", "op": "like", "value": "x"}]), "operator");
    // `matches` (regex) left the contract: Workers has no RE2.
    bad(&|s| s["conditions"] = json!([{"path": "a", "op": "matches", "value": "x"}]), "operator");
    bad(&|s| s["conditions"] = json!([{"path": "a", "op": "gt", "value": "many"}]), "a number");
    bad(
        &|s| s["conditions"] = json!([{"path": "a", "op": "not_in", "value": " , "}]),
        "at least one",
    );
    bad(&|s| s["conditions"] = json!([{"path": "a", "op": "equals"}]), "name a value");
    bad(&|s| s["action"]["harness"] = json!("gpt"), "claude or codex");
    bad(&|s| s["action"]["prompt"] = json!("  "), "prompt");
    bad(&|s| s["guardrails"]["maxRunsPerDay"] = json!(-1), "daily cap");

    let mut spec = ci_fix_spec();
    spec["trigger"] = json!({"type": "schedule", "cron": "0 9 * * 1-5"});
    spec["conditions"] = json!([{"path": "label.name", "op": "in", "value": "autofix, agent"}]);
    let checked = check_spec(&spec).unwrap();
    assert_eq!(checked["trigger"]["timeZone"], "UTC");
    assert_eq!(checked["conditions"][0]["value"], json!(["autofix", "agent"]));
    spec["conditions"] = json!([
        {"path": "pr.changed_files", "op": "lte", "value": 20},
        {"path": "pr.draft", "op": "missing", "value": "ignored"},
    ]);
    let checked = check_spec(&spec).unwrap();
    assert_eq!(checked["conditions"][0]["value"], "20");
    assert_eq!(checked["conditions"][1], json!({"path": "pr.draft", "op": "missing"}));
}

#[test]
fn autocloud_renders_templates() {
    let scope =
        json!({"event": {"pr": {"number": 42, "labels": ["a"]}}, "run": {"url": "https://x"}});
    let (text, missing) =
        render("PR #{{event.pr.number}} {{ run.url }} {{event.nope}} {{env.HOME}} {{", &scope);
    assert_eq!(text, "PR #42 https://x {{event.nope}} {{env.HOME}} {{");
    assert_eq!(missing, vec!["event.nope".to_owned(), "env.HOME".to_owned()]);
    assert_eq!(lookup(&json!({"a": [{"b": 1}]}), "a.0.b"), Some(&json!(1)));
    assert_eq!(lookup(&json!({"a": [1]}), "a.x"), None);
}

#[test]
fn autocloud_conditions_hold() {
    let event = json!({"b": "fix-login", "n": 3, "labels": ["bug", "autofix"], "none": null});
    let c = |path: &str, op: &str, value: Value| json!({"path": path, "op": op, "value": value});
    assert!(holds(&c("b", "equals", json!("fix-login")), &event).0);
    assert!(holds(&c("n", "equals", json!("3")), &event).0);
    assert!(holds(&c("b", "not_equals", json!("main")), &event).0);
    assert!(holds(&c("b", "contains", json!("login")), &event).0);
    assert!(holds(&c("labels", "contains", json!("autofix")), &event).0);
    assert!(!holds(&c("labels", "contains", json!("auto")), &event).0);
    assert!(holds(&c("b", "prefix", json!("fix-")), &event).0);
    assert!(!holds(&c("b", "prefix", json!("login")), &event).0);
    assert!(holds(&c("b", "in", json!(["main", "fix-login"])), &event).0);
    assert!(holds(&c("b", "not_in", json!(["main", "release"])), &event).0);
    assert!(!holds(&c("b", "not_in", json!(["fix-login"])), &event).0);
    assert!(holds(&c("n", "gt", json!("2")), &event).0);
    assert!(!holds(&c("n", "gt", json!("3")), &event).0);
    assert!(holds(&c("n", "gte", json!(3)), &event).0);
    assert!(holds(&c("n", "lt", json!("10")), &event).0);
    assert!(holds(&c("n", "lte", json!("3")), &event).0);
    assert!(!holds(&c("b", "lt", json!("10")), &event).0);
    assert!(holds(&json!({"path": "gone", "op": "missing"}), &event).0);
    assert!(holds(&json!({"path": "none", "op": "missing"}), &event).0);
    assert!(!holds(&json!({"path": "b", "op": "missing"}), &event).0);
    assert!(holds(&json!({"path": "b", "op": "exists"}), &event).0);
    assert!(!holds(&json!({"path": "none", "op": "exists"}), &event).0);
    assert!(!holds(&json!({"path": "gone", "op": "exists"}), &event).0);
    assert_eq!(holds(&c("b", "equals", json!("x")), &event).1.as_deref(), Some("fix-login"));
}

#[test]
fn autocloud_previews_the_ci_template() {
    let out = preview(&json!({"spec": ci_fix_spec()}));
    assert_eq!(out["ok"], true);
    assert_eq!(out["sample"], "ci_failure");
    assert_eq!(out["ref"], "fix-login-redirect");
    let prompt = out["prompt"].as_str().unwrap();
    assert!(prompt.starts_with("CI (CI) failed on pull request #42 in acme/web: https://github.com/acme/web/actions/runs/1234"));
    assert_eq!(out["missing"], json!([]));
    assert_eq!(out["matches"], true);
    assert_eq!(out["conditions"][0]["holds"], true);

    // A custom event that fails the first condition.
    let out = preview(
        &json!({"spec": ci_fix_spec(), "event": {"workflow_run": {"event": "push", "head_branch": "main"}}}),
    );
    assert_eq!(out["matches"], false);
    assert_eq!(out["matchText"], "This event would be skipped");
    assert!(out["missingText"].as_str().unwrap().contains("{{event.repository.full_name}}"));
    assert_eq!(preview(&json!({"spec": {}, "sample": "nope"}))["ok"], false);
}

#[test]
fn autocloud_every_template_is_a_valid_spec_once_named() {
    let list = templates();
    assert_eq!(
        list[0]["title"],
        "When CI fails on a PR, start an agent to fix it and push to the PR"
    );
    for t in list {
        let mut spec = t["spec"].clone();
        spec["trigger"]["repository"] = json!("acme/web");
        spec["action"]["repo"] = json!("acme/web");
        check_spec(&spec).unwrap_or_else(|e| panic!("{}: {e}", t["id"]));
        let out = preview(&json!({"spec": spec}));
        assert_eq!(out["missing"], json!([]), "{}", t["id"]);
        assert_eq!(out["matches"], true, "{}", t["id"]);
    }
}

#[test]
fn autocloud_shapes_views() {
    let now = 10_000_000;
    let a = json!({
        "id": "auto_1", "name": "Fix CI", "enabled": true, "revision": 2,
        "trigger": {"type": "github", "events": ["ci_failure"], "repository": "acme/web"},
        "conditions": [{"path": "workflow_run.event", "op": "equals", "value": "pull_request"}],
        "action": {"repo": "acme/web", "ref": "main", "harness": "codex", "prompt": "p"},
        "guardrails": {"maxRunsPerDay": 5},
        "lastRun": {"id": "run_1", "status": "failed", "startedAt": now - 180_000, "minutes": 4.2,
            "event": {"kind": "ci_failure", "summary": "CI failed on #42"},
            "links": {"pr": "https://github.com/acme/web/pull/42", "session": "javascript:alert(1)"},
            "error": "push refused"},
    });
    let v = automation_view(&a, now);
    assert_eq!(v["triggerText"], "GitHub · CI fails · acme/web");
    assert_eq!(v["conditionsText"], "Only when workflow_run.event equals pull_request");
    assert_eq!(v["actionText"], "Starts Codex on acme/web");
    assert_eq!(v["lastRunText"], "Failed 3 minutes ago");
    assert_eq!(v["lastRun"]["tone"], "bad");
    assert_eq!(v["lastRun"]["minutesText"], "4 minutes");
    assert_eq!(
        v["lastRun"]["links"],
        json!([{"label": "Pull request", "url": "https://github.com/acme/web/pull/42"}])
    );
    assert_eq!(v["spec"]["guardrails"]["maxRunsPerDay"], 5);
    assert_eq!(automation_view(&json!({"id": "x"}), now)["lastRunText"], "Never ran");
    assert_eq!(
        trigger_text(&json!({"type": "schedule", "cron": "0 9 * * *"})),
        "Schedule · 0 9 * * * · UTC"
    );
    assert_eq!(ago(now - 30_000, now), "just now");
    assert_eq!(ago(now - 3_600_000, now), "1 hour ago");
    assert_eq!(ago(now - 2 * 86_400_000, now), "2 days ago");
}

#[test]
fn autocloud_answers_from_the_platform() {
    // A deployment with no automations route: not here, not a failure.
    let out = overview(404, &json!({}), 0);
    assert_eq!(out["ok"], true);
    assert_eq!(out["available"], false);
    assert!(!out["templates"].as_array().unwrap().is_empty());
    // An automations 404 stays an error.
    let out = answer(
        &Verb::Remove { id: "a".into() },
        404,
        &json!({"code": "automation.not_found", "message": "gone"}),
        0,
    );
    assert_eq!(out["ok"], false);
    assert_eq!(out["error"]["code"], "automation.not_found");
    let out = answer(
        &Verb::Update { id: "a".into() },
        409,
        &json!({"error": {"code": "automation.conflict", "message": "edited elsewhere"}}),
        0,
    );
    assert_eq!(out["error"]["code"], "automation.conflict");
    assert_eq!(out["error"]["status"], 409);
    // The list.
    let out = overview(200, &json!({"automations": [{"id": "auto_1", "name": "n"}]}), 0);
    assert_eq!(out["available"], true);
    assert_eq!(out["automations"][0]["id"], "auto_1");
    // A webhook automation's secret, once.
    let body = json!({"automation": {"id": "auto_2", "trigger": {"type": "webhook"}, "webhookUrl": "https://p.example/v1/triggers/auto_2/webhook"}, "secret": "whsec_x"});
    let out = answer(&Verb::Create, 201, &body, 0);
    assert_eq!(out["secret"], "whsec_x");
    assert_eq!(out["automation"]["webhookUrl"], "https://p.example/v1/triggers/auto_2/webhook");
    assert_eq!(answer(&Verb::Create, 201, &json!({}), 0)["error"]["code"], "api.bad_answer");
    let out = answer(
        &Verb::Runs { id: "auto_1".into(), limit: 5 },
        200,
        &json!({"runs": [{"status": "capped"}]}),
        0,
    );
    assert_eq!(out["runs"][0]["statusLabel"], "Over the cap");
    assert_eq!(out["runs"][0]["tone"], "warn");
}

#[test]
fn autocloud_builds_requests() {
    let r = request_of(&Verb::Runs { id: "auto_1".into(), limit: 5 }, None).unwrap();
    assert_eq!(
        url_of("https://p.example", &r, Some("acme team")),
        "https://p.example/v1/automations/auto_1/runs?limit=5&team=acme%20team"
    );
    let r = request_of(&Verb::Enable { id: "auto_1".into(), enabled: false, revision: 7 }, None)
        .unwrap();
    assert_eq!(r.method, "PATCH");
    assert_eq!(r.body, Some(json!({"enabled": false, "revision": 7})));
    assert_eq!(request_of(&Verb::Remove { id: "a".into() }, None).unwrap().method, "DELETE");
    assert_eq!(
        url_of("https://p.example", &request_of(&Verb::Overview, None).unwrap(), None),
        "https://p.example/v1/automations"
    );
    assert!(request_of(&Verb::Preview, None).is_none());
}

#[test]
fn autocloud_catalog_labels_every_choice() {
    let c = catalog();
    assert_eq!(c["githubEvents"].as_array().unwrap().len(), GITHUB_EVENTS.len());
    assert_eq!(c["harnesses"][0], json!({"value": "claude", "label": "Claude Code"}));
    for kind in c["samples"].as_array().unwrap() {
        assert!(sample_event(kind["value"].as_str().unwrap()).is_some(), "{kind}");
    }
    for s in STATUSES {
        assert_ne!(status_label(s), "Unknown");
    }
}

/// Seeded secrets on the wire (cmux_egress::capture): the bearer rides only in `Authorization` and
/// the team only in the `team` query. tests/egress_seeded.json names this test for
/// `cmux_tui::cli::autocloud`.
#[tokio::test]
async fn seeded_secrets_ride_only_where_the_platform_needs_them() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let token = "SEEDautocloudBearer-5c3a";
    let team = "SEEDautocloudTeam-e81b";
    let common = Common {
        platform: Some(cmux_cloud_environment::PRODUCTION_PLATFORM.to_owned()),
        team: Some(team.to_owned()),
        token: TokenSource::Command(format!("printf %s {token}")),
    };
    let _ = run(&common, &Verb::Runs { id: "seeded".into(), limit: 1 }, None).await;
    let sent = cmux_egress::capture::requests_to("cmux-platform-production.debussy.workers.dev");
    let ours: Vec<_> = sent.iter().filter(|r| r.target.starts_with("/v1/automations")).collect();
    assert!(!ours.is_empty(), "{sent:?}");
    let places = cmux_egress::capture::leaks(token);
    assert!(!places.is_empty(), "{sent:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": target")), "{places:?}");
}
