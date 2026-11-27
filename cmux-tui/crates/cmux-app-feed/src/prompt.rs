//! An acpmux permission prompt as the Feed reads it (`AcpmuxPermissionPrompt`): its digest, the
//! command a shell would read, the other input fields, the offered options and whether it is a
//! question for a person rather than a tool permission.

use crate::json::{arr_at, canonical, obj_at, sha256_hex, str_at};
use crate::text::{count, cut, scrub, shell_quoted, visible};
use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The SHA-256 of the request's sorted-key JSON: an answer goes back only to the prompt it was
/// posted for.
pub fn digest(request: &Value) -> String {
    sha256_hex(canonical(request).as_bytes())
}

/// A tool input's `command` as a shell would read it: a string as is, an argv of strings
/// shell-quoted and joined, anything else as compact JSON. `None` when there is no command.
pub fn shown_command(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) => Some(text.clone()),
        Value::Array(parts) => {
            let words: Option<Vec<&str>> = parts.iter().map(Value::as_str).collect();
            Some(match words {
                Some(words) => words.into_iter().map(shell_quoted).collect::<Vec<_>>().join(" "),
                None => canonical(&Value::Array(parts.clone())),
            })
        }
        other => Some(canonical(other)),
    }
}

/// A tool input's other fields, scrubbed and cut, and whether anything was cut, scrubbed or left
/// out (an `env` is never shown).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InputSummary {
    pub fields: BTreeMap<String, String>,
    pub truncated: bool,
}

/// How many input fields show.
pub const SHOWN_FIELDS: usize = 8;

/// The input summary of `input`, `None` when there is nothing to show and nothing was left out.
pub fn input_summary(input: &Map<String, Value>) -> Option<InputSummary> {
    let mut fields = BTreeMap::new();
    let env = input.iter().find(|(key, _)| key.to_lowercase() == "env");
    let mut truncated = env.is_some_and(|(_, value)| !value.as_object().is_some_and(Map::is_empty));
    let mut shown: Vec<(&String, &Value)> = input
        .iter()
        .filter(|(key, _)| key.to_lowercase() != "env" && key.as_str() != "command")
        .collect();
    shown.sort_by(|a, b| (a.0 != "cwd", a.0).cmp(&(b.0 != "cwd", b.0)));
    if shown.len() > SHOWN_FIELDS {
        truncated = true;
    }
    for (key, value) in shown.iter().take(SHOWN_FIELDS) {
        let raw = value.as_str().map_or_else(|| canonical(value), str::to_owned);
        let scrubbed = scrub(&raw);
        if scrubbed != raw {
            truncated = true;
        }
        let text = visible(&scrubbed);
        if count(key) > 40 || count(&text) > 200 {
            truncated = true;
        }
        fields.insert(cut(&visible(key), 40), cut(&text, 200));
    }
    if fields.len() < shown.len().min(SHOWN_FIELDS) {
        truncated = true;
    }
    if fields.is_empty() && !truncated { None } else { Some(InputSummary { fields, truncated }) }
}

fn single_of_kind<'a>(offered: &'a [Value], kind: &str) -> Option<&'a Value> {
    let mut matches = offered.iter().filter(|option| str_at(option, "kind") == Some(kind));
    let first = matches.next()?;
    matches.next().is_none().then_some(first)
}

/// The one offered option of `allow_once` (or `reject_once`), when exactly one is offered.
pub fn once_option(allow: bool, offered: &[Value]) -> Option<String> {
    let kind = if allow { "allow_once" } else { "reject_once" };
    single_of_kind(offered, kind).and_then(|option| str_at(option, "optionId")).map(str::to_owned)
}

/// The one offered `allow_always` option.
pub fn always_option(offered: &[Value]) -> Option<String> {
    single_of_kind(offered, "allow_always")
        .and_then(|option| str_at(option, "optionId"))
        .map(str::to_owned)
}

/// The option an allow (`allow_once`) or a deny (`reject_once`, else `reject_always`) answers with.
pub fn option(allow: bool, offered: &[Value]) -> Option<String> {
    let kinds: &[&str] = if allow { &["allow_once"] } else { &["reject_once", "reject_always"] };
    kinds.iter().find_map(|kind| {
        single_of_kind(offered, kind)
            .and_then(|option| str_at(option, "optionId"))
            .map(str::to_owned)
    })
}

/// The request's offered options.
pub fn offered(request: &Value) -> Vec<Value> {
    arr_at(request, "options").cloned().unwrap_or_default()
}

fn meta(request: &Value) -> Option<&Map<String, Value>> {
    request.get("toolCall").and_then(|call| obj_at(call, "_meta"))
}

