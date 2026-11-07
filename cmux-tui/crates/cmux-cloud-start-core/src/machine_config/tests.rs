//! `.cmux/machine.toml`'s applier and its start (moved from the app's `CloudMachineConfigTests`).

use super::*;
use crate::machine_bootstrap::{ExecAnswer, Outcome, Payload, step_outcome};

#[test]
fn the_applier_keeps_its_files_private_and_never_routes_the_model_plane() {
    let applier = applier();
    for name in [
        "OPENAI_BASE_URL",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "OPTIND",
        "PS1",
        "ZDOTDIR",
    ] {
        assert!(
            applier.contains(&format!("\"{name}\"")),
            "a file from a repo never routes the model plane: {name}"
        );
    }
    assert!(applier.contains("def write(path, text, mode=0o600)"));
    assert!(applier.starts_with("#!/usr/bin/env python3\n"));
    assert!(
        applier.ends_with("    sys.exit(main())"),
        "the text ends as it always did, with no newline"
    );
    assert!(
        !applier.contains("log_tail"),
        "no setup output in status.json, which the app reads over the file API"
    );
    assert!(
        applier.contains(r#"='((?:[^']|'\\'')*)'"#) && !applier.contains("len(value) >="),
        "every delivered value is masked in setup's log, however short, multi-line ones too"
    );
    assert!(applier.contains("MAX_BYTES, MAX_NAMES, MAX_COMMANDS = 64 * 1024, 100, 50"));
    assert_eq!(MAX_BYTES, 64 * 1024, "the app's limit is the applier's");
}

fn plan(uploaded: bool) -> Plan {
    apply_plan(&ApplyRequest { uploaded, now_ms: 1_792_000_000_000, nonce: "ABCDEF01-2345".into() })
}

#[test]
fn an_apply_stages_its_request_beside_the_applier_then_starts_it() {
    let plan = plan(true);
    let id = "1792000000000-abcdef01";
    let writes: Vec<(&str, u32)> = plan
        .steps
        .iter()
        .filter_map(|step| match step {
            Step::Write { path, mode, .. } => Some((path.as_str(), *mode)),
            Step::Exec { .. } => None,
        })
        .collect();
    let at = |suffix: &str| format!("{DIRECTORY}/requests/{id}.{suffix}");
    // Its own applier copy, moved over `apply` only by the start; the request is complete only when
    // the start command renames .pending to .json, after the chown.
    assert_eq!(
        writes,
        [
            (at("apply").as_str(), 0o700),
            (at("toml").as_str(), 0o600),
            (at("pending").as_str(), 0o600)
        ]
    );
    assert!(matches!(&plan.steps[1], Step::Write { text: Some(t), .. } if t == applier()));
    assert!(matches!(
        &plan.steps[2],
        Step::Write { payload: Some(Payload::Config), text: None, .. }
    ));
    assert!(
        matches!(&plan.steps[3], Step::Write { text: Some(t), .. } if t == "{\"source\":\"uploaded\"}\n")
    );
    let commands: Vec<&str> = plan
        .steps
        .iter()
        .filter_map(|step| match step {
            Step::Exec { command, .. } => Some(command.as_str()),
            Step::Write { .. } => None,
        })
        .collect();
    assert_eq!(
        commands,
        [prepare_command(), start_command(id)],
        "the start finalizes only this request"
    );
    assert!(
        matches!(plan.steps.last(), Some(Step::Exec { said, .. }) if *said == ["started", "running"])
    );
}

#[test]
fn request_names_sort_by_time() {
    let (early, late) = (request_id(9_000, "aaaaaaaa"), request_id(10_000, "aaaaaaaa"));
    assert!(early < late);
    assert!(early.starts_with("0000000009000-"));
    assert_eq!(request_id(1, "ABCDEF0123"), "0000000000001-abcdef01");
}

#[test]
fn a_reapply_without_a_file_lets_the_machine_pick_its_source() {
    let plan = plan(false);
    assert!(
        !plan
            .steps
            .iter()
            .any(|s| matches!(s, Step::Write { path, .. } if path.ends_with(".toml")))
    );
    let pending = plan.steps.iter().rev().find_map(|s| match s {
        Step::Write { text, .. } => text.clone(),
        Step::Exec { .. } => None,
    });
    assert_eq!(pending.as_deref(), Some("{\"source\":\"auto\"}\n"));
}

#[test]
fn a_running_apply_is_not_started_again_and_a_failed_start_says_why() {
    let said: Vec<String> = ["started", "running"].map(String::from).to_vec();
    let running = ExecAnswer { exit_code: 0, stdout: "running\n".into(), stderr: String::new() };
    assert_eq!(step_outcome(&running, &said).unwrap().status, "running");
    let why = "the machine has no python3 with tomllib (3.11 or later)";
    let failed = ExecAnswer { exit_code: 1, stdout: String::new(), stderr: why.into() };
    assert_eq!(step_outcome(&failed, &said), Some(Outcome::failed(why.into())));
}

#[test]
fn the_applier_starts_isolated() {
    let start = start_command("0000000000001-abcdef01");
    assert!(
        start.contains(r#""$py" -I "$d/apply""#),
        "-I: no user site or cwd module shadows the applier's imports"
    );
    assert!(start.contains(r#""$py" -I -c 'import tomllib'"#), "the probe too");
    assert!(start.contains("r=0000000000001-abcdef01") && !start.contains("*.pending"));
    assert!(
        start.contains("command -v setsid >/dev/null 2>&1 || {"),
        "no way to start it is a failure"
    );
    assert!(start.contains("--unit=cmux-machine-config --property=KillMode=control-group"));
}

/// The commands parse as shell, and the applier as Python (where the host has them).
#[test]
fn the_scripts_parse() {
    for text in [prepare_command(), start_command("0000000000001-abcdef01")] {
        let Ok(out) = std::process::Command::new("sh").arg("-n").arg("-c").arg(&text).output()
        else {
            return;
        };
        assert!(out.status.success(), "{}\n{}", String::from_utf8_lossy(&out.stderr), text);
    }
    let check = "import ast, sys; ast.parse(sys.argv[1])";
    if let Ok(out) =
        std::process::Command::new("python3").args(["-I", "-c", check, applier()]).output()
    {
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    }
}
