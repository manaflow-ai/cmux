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
    use super::*;
    use serde_json::json;

    fn req(kind: &str, title: &str) -> Value {
        json!({"toolCall": {"kind": kind, "title": title, "rawInput": {"name": "Bash"}}})
    }

    #[test]
    fn precedence_deny_approve_ask_default() {
        let rules = json!({"autoApprove": ["read", "bash"], "autoDeny": ["rm -rf"], "ask": ["execute"], "default": "deny"});
        assert_eq!(decide(&rules, &req("execute", "rm -rf /tmp/x")), Some(RuleDecision::Deny));
        assert_eq!(decide(&rules, &req("execute", "ls")), Some(RuleDecision::Approve)); // raw name Bash
        assert_eq!(
            decide(&json!({"ask": ["execute"], "default": "deny"}), &req("execute", "ls")),
            Some(RuleDecision::Ask)
        );
        assert_eq!(
            decide(&json!({"default": "deny"}), &req("edit", "Write a.txt")),
            Some(RuleDecision::Deny)
        );
        assert_eq!(decide(&json!({}), &req("edit", "Write a.txt")), None);
    }

    #[test]
    fn title_head_and_star() {
        assert_eq!(
            decide(&json!({"autoApprove": ["write"]}), &req("edit", "Write: a.txt")),
            Some(RuleDecision::Approve)
        );
        assert_eq!(
            decide(&json!({"autoDeny": ["*"]}), &req("read", "Read x")),
            Some(RuleDecision::Deny)
        );
    }

    #[test]
    fn validation() {
        assert!(validate(&json!({"autoApprove": ["a"], "default": "ask"})).is_ok());
        assert!(validate(&json!({"autoApprove": "a"})).is_err());
        assert!(validate(&json!({"default": "maybe"})).is_err());
        assert!(validate(&json!({"bogus": []})).is_err());
    }
}
