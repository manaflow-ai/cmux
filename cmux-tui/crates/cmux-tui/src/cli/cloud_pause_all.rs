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
    let (mut out, err, mut code) = apps_run::report(&outcome, global.output);
    if global.output == OutputMode::Human
        && let Outcome::Answer(answer) = &outcome
        && answer["ok"] == true
    {
        out = Some(human_result(answer));
    }
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

fn human_result(answer: &Value) -> String {
    let Some(rows) = answer.pointer("/data/machines").and_then(Value::as_array) else {
        return "No machine outcomes returned.".to_owned();
    };
    if rows.is_empty() {
        return "No Cloud machines to pause.".to_owned();
    }
    let mut lines = rows
        .iter()
        .map(|row| {
            let machine = row["machine"].as_str().unwrap_or("unknown");
            let status = row["status"].as_str().unwrap_or("unknown");
            match row.pointer("/error/message").and_then(Value::as_str) {
                Some(message) => format!("{machine}: {status} — {message}"),
                None => format!("{machine}: {status}"),
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    if rows.iter().any(|row| row.pointer("/error/retryable") == Some(&Value::Bool(true)))
        && let Some(key) = answer.pointer("/data/idempotency_key").and_then(Value::as_str)
    {
        lines.push_str(&format!(
            "\nRetry unfinished machines: cmux vm pause-all --idempotency-key {}",
            super::cloud_start_chat::shell_quote(key)
        ));
    }
    lines
}

fn partial_failure(answer: &Value) -> bool {
    answer.pointer("/data/machines").and_then(Value::as_array).is_none_or(|rows| {
        rows.iter().any(|row| {
            !matches!(row["status"].as_str(), Some("paused" | "pausing" | "skipped"))
                || row.get("error").is_some_and(|e| !e.is_null())
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pause_all_reports_partial_failure_without_losing_successes() {
        assert!(partial_failure(&json!({"ok":true,"data":{}})));
        assert!(partial_failure(&json!({"ok":true,"data":{"machines":[{"status":"running"}]}})));
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
