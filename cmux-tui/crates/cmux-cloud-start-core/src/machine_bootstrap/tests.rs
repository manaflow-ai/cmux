//! The bootstrap start and the run's end (moved from the app's `CloudMachineConfigTests`,
//! `CloudMachineRepoTests+Completion` and `CloudNewMachineTests`).

use super::*;

fn repo() -> Repo {
    Repo::new("o", "r")
}

const CLONE: &str = "/home/cmux/work/r";

fn answer(status: Option<&str>, lock: &str, now: i64) -> ExecAnswer {
    let body = status.map(|s| format!("{s}\n")).unwrap_or_default();
    ExecAnswer {
        exit_code: 0,
        stdout: format!("cmux-wait {lock} {now}\n{body}"),
        stderr: String::new(),
    }
}

fn free(status: &str) -> ExecAnswer {
    answer(Some(status), "free", 1000)
}

fn status(state: &str, code: &str, repo: &str, at: i64, late: bool, step: Option<&str>) -> String {
    let extra = format!(
        "{}{}",
        if late { r#","late":true"# } else { "" },
        step.map(|s| format!(r#","step":"{s}""#)).unwrap_or_default()
    );
    format!(
        r#"{{"state":"{state}","exit_code":{code},"script_sha256":"a","start_sha256":"b","repo":{repo},"at":{at}{extra}}}"#
    )
}

fn plain(state: &str, code: &str, repo: &str) -> String {
    status(state, code, repo, 990, false, None)
}

fn repo_status(status: &str) -> String {
    format!(
        r#"{{"status":"{status}","url":"https://github.com/o/r.git","ref":"","dir":"/home/cmux/work/r","credential":"none","sha":"abc"}}"#
    )
}

/// The wait's loop as the app runs it: each answer in order, until one ends it or three fail.
fn run(repo: Option<Repo>, answers: Vec<Result<ExecAnswer, &str>>) -> (Run, usize) {
    let mut failures = 0;
    for (index, answer) in answers.iter().enumerate() {
        let (answer, error) = match answer {
            Ok(a) => (Some(a.clone()), None),
            Err(e) => (None, Some((*e).to_owned())),
        };
        let next = wait_next(&WaitRead { answer, error, failures, repo: repo.clone() });
        if let Some(run) = next.ended {
            return (run, index + 1);
        }
        failures = next.failures;
        if let Some(run) = next.unreachable {
            return (run, index + 1);
        }
    }
    (Run::StillRunning, answers.len())
}

fn finished(path: Option<&str>) -> Run {
    Run::Finished { repo_path: path.map(str::to_owned) }
}

#[test]
fn a_finished_run_gives_the_clone_path_or_none_without_a_repo() {
    let cloned = plain("done", "0", &repo_status("cloned"));
    assert_eq!(run(Some(repo()), vec![Ok(free(&cloned))]), (finished(Some(CLONE)), 1));
    let kept = plain("done", "0", &repo_status("kept"));
    assert_eq!(run(Some(repo()), vec![Ok(free(&kept))]).0, finished(Some("/home/cmux/work/r")));
    assert_eq!(run(None, vec![Ok(free(&plain("done", "0", "null")))]).0, finished(None));
    // A relative `dir` is not a path: the repo's own folder under the work user's home.
    let relative = plain("done", "0", r#"{"status":"cloned","dir":"work/r"}"#);
    assert_eq!(run(Some(repo()), vec![Ok(free(&relative))]).0, finished(Some(CLONE)));
}

#[test]
fn each_failure_says_why() {
    let needs = plain("failed", "3", &repo_status("needs_github"));
    assert_eq!(
        run(Some(repo()), vec![Ok(free(&needs))]).0,
        Run::NeedsGitHub { repo: "o/r".into() }
    );
    let clone = plain("failed", "1", &repo_status("failed"));
    assert_eq!(run(Some(repo()), vec![Ok(free(&clone))]).0, Run::RepoFailed { repo: "o/r".into() });
    let script = plain("failed", "7", "null");
    assert_eq!(run(None, vec![Ok(free(&script))]).0, Run::ScriptFailed { exit_code: 7 });
    let late = status("failed", "75", "null", 990, true, None);
    assert_eq!(run(Some(repo()), vec![Ok(free(&late))]).0, Run::RunnerNeverCame, "a minute late");
    let own = plain("failed", "75", "null");
    assert_eq!(run(None, vec![Ok(free(&own))]).0, Run::ScriptFailed { exit_code: 75 });
    // The runner says which step failed: a script that exits 3 after a needs_github repo step is
    // the script's failure, the repo step's retry after it is the repo's, and a late refusal wins
    // over any repo status.
    let needs_github = repo_status("needs_github");
    let by_script = status("failed", "3", &needs_github, 990, false, Some("script"));
    assert_eq!(run(Some(repo()), vec![Ok(free(&by_script))]).0, Run::ScriptFailed { exit_code: 3 });
    let by_repo = status("failed", "3", &needs_github, 990, false, Some("repo"));
    assert_eq!(
        run(Some(repo()), vec![Ok(free(&by_repo))]).0,
        Run::NeedsGitHub { repo: "o/r".into() }
    );
    let late_repo = status("failed", "75", &repo_status("failed"), 990, true, None);
    assert_eq!(run(Some(repo()), vec![Ok(free(&late_repo))]).0, Run::RunnerNeverCame);
    let starting = status("starting", "null", "null", 1000, false, None);
    assert_eq!(
        run(Some(repo()), vec![Ok(answer(Some(&starting), "free", 1100))]).0,
        Run::RunnerNeverCame
    );
    assert_eq!(run(Some(repo()), vec![Ok(answer(None, "free", 1000))]).0, Run::RunnerNeverCame);
    let running = plain("running", "null", "null");
    assert_eq!(run(Some(repo()), vec![Ok(free(&running))]).0, Run::Stopped, "under a free lock");
    // `running` with no `alive` yet raced the runner making it: read again, and the next read sees
    // the run.
    let done = plain("done", "0", &repo_status("cloned"));
    assert_eq!(
        run(Some(repo()), vec![Ok(answer(Some(&running), "none", 1000)), Ok(free(&done))]),
        (finished(Some(CLONE)), 2)
    );
    // Without a repo of its own, the clone's URL names a failed repo step.
    assert_eq!(
        run(None, vec![Ok(free(&clone))]).0,
        Run::RepoFailed { repo: "https://github.com/o/r.git".into() }
    );
}

#[test]
fn a_read_cut_off_while_the_runner_runs_is_issued_again() {
    let running = plain("running", "null", "null");
    let starting = status("starting", "null", "null", 995, false, None);
    let done = plain("done", "0", &repo_status("cloned"));
    let answers = vec![
        Ok(answer(Some(&running), "held", 1000)),
        Err("timed out"),
        Ok(free(&starting)),
        Ok(free(&done)),
    ];
    assert_eq!(run(Some(repo()), answers), (finished(Some(CLONE)), 4));
    let unreachable = run(Some(repo()), vec![Err("a"), Err("b"), Err("timed out")]);
    assert_eq!(unreachable, (Run::Unreachable { error: "timed out".into() }, 3));
    let unreadable = ExecAnswer { exit_code: 0, stdout: "nonsense".into(), stderr: String::new() };
    let three = vec![Ok(unreadable.clone()), Ok(unreadable.clone()), Ok(unreadable)];
    assert_eq!(run(None, three), (Run::Unreachable { error: "unreadable answer".into() }, 3));
    // A read that says read again starts the count over.
    let held = answer(Some(&running), "held", 1000);
    let reset = vec![Err("a"), Err("b"), Ok(held), Err("c"), Err("d")];
    assert_eq!(run(None, reset), (Run::StillRunning, 5));
}

#[test]
fn an_answer_that_says_nothing_is_unreadable() {
    let failed =
        ExecAnswer { exit_code: 1, stdout: "cmux-wait free 1\n".into(), stderr: String::new() };
    assert_eq!(read(&failed, None), Read::Unreadable);
    for stdout in [
        "cmux-wait free\n",
        "cmux-wait free x\n",
        "cmux-wait free 1\n[1]\n",
        "cmux-wait free 1\n{}\n",
    ] {
        let ran = ExecAnswer { exit_code: 0, stdout: stdout.into(), stderr: String::new() };
        assert_eq!(read(&ran, None), Read::Unreadable, "{stdout:?}");
    }
    let other = plain("paused", "null", "null");
    assert_eq!(read(&free(&other), None), Read::Unreadable);
    // Lines before the head (a login banner) are skipped.
    let banner = ExecAnswer {
        exit_code: 0,
        stdout: format!("welcome\ncmux-wait free 1000\n{}\n", plain("done", "0", "null")),
        stderr: String::new(),
    };
    assert_eq!(read(&banner, None), Read::Ended(finished(None)));
}

#[test]
fn the_read_blocks_on_the_runners_lock_and_never_loops_on_the_machine() {
    let command = wait_command();
    assert!(command.contains(r#"exec 8<"$d/alive"; then if flock -s -w 15 8; then w=free; n=$(date +%s); s=$(cat "$d/status.json""#));
    let starting = command.find("then sleep 1; fi").unwrap();
    let locked = command.find("flock -s").unwrap();
    assert!(starting < locked, "a `starting` read waits before it takes the lock");
    assert!(!command.contains("while") && !command.contains("until"));
    assert!(runner().contains("exec 8>\"$d/alive\"\nflock 8\n"));
}

#[test]
fn a_bootstrap_start_waits_for_a_running_apply_and_never_reruns_a_done_script() {
    let start = start_command(&staging_directory("ab"));
    let at = |needle: &str| start.find(needle).unwrap_or_else(|| panic!("{needle}"));
    let order = [
        at("flock -w 15 7"),
        at("flock -n 6"),
        at(r#""\"state\":\"done\".*"#),
        at(r#"printf '{"state":"starting""#),
        at("exec 6<&-"),
        at("systemd-run"),
    ];
    assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{order:?}");
    assert!(runner().contains(r#"if grep -q "\"state\":\"done\".*"#));
    assert!(start.contains("7<&-"), "the setsid runner never inherits start.lock");
    assert!(
        runner().contains(r#"exec 8>"$d/alive""#),
        "the runner holds `alive` for its whole life"
    );
    assert!(runner().contains(r#"[ -f "$d/alive" ] && [ ! -L "$d/alive" ] || rm -f "$d/alive""#));
    assert!(start.contains(r#"[ -f "$d/start.lock" ] && [ ! -L "$d/start.lock" ]"#));
}

#[test]
fn the_runner_retries_the_repo_step_only_after_needing_github() {
    let runner = runner();
    assert!(runner.starts_with("#!/bin/sh\n# cmux machine bootstrap runner"));
    assert!(runner.ends_with("exit \"$code\""), "the text ends as it always did, with no newline");
    assert!(runner.contains(&format!(r#"[ "$repo_code" -ne {NEEDS_GITHUB_EXIT} ]"#)));
}

#[test]
fn a_start_uploads_into_its_own_folder_then_starts() {
    let request = StartRequest {
        kind: Kind::Lane,
        name: Some("lane-vm-1".into()),
        repo: Some(repo()),
        start_id: "1234abcd-ef00-0000-0000-000000000000".into(),
    };
    let plan = start_plan(&request);
    let staged = format!("{DIRECTORY}/in-1234abcd-ef00-0000-0000-000000000000");
    assert_eq!(
        plan.steps.first(),
        Some(&Step::Exec { command: prepare_command(&staged), said: vec![] })
    );
    let writes: Vec<(String, u32)> = plan
        .steps
        .iter()
        .filter_map(|step| match step {
            Step::Write { path, mode, .. } => {
                Some((path.trim_start_matches(&staged).to_owned(), *mode))
            }
            Step::Exec { .. } => None,
        })
        .collect();
    let expected = [
        ("/script", 0o700),
        ("/env", 0o600),
        ("/run", 0o700),
        ("/repo.json", 0o644),
        ("/repo", 0o700),
    ];
    assert_eq!(writes, expected.map(|(p, m)| (p.to_owned(), m)));
    assert!(matches!(
        &plan.steps[1],
        Step::Write { payload: Some(Payload::Script), text: None, .. }
    ));
    assert!(matches!(&plan.steps[2], Step::Write { text: Some(env), .. }
        if env == "export CMUX_MACHINE_NAME='lane-vm-1'\nexport LANE_VM_NAME='lane-vm-1'\n"));
    assert!(matches!(&plan.steps[4], Step::Write { text: Some(r), .. } if *r == repo().record()));
    assert!(matches!(&plan.steps[5], Step::Write { text: Some(r), .. } if *r == repo().step()));
    assert_eq!(
        plan.steps.last(),
        Some(&Step::Exec {
            command: start_command(&staged),
            said: vec!["started".into(), "running".into(), "skipped".into()]
        })
    );
    // No repo: `null` and a no-op step, so nothing of an earlier start is left.
    let bare = start_plan(&StartRequest {
        kind: Kind::Plain,
        name: None,
        repo: None,
        start_id: "x".into(),
    });
    assert!(matches!(&bare.steps[2], Step::Write { text: Some(env), .. } if env.is_empty()));
    assert!(matches!(&bare.steps[4], Step::Write { text: Some(r), .. } if r == "null\n"));
    assert!(matches!(&bare.steps[5], Step::Write { text: Some(r), .. } if r == NO_SCRIPT));
}

#[test]
fn names_are_quoted_and_upload_folders_keep_only_uuid_characters() {
    assert_eq!(environment(Kind::Plain, Some("it's")), "export CMUX_MACHINE_NAME='it'\\''s'\n");
    assert_eq!(environment(Kind::Lane, None), "");
    assert_eq!(staging_directory("AB-12; rm -rf /"), format!("{DIRECTORY}/in-AB-12-f"));
}

#[test]
fn an_exec_says_how_the_start_went_in_its_last_line() {
    let said: Vec<String> = ["started", "running", "skipped"].map(String::from).to_vec();
    let ran = |code, out: &str, err: &str| ExecAnswer {
        exit_code: code,
        stdout: out.into(),
        stderr: err.into(),
    };
    assert_eq!(step_outcome(&ran(0, "", ""), &[]), None, "a step with no word only has to succeed");
    assert_eq!(step_outcome(&ran(1, "out", ""), &[]), Some(Outcome::failed("out".into())));
    assert_eq!(step_outcome(&ran(1, "out", "err"), &[]), Some(Outcome::failed("err".into())));
    let started = step_outcome(&ran(0, "noise\nstarted\n\n", ""), &said);
    assert_eq!(started, Some(Outcome { status: "started".into(), reason: None }));
    assert_eq!(step_outcome(&ran(0, "skipped\r\n", ""), &said).unwrap().status, "skipped");
    assert_eq!(step_outcome(&ran(0, "done\n", ""), &said), Some(Outcome::failed("done\n".into())));
    assert_eq!(
        step_outcome(&ran(2, "started\n", "no sudo"), &said),
        Some(Outcome::failed("no sudo".into()))
    );
    let long = "é".repeat(600);
    let reason = step_outcome(&ran(1, "", &long), &[]).unwrap().reason.unwrap();
    assert_eq!(reason.chars().count(), 500, "the last 500 characters, never a cut character");
}

#[test]
fn the_wire_shapes_are_the_apps() {
    let run = serde_json::to_value(finished(Some(CLONE))).unwrap();
    assert_eq!(run, serde_json::json!({"run": "finished", "repoPath": CLONE}));
    let failed = serde_json::to_value(Run::ScriptFailed { exit_code: 7 }).unwrap();
    assert_eq!(failed, serde_json::json!({"run": "scriptFailed", "exitCode": 7}));
    assert_eq!(
        serde_json::to_value(Run::RunnerNeverCame).unwrap(),
        serde_json::json!({"run": "runnerNeverCame"})
    );
    let write = serde_json::to_value(
        &start_plan(&StartRequest {
            kind: Kind::Plain,
            name: None,
            repo: None,
            start_id: "a".into(),
        })
        .steps[1],
    )
    .unwrap();
    assert_eq!(
        write,
        serde_json::json!({"kind": "write", "path": format!("{DIRECTORY}/in-a/script"), "mode": 0o700, "payload": "script"})
    );
}

/// Every command and the runner are shell `sh -n` takes (where the host has a shell).
#[test]
fn the_shell_parses() {
    let staged = staging_directory("ab");
    for text in
        [prepare_command(&staged), start_command(&staged), wait_command(), runner().to_owned()]
    {
        let Ok(out) = std::process::Command::new("sh").arg("-n").arg("-c").arg(&text).output()
        else {
            return;
        };
        assert!(out.status.success(), "{}\n{}", String::from_utf8_lossy(&out.stderr), text);
    }
}

#[test]
fn every_machine_command_names_the_work_user() {
    let staged = staging_directory("ab");
    assert!(prepare_command(&staged).contains("root chown -h cmux:cmux"));
    let start = start_command(&staged);
    assert!(start.contains(r#"--uid="$u""#));
    assert!(
        start.contains(r#"as_u env HOME="$h" setsid"#),
        "the fallback runs as the work user too"
    );
    assert!(start.contains(r#"as_u mv -f "$s/$f" "$d/$f""#), "the files move as the work user");
    assert_eq!(
        staging_directory("zz; ~/.."),
        format!("{DIRECTORY}/in-"),
        "only an id's own characters"
    );
}

#[test]
fn the_runner_clones_first_and_retries_after_a_script_that_sets_up_github() {
    let runner = runner();
    let at = |text: &str, needle: &str| text.find(needle).unwrap_or_else(|| panic!("{needle}"));
    assert!(at(runner, "repo_step\n") < at(runner, r#""$d/script" >>"#));
    assert!(runner.contains(
        r#"if [ "$code" -eq 0 ] && [ "$repo_code" -ne 0 ]; then repo_step; code=$?; step=repo; fi"#
    ));
    assert!(runner.contains(r#""repo":%s"#));
    assert!(
        runner.contains(r#""script_sha256":"%s","start_sha256":"%s","repo":%s"#)
            && runner.contains(r#"sum=$(sha256sum "$d/script" | cut -d' ' -f1)"#),
        "script_sha256 stays the script's own digest; the repo step only joins start_sha256"
    );
    assert!(runner.contains(r#"if grep -q "\"state\":\"done\".*\"start_sha256\":\"$key\"""#));
    let start = start_command(&staging_directory("ab"));
    let held = at(&start, "flock -n 6");
    let moved = at(&start, r#"as_u mv -f "$s/$f" "$d/$f""#);
    let released = at(&start, "exec 6<&-");
    assert!(held < moved && moved < released, "files move only under the runner's lock");
    assert!(start.contains(r#"flock -n 6 || { as_u rm -rf "$s" || true; echo running; exit 0; }"#));
    let fresh = at(&start, r#"-lt 60 ]; then as_u rm -rf "$s" || true; echo running"#);
    assert!(
        held < fresh && fresh < moved,
        "an earlier start's runner that has not taken over keeps its files"
    );
    let alive = at(runner, "flock 8\n") + "flock 8\n".len();
    let late = at(runner, "-ge 60 ]; then");
    let running = at(runner, "status running null");
    assert!(alive <= late && late < running);
    assert!(runner.contains(r#"status failed 75 ',"late":true'; exit 75"#));
    assert!(!runner.contains("start.lock"), "the runner never waits on start.lock");
}

/// cmux#38364: an identical start runs again when its background fill failed since, and only
/// then: both the start command and the runner skip it otherwise.
#[cfg(unix)]
#[test]
fn an_identical_start_runs_again_only_after_its_fill_failed() {
    let runner = runner();
    assert!(runner.contains(FILL_FAILED));
    assert!(runner.contains(r#"2>/dev/null && ! fill_failed; then exit 0; fi"#));
    assert!(start_command("x").contains(&format!("{FILL_FAILED}; if grep -q")));
    let scratch = std::env::temp_dir().join(format!("cmux-fill-failed-{}", std::process::id()));
    std::fs::create_dir_all(scratch.join("bin")).unwrap();
    let cmux = scratch.join("bin/cmux-tui");
    let stub = "#!/bin/sh\n[ \"$1 $2 $3 $4\" = \"repo wait /w/r 0\" ] || exit 2\nexit \"$CODE\"\n";
    std::fs::write(&cmux, stub).unwrap();
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:/usr/bin:/bin", scratch.join("bin").display());
    let failed = |fill: &str, code: &str| {
        let status = format!(r#"{{"status":"cloned","dir":"/w/r","fill":"{fill}"}}"#);
        std::fs::write(scratch.join("repo-status.json"), status).unwrap();
        let script =
            format!("d='{}'; as_u() {{ \"$@\"; }}; {FILL_FAILED}; fill_failed", scratch.display());
        std::process::Command::new("sh")
            .arg("-c")
            .arg(script)
            .env("PATH", &path)
            .env("CODE", code)
            .status()
            .unwrap()
            .success()
    };
    assert!(failed("background", "1"), "a failed fill runs the start again");
    assert!(!failed("background", "124"), "a running fill is left to itself");
    assert!(!failed("background", "0"), "a fill that ended is done");
    assert!(!failed("background", "2"), "a cmux with no `repo wait` changes nothing");
    assert!(!failed("done", "1"), "a whole clone is done");
    let _ = std::fs::remove_dir_all(&scratch);
}
