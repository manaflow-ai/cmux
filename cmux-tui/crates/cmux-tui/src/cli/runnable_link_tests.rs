use std::collections::VecDeque;
use std::time::Duration;

use serde_json::{Value, json};

use super::*;

fn w(words: &[&str]) -> Vec<String> {
    words.iter().map(|s| (*s).to_owned()).collect()
}

fn no_env(_: &str) -> Option<String> {
    None
}

#[test]
fn every_link_form_names_its_id() {
    for text in [
        "https://cmux.com/run/rl_abc123",
        "https://www.cmux.com/run/rl_abc123",
        "https://cmux.com/ja/run/rl_abc123",
        "https://cmux.com/zh-CN/run/rl_abc123/",
        "https://cmux.com/run/rl_abc123?utm=x",
        "https://cmux.com/run/rl_abc123#top",
        "cmux://run/rl_abc123",
        "cmux-next://run/rl_abc123",
        "cmux-dev://run/rl_abc123",
        "  rl_abc123  ",
    ] {
        assert_eq!(parse_link(text).as_deref(), Some("rl_abc123"), "{text}");
    }
}

#[test]
fn other_urls_are_not_runnable_links() {
    for text in [
        "http://cmux.com/run/rl_abc123",
        "https://evil.com/run/rl_abc123",
        "https://cmux.com.evil.com/run/rl_abc123",
        "https://cmux.com/deeplink/agent?session=x",
        "https://cmux.com/run/",
        "https://cmux.com/run/a/b",
        "https://cmux.com/run/rl abc",
        "https://cmux.com/run/../x",
        "cmux://agent/claude/abc",
        "cmuxx://run/rl_abc123",
        "cmux-://run/rl_abc123",
        "notcmux://run/rl_abc123",
        "rl/abc",
        "",
    ] {
        assert_eq!(parse_link(text), None, "{text}");
    }
    assert_eq!(parse_link(&format!("rl_{}", "a".repeat(200))), None);
}

#[test]
fn ttl_reads_days_hours_minutes_and_bounds_them() {
    assert_eq!(parse_ttl("7d"), Ok(7 * 86_400));
    assert_eq!(parse_ttl("12h"), Ok(12 * 3600));
    assert_eq!(parse_ttl("30m"), Ok(1800));
    assert_eq!(parse_ttl("3600"), Ok(3600));
    assert!(parse_ttl("10s").is_err());
    assert!(parse_ttl("31d").is_err());
    assert!(parse_ttl("7w").is_err());
    assert!(parse_ttl("d").is_err());
}

#[test]
fn the_flag_is_off_unless_json_true_or_the_env_says_on() {
    assert!(!enabled(None, None));
    assert!(!enabled(None, Some(&json!({}))));
    assert!(!enabled(None, Some(&json!({"cloud": {"runnableLinks": "true"}}))));
    assert!(!enabled(None, Some(&json!({"cloud": {"runnableLinks": 1}}))));
    assert!(enabled(None, Some(&json!({"cloud": {"runnableLinks": true}}))));
    assert!(enabled(Some("1"), None));
    assert!(!enabled(Some("0"), Some(&json!({"cloud": {"runnableLinks": true}}))));
}

#[test]
fn parse_reads_both_verbs_and_refuses_the_rest() {
    let p = parse(&w(&["open", "https://cmux.com/run/rl_x", "--yes", "--json"]), &no_env).unwrap();
    assert_eq!(p.verb, Verb::Open { id: "rl_x".into(), no_app: false });
    assert!(p.yes && p.json);
    assert_eq!(p.common.token, TokenSource::App);
    let p = parse(&w(&["mint", "vm_abc", "--ttl", "2d", "--note", "repro"]), &no_env).unwrap();
    assert_eq!(
        p.verb,
        Verb::Mint {
            machine: "vm_abc".into(),
            ttl_seconds: Some(2 * 86_400),
            note: Some("repro".into())
        }
    );
    assert!(!p.yes);
    assert!(parse(&w(&["open"]), &no_env).is_err());
    assert!(parse(&w(&["open", "https://evil.com/run/x"]), &no_env).is_err());
    assert!(parse(&w(&["open", "rl_x", "--ttl", "1d"]), &no_env).is_err());
    assert!(parse(&w(&["mint", "vm/../x"]), &no_env).is_err());
    assert!(parse(&w(&["fork", "rl_x"]), &no_env).is_err());
    let env = |k: &str| (k == "CMUX_CLOUD_ACCESS_TOKEN").then(|| "t".to_owned());
    assert_eq!(parse(&w(&["open", "rl_x"]), &env).unwrap().common.token, TokenSource::Env);
}

