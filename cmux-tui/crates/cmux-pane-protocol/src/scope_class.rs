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
    let rules = table["rules"].as_array().ok_or("scope-classes.json has no rules")?;
    rules
        .iter()
        .map(|rule| {
            let pattern = rule["pattern"].as_str().ok_or("a rule has no pattern")?;
            let class = rule["class"].as_str().ok_or("a rule has no class")?;
            Ok(Rule {
                pattern: Regex::new(pattern).map_err(|e| format!("rule {pattern:?}: {e}"))?,
                class: class.to_owned(),
                server_only: rule["serverOnly"].as_bool().unwrap_or(false),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_matching_rule_wins() {
        assert_eq!(classify("git:read"), Ok(("standard".into(), false)));
        assert_eq!(classify("router:write"), Ok(("sensitive".into(), false)));
        assert_eq!(classify("fs:write"), Ok(("restricted".into(), false)));
        assert_eq!(classify("process:spawn:git"), Ok(("restricted".into(), true)));
        assert!(classify("router:use").is_err());
    }
}
