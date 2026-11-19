//! `cmux agent-config <surface> ...`: one entry point for every surface this
//! crate edits, so the cmux CLI routes the whole scope here.

use serde_json::Value;

pub const HELP: &str = "\
cmux agent-config: Claude Code and Codex customization, edited in their own files

  cmux agent-config hooks list|enable|disable|add|remove   (cmux agent-config hooks --help)

Add --json for machine output.";

/// Runs `agent-config <words>`; `words` start after `agent-config`.
pub fn run(words: &[String]) -> anyhow::Result<Value> {
    match words.split_first() {
        Some((surface, rest)) if surface == "hooks" => {
            if rest.iter().any(|word| word == "--help" || word == "-h") || rest.is_empty() {
                return Ok(serde_json::json!({ "help": crate::hooks_cli::HELP }));
            }
            crate::hooks_cli::run(rest)
        }
        Some((word, _)) if word != "--help" && word != "-h" && word != "help" => {
            anyhow::bail!("unknown agent-config surface {word:?}\n\n{HELP}")
        }
        _ => Ok(serde_json::json!({ "help": HELP })),
    }
}

/// The human-readable form of `run`'s answer.
pub fn render_human(value: &Value) -> String {
    if let Some(help) = value.get("help").and_then(Value::as_str) {
        return format!("{help}\n");
    }
    if let Some(hooks) = value.get("hooks").and_then(Value::as_array) {
        return crate::hooks_cli::render_list(hooks, value);
    }
    let mut text = serde_json::to_string_pretty(value).unwrap_or_default();
    text.push('\n');
    text
}