/// A platform that answers each request from a script, in order, and logs every call.
#[derive(Default)]
struct FakePlatform {
    script: VecDeque<(&'static str, String, u16, Value)>,
    calls: Vec<(String, String, Option<Value>)>,
}

impl FakePlatform {
    fn answer(mut self, method: &'static str, path: &str, status: u16, body: Value) -> Self {
        self.script.push_back((method, path.to_owned(), status, body));
        self
    }
}

impl Platform for FakePlatform {
    async fn call(
        &mut self,
        method: &'static str,
        path: &str,
        body: Option<Value>,
    ) -> Result<(u16, Value), String> {
        self.calls.push((method.to_owned(), path.to_owned(), body));
        match self.script.pop_front() {
            Some((m, p, status, answer)) if m == method && p == path => Ok((status, answer)),
            Some((m, p, ..)) => Err(format!("expected {m} {p}, got {method} {path}")),
            None => Err(format!("unscripted {method} {path}")),
        }
    }
}

#[derive(Default)]
struct FakeApp {
    present: bool,
    steps: Vec<Vec<String>>,
}

impl App for FakeApp {
    fn present(&mut self) -> bool {
        self.present
    }
    fn step(&mut self, args: &[String]) -> Result<Value, Value> {
        self.steps.push(args.to_vec());
        match args.first().map(String::as_str) {
            Some("cloud") if args.get(1).map(String::as_str) == Some("list-machines") => {
                Ok(json!({"machines": [{"id": "vm_copy"}]}))
            }
            _ => Ok(json!({"ok": true})),
        }
    }
}

fn quick() -> Waits {
    Waits {
        poll: Duration::ZERO,
        running: Duration::from_secs(5),
        acpmux: Duration::from_secs(5),
        app_list: Duration::from_secs(5),
    }
}

fn link_body() -> Value {
    json!({"value": {
        "id": "rl_x", "snapshotId": "snap_1", "expiresAt": 4_102_444_800_000_i64, "revokedAt": null,
        "manifest": {"sourceMachine": "vm_src", "createdBy": "user_1", "repo": "manaflow-ai/cmux", "head": "abc1234",
                     "sessions": ["fix-bug"]}
    }})
}

fn run_async<F: Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
}

#[test]
fn open_resolves_forks_waits_execs_and_opens_in_the_app() {
    let mut platform = FakePlatform::default()
        .answer("GET", "/v1/runnable-links/rl_x", 200, link_body())
        .answer("POST", "/v1/runnable-links/rl_x/fork", 200, json!({"machine": {"id": "vm_copy", "state": "starting"}}))
        .answer("GET", "/v1/machines/vm_copy", 200, json!({"id": "vm_copy", "state": "starting"}))
        .answer("GET", "/v1/machines/vm_copy", 200, json!({"id": "vm_copy", "state": "running"}))
        .answer("POST", "/v1/cloud/machines/vm_copy/exec", 200, json!({"exitCode": 0, "stdout": ""}))
        .answer("POST", "/v1/cloud/machines/vm_copy/exec", 200, json!({"exitCode": 1, "stdout": ""}))
        .answer(
            "POST",
            "/v1/cloud/machines/vm_copy/exec",
            200,
            json!({"exitCode": 0, "stdout": "[{\"name\":\"fix-bug\",\"id\":\"s_1\"},{\"name\":\"other\",\"id\":\"s_2\"}]"}),
        );
    let mut app = FakeApp { present: true, ..FakeApp::default() };
    let mut shown = vec![];
    let mut confirm = |lines: &[String]| {
        shown = lines.to_vec();
        true
    };
    let out = run_async(open(&mut platform, Some(&mut app), "rl_x", quick(), &mut confirm));
    assert_eq!(out["ok"], json!(true), "{out}");
    assert_eq!(out["machine"], "vm_copy");
    assert_eq!(out["attached"], json!(["fix-bug"]));
    for phase in [
        "resolve",
        "fork",
        "running",
        "first_exec",
        "acpmux_sessions_listed",
        "workspace_open",
        "total",
    ] {
        assert!(out["timings"][format!("{phase}_ms")].is_u64(), "{phase}: {out}");
    }
    assert_eq!(out["gaps"], json!([]));
    // The disclosure names the version, creator and what is never carried.
    let text = shown.join("\n");
    assert!(
        text.contains("snap_1")
            && text.contains("user_1")
            && text.contains("never the creator's tokens")
    );
    // The fork carries a client key and nothing of the creator's.
    let fork = platform.calls.iter().find(|c| c.1.ends_with("/fork")).unwrap();
    let body = fork.2.as_ref().unwrap();
    assert!(body["clientKey"].as_str().is_some_and(|k| k.len() == 36));
    assert_eq!(body.as_object().unwrap().len(), 1);
    assert!(platform.script.is_empty());
    // The app opened the copy with its own Cloud verb, then attached the named session.
    assert!(app.steps.contains(&w(&[
        "cloud",
        "new-terminal-on-machine",
        "--target",
        "machine:vm_copy",
        "--focus"
    ])));
    assert!(
        app.steps.contains(&w(&["agent", "open", "s_1", "--host", "vm_copy", "--name", "fix-bug"]))
    );
}

