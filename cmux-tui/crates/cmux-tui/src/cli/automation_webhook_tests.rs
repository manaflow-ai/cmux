use super::*;
use serde_json::json;
use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|w| w.to_string()).collect()
}

/// A complete create, after the verb.
const BASE: &[&str] = &[
    "ci-fix",
    "--webhook",
    "--on",
    "cloud",
    "--from",
    "vm_src",
    "--repo",
    "acme/api",
    "--prompt",
    "Fix CI",
    "--yes",
];

fn with(extra: &[&str]) -> Vec<String> {
    let mut all = words(BASE);
    all.extend(words(extra));
    all
}

fn without(flag: &str) -> Vec<String> {
    let mut all = Vec::new();
    let mut rest = BASE.iter();
    while let Some(word) = rest.next() {
        if *word == flag {
            if flag.starts_with("--") && flag != "--webhook" && flag != "--yes" {
                rest.next();
            }
            continue;
        }
        all.push(word.to_string());
    }
    all
}

fn refused(args: &[String]) -> String {
    match plan(args) {
        Err(Failure::Usage(message)) => message,
        Err(Failure::Store(e)) => panic!("store error {e}"),
        Ok(p) => panic!("accepted {p:?}"),
    }
}

fn base_plan() -> Plan {
    plan(&words(BASE)).unwrap_or_else(|_| panic!("the base create is refused"))
}

#[test]
fn only_a_create_with_on_takes_this_path() {
    assert!(wants(&words(&["create", "x", "--on", "cloud", "--webhook"])));
    assert!(wants(&words(&["new", "x", "--on=cloud"])));
    assert!(wants(&words(&["add", "x", "--webhook", "--on", "cloud"])));
    // `--target cloud --webhook` stays the Chief job; local creates and other verbs are untouched.
    assert!(!wants(&words(&["create", "x", "--webhook", "--target", "cloud", "--prompt", "p"])));
    assert!(!wants(&words(&["create", "x", "--every", "30m", "--prompt", "on"])));
    assert!(!wants(&words(&["list", "--on", "cloud"])));
    assert!(!wants(&[]));
}

#[test]
fn a_cloud_webhook_runs_a_prompt_only() {
    for (flag, value) in [
        ("--if", "true"),
        ("--watch", "tail -f x"),
        ("--every", "30m"),
        ("--command", "make"),
        ("--daily", "09:00"),
        ("--cron", "0 * * * *"),
    ] {
        let message = refused(&with(&[flag, value]));
        assert_eq!(
            message,
            messages().webhook_prompt_only.replace("{flag}", flag.trim_start_matches('-')),
            "{flag}"
        );
    }
    let message = refused(&with(&["--manual"]));
    assert_eq!(message, messages().webhook_prompt_only.replace("{flag}", "manual"));
}

#[test]
fn repo_from_and_prompt_are_required() {
    for flag in ["--repo", "--from", "--prompt"] {
        assert_eq!(
            refused(&without(flag)),
            messages().webhook_missing.replace("{flag}", flag.trim_start_matches('-')),
            "{flag}"
        );
    }
    assert_eq!(refused(&without("ci-fix")), messages().missing_word.replace("{what}", "NAME"));
}

#[test]
fn on_takes_cloud_and_needs_webhook() {
    let mut mars = words(BASE);
    mars[3] = "mars".into();
    assert_eq!(refused(&mars), messages().webhook_bad_on.replace("{value}", "mars"));
    assert_eq!(refused(&without("--webhook")), messages().webhook_needs_webhook);
}

#[test]
fn a_bad_repo_shape_is_refused() {
    for bad in ["acme", "acme/api/x", "acme/a pi", "/api", "acme/", "acme/api?x"] {
        let mut args = words(BASE);
        args[7] = bad.into();
        assert_eq!(refused(&args), messages().webhook_bad_repo.replace("{value}", bad), "{bad}");
    }
    for bad in ["vm/../x", "", "a b"] {
        let mut args = words(BASE);
        args[5] = bad.into();
        assert_eq!(refused(&args), messages().webhook_bad_machine.replace("{value}", bad), "{bad}");
    }
}

#[test]
fn from_without_yes_names_what_the_run_sees() {
    let message = refused(&without("--yes"));
    assert_eq!(
        message,
        messages().webhook_consent_needed.replace("{consent}", &consent_line("vm_src"))
    );
    let english = &crate::localization::catalog_for_locale("en").automation;
    let line = english.webhook_consent.replace("{machine}", "vm_src");
    assert!(line.contains("harness login"), "{line}");
    assert!(line.contains("checkouts"), "{line}");
    assert!(line.contains("credential"), "{line}");
    assert!(english.webhook_consent_needed.contains("--yes"));
}

