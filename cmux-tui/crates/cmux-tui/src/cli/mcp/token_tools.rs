//! `api_tokens_list`, `api_token_create` and `api_token_revoke`: `cmux token list|create|revoke` as
//! tools, so an agent can set up a script's or CI job's access for the person (Leo, 2026-11-25:
//! "Convienient beats all. Just make good ui for it so people flow."). Each runs this CLI's own
//! `cmux --json token …` in a child process, as `cloud_connect_tools` does, so a tool and its
//! command never differ. They sign in as the person (the cmux app), never with a `cmux_pat_` token.

use cmux_process::{Command, Stdio};
use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const LIST: &str = "api_tokens_list";
pub(super) const CREATE: &str = "api_token_create";
pub(super) const REVOKE: &str = "api_token_revoke";

pub(super) fn descriptors() -> Vec<Value> {
    let team = json!({"type": "string", "pattern": "^team_[0-9a-f]{20}$", "description": "A team other than the person's personal one."});
    vec![
        json!({
            "name": LIST,
            "title": "List cmux API tokens",
            "description": "The person's cmux API tokens (cmux token list), and the team's for team admins: each one's id, name, display form (cmux_pat_AbCd…wXyZ, never the secret), scopes, expiry, last use and owner.",
            "inputSchema": {"type": "object", "properties": {"team": team}},
            "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true},
        }),
        json!({
            "name": CREATE,
            "title": "Create a cmux API token",
            "description": "Make a cmux API token (cmux token create) for a script, a CI job or another computer: CMUX_TOKEN=<token> then runs any cmux Cloud command with no app. Answers {token, tokenInfo} once; the token is never shown again, so hand it to the person or put it straight where it goes (a CI secret). Scopes: machines (start, stop, list), chats (start, send, read), usage (read); default all three. expires: 30d, 90d (default), 1y or never.",
            "inputSchema": {
                "type": "object",
                "required": ["name"],
                "properties": {
                    "name": {"type": "string", "minLength": 1, "maxLength": 64},
                    "scopes": {"type": "array", "items": {"enum": ["machines", "chats", "usage"]}, "minItems": 1, "uniqueItems": true},
                    "expires": {"type": "string", "pattern": "^(never|[0-9]{1,3}[dwmy]?)$", "description": "30d, 90d (default), 6m, 1y, or never."},
                    "spend_cap_usd": {"type": "number", "exclusiveMinimum": 0},
                    "team": team,
                    "team_token": {"type": "boolean", "description": "A team service token (team admins only)."}
                }
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true},
        }),
        json!({
            "name": REVOKE,
            "title": "Revoke a cmux API token",
            "description": "Revoke a cmux API token now (cmux token revoke), by its id or its name. Whatever used it stops working.",
            "inputSchema": {
                "type": "object",
                "required": ["token"],
                "properties": {
                    "token": {"type": "string", "minLength": 1, "maxLength": 64, "description": "The token's id or name from api_tokens_list."},
                    "team": team
                }
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": true},
        }),
    ]
}

fn string(arguments: &Map<String, Value>, key: &str) -> Result<Option<String>, String> {
    match arguments.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if !text.trim().is_empty() && !text.starts_with('-') => {
            Ok(Some(text.clone()))
        }
        Some(_) => Err(format!("{key} must be a non-empty string")),
    }
}

/// The `cmux token …` words for a tool, `None` for any other tool name.
pub(super) fn words(
    name: &str,
    arguments: &Map<String, Value>,
) -> Option<Result<Vec<String>, String>> {
    let build = || -> Result<Vec<String>, String> {
        let mut words = vec!["token".to_owned()];
        match name {
            LIST => words.push("list".into()),
            CREATE => {
                let token_name = string(arguments, "name")?.ok_or("name is required")?;
                words.extend(["create".into(), token_name]);
                if let Some(scopes) = arguments.get("scopes").filter(|v| !v.is_null()) {
                    let scopes = scopes
                        .as_array()
                        .map(|s| s.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(","))
                        .filter(|s| !s.is_empty())
                        .ok_or("scopes must be a list of machines, chats, usage")?;
                    crate::cli::api_tokens::parse_scopes(&scopes)?;
                    words.extend(["--scope".into(), scopes]);
                }
                if let Some(expires) = string(arguments, "expires")? {
                    crate::cli::api_tokens::parse_expiry(&expires)?;
                    words.extend(["--expires".into(), expires]);
                }
                match arguments.get("spend_cap_usd") {
                    None | Some(Value::Null) => {}
                    Some(cap) => {
                        let cap = cap
                            .as_f64()
                            .filter(|c| c.is_finite() && *c > 0.0)
                            .ok_or("spend_cap_usd must be a number above 0")?;
                        words.extend(["--spend-cap".into(), cap.to_string()]);
                    }
                }
                if arguments.get("team_token").and_then(Value::as_bool) == Some(true) {
                    words.push("--team-token".into());
                }
            }
            REVOKE => {
                let token = string(arguments, "token")?.ok_or("token is required")?;
                words.extend(["revoke".into(), token]);
            }
            _ => return Err(format!("{name} is not a token tool")),
        }
        if let Some(team) = string(arguments, "team")? {
            words.extend(["--team".into(), team]);
        }
        Ok(words)
    };
    matches!(name, LIST | CREATE | REVOKE).then(build)
}

/// Runs a token tool; `None` for any other tool name.
pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    let words = match words(name, arguments)? {
        Ok(words) => words,
        Err(message) => {
            return Some(tool_error(envelope(v2_tools::invalid(message), "not_run", None)));
        }
    };
    Some(run(&words, name != LIST))
}

fn run(words: &[String], applied: bool) -> Value {
    let program = match std::env::current_exe() {
        Ok(program) => program,
        Err(error) => return failed(&format!("this cmux has no path: {error}")),
    };
    let output = Command::new(program)
        .arg("--json")
        .args(words)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => return failed(&format!("cmux token did not start: {error}")),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let last =
        stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let message = stderr
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
            .and_then(|v| v.pointer("/error/message").or_else(|| v.get("message")).cloned())
            .and_then(|m| m.as_str().map(str::to_owned))
            .unwrap_or_else(|| stderr.trim().to_owned());
        return failed(message.trim_start_matches("cmux: "));
    }
    success(last.unwrap_or_else(|| json!({"output": stdout.trim()})), applied)
}

fn failed(message: &str) -> Value {
    let error =
        json!({"code": "token.failed", "message": message, "details": {}, "retryable": false});
    tool_error(envelope(error, "rejected", None))
}

#[cfg(test)]
#[path = "token_tools_tests.rs"]
mod tests;