#[test]
fn a_declined_open_starts_nothing() {
    let mut platform =
        FakePlatform::default().answer("GET", "/v1/runnable-links/rl_x", 200, link_body());
    let out = run_async(open::<_, FakeApp>(
        &mut platform,
        None,
        "rl_x",
        quick(),
        &mut |_: &[String]| false,
    ));
    assert_eq!(out["error"]["code"], "link.declined");
    assert_eq!(platform.calls.len(), 1, "only the read ran");
    assert!(out["timings"]["resolve_ms"].is_u64());
}

#[test]
fn a_refused_fork_says_why_and_a_revoked_link_never_asks() {
    let mut platform =
        FakePlatform::default().answer("GET", "/v1/runnable-links/rl_x", 200, link_body()).answer(
            "POST",
            "/v1/runnable-links/rl_x/fork",
            403,
            json!({"error": {"code": "link.forbidden", "message": "not your team"}}),
        );
    let out = run_async(open::<_, FakeApp>(
        &mut platform,
        None,
        "rl_x",
        quick(),
        &mut |_: &[String]| true,
    ));
    assert_eq!(out["error"]["code"], "link.forbidden");
    assert_eq!(out["error"]["message"], "not your team");

    let mut revoked = link_body();
    revoked["value"]["revokedAt"] = json!(1);
    let mut platform =
        FakePlatform::default().answer("GET", "/v1/runnable-links/rl_x", 200, revoked);
    let mut asked = false;
    let out = run_async(open::<_, FakeApp>(
        &mut platform,
        None,
        "rl_x",
        quick(),
        &mut |_: &[String]| {
            asked = true;
            true
        },
    ));
    assert_eq!(out["error"]["code"], "link.revoked");
    assert!(!asked);

    let mut platform =
        FakePlatform::default().answer("GET", "/v1/runnable-links/rl_x", 404, json!({}));
    let out = run_async(open::<_, FakeApp>(
        &mut platform,
        None,
        "rl_x",
        quick(),
        &mut |_: &[String]| true,
    ));
    assert_eq!(out["error"]["code"], "link.not_found");
}

#[test]
fn a_failed_copy_stops_the_wait() {
    let mut platform = FakePlatform::default()
        .answer("GET", "/v1/runnable-links/rl_x", 200, link_body())
        .answer(
            "POST",
            "/v1/runnable-links/rl_x/fork",
            200,
            json!({"id": "vm_copy", "state": "starting"}),
        )
        .answer("GET", "/v1/machines/vm_copy", 200, json!({"state": "failed"}));
    let out = run_async(open::<_, FakeApp>(
        &mut platform,
        None,
        "rl_x",
        quick(),
        &mut |_: &[String]| true,
    ));
    assert_eq!(out["error"]["code"], "machine.failed");
    assert_eq!(out["machine"], "vm_copy");
}