#[test]
fn other_bad_values_are_usage_errors() {
    assert_eq!(
        refused(&with(&["--harness", "gemini"])),
        messages().webhook_bad_harness.replace("{value}", "gemini")
    );
    assert_eq!(
        refused(&with(&["--events", "ci_failure,push"])),
        messages().webhook_bad_event.replace("{value}", "push")
    );
    assert_eq!(
        refused(&with(&["--cwd", "work/api"])),
        messages().webhook_bad_cwd.replace("{value}", "work/api")
    );
    assert_eq!(
        refused(&with(&["--cooldown", "2d"])),
        messages().webhook_bad_cooldown.replace("{value}", "2d")
    );
    assert_eq!(
        refused(&with(&["--max-runs", "5000"])),
        messages().bad_max_runs.replace("{value}", "5000")
    );
    assert_eq!(
        refused(&with(&["--cooldown", "soon"])),
        messages().bad_duration.replace("{value}", "soon")
    );
    let mut dots = words(BASE);
    dots[0] = "!!!".into();
    assert_eq!(refused(&dots), messages().webhook_bad_name.replace("{value}", "!!!"));
}

#[test]
fn defaults_follow_the_rfd() {
    let p = base_plan();
    assert_eq!(p.name, "ci-fix");
    assert_eq!(p.from, "vm_src");
    assert_eq!(p.repository, "acme/api");
    assert_eq!(p.prompt, "Fix CI");
    assert_eq!(p.events, vec!["ci_failure"]);
    assert_eq!(p.cwd, "/root/api");
    assert_eq!(p.harness, "claude");
    assert_eq!(p.cooldown_seconds, 600);
    assert_eq!(p.max_runs, 24);
    assert_eq!(p.platform, None);
    assert_eq!(p.workspace(), "auto-ci-fix");
    assert_eq!(p.session(), "auto-ci-fix");
}

#[test]
fn flags_set_every_field() {
    let p = plan(&with(&[
        "--cwd",
        "/work/api",
        "--harness",
        "codex",
        "--events",
        "pr_opened, github.workflow_run.failed,pr_comment,pr_opened",
        "--cooldown",
        "30m",
        "--max-runs",
        "0",
        "--platform",
        "https://example.test",
    ]))
    .unwrap_or_else(|_| panic!("refused"));
    assert_eq!(p.cwd, "/work/api");
    assert_eq!(p.harness, "codex");
    // RFD 5.2's class names map to the stored kinds; a repeat is dropped.
    assert_eq!(p.events, vec!["pr_opened", "ci_failure", "pr_comment"]);
    assert_eq!(p.cooldown_seconds, 1_800);
    assert_eq!(p.max_runs, 0);
    assert_eq!(p.platform.as_deref(), Some("https://example.test"));
}

#[test]
fn slugs_are_lowercase_words_joined_by_dashes() {
    assert_eq!(slug("CI fix!"), "ci-fix");
    assert_eq!(slug("  Review -- PRs  "), "review-prs");
    assert_eq!(slug("!!!"), "");
    assert_eq!(slug(&"a".repeat(100)).len(), 48);
}

#[test]
fn the_client_key_is_the_same_for_the_same_automation() {
    let p = base_plan();
    let key = p.client_key();
    assert_eq!(key, base_plan().client_key());
    assert!(key.starts_with("auto-webhook-"), "{key}");
    let hex = &key["auto-webhook-".len()..];
    assert_eq!(hex.len(), 32);
    assert!(hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)), "{key}");
    // Flags that do not name the automation do not change it: a retried create reuses the fork.
    let retried = plan(&with(&["--cooldown", "1h", "--events", "pr_opened"]))
        .unwrap_or_else(|_| panic!("refused"));
    assert_eq!(retried.client_key(), key);
    // The repository's case does not either (GitHub names are case-insensitive).
    let mut upper = words(BASE);
    upper[7] = "Acme/API".into();
    assert_eq!(plan(&upper).unwrap_or_else(|_| panic!("refused")).client_key(), key);
    for (index, other) in [(0, "ci-fix-2"), (5, "vm_other"), (7, "acme/web")] {
        let mut args = words(BASE);
        args[index] = other.into();
        assert_ne!(plan(&args).unwrap_or_else(|_| panic!("refused")).client_key(), key, "{other}");
    }
}

