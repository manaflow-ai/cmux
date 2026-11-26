//! Per-session permission rules, layered above the named policy. A rule
//! set is JSON: `{"autoApprove": [...], "autoDeny": [...], "ask": [...],
//! "default": "approve"|"deny"|"ask"}`. Each entry matches, case-insensitive,
//! against the tool kind, the full title, the title head (before `:` or
//! whitespace), or the raw tool name; a multi-word entry also matches a
//! title that starts with it; `"*"` matches everything. Precedence:
//! deny, approve, ask, default, then the session policy decides.

use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleDecision {
    Approve,
    Deny,
    /// Force a client prompt even when the policy would auto-answer.
    Ask,
}

/// Validate a rule set; returns a message when the shape is wrong.
pub fn validate(rules: &Value) -> Result<(), String> {
    let Some(obj) = rules.as_object() else { return Err("rules must be a JSON object".into()) };
    for key in ["autoApprove", "autoDeny", "ask"] {
        if let Some(v) = obj.get(key) {
            let ok = v.as_array().map(|a| a.iter().all(Value::is_string)).unwrap_or(false);
            if !ok {
                return Err(format!("{key} must be an array of strings"));
            }
        }
    }
    if let Some(d) = obj.get("default")
        && !matches!(d.as_str(), Some("approve" | "deny" | "ask"))
    {
        return Err("default must be approve, deny or ask".into());
    }
    for k in obj.keys() {
        if !matches!(k.as_str(), "autoApprove" | "autoDeny" | "ask" | "default") {
            return Err(format!("unknown key {k}"));
        }
    }
    Ok(())
}

/// The tokens a request can be matched on.
pub fn tokens(request: &Value) -> Vec<String> {
    let tc = request.get("toolCall").cloned().unwrap_or(Value::Null);
    let mut out = Vec::new();
    if let Some(k) = tc.get("kind").and_then(Value::as_str) {
        out.push(k.to_lowercase());
    }
    if let Some(t) = tc.get("title").and_then(Value::as_str) {
        // A subagent's command is matched as it was written, not on the hook's mark line.
        let t = crate::bg_hook::without_subagent_mark(t);
        out.push(t.to_lowercase());
        let head = t.split(|c: char| c == ':' || c.is_whitespace()).next().unwrap_or("").trim();
        if !head.is_empty() {
            out.push(head.to_lowercase());
        }
    }
    for key in ["name", "tool", "toolName"] {
        if let Some(n) = tc.get("rawInput").and_then(|r| r.get(key)).and_then(Value::as_str) {
            out.push(n.to_lowercase());
        }
    }
    out
}

fn matches(list: Option<&Value>, toks: &[String]) -> bool {
    let Some(arr) = list.and_then(Value::as_array) else { return false };
    arr.iter().filter_map(Value::as_str).any(|p| {
        let p = p.to_lowercase();
        // A multi-word pattern also matches a title that starts with it,
        // so "rm -rf" catches "rm -rf /tmp/x".
        p == "*" || toks.iter().any(|t| t == &p || (p.contains(' ') && t.starts_with(&p)))
    })
}

/// Decide for one request, or None when no rule applies.
pub fn decide(rules: &Value, request: &Value) -> Option<RuleDecision> {
    let toks = tokens(request);
    if matches(rules.get("autoDeny"), &toks) {
        return Some(RuleDecision::Deny);
    }
    if matches(rules.get("autoApprove"), &toks) {
        return Some(RuleDecision::Approve);
    }
    if matches(rules.get("ask"), &toks) {
        return Some(RuleDecision::Ask);
    }
    match rules.get("default").and_then(Value::as_str) {
        Some("approve") => Some(RuleDecision::Approve),
        Some("deny") => Some(RuleDecision::Deny),
        Some("ask") => Some(RuleDecision::Ask),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    mod caller_identity {
        use super::super::*;
        use serde_json::json;

        /// A Claude Code subagent's Bash title starts with the hook's mark line
        /// (`bg_hook::subagent_mark`); a rule still matches the command it was written as.
        #[test]
        fn a_rule_matches_a_subagents_marked_command_as_written() {
            let rules = json!({"autoDeny": ["rm", "git push"], "autoApprove": ["cargo build"]});
            let mark = "export ACPMUX_CALLER_SUBAGENT=general-purpose:a0a68e7af3df5967e\n";
            let request = |title: &str| json!({"toolCall": {"kind": "execute", "title": title}});
            for (command, want) in [
                ("rm -rf build", Some(RuleDecision::Deny)),
                ("git push origin HEAD", Some(RuleDecision::Deny)),
                ("cargo build --release", Some(RuleDecision::Approve)),
                ("./scripts/tell beta hi", None),
            ] {
                assert_eq!(decide(&rules, &request(command)), want, "{command}");
                let marked = format!("{mark}{command}");
                assert_eq!(decide(&rules, &request(&marked)), want, "marked {command}");
            }
            // Only the hook's exact mark is passed over: another first line is the command.
            let other = request("export X=1\nrm -rf build");
            assert_eq!(decide(&rules, &other), None);
        }
    }
}