#[test]
fn with_no_app_the_copy_runs_and_says_it_was_not_opened() {
    let mut platform = FakePlatform::default()
        .answer("GET", "/v1/runnable-links/rl_x", 200, link_body())
        .answer(
            "POST",
            "/v1/runnable-links/rl_x/fork",
            200,
            json!({"machine": {"id": "vm_copy", "state": "running"}}),
        )
        .answer("POST", "/v1/cloud/machines/vm_copy/exec", 200, json!({"value": {"exitCode": 0}}))
        .answer(
            "POST",
            "/v1/cloud/machines/vm_copy/exec",
            200,
            json!({"value": {"exitCode": 0, "stdout": "{\"sessions\":[]}"}}),
        );
    let mut app = FakeApp::default();
    let out =
        run_async(open(&mut platform, Some(&mut app), "rl_x", quick(), &mut |_: &[String]| true));
    assert_eq!(out["ok"], json!(true), "{out}");
    assert!(out["timings"].get("workspace_open_ms").is_none());
    assert!(out["gaps"].to_string().contains("no running cmux app"));
    assert!(app.steps.is_empty());
}

#[test]
fn mint_shows_the_disclosure_then_posts_and_prints_the_url() {
    let mut platform = FakePlatform::default().answer(
        "POST",
        "/v1/runnable-links",
        200,
        json!({"id": "rl_new", "url": "https://cmux.com/run/rl_new", "snapshotId": "snap_9", "expiresAt": 1}),
    );
    let mut shown = vec![];
    let out = run_async(mint(
        &mut platform,
        "vm_src",
        Some(86_400),
        Some("repro"),
        &mut |l: &[String]| {
            shown = l.to_vec();
            true
        },
    ));
    assert_eq!(out["url"], "https://cmux.com/run/rl_new");
    assert!(
        shown.join("\n").contains("snapshots the machine") && shown.join("\n").contains("1 days")
    );
    let body = platform.calls[0].2.clone().unwrap();
    assert_eq!(body["machine"], "vm_src");
    assert_eq!(body["ttlSeconds"], 86_400);
    assert_eq!(body["note"], "repro");

    let mut platform = FakePlatform::default();
    let out = run_async(mint(&mut platform, "vm_src", None, None, &mut |_: &[String]| false));
    assert_eq!(out["error"]["code"], "link.declined");
    assert!(platform.calls.is_empty());
}

#[test]
fn expiry_reads_as_time_left() {
    assert_eq!(relative(1_000 + 3 * 86_400_000, 1_000), "in 3 days");
    assert_eq!(relative(7_200_000, 0), "in 2 hours");
    assert_eq!(relative(10_000, 0), "in 1 minutes");
    assert_eq!(relative(0, 5), "expired");
}

/// Seeded secrets on the wire (cmux_egress::capture): the bearer rides only in `Authorization`, the team only in
/// the `team` query. tests/egress_seeded.json names this test for the `cmux_tui::cli::runnable_link` gate site.
#[test]
fn seeded_secrets_ride_only_in_authorization_and_the_team_query() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let bearer = "SEEDrunnableLinkBearer-7c4e";
    let team = "SEEDrunnableLinkTeam-91ab";
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let mut http = Http {
            client: http_client().unwrap(),
            origin: "https://cmux.dev".to_owned(),
            team: Some(team.to_owned()),
            token: Zeroizing::new(bearer.to_owned()),
        };
        let _ = http.call("POST", "/v1/runnable-links", Some(json!({"machine": "m-seeded"}))).await;
        let _ = http.call("GET", "/v1/runnable-links/rl-seeded", None).await;
    });
    let sent: Vec<_> = cmux_egress::capture::requests_to("cmux.dev")
        .into_iter()
        .filter(|r| r.target.starts_with("/v1/runnable-links"))
        .collect();
    assert_eq!(sent.len(), 2, "{sent:?}");
    let places = cmux_egress::capture::leaks(bearer);
    assert_eq!(places.len(), 2, "{places:?}");
    assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
    let places = cmux_egress::capture::leaks(team);
    assert_eq!(places.len(), 2, "{places:?}");
    assert!(places.iter().all(|p| p.ends_with(": target")), "{places:?}");
}
