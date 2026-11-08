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

/// Review F1 (cmux#38099, 344dd0d083c): a --repo checkout cloned head first gets the rest of its
/// tree after the bootstrap runner ended, so the applier waits at the repository barrier
/// (`cmux repo wait`) before setup runs in the checkout, and a fill that failed refuses the apply.
#[cfg(unix)]
#[test]
fn an_apply_waits_for_a_checkout_still_filling() {
    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    impl Scratch {
        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    let scratch = std::env::temp_dir().join(format!("cmux-apply-wait-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    let root = Scratch(scratch.canonicalize().unwrap());
    let home = root.path().join("home");
    let boot = home.join(".cmux/bootstrap");
    std::fs::create_dir_all(&boot).unwrap();
    std::fs::create_dir_all(home.join("work/r")).unwrap();
    std::fs::create_dir_all(root.path().join("bin")).unwrap();
    std::fs::create_dir_all(root.path().join("conf")).unwrap();
    std::fs::write(boot.join("repo.json"), r#"{"dir":"work/r"}"#).unwrap();
    let applier_path = root.path().join("conf/apply");
    std::fs::write(&applier_path, applier()).unwrap();
    // A stand-in cmux: records its arguments, exits with $CODE.
    // Under both names: the applier asks for `cmux-tui` first.
    use std::os::unix::fs::PermissionsExt as _;
    for name in ["bin/cmux", "bin/cmux-tui"] {
        let cmux = root.path().join(name);
        std::fs::write(&cmux, "#!/bin/sh\necho \"$@\" > \"$HOME/waited\"\nexit \"$CODE\"\n")
            .unwrap();
        std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let call = "import importlib.util, sys\n\
                s = importlib.util.spec_from_file_location('applier', sys.argv[1])\n\
                m = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n\
                try:\n    m.wait_for_repository(); print('applies')\n\
                except m.Refused as e:\n    print('refused:', e)\n";
    let path = format!("{}:/usr/bin:/bin", root.path().join("bin").display());
    let apply = |fill: &str, code: &str| {
        let _ = std::fs::remove_file(home.join("waited"));
        std::fs::write(boot.join("repo-status.json"), format!(r#"{{"fill":"{fill}"}}"#)).unwrap();
        let out = std::process::Command::new("python3")
            .args(["-I", "-c", call])
            .arg(&applier_path)
            .env("HOME", &home)
            .env("PATH", &path)
            .env("CODE", code)
            .output()
            .ok()?;
        let said = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        let waited = std::fs::read_to_string(home.join("waited")).ok();
        Some((said, waited.map(|w| w.trim().to_owned())))
    };
    // A host without python3 3.11 (tomllib) cannot load the applier.
    let Some((said, waited)) = apply("background", "0") else { return };
    if said.is_empty() {
        return;
    }
    let dir = home.join("work/r").display().to_string();
    assert_eq!(said, "applies");
    assert_eq!(waited, Some(format!("repo wait {dir} 10800")));
    let (said, _) = apply("background", "1").unwrap();
    assert!(said.starts_with("refused:") && said.contains("not checked out completely"), "{said}");
    let (said, _) = apply("background", "124").unwrap();
    assert!(said.starts_with("refused:") && said.contains("after 3 h"), "{said}");
    let whole = apply("done", "1").unwrap();
    assert_eq!(whole, ("applies".to_owned(), None), "a whole clone waits on nothing");
}
