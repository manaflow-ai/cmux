//! Pause every managed Cloud machine and hold automatic wakes until explicit resume.
//! Uses the Cloud app's operation path so authorization and idempotency stay on the server.

use serde_json::{Value, json};

use super::OutputMode;
use super::apps_run::{self, AppOp, Outcome};

use super::cloud_help::PAUSE_ALL_USAGE as USAGE;

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let [scope, verb, rest @ ..] = command.as_slice() else { return None };
    if scope != "cloud" || verb != "pause-all" {
        return None;
    }
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            "--help" | "-h" => {
                print!("{USAGE}");
                return Some(0);
            }
            _ => return Some(super::app::failure("usage.invalid", USAGE, global.output, 2)),
        }
    }
    let request = AppOp {
        app: "cmux/cloud".to_owned(),
        op: "cloud.machine.pause_all".to_owned(),
        args: json!({}),
        idempotency_key: Some(
            global
                .idempotency_key
                .clone()
                .unwrap_or_else(|| format!("cli-{}", uuid::Uuid::new_v4().simple())),
        ),
    };
    let outcome = match apps_run::execute(&global, &request) {
        Ok(outcome) => outcome,
        Err(code) => return Some(code),
    };
    let (out, err, mut code) = apps_run::report(&outcome, global.output);
    if let Some(out) = out {
        println!("{out}");
    }
    if let Some(err) = err {
        eprintln!("{err}");
    }
    if let Outcome::Answer(answer) = &outcome
        && partial_failure(answer)
    {
        code = 1;
    }
    Some(code)
}

fn partial_failure(answer: &Value) -> bool {
    answer.pointer("/data/machines").and_then(Value::as_array).is_some_and(|rows| {
        rows.iter()
            .any(|row| row["status"] == "failed" || row.get("error").is_some_and(|e| !e.is_null()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pause_all_reports_partial_failure_without_losing_successes() {
        assert!(partial_failure(&json!({"ok": true, "data": {"machines": [
            {"machine": "vm-a", "status": "paused"},
            {"machine": "vm-b", "status": "failed", "error": {"code": "cloud.machine.busy"}}
        ]}})));
        assert!(!partial_failure(&json!({"ok": true, "data": {"machines": [
            {"machine": "vm-a", "status": "pausing"},
            {"machine": "vm-b", "status": "paused"}
        ]}})));
    }
}
