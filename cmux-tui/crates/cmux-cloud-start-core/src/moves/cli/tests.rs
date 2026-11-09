//! The CLI answers (moved from the app's `CloudMachineUpdateTargetTests`,
//! `CloudLegacyMachineUpdateTests` and the Swift `CloudMoveCLI`).

use super::*;
use serde_json::json;

fn output(stdout: &str, stderr: &str, status: i32) -> Output {
    Output { stdout: stdout.to_owned(), stderr: stderr.to_owned(), status }
}

#[test]
fn an_answer_is_the_last_json_line_and_anything_else_is_a_bad_answer() {
    let (answer, object) = parse(&output(
        "progress\n{\"ok\":true,\"session_id\":\"s\",\"transfer_id\":\"t\",\"conflicts\":[\"a\"]}\n\n",
        "",
        0,
    ));
    assert!(answer.ok && object.is_some());
    assert_eq!(answer.session_id.as_deref(), Some("s"));
    assert_eq!(answer.transfer_id.as_deref(), Some("t"));
    assert_eq!(answer.conflicts, ["a"]);
    let (crash, none) = parse(&output("", "  thread panicked\n", 101));
    assert!(none.is_none());
    assert_eq!(crash, Answer::failed(BAD_ANSWER, "thread panicked"));
    assert_eq!(parse(&output("{\"no\":1}", "", 9)).0, Answer::failed(BAD_ANSWER, "exit 9"));
    let (refused, _) = parse(&output(
        "{\"ok\":false,\"error_code\":\"machine_outdated\",\"side\":\"target\"}",
        "",
        1,
    ));
    assert_eq!(refused.error_code.as_deref(), Some("machine_outdated"));
    assert_eq!(refused.side.as_deref(), Some("target"));
    let (seed, _) = parse(&output(
        "{\"ok\":true,\"seed_state\":\"done\",\"seed_started_at\":3,\"seed_finished_at\":4.5}",
        "",
        0,
    ));
    assert_eq!((seed.seed_started_at, seed.seed_finished_at), (Some(3.0), Some(4.5)));
    let (refused, _) = parse(&output(
        "{\"ok\":false,\"error_code\":\"seed_refused\",\"fallback_code\":\"seed.needs_github\",\"install_url\":\"https://x.test\"}",
        "",
        1,
    ));
    assert_eq!(refused.fallback_code.as_deref(), Some("seed.needs_github"));
    assert_eq!(refused.install_url.as_deref(), Some("https://x.test"));
    // The app's Swift `Answer` decodes these names.
    let named = serde_json::to_value(&refused).unwrap();
    assert_eq!(named["fallbackCode"], "seed.needs_github");
    assert_eq!(named["installURL"], "https://x.test");
}

/// A `link machine update` success line must carry its outcome and exit 0; `{"ok":true}` alone,
/// or a success with a failing exit, is no answer, never "the machine needed nothing".
#[test]
fn a_success_line_without_its_outcome_is_no_answer() {
    let bundled = "a".repeat(40);
    let read = |object: Value, status: i32| {
        let stdout = object.to_string();
        let (answer, object) = parse(&output(&stdout, "", status));
        machine_update_answer(answer, object.as_ref(), status)
    };
    let code = |answer: Answer| answer.error_code;
    assert_eq!(code(read(json!({"ok": true}), 0)).as_deref(), Some(BAD_ANSWER));
    assert_eq!(code(read(json!({"ok": true, "updated": "yes"}), 0)).as_deref(), Some(BAD_ANSWER));
    assert_eq!(
        code(read(json!({"ok": true, "updated": true}), 0)).as_deref(),
        Some(BAD_ANSWER),
        "updated with no build"
    );
    assert_eq!(
        code(read(json!({"ok": true, "updated": true, "build": bundled}), 1)).as_deref(),
        Some(BAD_ANSWER)
    );
    let updated = read(json!({"ok": true, "updated": true, "build": bundled}), 0);
    assert_eq!(
        updated,
        Answer { ok: true, updated: true, build: Some(bundled), ..Answer::default() }
    );
    assert!(read(json!({"ok": true, "updated": false, "build": "b"}), 0).ok);
    assert_eq!(
        code(read(json!({"ok": false, "error_code": "machine_update_busy"}), 1)).as_deref(),
        Some("machine_update_busy")
    );
}

