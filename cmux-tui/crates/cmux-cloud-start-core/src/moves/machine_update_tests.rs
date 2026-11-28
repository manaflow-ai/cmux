//! Parity with the app's CloudMachineUpdateTargetTests, CloudLegacyMachineUpdateTests and
//! CloudMachineUpdateButtonTests, plus a case for every branch.

use super::*;

fn answer(ok: bool, code: Option<&str>, error: Option<&str>) -> Answer {
    Answer {
        ok,
        error_code: code.map(str::to_owned),
        error: error.map(str::to_owned),
        ..Answer::default()
    }
}

fn pin() -> Pin {
    Pin { commit: "b".repeat(40), sha256: "a".repeat(64) }
}

fn exec(exit_code: i64, stdout: &str, stderr: &str) -> ExecRun {
    ExecRun { exit_code, stdout: stdout.to_owned(), stderr: stderr.to_owned() }
}

#[test]
fn an_answer_maps_to_the_policys_outcome() {
    let mut newer = answer(true, None, None);
    newer.not_older = true;
    newer.updated = true;
    assert_eq!(outcome(&newer), Outcome::HandledElsewhere);
    let mut updated = answer(true, None, None);
    updated.updated = true;
    updated.build = Some("c".repeat(40));
    assert_eq!(outcome(&updated), Outcome::Updated { build: Some("c".repeat(40)) });
    assert_eq!(outcome(&answer(true, None, None)), Outcome::Current);
    for code in [
        "machine_update_busy",
        "machine_unreachable",
        "machine_update_unresolved",
        "machine_update_pending",
    ] {
        assert_eq!(outcome(&answer(false, Some(code), Some("x"))), Outcome::Busy, "{code}");
    }
    for code in ["machine_update_foreign_daemon", MACHINE_UPDATE_ABANDONED] {
        assert_eq!(
            outcome(&answer(false, Some(code), Some("someone's build"))),
            Outcome::Held { reason: "someone's build".into() }
        );
    }
    assert_eq!(
        outcome(&answer(false, Some("machine_update_foreign_daemon"), None)),
        Outcome::Held { reason: "machine_update_foreign_daemon".into() },
        "no error text: the code is the reason"
    );
    for code in ["machine_update_unavailable", "machine_update_download_failed"] {
        assert_eq!(
            outcome(&answer(false, Some(code), None)),
            Outcome::NeedsBinary { target: "x86_64-unknown-linux-gnu".into() }
        );
    }
    assert_eq!(
        outcome(&answer(false, Some("machine_update_unsupported"), Some("old"))),
        Outcome::Unsupported
    );
    assert_eq!(
        outcome(&answer(false, Some("machine_update_rolled_back"), Some("ROLLBACK x"))),
        Outcome::RolledBack { reason: "ROLLBACK x".into() }
    );
    assert_eq!(
        outcome(&answer(false, Some("boom"), Some("it broke"))),
        Outcome::Failed { reason: "it broke".into() }
    );
    assert_eq!(
        outcome(&answer(false, None, None)),
        Outcome::Failed { reason: "bad_answer".into() },
        "no code and no text: the bad answer's code"
    );
}

#[test]
fn a_build_names_a_commit_by_a_prefix_of_seven_or_more() {
    let hash = "0123456789abcdef0123456789abcdef01234567";
    assert!(same_commit(hash, "0123456"));
    assert!(same_commit(hash, "0123456789ABCDEF"));
    assert!(same_commit(hash, &format!("{hash}ff")));
    assert!(!same_commit(hash, "012345"));
    assert!(!same_commit(hash, "1123456"));
    assert!(!same_commit(hash, "0123456z"));
}

#[test]
fn an_update_is_held_to_the_build_it_asked_for() {
    let build = "0123456789abcdef0123456789abcdef01234567".to_owned();
    let mut updated = answer(true, None, None);
    updated.updated = true;
    updated.build = Some("0123456789ab".into());
    let ok =
        checked(&Ran { answer: Some(updated.clone()), build: build.clone(), ..Ran::default() });
    assert_eq!(ok.outcome, Outcome::Updated { build: Some("0123456789ab".into()) });
    assert!(ok.restarted);

    updated.build = Some("f".repeat(40));
    let other =
        checked(&Ran { answer: Some(updated.clone()), build: build.clone(), ..Ran::default() });
    assert_eq!(
        other.outcome,
        Outcome::Failed {
            reason: format!(
                "the machine reports build {} after the update, not {build}",
                "f".repeat(40)
            )
        }
    );
    // A DEV build's tree pin: the legacy update's pinned commit, which the machine then reports.
    let tree = checked(&Ran {
        answer: Some(updated),
        build: build.clone(),
        pinned: Some("f".repeat(40)),
        ..Ran::default()
    });
    assert_eq!(tree.outcome, Outcome::Updated { build: Some("f".repeat(40)) });

    let timed_out = checked(&Ran { timed_out: true, build: build.clone(), ..Ran::default() });
    assert_eq!(timed_out, Checked { outcome: Outcome::Busy, restarted: true });
    let threw = checked(&Ran {
        error: Some("spawn failed".into()),
        build: build.clone(),
        ..Ran::default()
    });
    assert_eq!(
        threw,
        Checked { outcome: Outcome::Failed { reason: "spawn failed".into() }, restarted: true }
    );
    let current = checked(&Ran { answer: Some(answer(true, None, None)), build, ..Ran::default() });
    assert_eq!(current.outcome, Outcome::Current);
    assert_eq!(current.restarted, answer(true, None, None).may_have_restarted_daemon());
}

