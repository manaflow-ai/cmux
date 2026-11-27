//! Scope classes (decision 27), derived from the app platform's table
//! `cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json`. The table is
//! compiled in, so `emit-ir --check` fails when it changes and the IR was not
//! regenerated. Rules apply in order; the first match wins.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

/// The table, read at build time. This crate never edits it.
pub const TABLE: &str = include_str!("../../cmux-app-host/schema/v2/scope-classes.json");

struct Rule {
    pattern: Regex,
    class: String,
    server_only: bool,
}

static RULES: LazyLock<Result<Vec<Rule>, String>> = LazyLock::new(|| {
    let table: Value =
        serde_json::from_str(TABLE).map_err(|e| format!("scope-classes.json: {e}"))?;
    let rules =
        table.get("rules").and_then(Value::as_array).ok_or("scope-classes.json has no rules")?;
    rules
        .iter()
        .map(|rule| {
            let pattern =
                rule.get("pattern").and_then(Value::as_str).ok_or("a rule has no pattern")?;
            let class = rule.get("class").and_then(Value::as_str).ok_or("a rule has no class")?;
            Ok(Rule {
                pattern: Regex::new(pattern).map_err(|e| format!("rule {pattern:?}: {e}"))?,
                class: class.to_owned(),
                server_only: rule.get("serverOnly").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect()
});

/// The class of `scope` and whether its rule is server-only, or an error
/// when no rule matches (or the table is broken).
pub fn classify(scope: &str) -> Result<(String, bool), String> {
    let rules = RULES.as_ref().map_err(Clone::clone)?;
    rules
        .iter()
        .find(|rule| rule.pattern.is_match(scope))
        .map(|rule| (rule.class.clone(), rule.server_only))
        .ok_or_else(|| format!("scope {scope:?} matches no rule in scope-classes.json"))
}
