//! `cmux perf ab --patch SHA [--rollback] [--unsigned-daemon] [--allow-partial]`: hot-apply's
//! plan for SHA first, then profile, hot-apply SHA with `scripts/cmux-next/hot-apply.py`,
//! profile again, compare, and roll back when asked.
//!
//! hot-apply swaps only what can go into a running app (web bundle, daemon Rust, the FFI
//! dylib); its `plan` says what of SHA needs a build instead (Swift signatures, resources).
//! When the plan leaves any of SHA out, the A/B would credit the whole patch with part of it,
//! so this command refuses with the list unless `--allow-partial`; when nothing of SHA can go
//! in live, it stops before the second profile rather than compare an unchanged app with
//! itself. `--unsigned-daemon` goes to hot-apply's `plan` and `apply`: a Team-signed NIGHTLY
//! refuses the ad-hoc-signed published daemon without it, and with it Cloud fails until
//! rollback, so it warns and suggests `--rollback`. Over ssh the steps that need the person's
//! GUI session (`--restart-sessions` on macOS) are skipped and said so.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::super::super::OutputMode;
use super::super::GlobalArgs;
use super::{AbArgs, ProfileArgs};

const SCRIPT: &str = "scripts/cmux-next/hot-apply.py";

/// The checkout with hot-apply.py: `start` or the nearest parent that has it.
pub(super) fn find_repo(start: &Path) -> Option<PathBuf> {
    start.ancestors().find(|dir| dir.join(SCRIPT).is_file()).map(Path::to_path_buf)
}

/// What hot-apply's plan JSON says: the parts that go in live, and the rest with why.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct Plan {
    pub parts: Vec<String>,
    pub left: Vec<(String, String)>,
    /// Everything the plan leaves out, one `kind: file or reason` per entry.
    pub excluded: Vec<String>,
}

/// What of the patch the A/B would leave out: `Some` when part goes in live and part does not
/// (the after profile would measure part of the patch), unless that is allowed.
pub(super) fn partial_refusal(plan: &Plan, allow_partial: bool) -> Option<&[String]> {
    (!allow_partial && !plan.parts.is_empty() && !plan.excluded.is_empty())
        .then_some(plan.excluded.as_slice())
}

pub(super) fn parse_plan(text: &str) -> Option<Plan> {
    // The plan is the JSON object on stdout; progress lines may come before it.
    let start = text.find('{')?;
    let value: Value = serde_json::from_str(text[start..].trim()).ok()?;
    let parts =
        value["parts"].as_array()?.iter().filter_map(|p| p.as_str().map(str::to_owned)).collect();
    let mut left = Vec::new();
    let mut excluded = Vec::new();
    if let Some(map) = value["left"].as_object() {
        for (kind, why) in map {
            let items: Vec<String> = match why {
                Value::Array(items) => {
                    items.iter().filter_map(Value::as_str).map(str::to_owned).collect()
                }
                Value::String(text) => vec![text.clone()],
                other => vec![other.to_string()],
            };
            excluded.extend(items.iter().map(|item| format!("{kind}: {item}")));
            left.push((kind.clone(), items.join("; ")));
        }
    }
    Some(Plan { parts, left, excluded })
}