/// The request's normalized question (`toolCall._meta.acpmux.question`), when it has one.
pub fn question(request: &Value) -> Option<&Value> {
    meta(request)?.get("acpmux")?.get("question")
}

/// True when the request is a question an agent asks a person, never a tool permission.
pub fn is_question(request: &Value) -> bool {
    question(request).is_some()
        || meta(request)
            .and_then(|meta| meta.get("claude"))
            .and_then(|claude| str_at(claude, "tool"))
            == Some("AskUserQuestion")
}

/// True when the request is a tool permission with both an allow and a deny to answer.
pub fn is_tool_permission(request: &Value) -> bool {
    let offered = offered(request);
    !is_question(request) && option(true, &offered).is_some() && option(false, &offered).is_some()
}

/// The prompt's banner: its title and command, scrubbed and trimmed, one line when they agree.
pub fn summary(request: &Value) -> String {
    let call = request.get("toolCall");
    let title = call.and_then(|call| str_at(call, "title")).map(str::to_owned);
    let command = shown_command(
        call.and_then(|call| call.get("rawInput")).and_then(|input| input.get("command")),
    );
    let lines: Vec<String> = [title, command]
        .into_iter()
        .flatten()
        .map(|line| visible(&scrub(&line)).trim().to_owned())
        .filter(|line| !line.is_empty())
        .collect();
    let unique = match lines.as_slice() {
        [first, second] if first == second => vec![first.clone()],
        _ => lines,
    };
    cut(&unique.join("\n"), 300)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn shown_command_quotes_an_argv() {
        assert_eq!(
            shown_command(Some(&json!(["git", "commit", "-m", "a b"]))).unwrap(),
            "git commit -m 'a b'"
        );
        assert_eq!(shown_command(Some(&json!("ls -la"))).unwrap(), "ls -la");
        assert_eq!(shown_command(Some(&json!(["a", 1]))).unwrap(), "[\"a\",1]");
        assert_eq!(
            shown_command(Some(&json!({"b": "/x", "a": 2.0}))).unwrap(),
            "{\"a\":2,\"b\":\"/x\"}"
        );
        assert_eq!(shown_command(Some(&Value::Null)).unwrap(), "null");
        assert_eq!(shown_command(None), None);
    }

    #[test]
    fn input_summary_shows_cwd_first_and_hides_env() {
        let input = json!({"command": "x", "cwd": "/r", "path": "a.txt", "env": {}});
        let summary = input_summary(input.as_object().unwrap()).unwrap();
        assert!(!summary.truncated);
        assert_eq!(summary.fields.len(), 2);
        let with_env = json!({"env": {"A": "1"}});
        assert!(input_summary(with_env.as_object().unwrap()).unwrap().truncated);
        assert_eq!(input_summary(json!({"command": "x"}).as_object().unwrap()), None);
        let many: Map<String, Value> = (0..9).map(|i| (format!("k{i}"), json!(i))).collect();
        let summary = input_summary(&many).unwrap();
        assert!(summary.truncated);
        assert_eq!(summary.fields.len(), 8);
        let secret = json!({"header": "token=abcdef123"});
        let summary = input_summary(secret.as_object().unwrap()).unwrap();
        assert!(summary.truncated);
        assert_eq!(summary.fields["header"], "token=[redacted]");
    }

    #[test]
    fn options_match_exactly_one() {
        let offered = vec![
            json!({"optionId": "yes", "kind": "allow_once"}),
            json!({"optionId": "always", "kind": "allow_always"}),
            json!({"optionId": "never", "kind": "reject_always"}),
        ];
        assert_eq!(option(true, &offered).as_deref(), Some("yes"));
        assert_eq!(option(false, &offered).as_deref(), Some("never"));
        assert_eq!(once_option(false, &offered), None);
        assert_eq!(always_option(&offered).as_deref(), Some("always"));
        let twice = vec![
            json!({"optionId": "a", "kind": "allow_once"}),
            json!({"optionId": "b", "kind": "allow_once"}),
        ];
        assert_eq!(option(true, &twice), None);
    }

    #[test]
    fn digest_is_order_free() {
        assert_eq!(digest(&json!({"a": 1, "b": [true]})), digest(&json!({"b": [true], "a": 1})));
        assert_eq!(digest(&json!({})), sha256_hex(b"{}"));
    }

    #[test]
    fn summary_joins_distinct_lines() {
        let request = json!({"toolCall": {"title": "ls", "rawInput": {"command": ["ls"]}}});
        assert_eq!(summary(&request), "ls");
        let request = json!({"toolCall": {"title": "List", "rawInput": {"command": "ls"}}});
        assert_eq!(summary(&request), "List\nls");
    }
}