#[test]
fn only_an_unsupported_answer_naming_its_build_runs_the_exec_update() {
    let mut unsupported = answer(false, Some("machine_update_unsupported"), Some("too old"));
    assert_eq!(legacy_judged(&unsupported), None, "no build named: not this way");
    unsupported.build = Some(String::new());
    assert_eq!(legacy_judged(&unsupported), None);
    unsupported.build = Some("c".repeat(40));
    assert_eq!(legacy_judged(&unsupported), Some("c".repeat(40).as_str()));
    let mut busy = answer(false, Some("machine_update_busy"), None);
    busy.build = Some("c".repeat(40));
    assert_eq!(legacy_judged(&busy), None);
}

#[test]
fn the_update_buttons_stop() {
    assert_eq!(stop(&answer(true, None, None)), Stop::None);
    assert_eq!(
        stop(&answer(false, Some("machine_update_unsupported"), Some("x"))),
        Stop::Unsupported
    );
    assert_eq!(
        stop(&answer(false, Some("machine_update_unavailable"), Some("x"))),
        Stop::Unavailable
    );
    assert_eq!(
        stop(&answer(false, Some("machine_update_failed"), Some("disk full"))),
        Stop::Failed { detail: "disk full".into() }
    );
    assert_eq!(
        stop(&answer(false, Some("machine_update_failed"), None)),
        Stop::Failed { detail: "machine_update_failed".into() }
    );
    assert_eq!(stop(&answer(false, None, None)), Stop::Failed { detail: String::new() });
}

#[test]
fn base64_matches_foundation() {
    assert_eq!(base64(b""), "");
    assert_eq!(base64(b"f"), "Zg==");
    assert_eq!(base64(b"fo"), "Zm8=");
    assert_eq!(base64(b"foo"), "Zm9v");
    assert_eq!(base64(b"echo guest\n"), "ZWNobyBndWVzdAo=");
    assert_eq!(base64(&[0xff, 0xfe, 0x00]), "//4A");
}

#[test]
fn the_install_downloads_the_pin_and_checks_it() {
    let install = install_command(&pin());
    let commit = "b".repeat(40);
    let sha = "a".repeat(64);
    assert!(install.contains(&format!(
        "'https://files.cmux.com/cmux-tui/{commit}/cmux-tui-x86_64-unknown-linux-musl'"
    )));
    assert!(install.contains(&format!("printf '%s  %s\\n' {sha} \"$tmp\" | sha256sum -c")));
    assert!(install.contains(&format!("if [ -x \"$bin\" ] && printf '%s  %s\\n' {sha} \"$bin\"")));
    assert!(install.starts_with("set -eu\nif id -u cmux"));
    assert!(install.ends_with("\"$bin\" --version\n"));
    assert_eq!(unit("0123456789abcdef"), "cmux-app-tui-update-0123456789abcdef");
}