fn hot_apply(repo: &Path, args: &[String]) -> Result<(i32, String, String), String> {
    let output = cmux_process::Command::new("python3")
        .arg(repo.join(SCRIPT))
        .args(args)
        .current_dir(repo)
        .output()
        .map_err(|error| error.to_string())?;
    Ok((
        output.status.code().unwrap_or(1),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

fn step(name: &str, ok: bool, detail: Value) -> Value {
    json!({ "step": name, "ok": ok, "detail": detail })
}

pub(super) fn run(global: &GlobalArgs, args: &AbArgs) -> i32 {
    let messages = &crate::localization::catalog().app_control.perf;
    let output = global.output;
    let fail = |code: &str, message: String, exit: i32| {
        super::super::super::wire::print_local_error(
            &super::local_error(code, message),
            output,
            exit,
        )
    };
    let repo = match args
        .repo
        .clone()
        .or_else(|| std::env::current_dir().ok().and_then(|d| find_repo(&d)))
    {
        Some(repo) if repo.join(SCRIPT).is_file() => repo,
        _ => return fail("perf.no_repo", messages.ab_no_repo.to_owned(), 2),
    };
    let socket = match super::super::command_socket(global) {
        Ok(socket) => socket.path,
        Err(error) => return super::super::super::wire::print_local_error(&error, output, 3),
    };
    let unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dir = args
        .out_dir
        .clone()
        .unwrap_or_else(|| std::env::temp_dir().join(format!("cmux-perf-ab-{unix}")));
    if let Err(error) = std::fs::create_dir_all(&dir) {
        return fail(
            "perf.write_failed",
            super::fill(
                messages.write_failed,
                &[("path", dir.display().to_string()), ("error", error.to_string())],
            ),
            1,
        );
    }
    let over_ssh = std::env::var_os("SSH_CONNECTION").is_some();
    let mut steps = Vec::new();
    let mut notes = Vec::new();
    if over_ssh && cfg!(target_os = "macos") {
        notes.push(messages.ab_ssh.to_owned());
    }
    let progress = |text: String| eprintln!("cmux perf ab: {text}");
    if args.unsigned_daemon {
        let mut warning = messages.ab_unsigned.to_owned();
        if !args.rollback {
            warning = format!("{warning} {}", messages.ab_unsigned_rollback);
        }
        progress(warning.clone());
        notes.push(warning);
    }

    let profile = |label: &str| ProfileArgs {
        seconds: args.seconds,
        out: Some(dir.join(format!("{label}.json"))),
        label: Some(format!("{label} {}", args.patch)),
        probe: args.probe,
        probe_samples: args.probe_samples,
    };

    // The plan comes first: a patch that cannot go in whole is refused before any profiling.
    let identify = super::super::connect_command(global)
        .ok()
        .and_then(|mut stream| super::profile::call(&mut stream, "system.identify", json!({})));
    let app = identify.as_ref().and_then(|i| i["app_bundle_path"].as_str()).map(str::to_owned);
    let mut app_args = Vec::new();
    if let Some(app) = &app {
        app_args = vec!["--app".to_owned(), app.clone()];
    }
    let mut daemon_args = Vec::new();
    if args.unsigned_daemon {
        daemon_args.push("--unsigned-daemon".to_owned());
    }
    let mut plan_args =
        vec!["plan".to_owned(), args.patch.clone(), "--repo".into(), repo.display().to_string()];
    plan_args.extend(app_args.clone());
    plan_args.extend(daemon_args.clone());
    let plan = match hot_apply(&repo, &plan_args) {
        Ok((_, stdout, stderr)) => match parse_plan(&stdout) {
            Some(plan) => plan,
            None => {
                return fail(
                    "perf.ab_plan",
                    super::fill(messages.ab_plan_failed, &[("error", stderr.trim().to_owned())]),
                    1,
                );
            }
        },
        Err(error) => {
            return fail(
                "perf.ab_plan",
                super::fill(messages.ab_plan_failed, &[("error", error)]),
                1,
            );
        }
    };
    if let Some(excluded) = partial_refusal(&plan, args.allow_partial) {
        return fail(
            "perf.ab_partial",
            super::fill(
                messages.ab_partial,
                &[
                    ("sha", args.patch.clone()),
                    ("parts", plan.parts.join(",")),
                    (
                        "files",
                        excluded.iter().map(|f| format!("  {f}")).collect::<Vec<_>>().join("\n"),
                    ),
                ],
            ),
            2,
        );
    }
    for (kind, why) in &plan.left {
        notes.push(super::fill(messages.ab_left, &[("kind", kind.clone()), ("why", why.clone())]));
    }
    progress(super::fill(
        messages.ab_profiling,
        &[("label", "before".into()), ("seconds", args.seconds.to_string())],
    ));
    let before_args = profile("before");
    let before = match super::profile::collect(global, &before_args) {
        Ok(report) => report,
        Err(error) => return super::super::super::wire::print_local_error(&error, output, 3),
    };
    let before_path = before_args.out.unwrap_or_default();
    if let Err(error) = super::profile::write(&before, &before_path) {
        return super::super::super::wire::print_local_error(&error, output, 1);
    }
    steps.push(step("plan", true, json!({ "parts": plan.parts, "left": plan.left })));
    steps.push(step("profile before", true, json!(before_path)));

    let mut after_path = None;
    let mut applied = false;
    let mut comparison = None;
    if plan.parts.is_empty() {
        notes.push(messages.ab_nothing_live.to_owned());
    } else {
        let mut apply_args = vec![
            "apply".to_owned(),
            args.patch.clone(),
            "--repo".into(),
            repo.display().to_string(),
            "--socket".into(),
            socket.display().to_string(),
        ];
        apply_args.extend(app_args.clone());
        apply_args.extend(daemon_args.clone());
        if let Some(parts) = &args.parts {
            apply_args.extend(["--parts".to_owned(), parts.clone()]);
        }
        progress(super::fill(
            messages.ab_applying,
            &[("sha", args.patch.clone()), ("parts", plan.parts.join(","))],
        ));
        let (code, stdout, stderr) = match hot_apply(&repo, &apply_args) {
            Ok(result) => result,
            Err(error) => (1, String::new(), error),
        };
        applied = code == 0;
        let receipt =
            stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok());
        steps.push(step(
            "apply",
            applied,
            receipt.unwrap_or_else(|| json!({ "exit": code, "stderr": stderr.lines().rev().take(8).collect::<Vec<_>>() })),
        ));
        if applied {
            progress(super::fill(
                messages.ab_profiling,
                &[("label", "after".into()), ("seconds", args.seconds.to_string())],
            ));
            let after_args = profile("after");
            match super::profile::collect(global, &after_args) {
                Ok(after) => {
                    let path = after_args.out.clone().unwrap_or_default();
                    let wrote = super::profile::write(&after, &path).is_ok();
                    steps.push(step("profile after", wrote, json!(path)));
                    after_path = Some(path);
                    let rows = super::compare::compare(&before, &after);
                    comparison = Some((after, rows));
                }
                Err(error) => steps.push(step("profile after", false, error)),
            }
        } else {
            notes.push(messages.ab_apply_failed.to_owned());
        }
    }

    if args.rollback && applied {
        let mut rollback_args =
            vec!["rollback".to_owned(), "--socket".into(), socket.display().to_string()];
        rollback_args.extend(app_args);
        let ok = matches!(hot_apply(&repo, &rollback_args), Ok((0, _, _)));
        steps.push(step("rollback", ok, Value::Null));
    }

    let summary = json!({
        "schema": "cmux.perf.ab/1",
        "patch": args.patch,
        "dir": dir,
        "before": before_path,
        "after": after_path,
        "applied": applied,
        "rolled_back": args.rollback && applied,
        "steps": steps,
        "notes": notes,
        "rows": comparison.as_ref().map(|(_, rows)| rows),
    });
    let _ = std::fs::write(
        dir.join("ab.json"),
        serde_json::to_string_pretty(&summary).unwrap_or_default(),
    );
    match output {
        OutputMode::Human => {
            if let Some((after, rows)) = &comparison {
                print!("{}", super::compare::human(&before, after, rows));
            }
            for note in &notes {
                println!("{note}");
            }
            println!(
                "{}",
                super::fill(messages.wrote, &[("path", dir.join("ab.json").display().to_string())])
            );
            i32::from(!applied && !plan.parts.is_empty())
        }
        _ => super::super::super::wire::print_local_success(&summary, output),
    }
}
