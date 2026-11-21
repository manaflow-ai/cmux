//! `cmux cloud keep-machine --target machine:ID [--off]` and `cmux cloud archive-machine --target
//! machine:ID --confirm`: automatic machine cleanup from the CLI (cmux-platform Retention.ts; Leo,
//! 2026-11-10: "we should defo have auto pause or complete cleanup somethimes...").
//!
//! Both run one Cloud app op through the session daemon's `apps-run` (apps_run.rs), as origin
//! `cli`: `cloud.machine.keep {machine, keep}` (a shared mutation) and `cloud.machine.archive_delete
//! {machine}` (destructive). The supervisor keeps a destructive op for a person (`person_only`), so
//! from the CLI the archive answers `apps.gesture_required`; the command then says where the app
//! offers it (the Cloud page's row, "Archive and delete") instead of the bare refusal.
//!
//! They are the CLI's own verbs, not app actions (no Swift handler): `cmux cloud --help` lists them
//! after the catalog's verbs (cloud_help.rs `CLEANUP`).

use serde_json::{Value, json};

use super::apps_run::{self, AppOp, Outcome};
use super::{GlobalArgs, OutputMode};

/// The Cloud app (first-party-apps/cloud).
const APP: &str = "cmux/cloud";

use super::cloud_help::{ARCHIVE, ARCHIVE_USAGE, KEEP, KEEP_USAGE};

/// One parsed command.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help(&'static str),
    Keep { machine: String, keep: bool },
    Archive { machine: String },
}

/// `Some(exit code)` when `args` is `cloud keep-machine …` or `cloud archive-machine …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || (verb != KEEP && verb != ARCHIVE) {
        return None;
    }
    let mut words = Vec::new();
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            _ => words.push(word.clone()),
        }
    }
    Some(match parse(verb, &words) {
        Ok(Parsed::Help(usage)) => {
            print!("{usage}");
            0
        }
        Ok(parsed) => run(&global, &parsed),
        Err(message) => {
            let usage = if verb == KEEP { KEEP_USAGE } else { ARCHIVE_USAGE };
            super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}\n{usage}"),
                global.output,
                2,
            )
        }
    })
}

/// The words after the verb.
pub(super) fn parse(verb: &str, words: &[String]) -> Result<Parsed, String> {
    let usage = if verb == KEEP { KEEP_USAGE } else { ARCHIVE_USAGE };
    let mut target = None;
    let mut off = false;
    let mut confirm = false;
    let mut index = 0;
    while let Some(word) = words.get(index).map(String::as_str) {
        match word.split_once('=') {
            Some(("--target", value)) => target = Some(value.to_owned()),
            _ => match word {
                "-h" | "--help" | "help" => return Ok(Parsed::Help(usage)),
                "--target" => {
                    index += 1;
                    target = Some(words.get(index).cloned().ok_or("--target needs a value")?);
                }
                "--off" if verb == KEEP => off = true,
                // `--yes` (`-y`) like every delete; the old `--confirm` still works.
                "--yes" | "-y" | "--confirm" if verb == ARCHIVE => confirm = true,
                _ => return Err(format!("unexpected argument {word:?}")),
            },
        }
        index += 1;
    }
    let target = target.ok_or("--target vm:VM_ID is required")?;
    let machine = super::vm_words::bare_id(&target).trim().to_owned();
    if machine.is_empty() {
        return Err("--target vm:VM_ID".to_owned());
    }
    if verb == KEEP {
        return Ok(Parsed::Keep { machine, keep: !off });
    }
    if !confirm {
        return Err("archive-machine deletes the machine: add --yes".to_owned());
    }
    Ok(Parsed::Archive { machine })
}

/// The app op of a parsed command (never `Help`).
pub(super) fn op_of(parsed: &Parsed, idempotency_key: Option<String>) -> Option<AppOp> {
    let key =
        Some(idempotency_key.unwrap_or_else(|| format!("cli-{}", uuid::Uuid::new_v4().simple())));
    let (op, args) = match parsed {
        Parsed::Help(_) => return None,
        Parsed::Keep { machine, keep } => {
            ("cloud.machine.keep", json!({"machine": machine, "keep": keep}))
        }
        Parsed::Archive { machine } => {
            ("cloud.machine.archive_delete", json!({"machine": machine}))
        }
    };
    Some(AppOp { app: APP.to_owned(), op: op.to_owned(), args, idempotency_key: key })
}

fn run(global: &GlobalArgs, parsed: &Parsed) -> i32 {
    let Some(request) = op_of(parsed, global.idempotency_key.clone()) else { return 2 };
    let outcome = match apps_run::execute(global, &request) {
        Ok(outcome) => outcome,
        Err(code) => return code,
    };
    let (stdout, stderr, code) = answer(parsed, &outcome, global.output);
    if let Some(text) = stdout {
        println!("{text}");
    }
    if let Some(text) = stderr {
        eprintln!("{text}");
    }
    code
}

/// What to print and the exit code. A done keep or archive says what changed in words (the
/// machine record with `--json`); an archive the CLI may not run says where the app offers it.
pub(super) fn answer(
    parsed: &Parsed,
    outcome: &Outcome,
    output: OutputMode,
) -> (Option<String>, Option<String>, i32) {
    let japanese = crate::localization::catalog().is_japanese();
    if let (Parsed::Archive { machine }, Outcome::Answer(answer)) = (parsed, outcome)
        && answer["ok"] != true
        && matches!(
            answer["error_code"].as_str(),
            Some("apps.gesture_required" | "apps.scope_missing")
        )
    {
        let text = if japanese {
            format!(
                "cmux: アーカイブして削除するには本人の操作が必要です。アプリの Cloud ページで machine:{machine} の行の「アーカイブして削除」を使ってください。"
            )
        } else {
            format!(
                "cmux: archive and delete needs a person: use \"Archive and delete\" on machine:{machine}'s row in the app's Cloud page."
            )
        };
        let text = match output {
            OutputMode::Json | OutputMode::JsonLines => json!({
                "code": "cloud.gesture_required",
                "message": text,
                "details": {"machine_id": machine, "app": answer},
                "retryable": false,
            })
            .to_string(),
            _ => text,
        };
        return (None, Some(text), 1);
    }
    let Outcome::Answer(answer) = outcome else { return apps_run::report(outcome, output) };
    if answer["ok"] != true || output != OutputMode::Human {
        return apps_run::report(outcome, output);
    }
    let record = answer.pointer("/data/machine").unwrap_or(&Value::Null);
    let name = record["name"].as_str().filter(|name| !name.is_empty());
    let id = record["id"].as_str().unwrap_or_default();
    let on = name.map_or_else(|| format!("machine:{id}"), |name| format!("{name} (machine:{id})"));
    let text = match (parsed, japanese) {
        (Parsed::Keep { keep: true, .. }, false) => {
            format!("Kept {on}: nothing deletes it automatically.")
        }
        (Parsed::Keep { keep: true, .. }, true) => {
            format!("{on} を保持しました。自動で削除されません。")
        }
        (Parsed::Keep { .. }, false) => format!("{on} follows the plan's cleanup again."),
        (Parsed::Keep { .. }, true) => format!("{on} はプランのクリーンアップに戻りました。"),
        (_, false) => format!("Archiving {on}: it is deleted once its archive is ready."),
        (_, true) => format!("{on} をアーカイブしています。アーカイブが済むと削除されます。"),
    };
    (Some(text), None, 0)
}

#[cfg(test)]
#[path = "cloud_retention_tests.rs"]
mod tests;