#[test]
fn only_an_update_or_an_end_the_cli_lost_may_have_restarted_the_daemon() {
    assert!(Answer { ok: true, updated: true, ..Answer::default() }.may_have_restarted_daemon());
    assert!(!Answer { ok: true, ..Answer::default() }.may_have_restarted_daemon());
    for code in [
        "machine_update_busy",
        "machine_unreachable",
        "machine_update_unavailable",
        "machine_update_download_failed",
        "machine_update_unsupported",
        "machine_update_foreign_daemon",
    ] {
        assert!(!Answer::failed(code, "").may_have_restarted_daemon(), "{code}");
    }
    assert!(Answer::failed("machine_update_rolled_back", "").may_have_restarted_daemon());
    assert!(Answer::failed(BAD_ANSWER, "").may_have_restarted_daemon());
}

#[test]
fn a_plan_names_its_machine_keys_and_setup_and_without_keys_is_no_answer() {
    let stdout = json!({"ok": true, "machine": "vm-1", "create_key": "c", "tab_key": "t", "target_pane": "p", "create_team": "team",
        "create_sent": true, "ensured": {"environment": {"id": "env-1"}, "setup": {"state": "running", "startedAt": 2, "has_script": true}}})
    .to_string();
    let (answer, object) = parse(&output(&stdout, "", 0));
    let (answer, plan) = start_chat_plan(answer, object.as_ref());
    assert!(answer.ok);
    assert_eq!(plan.machine.as_deref(), Some("vm-1"));
    assert_eq!((plan.create_key.as_str(), plan.tab_key.as_str()), ("c", "t"));
    assert!(plan.create_sent);
    assert_eq!(plan.environment_id.as_deref(), Some("env-1"));
    let setup = plan.setup.unwrap();
    assert_eq!(
        (setup.state.as_deref(), setup.started_at, setup.has_script),
        (Some("running"), Some(2.0), Some(true))
    );
    let (answer, object) =
        parse(&output("{\"ok\":true,\"new_name\":\"n\",\"create_key\":\"c\"}", "", 0));
    let (answer, plan) = start_chat_plan(answer, object.as_ref());
    assert_eq!(answer.error.as_deref(), Some("link start-chat plan answered ok without its keys"));
    assert_eq!(plan.new_name.as_deref(), Some("n"));
    let info =
        StartInfo::read(json!({"environment_id": "env-2", "setup": {}}).as_object().unwrap());
    assert_eq!(
        info,
        StartInfo { environment_id: Some("env-2".into()), setup: None },
        "an empty setup names nothing"
    );
}

#[test]
fn a_copy_is_an_answer_only_with_an_absolute_folder_holding_the_chat() {
    let read = |object: Value| {
        let (answer, object) = parse(&output(&object.to_string(), "", 0));
        start_chat_copy(answer, object.as_ref())
    };
    let (answer, copy) = read(
        json!({"ok": true, "chat": "/w/a/web", "folder": "/w/a", "copied": true, "source_trusted": true}),
    );
    assert!(answer.ok && copy.copied && copy.source_trusted);
    assert!(read(json!({"ok": true, "chat": "/w/a", "folder": "/w/a"})).0.ok);
    for bad in [
        json!({"ok": true, "chat": "/w/ab", "folder": "/w/a"}),
        json!({"ok": true, "chat": "w/a", "folder": "w/a"}),
        json!({"ok": true}),
    ] {
        let (answer, copy) = read(bad);
        assert_eq!(answer.error_code.as_deref(), Some(BAD_ANSWER));
        assert!(!copy.copied);
    }
    assert_eq!(
        read(json!({"ok": false, "error_code": "machine_outdated"})).0.error_code.as_deref(),
        Some("machine_outdated")
    );
}

