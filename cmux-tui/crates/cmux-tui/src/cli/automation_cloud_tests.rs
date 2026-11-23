use super::*;

#[test]
fn zone_names_come_from_the_zoneinfo_link() {
    assert_eq!(
        zone_from_path("/var/db/timezone/zoneinfo/America/Los_Angeles").as_deref(),
        Some("America/Los_Angeles")
    );
    assert_eq!(zone_from_path("/usr/share/zoneinfo/UTC").as_deref(), Some("UTC"));
    assert_eq!(zone_from_path("/etc/elsewhere"), None);
}

#[test]
fn the_default_active_chief_is_picked() {
    let list = json!({"chiefs": [
        {"id": "agent_OLD", "is_default": true, "archived_at": 5, "main_conversation": "c_old"},
        {"id": "agent_A", "is_default": false, "archived_at": null, "main_conversation": "c_a"},
        {"id": "agent_B", "is_default": true, "archived_at": null, "main_conversation": "c_b"},
    ], "tombstones": []});
    assert_eq!(default_chief(&list), Some(("agent_B".into(), "c_b".into())));
    let no_default =
        json!({"chiefs": [{"id": "agent_A", "is_default": false, "main_conversation": "c_a"}]});
    assert_eq!(default_chief(&no_default), Some(("agent_A".into(), "c_a".into())));
    assert_eq!(default_chief(&json!({"chiefs": []})), None);
}

fn scout(timeout: u64) -> CloudCommand {
    CloudCommand {
        command: "bash scripts/models/run-scout.sh".into(),
        folder: None,
        repo: Some(("manaflow-ai/cmux".into(), "feat-cmux-next".into())),
        machine: "vm_abcdefghij0123456789".into(),
        timeout_seconds: timeout,
    }
}

#[test]
fn every_step_ends_before_the_provider_cuts_an_exec_even_at_the_longest_timeout() {
    for timeout in [
        1,
        WAIT_SECONDS,
        WAIT_SECONDS + 1,
        1_200,
        MAX_CLOUD_COMMAND_SECONDS,
        MAX_CLOUD_COMMAND_SECONDS + 999,
    ] {
        let body = command_body(&scout(timeout));
        let steps = body["steps"].as_array().unwrap();
        assert!(steps.len() <= 50, "a body holds at most 50 steps ({timeout} s: {})", steps.len());
        // STEP_LIMIT itself stays within the provider's 300 s exec; checked at compile time.
        const { assert!(STEP_LIMIT <= 300) };
        for (i, s) in steps.iter().enumerate() {
            let limit = s["timeout_seconds"].as_u64().unwrap();
            assert!(
                limit <= STEP_LIMIT,
                "{timeout} s: step {i} may run {limit} s, past the provider's 300 s exec"
            );
        }
        let waited: u64 =
            steps[1..].iter().map(|s| s["timeout_seconds"].as_u64().unwrap() - STEP_SLACK).sum();
        assert_eq!(
            waited,
            timeout.clamp(1, MAX_CLOUD_COMMAND_SECONDS),
            "the waits cover the timeout exactly"
        );
    }
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let usage = crate::localization::catalog_for_locale(locale).automation.usage;
        let max = format!("{}m", MAX_CLOUD_COMMAND_SECONDS / 60);
        assert!(usage.contains(&max), "{locale}: the help names the real --timeout maximum, {max}");
    }
}

#[test]
fn a_cloud_command_is_one_start_step_then_waits_that_cover_its_timeout() {
    let p = command_create_params(
        "models-scout",
        &scout(1_200),
        &CloudSchedule::Cron { expr: "0 */6 * * *".into(), tz: "UTC".into() },
        Some("latest"),
        false,
    );
    let steps = p["body"]["steps"].as_array().unwrap();
    assert_eq!(p["body"]["type"], "steps");
    assert_eq!(steps.len(), 1 + 5, "20 min = 5 waits of at most 280 s");
    for s in steps {
        assert_eq!(s["type"], "machine");
        assert_eq!(s["machine"], "vm_abcdefghij0123456789");
        assert!(
            s["timeout_seconds"].as_u64().unwrap() <= 300,
            "one provider exec answers within 300 s"
        );
        assert!(
            s["command"].as_str().unwrap().len() <= 4000,
            "a step command is at most 4000 characters"
        );
    }
    assert!(
        steps[0]["command"]
            .as_str()
            .unwrap()
            .contains("git -C \"$w\" fetch --quiet origin feat-cmux-next"),
        "each run moves to the branch's newest head"
    );
    assert_eq!(p["concurrency"], json!({"max": 1, "on_limit": "skip"}));
    assert_eq!(p["catch_up"], "latest");
    assert_eq!(p["triggers"][1], json!({"type": "manual"}));
    assert_eq!(command_machine(&p["body"]), Some("vm_abcdefghij0123456789"));
    let long = command_body(&scout(10 * 86_400));
    assert_eq!(long["steps"].as_array().unwrap().len(), 50, "a body holds at most 50 steps");
}

/// Runs one step script as the Workflow does (`bash -lc`, `CMUX_RUN` set) with HOME at `home`.
fn step(script: &str, home: &std::path::Path, run: &str) -> (i32, String, String) {
    let out = cmux_process::Command::new("bash")
        .args(["-c", script])
        .env("HOME", home)
        .env("CMUX_RUN", run)
        .stdin(cmux_process::Stdio::null())
        .output()
        .unwrap();
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into(),
        String::from_utf8_lossy(&out.stderr).into(),
    )
}