#[test]
fn the_start_writes_its_files_and_starts_detached() {
    let start = start_command(&pin(), "echo guest\n", "0123456789abcdef", DIRECTORY, None);
    assert!(start.contains(r#"r="$d/app-0123456789abcdef""#));
    assert!(start.contains("d=/var/lib/cmux-tui-upgrade;"));
    assert!(start.contains(&base64(install_command(&pin()).as_bytes())));
    assert!(start.contains(&format!(
        "echo {} | base64 -d | root tee \"$r/upgrade.sh\" >/dev/null",
        base64(b"echo guest\n")
    )));
    assert!(start.contains(&format!(
        "systemd-run --quiet --collect --unit=cmux-app-tui-update-0123456789abcdef /bin/sh \"$r/upgrade.sh\" {} {} \"$r\"",
        "a".repeat(64),
        "b".repeat(40)
    )));
    assert!(!start.contains("--wait"), "the start exec waits for nothing");
    assert!(start.ends_with("fi\necho started"));
    assert!(!start.contains("expect-build"));
    assert!(
        !start_command(&pin(), "", "c", DIRECTORY, Some("not-hex; rm -rf /"))
            .contains("expect-build")
    );
    let held = start_command(&pin(), "", "c", DIRECTORY, Some(&"C".repeat(40)));
    assert!(held.contains(&format!(
        "echo {} | base64 -d | root tee \"$r/expect-build\" >/dev/null",
        base64(format!("{}\n", "c".repeat(40)).as_bytes())
    )));
}

#[test]
fn the_wait_reads_the_runs_result() {
    let wait = wait_command("n", "/d", 270);
    assert!(wait.contains("r=/d/app-n\n"));
    assert!(wait.contains("root timeout 270 tail --pid=\"$pid\""));
    assert!(wait.contains(r#"if [ "${pid:-0}" -gt 0 ]"#));
    assert!(wait.ends_with(r#"printf '%s\n' "$line""#));
}

/// Runs the plan against `answers` (none: the exec threw) and gives the execs made and the answer.
fn run(plan: Plan, answers: &[Option<ExecRun>]) -> (Vec<(String, u64)>, Answer) {
    let mut made = Vec::new();
    let mut step = begin(&plan);
    let mut answers = answers.iter();
    loop {
        match step {
            Step::Done { answer } => return (made, answer),
            Step::Exec { command, timeout_ms, state } => {
                made.push((command, timeout_ms));
                let ran = answers.next().cloned().flatten();
                step = advance(state, ran.as_ref());
            }
        }
    }
}

fn plan() -> Plan {
    Plan {
        pin: pin(),
        script: "echo guest\n".into(),
        nonce: "0123456789abcdef".into(),
        directory: None,
        wait_seconds: None,
        waits: None,
        expected: None,
    }
}

#[test]
fn the_run_starts_detached_then_waits_for_its_result() {
    let (made, answer) = run(
        plan(),
        &[
            Some(exec(0, "started\n", "")),
            Some(exec(
                124,
                "",
                "cmux: the command did not exit within 290s; it may still be running",
            )),
            Some(exec(0, "running\n", "")),
            Some(exec(0, "OK upgraded terminals=3->3 daemon=812 hosts-before=3\n", "")),
        ],
    );
    assert_eq!(
        answer,
        Answer { ok: true, updated: true, build: Some("b".repeat(40)), ..Answer::default() }
    );
    assert_eq!(
        made.iter().map(|(_, ms)| *ms).collect::<Vec<_>>(),
        [60_000, 290_000, 290_000, 290_000]
    );
    assert_eq!(
        made[0].0,
        start_command(&pin(), "echo guest\n", "0123456789abcdef", DIRECTORY, None)
    );
    for (command, _) in &made[1..] {
        assert_eq!(*command, wait_command("0123456789abcdef", DIRECTORY, WAIT_SECONDS));
    }
}

#[test]
fn a_start_or_run_with_no_outcome_is_unresolved() {
    let (made, lost) = run(plan(), &[]);
    assert_eq!(lost.error_code.as_deref(), Some("machine_update_unresolved"));
    assert_eq!(lost.error.as_deref(), Some("the machine's update did not end within 27 minutes"));
    assert_eq!(made.len(), 7, "a start that did not answer is waited on");

    let mut three = plan();
    three.waits = Some(3);
    let mut answers = vec![Some(exec(0, "started\n", ""))];
    answers.extend(std::iter::repeat_n(Some(exec(0, "running\n", "")), 3));
    let (made, running) = run(three, &answers);
    assert_eq!(running.error_code.as_deref(), Some("machine_update_unresolved"));
    assert_eq!(made.len(), 4);

    let (made, no_root) = run(plan(), &[Some(exec(0, "NOROOT\n", ""))]);
    assert_eq!(no_root.error_code.as_deref(), Some("machine_update_unsupported"));
    assert_eq!(made.len(), 1);
}

#[test]
fn a_start_the_provider_ended_is_waited_on_and_a_refused_one_fails() {
    let (_, ended) = run(
        plan(),
        &[
            Some(exec(124, "", "the command did not exit within 60s; it may still be running")),
            Some(exec(0, "ROLLBACK lost-hosts=[12] old-daemon=7\n", "")),
        ],
    );
    assert_eq!(ended.error_code.as_deref(), Some("machine_update_rolled_back"));

    let (made, refused) =
        run(plan(), &[Some(exec(1, "", "base64: invalid input")), Some(exec(0, "\n", ""))]);
    assert_eq!(refused.error_code.as_deref(), Some("machine_update_failed"));
    assert_eq!(refused.error.as_deref(), Some("base64: invalid input"));
    assert_eq!(made.len(), 2, "one wait for a run that never began");

    let (made, refused_then_lost) = run(plan(), &[Some(exec(1, "nope\n", ""))]);
    assert_eq!(refused_then_lost.error.as_deref(), Some("nope"));
    assert_eq!(made.len(), 2);
}

#[test]
fn a_run_with_no_waits_is_unresolved_at_once() {
    let mut none = plan();
    none.waits = Some(0);
    none.directory = Some("/tmp/x".into());
    let (made, answer) = run(none, &[Some(exec(0, "started\n", ""))]);
    assert_eq!(made.len(), 1);
    assert!(made[0].0.contains("d=/tmp/x;"));
    assert_eq!(answer.error.as_deref(), Some("the machine's update did not end within 0 minutes"));
}

#[test]
fn the_state_round_trips_through_the_app() {
    let Step::Exec { state, .. } = begin(&plan()) else { panic!("starts with an exec") };
    let json = serde_json::to_value(&state).unwrap();
    assert_eq!(json["waitSeconds"], 270);
    assert_eq!(json["started"], false);
    let back: State = serde_json::from_value(json).unwrap();
    assert_eq!(back, state);
}