#[test]
fn each_verb_carries_its_arguments() {
    let call = |value: Value| invocation(&serde_json::from_value(value).unwrap());
    let moved = call(
        json!({"verb": "agent-move", "from": "/a.sock", "surface": 7, "to": "/b.sock", "cwd": "/w",
        "sync": {"pull": false, "socket": "/s", "local": "/l", "remote": "/r"}, "askFirst": true, "vmKind": "owner", "toPid": 42}),
    );
    assert_eq!(
        moved.args,
        [
            "link",
            "agent",
            "move",
            "--from-socket",
            "/a.sock",
            "--surface",
            "7",
            "--to-socket",
            "/b.sock",
            "--cwd",
            "/w",
            "--interrupt",
            "--sync",
            "seed",
            "--sync-socket",
            "/s",
            "--sync-local",
            "/l",
            "--sync-remote",
            "/r",
            "--ask-first",
            "--vm-kind",
            "owner",
            "--to-pid",
            "42"
        ]
    );
    assert_eq!(agent_move_flags(None, false, None, None), ["--interrupt"]);
    let update =
        call(json!({"verb": "machine-update", "socket": "/s", "toBundled": true, "ifOlder": true}));
    assert_eq!(
        update.args,
        ["link", "machine", "update", "--socket", "/s", "--to-bundled", "--if-older"]
    );
    assert_eq!(update.min_timeout_seconds, Some(MACHINE_UPDATE_TIMEOUT_SECONDS));
    assert_eq!(
        call(json!({"verb": "machine-update", "socket": "/s", "ifOlder": true})).args,
        ["link", "machine", "update", "--socket", "/s"]
    );
    assert_eq!(call(json!({"verb": "machine-pin"})).timeout_seconds, Some(150));
    let release = call(json!({"verb": "start-chat-reservation", "release": true, "request": "{}"}));
    assert_eq!((release.args[2].as_str(), release.timeout_seconds), ("release", Some(15)));
    assert_eq!(
        call(json!({"verb": "start-chat-reservation", "release": false, "request": "{}"}))
            .timeout_seconds,
        Some(125)
    );
    let warm = call(json!({"verb": "start-chat-warm-spare", "request": "{}"}));
    assert_eq!(
        (&warm.args[..3], warm.timeout_seconds),
        (&["link".to_string(), "start-chat".into(), "warm-spare".into()][..], Some(95))
    );
    let copy = call(
        json!({"verb": "start-chat-copy", "key": "k", "account": "u/", "machine": "m", "socket": "/s", "local": "/l", "subpath": "",
        "workRoots": ["/home/cmux/work", "/root/work"], "acpmuxHome": "/h", "store": true}),
    );
    assert_eq!(
        copy.args[15..],
        [
            "--work-root",
            "/home/cmux/work",
            "--work-root",
            "/root/work",
            "--acpmux-home",
            "/h",
            "--store",
            "default"
        ]
    );
    let ask = call(
        json!({"verb": "start-chat-copy", "key": "k", "account": "u/", "machine": "m", "socket": "/s", "local": "/l", "subpath": "",
        "workRoots": ["/w"], "onSeedRefusal": "ask"}),
    );
    assert_eq!(ask.args[15..], ["--work-root", "/w", "--on-seed-refusal", "ask"]);
    let copies = call(
        json!({"verb": "start-chat-copy", "key": "k", "account": "u/", "machine": "m", "socket": "/s", "local": "/l", "subpath": "",
        "workRoots": ["/w"], "store": true, "onSeedRefusal": "copy"}),
    );
    assert_eq!(
        copies.args[15..],
        ["--work-root", "/w", "--store", "default", "--on-seed-refusal", "copy"]
    );
    let pin = call(json!({"verb": "start-chat-pin", "key": "k", "account": "a", "machine": "m"}));
    assert_eq!(
        pin.args,
        ["link", "start-chat", "pin", "--key", "k", "--account", "a", "--machine", "m"]
    );
    assert_eq!(
        call(json!({"verb": "bring-back-pull", "socket": "/s", "local": "/l", "remote": "/r"}))
            .args
            .last()
            .unwrap(),
        "--or-copy"
    );
}