#[test]
fn the_step_scripts_start_once_wait_and_answer_the_commands_exit() {
    let home = std::env::temp_dir().join(format!("cmux-cloud-command-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("work")).unwrap();
    let mut c = scout(60);
    c.repo = None;
    c.folder = Some("~/work".into());

    // A command that succeeds: the start answers at once, a wait sees it end.
    c.command = "pwd; echo hello".into();
    let (code, out, _) = step(&start_script(&c), &home, "run_ok");
    assert_eq!(code, 0, "{out}");
    let (again, out2, _) = step(&start_script(&c), &home, "run_ok");
    assert_eq!((again, out2.trim()), (0, "started"), "a replayed start never starts it twice");
    let (code, out, err) = step(&wait_script(20, true), &home, "run_ok");
    let launch = std::fs::read_to_string(home.join(".cmux/automations/runs/run_ok/launch.log"))
        .unwrap_or_default();
    assert_eq!(code, 0, "wait: {err}; launch: {launch}");
    assert!(out.contains("hello") && out.contains("/work"), "{out}");
    let log = std::fs::read_to_string(home.join(".cmux/automations/runs/run_ok/log")).unwrap();
    assert!(log.contains("hello"));

    // A command that fails: the wait answers its exit code with the log's last lines on stderr.
    c.command = "echo building; echo 'error: 2 tests failed' >&2; exit 3".into();
    step(&start_script(&c), &home, "run_fail");
    let (code, _, err) = step(&wait_script(20, true), &home, "run_fail");
    assert_eq!(code, 3);
    assert!(err.contains("error: 2 tests failed"), "{err}");

    // A command still running: a middle wait says so, the last one ends it as a timeout.
    c.command = "sleep 30; echo never".into();
    step(&start_script(&c), &home, "run_slow");
    let (code, out, _) = step(&wait_script(1, false), &home, "run_slow");
    assert_eq!((code, out.trim()), (0, "running"));
    let (code, _, err) = step(&wait_script(1, true), &home, "run_slow");
    assert_eq!(code, 124, "{err}");
    assert!(err.contains("timed out"));
    let (code, out, _) = step(&log_script("run_fail"), &home, "x");
    assert_eq!(code, 0);
    assert!(out.contains("building"));
    let (code, _, _) = step(&log_script("run_none"), &home, "x");
    assert_eq!(code, 3);
    let _ = std::fs::remove_dir_all(&home);
}

/// [`step`] with `PATH` led by `bin`.
fn step_with_path(
    script: &str,
    home: &std::path::Path,
    run: &str,
    bin: &std::path::Path,
) -> (i32, String, String) {
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    let out = cmux_process::Command::new("bash")
        .args(["-c", script])
        .env("HOME", home)
        .env("CMUX_RUN", run)
        .env("PATH", path)
        .stdin(cmux_process::Stdio::null())
        .output()
        .unwrap();
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into(),
        String::from_utf8_lossy(&out.stderr).into(),
    )
}

/// models-scout on a fresh machine (2026-11-20): step 0 cloned manaflow-ai/cmux (1.1 GB) in the
/// foreground, the provider's exec gave up first ("the machine did not answer") and left a
/// half-made checkout with its `index.lock`. The checkout now runs detached, before the command.
#[cfg(unix)]
#[test]
fn a_slow_first_clone_runs_detached_so_the_start_step_answers_at_once() {
    let home = std::env::temp_dir().join(format!("cmux-cloud-clone-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let bin = home.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    // A git whose clone takes 3 s and makes the checkout; every other verb succeeds.
    let git = bin.join("git");
    std::fs::write(&git, "#!/bin/sh\nif [ \"$1\" = clone ]; then sleep 3; for a; do w=\"$a\"; done; mkdir -p \"$w/.git\"; fi\nexit 0\n").unwrap();
    std::fs::set_permissions(&git, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let mut c = scout(60);
    c.command = "pwd; echo hello".into();

    let started = std::time::Instant::now();
    let (code, out, err) = step_with_path(&start_script(&c), &home, "run_clone", &bin);
    assert_eq!(code, 0, "{out} {err}");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "step 0 waited for the clone: {:?}",
        started.elapsed()
    );
    let (code, out, err) = step_with_path(&wait_script(20, true), &home, "run_clone", &bin);
    assert_eq!(code, 0, "{err}");
    assert!(out.contains("hello") && out.contains("checkouts/manaflow-ai-cmux"), "{out}");

    // A half-made checkout (a clone the provider ended) is fetched again, its lock cleared.
    std::fs::write(home.join(".cmux/automations/checkouts/manaflow-ai-cmux/.git/index.lock"), "")
        .unwrap();
    step_with_path(&start_script(&c), &home, "run_again", &bin);
    let (code, out, err) = step_with_path(&wait_script(20, true), &home, "run_again", &bin);
    assert_eq!(code, 0, "{err}");
    assert!(out.contains("hello"), "{out}");
    assert!(!home.join(".cmux/automations/checkouts/manaflow-ai-cmux/.git/index.lock").exists());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn create_params_make_a_chief_job_with_a_manual_trigger() {
    let p = create_params(
        "Morning brief",
        "Summarize PRs",
        &CloudSchedule::Cron { expr: "0 9 * * 1-5".into(), tz: "America/Los_Angeles".into() },
        &("agent_B".into(), "c_b".into()),
        false,
    );
    assert_eq!(
        p["body"],
        json!({"type": "chief", "chief": "agent_B", "conversation": "c_b", "prompt": "Summarize PRs"})
    );
    assert_eq!(
        p["triggers"],
        json!([{"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}, {"type": "manual"}])
    );
    assert_eq!(p["enabled"], json!(true));
    assert_eq!(CloudSchedule::Manual.triggers(), json!([{"type": "manual"}]));
}
