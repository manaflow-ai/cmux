//! `agent(prompt, {schema})`: the reply must hold a JSON value that matches
//! the schema.

use serde_json::Value;

/// Errors listed back to the agent when its reply does not match.
const MAX_ERRORS: usize = 5;

pub(crate) fn compile(schema: &Value) -> Result<jsonschema::Validator, String> {
    if schema.get("type").and_then(Value::as_str) != Some("object") {
        return Err("an agent schema needs {type: \"object\"} at its root".into());
    }
    jsonschema::validator_for(schema)
        .map_err(|error| format!("the agent schema is invalid: {error}"))
}

/// The JSON value in `text` when it matches `validator`, or what is wrong.
pub(crate) fn check(text: &str, validator: &jsonschema::Validator) -> Result<Value, String> {
    let value = extract(text).ok_or_else(|| "the reply holds no JSON value".to_owned())?;
    let errors = validator
        .iter_errors(&value)
        .take(MAX_ERRORS)
        .map(|error| {
            let at = error.instance_path.to_string();
            if at.is_empty() { error.to_string() } else { format!("{at}: {error}") }
        })
        .collect::<Vec<_>>();
    if errors.is_empty() { Ok(value) } else { Err(errors.join("; ")) }
}

/// The reply as JSON: the whole text, else the last fenced block that
/// parses, else the outermost braces.
pub(crate) fn extract(text: &str) -> Option<Value> {
    let text = text.trim();
    if let Ok(value) = serde_json::from_str(text) {
        return Some(value);
    }
    let fenced = text
        .split("```")
        .skip(1)
        .step_by(2)
        .filter_map(|block| {
            // The fence's first line may name a language (`json`).
            let body = match block.split_once('\n') {
                Some((first, rest)) if !first.trim_start().starts_with(['{', '[']) => rest,
                _ => block,
            };
            serde_json::from_str::<Value>(body.trim()).ok()
        })
        .last();
    if fenced.is_some() {
        return fenced;
    }
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    (start < end).then(|| serde_json::from_str(&text[start..=end]).ok()).flatten()
}