#[test]
fn a_reservation_answer_is_its_object_else_a_bad_answers() {
    assert_eq!(
        read(Reading::Reservation, &output("{\"ok\":true,\"x\":1}", "", 0))["object"],
        json!({"ok": true, "x": 1})
    );
    assert_eq!(
        read(Reading::Reservation, &output("", "", 1))["object"],
        json!({"ok": false, "error_code": BAD_ANSWER})
    );
}

/// Each result line of the guest script as a `link machine update` answer.
#[test]
fn result_lines_map_to_answers() {
    let commit = "b".repeat(40);
    let code = |stdout: &str, exit: i64| {
        let run = ExecRun {
            exit_code: exit,
            stdout: stdout.to_owned(),
            stderr: "sudo: a password is required".to_owned(),
        };
        let answer = run.legacy_update_answer(&commit);
        if answer.ok {
            if answer.updated {
                format!("updated:{}", answer.build.unwrap_or_default())
            } else {
                "current".to_owned()
            }
        } else {
            answer.error_code.unwrap_or_default()
        }
    };
    assert_eq!(code("OK already-current daemon=9\n", 0), "current", "nothing restarted");
    assert_eq!(code("OK canary daemon=9 hosts-before=1\n", 0), format!("updated:{commit}"));
    assert_eq!(
        code("UNVERIFIED terminal count unavailable terminals=?->2 daemon=9\n", 0),
        format!("updated:{commit}")
    );
    assert_eq!(code("ROLLBACK lost-hosts=[12] old-daemon=7\n", 0), "machine_update_rolled_back");
    assert_eq!(code("FAIL rollback-daemon-unhealthy reason=x\n", 0), "machine_update_failed");
    assert_eq!(code("SKIP busy another upgrade run holds the lock\n", 0), "machine_update_busy");
    assert_eq!(
        code(&format!("SKIP changed binary={} expected={}\n", "2".repeat(40), "1".repeat(40)), 0),
        "machine_update_busy"
    );
    assert_eq!(code("SKIP no-daemon\n", 0), "machine_unreachable");
    assert_eq!(code("SKIP unsupported-cloud-auth\n", 0), "machine_update_unsupported");
    assert_eq!(code("SKIP disk-free=120MB\n", 0), "machine_update_busy");
    assert_eq!(code("NOROOT\n", 0), "machine_update_unsupported");
    assert_eq!(code("running\n", 0), "machine_update_unresolved");
    assert_eq!(code("", 0), "machine_update_unresolved");
    assert_eq!(
        code("", 124),
        "machine_update_unresolved",
        "the provider ended the wait; the run may go on"
    );
    assert_eq!(code("garbage", 124), "machine_update_unresolved");
    assert_eq!(code("garbage", 1), "machine_update_failed");
}

#[test]
fn a_failure_says_its_result_line_else_the_end_of_stderr() {
    let run = ExecRun { exit_code: 1, stdout: "\n".into(), stderr: "x".repeat(500) + "end" };
    assert_eq!(run.failure_detail().len(), 400);
    assert!(run.failure_detail().ends_with("end"));
    assert_eq!(
        ExecRun { exit_code: 0, stdout: "a\nstarted\n".into(), stderr: String::new() }.last_line(),
        "started"
    );
}