#[test]
fn the_three_requests_are_exact() {
    let p = base_plan();
    let key = p.client_key();
    assert_eq!(fork_path(&p), "/v1/machines/vm_src/fork");
    assert_eq!(fork_body(&p), json!({"clientKey": key}));
    assert_eq!(bind_path(&p), "/v1/workspaces/auto-ci-fix/machine/import");
    assert_eq!(
        bind_body(&p, "vm_fork"),
        json!({"carrierMachine": "vm_fork", "expectedGeneration": 0, "clientKey": key})
    );
    assert_eq!(TRIGGERS_PATH, "/v1/triggers");
    assert_eq!(
        trigger_body(&p, "vm_fork"),
        json!({
            "repository": "acme/api",
            "prompt": "Fix CI",
            "events": ["ci_failure"],
            "target": {
                "machine": "vm_fork",
                "workspace": "auto-ci-fix",
                "session": "auto-ci-fix",
                "cwd": "/root/api",
                "harness": "claude",
                "policy": "start_session",
            },
            "guardrails": {"cooldownSeconds": 600, "maxRunsPerDay": 24},
        })
    );
    assert!(trigger_body(&p, "vm_fork").get("installation").is_none());
}

#[test]
fn match_sets_conditions_the_platform_takes() {
    let p = plan(&with(&[
        "--match",
        "branch=main,release",
        "--match",
        "workflow^=ci",
        "--match=actor!=dependabot",
        "--match",
        "labels~=agent",
        "--match",
        "pull_request>=100",
        "--match",
        "draft=false",
        "--match",
        "!draft",
        "--match",
        "base?",
        "--match",
        "actor!=a,b",
    ]))
    .unwrap_or_else(|_| panic!("refused"));
    assert_eq!(
        p.conditions,
        vec![
            json!({"path": "branch", "op": "in", "value": ["main", "release"]}),
            json!({"path": "workflow", "op": "prefix", "value": "ci"}),
            json!({"path": "actor", "op": "not_equals", "value": "dependabot"}),
            json!({"path": "labels", "op": "contains", "value": "agent"}),
            json!({"path": "pull_request", "op": "gte", "value": 100}),
            json!({"path": "draft", "op": "equals", "value": "false"}),
            json!({"path": "draft", "op": "missing"}),
            json!({"path": "base", "op": "exists"}),
            json!({"path": "actor", "op": "not_in", "value": ["a", "b"]}),
        ]
    );
    let body = trigger_body(&p, "vm_fork");
    assert_eq!(body["conditions"], Value::Array(p.conditions.clone()));
    // No --match sends no conditions: the trigger starts on every event, as before.
    assert!(trigger_body(&base_plan(), "vm_fork").get("conditions").is_none());
}

#[test]
fn a_webhook_source_takes_its_own_events_and_body_paths() {
    let p = plan(&with(&[
        "--source",
        "webhook",
        "--events",
        "deploy.failed,alert",
        "--match",
        "level=error,critical",
        "--match",
        "data.service^=api",
        "--match",
        "alerts.0.count>=3",
        "--match",
        "!data.muted",
    ]))
    .unwrap_or_else(|_| panic!("refused"));
    assert_eq!(p.source, "webhook");
    assert_eq!(p.events, vec!["deploy.failed", "alert"]);
    assert_eq!(
        p.conditions,
        vec![
            json!({"path": "level", "op": "in", "value": ["error", "critical"]}),
            json!({"path": "data.service", "op": "prefix", "value": "api"}),
            json!({"path": "alerts.0.count", "op": "gte", "value": 3}),
            json!({"path": "data.muted", "op": "missing"}),
        ]
    );
    let body = trigger_body(&p, "vm_fork");
    assert_eq!(body["source"], "webhook");
    assert_eq!(body["events"], json!(["deploy.failed", "alert"]));
    // GitHub stays the default, and its body names no source, exactly as before.
    assert!(trigger_body(&base_plan(), "vm_fork").get("source").is_none());
    let v = created(&p, "https://api.example.test", &registered());
    assert_eq!(
        v["url"],
        "https://api.example.test/v1/triggers/0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70/webhook"
    );
    assert_eq!(v["github_events"], json!([]));
    let text = human_lines(&p, &v).join("\n");
    assert!(text.contains("x-cmux-webhook-signature"), "{text}");
    assert!(text.contains("webhook fire 0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70"), "{text}");
    assert!(!text.contains("Workflow runs"), "{text}");
    // No --events: the body's event defaults to `webhook`, so that is what it takes.
    let plain = plan(&with(&["--source", "webhook"])).unwrap_or_else(|_| panic!("refused"));
    assert_eq!(plain.events, vec!["webhook"]);
}

#[test]
fn a_bad_webhook_source_is_a_usage_error() {
    assert_eq!(
        refused(&with(&["--source", "gitlab"])),
        messages().webhook_bad_source.replace("{value}", "gitlab")
    );
    for bad in ["has space", "x/y", ""] {
        let refusal = refused(&with(&["--source", "webhook", "--events", bad]));
        assert!(refusal.starts_with("--events"), "{bad}: {refusal}");
    }
    for bad in ["data..level=x", "level", "a.b.c.d.e.f.g.h.i=1", "level>x"] {
        assert_eq!(
            refused(&with(&["--source", "webhook", "--match", bad])),
            messages().webhook_bad_hook_match.replace("{value}", bad),
            "{bad}"
        );
    }
}

#[test]
fn a_bad_match_is_a_usage_error() {
    for bad in [
        "secret=x",
        "branch",
        "branch=",
        "branch>main",
        "pull_request>=ten",
        "branch=a,,b",
        "!secret",
        "data.level=error",
    ] {
        assert_eq!(
            refused(&with(&["--match", bad])),
            messages().webhook_bad_match.replace("{value}", bad),
            "{bad}"
        );
    }
    let many: Vec<&str> = (0..17).flat_map(|_| ["--match", "base?"]).collect();
    assert!(refused(&with(&many)).starts_with("--match"));
}

fn registered() -> Registered {
    Registered {
        machine: "vm_fork".into(),
        trigger: "0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70".into(),
        secret: "whsec_s3cret".into(),
    }
}

#[test]
fn the_answer_has_every_field_once() {
    let p = plan(&with(&["--events", "ci_failure,pr_review_comment"]))
        .unwrap_or_else(|_| panic!("refused"));
    let v = created(&p, "https://api.example.test", &registered());
    assert_eq!(
        v,
        json!({
            "id": "0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70",
            "name": "ci-fix",
            "machine": "vm_fork",
            "from": "vm_src",
            "workspace": "auto-ci-fix",
            "session": "auto-ci-fix",
            "repository": "acme/api",
            "events": ["ci_failure", "pr_review_comment"],
            "conditions": [],
            "source": "github",
            "url": "https://api.example.test/v1/triggers/0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70/github",
            "content_type": "application/json",
            "github_events": ["Workflow runs", "Pull request reviews", "Pull request review comments"],
            "secret": "whsec_s3cret",
            "secret_shown_once": true,
        })
    );
}

#[test]
fn the_human_lines_show_the_secret_once_with_its_warning_and_the_consent() {
    let p = base_plan();
    let v = created(&p, "https://api.example.test", &registered());
    let lines = human_lines(&p, &v);
    let text = lines.join("\n");
    assert_eq!(text.matches("whsec_s3cret").count(), 1, "{text}");
    assert_eq!(
        text.matches(
            "https://api.example.test/v1/triggers/0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70/github"
        )
        .count(),
        1
    );
    assert!(text.contains("vm_fork"), "{text}");
    assert!(text.contains("0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70"), "{text}");
    assert!(text.contains("application/json"), "{text}");
    assert!(text.contains("Workflow runs"), "{text}");
    assert_eq!(lines.iter().filter(|l| **l == messages().webhook_secret_once).count(), 1);
    assert_eq!(lines.iter().filter(|l| **l == consent_line("vm_src")).count(), 1);
    // Quiet keeps what cannot be read again: the URL and the secret.
    let quiet = quiet_lines(&v).join("\n");
    assert!(quiet.contains("whsec_s3cret") && quiet.contains("/github"), "{quiet}");
}

#[test]
fn a_stop_after_the_fork_names_the_step_and_keeps_the_machine() {
    let p = base_plan();
    let stop = Stopped {
        step: Step::Bind,
        machine: Some("vm_fork".into()),
        why: Why::Call(CallError::Status { status: 409, code: "", facts: None }),
    };
    let (error, exit, unknown) = stopped_error(&p, &stop);
    assert_eq!(exit, 1);
    assert!(!unknown);
    assert_eq!(error["code"], "automation.webhook.refused");
    assert_eq!(error["details"]["step"], "bind");
    assert_eq!(error["details"]["machine"], "vm_fork");
    assert!(error["message"].as_str().unwrap().contains("409"));

    let lost = Stopped {
        step: Step::Trigger,
        machine: Some("vm_fork".into()),
        why: Why::Call(CallError::Unreachable("timed out".into())),
    };
    let (error, exit, unknown) = stopped_error(&p, &lost);
    assert_eq!((exit, unknown), (3, true));
    assert_eq!(error["code"], "automation.webhook.unreachable");

    let signed_out = Stopped {
        step: Step::Fork,
        machine: None,
        why: Why::Call(CallError::Status { status: 401, code: "", facts: None }),
    };
    let (error, exit, _) = stopped_error(&p, &signed_out);
    assert_eq!(exit, 3);
    assert_eq!(error["code"], "automation.signed_out");
    assert!(error["details"].get("machine").is_none());

    let other = Stopped {
        step: Step::Bind,
        machine: Some("vm_fork".into()),
        why: Why::Bound("vm_old".into()),
    };
    let (error, exit, _) = stopped_error(&p, &other);
    assert_eq!(exit, 1);
    assert_eq!(error["code"], "automation.webhook.workspace_taken");
}

/// A fake platform that answers the requests in order with `replies` and keeps what it saw.
fn platform(replies: Vec<(u16, &'static str)>) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        let mut replies = replies.into_iter();
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 8192];
            loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                let text = String::from_utf8_lossy(&buffer).to_string();
                if let Some(end) = text.find("\r\n\r\n") {
                    let length = text[..end]
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if buffer.len() >= end + 4 + length {
                        break;
                    }
                }
                if n == 0 {
                    break;
                }
            }
            log.lock().unwrap().push(String::from_utf8_lossy(&buffer).to_string());
            let (status, reply) = replies.next().unwrap_or((500, "{}"));
            let _ = stream.write_all(
                format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
                    .as_bytes(),
            );
        }
    });
    (origin, seen)
}

fn body_of(request: &str) -> Value {
    serde_json::from_str(request.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("")).unwrap()
}

#[test]
fn create_forks_binds_and_registers_in_that_order() {
    let (origin, seen) = platform(vec![
        (200, r#"{"id":"vm_fork","provider":"cloud","state":"running"}"#),
        (
            200,
            r#"{"machineId":"vm_fork","generation":1,"provider":"cloud","connectionMachine":"vm_fork","reconnectRequired":true}"#,
        ),
        (
            200,
            r#"{"trigger":{"id":"0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70"},"secret":"whsec_s3cret"}"#,
        ),
    ]);
    let p = base_plan();
    let platform = Platform::new(origin, "tok".into(), Duration::from_secs(5))
        .unwrap_or_else(|_| panic!("no platform"));
    let done = register(&platform, &p).unwrap_or_else(|stop| panic!("stopped at {:?}", stop.step));
    assert_eq!(done.machine, "vm_fork");
    assert_eq!(done.trigger, "0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70");
    assert_eq!(done.secret, "whsec_s3cret");
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 3);
    assert!(seen[0].starts_with("POST /v1/machines/vm_src/fork "), "{}", seen[0]);
    assert!(seen[1].starts_with("POST /v1/workspaces/auto-ci-fix/machine/import "), "{}", seen[1]);
    assert!(seen[2].starts_with("POST /v1/triggers "), "{}", seen[2]);
    assert_eq!(body_of(&seen[0]), fork_body(&p));
    assert_eq!(body_of(&seen[1]), bind_body(&p, "vm_fork"));
    assert_eq!(body_of(&seen[2]), trigger_body(&p, "vm_fork"));
    for request in seen.iter() {
        let lower = request.to_ascii_lowercase();
        assert!(lower.contains("authorization: bearer tok"), "{request}");
        // The personal team: the workspace binding and the trigger's check both live there.
        assert!(!lower.contains("x-cmux-team"), "{request}");
    }
}

#[test]
fn a_refused_bind_stops_before_the_trigger() {
    let (origin, seen) = platform(vec![
        (200, r#"{"id":"vm_fork"}"#),
        (400, r#"{"code":"machine.turn_machine_conflict","message":"x"}"#),
    ]);
    let p = base_plan();
    let platform = Platform::new(origin, "tok".into(), Duration::from_secs(5))
        .unwrap_or_else(|_| panic!("no platform"));
    let Err(stop) = register(&platform, &p) else { panic!("registered") };
    assert_eq!(stop.step, Step::Bind);
    assert_eq!(stop.machine.as_deref(), Some("vm_fork"));
    assert_eq!(seen.lock().unwrap().len(), 2);
}

#[test]
fn rm_takes_a_trigger_id() {
    assert_eq!(
        trigger_id("0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70").ok(),
        Some("0b6c1a52-5f0e-4c1e-9d55-6f2f3e1a9b70")
    );
    assert!(trigger_id("../machines").is_err());
    assert!(trigger_id("trg_1").is_err());
}
