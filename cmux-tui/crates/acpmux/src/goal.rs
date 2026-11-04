//! Provider-neutral goal lifecycle metadata.
//!
//! Harnesses report slightly different spellings for the same lifecycle.  The
//! daemon stores one typed shape so clients can render Codex goals and Claude
//! loops through the same projection while retaining fields from newer agents.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GoalProvider {
    Codex,
    Claude,
    Gemini,
    Muse,
    Unknown(String),
}

impl Default for GoalProvider {
    fn default() -> Self {
        Self::Unknown("unknown".to_owned())
    }
}

impl Serialize for GoalProvider {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for GoalProvider {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(Self::from_name(&value))
    }
}

impl GoalProvider {
    pub fn from_name(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "codex" | "openai" => Self::Codex,
            "claude" | "anthropic" => Self::Claude,
            "gemini" | "google" => Self::Gemini,
            "muse" => Self::Muse,
            other => Self::Unknown(other.to_owned()),
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Gemini => "gemini",
            Self::Muse => "muse",
            Self::Unknown(value) => value,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GoalStatus {
    Running,
    Stalled,
    Paused,
    Done,
    /// Legacy Codex statuses are kept so reconnecting clients can distinguish
    /// a budget or usage stop while they migrate to the common lifecycle.
    Active,
    Blocked,
    UsageLimited,
    BudgetLimited,
    Unknown(String),
}

impl Default for GoalStatus {
    fn default() -> Self {
        Self::Running
    }
}

impl Serialize for GoalStatus {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for GoalStatus {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(Self::from_name(&value))
    }
}

impl GoalStatus {
    pub fn from_name(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "running" => Self::Running,
            "stalled" => Self::Stalled,
            "paused" => Self::Paused,
            "done" | "complete" | "completed" | "finished" => Self::Done,
            "active" => Self::Active,
            "blocked" => Self::Blocked,
            "usagelimited" | "usage_limited" | "usage-limited" => Self::UsageLimited,
            "budgetlimited" | "budget_limited" | "budget-limited" => Self::BudgetLimited,
            other => Self::Unknown(other.to_owned()),
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            Self::Running | Self::Active => "running",
            Self::Stalled | Self::Blocked | Self::UsageLimited | Self::BudgetLimited => "stalled",
            Self::Paused => "paused",
            Self::Done => "done",
            Self::Unknown(value) => value,
        }
    }

    /// The compact lifecycle used by the composer, preserving budget stops as
    /// stalled until the harness reports a terminal result.
    pub fn lifecycle(&self) -> &'static str {
        match self {
            Self::Running | Self::Active => "running",
            Self::Stalled | Self::Blocked | Self::UsageLimited | Self::BudgetLimited => "stalled",
            Self::Paused => "paused",
            Self::Done => "done",
            Self::Unknown(_) => "running",
        }
    }
}

/// A single provider-neutral goal snapshot. Unknown fields are retained for
/// forward compatibility with harnesses adding richer plans or accounting.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GoalState {
    pub objective: String,
    #[serde(default)]
    pub status: GoalStatus,
    #[serde(default)]
    pub provider: GoalProvider,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_budget: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_used: Option<u64>,
    #[serde(
        rename = "timeUsedSeconds",
        alias = "elapsedSeconds",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub elapsed_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steps: Option<Vec<Value>>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl GoalState {
    /// Normalize legacy `_meta.goal` payloads. Invalid or empty objectives are
    /// discarded so a stale malformed update cannot create a banner.
    pub fn from_value(value: &Value, family: Option<&str>) -> Option<Self> {
        let object = value.as_object()?;
        let objective = object.get("objective")?.as_str()?.trim();
        if objective.is_empty() {
            return None;
        }
        let status = object
            .get("status")
            .or_else(|| object.get("state"))
            .and_then(Value::as_str)
            .map(GoalStatus::from_name)
            .unwrap_or_default();
        let provider = object
            .get("provider")
            .or_else(|| object.get("source"))
            .or_else(|| object.get("harness"))
            .and_then(Value::as_str)
            .map(GoalProvider::from_name)
            .or_else(|| family.map(GoalProvider::from_name))
            .unwrap_or_default();

        let mut normalized = object.clone();
        normalized.insert("objective".to_owned(), Value::String(objective.to_owned()));
        normalized.insert("status".to_owned(), Value::String(status.as_str().to_owned()));
        normalized.insert("provider".to_owned(), Value::String(provider.as_str().to_owned()));
        // Older daemons stored the goal as an untyped JSON value.  Ignore malformed
        // typed fields instead of letting one stale field make SessionMeta unloadable.
        for key in ["tokenBudget", "tokensUsed", "timeUsedSeconds", "elapsedSeconds"] {
            if normalized.get(key).is_some_and(|value| value.as_u64().is_none()) {
                normalized.remove(key);
            }
        }
        if normalized.get("steps").is_some_and(|value| !value.is_array()) {
            normalized.remove("steps");
        }
        serde_json::from_value(Value::Object(normalized)).ok()
    }

    pub fn lifecycle(&self) -> &'static str {
        self.status.lifecycle()
    }

    /// Build a goal from Claude Code's ACP `plan` update. TodoWrite emits
    /// entries with `pending`, `in_progress`, or `completed` statuses; the
    /// common lifecycle remains running until every entry is completed.
    pub fn from_plan_update(update: &Value) -> Option<Self> {
        if update.get("sessionUpdate").and_then(Value::as_str) != Some("plan") {
            return None;
        }
        let entries = update.get("entries")?.as_array()?;
        if entries.is_empty() {
            return None;
        }
        let objective = entries
            .iter()
            .find(|entry| entry.get("status").and_then(Value::as_str) == Some("in_progress"))
            .or_else(|| entries.first())
            .and_then(|entry| entry.get("content").or_else(|| entry.get("title")))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|content| !content.is_empty())?
            .to_owned();
        let stalled = entries.iter().any(|entry| {
            matches!(
                entry.get("status").and_then(Value::as_str),
                Some("blocked" | "stalled" | "failed" | "cancelled")
            )
        });
        let complete = entries.iter().all(|entry| {
            matches!(
                entry.get("status").and_then(Value::as_str),
                Some("completed" | "complete" | "done")
            )
        });
        Some(Self {
            objective,
            status: if stalled {
                GoalStatus::Stalled
            } else if complete {
                GoalStatus::Done
            } else {
                GoalStatus::Running
            },
            provider: GoalProvider::Claude,
            steps: Some(entries.clone()),
            token_budget: None,
            tokens_used: None,
            elapsed_seconds: None,
            created_at: None,
            updated_at: None,
            extra: BTreeMap::new(),
        })
    }

    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|_| Value::Object(Map::new()))
    }
}

/// Migration hook for the persisted `SessionMeta.goal` field.
///
/// Before goals were typed, any JSON object could be stored there.  A malformed
/// legacy value should be dropped like the web parser drops malformed metadata,
/// rather than preventing the whole session from loading after a daemon restart.
pub fn deserialize_option<'de, D>(deserializer: D) -> Result<Option<GoalState>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(value.as_ref().and_then(|value| GoalState::from_value(value, None)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalizes_legacy_codex_goal_and_preserves_elapsed_fields() {
        let goal = GoalState::from_value(
            &json!({
                "objective": "Keep typing responsive",
                "status": "active",
                "tokensUsed": 240,
                "tokenBudget": 12000,
                "timeUsedSeconds": 42,
                "createdAt": 10,
                "updatedAt": 52,
                "steps": [{"title": "Inspect", "status": "done"}]
            }),
            Some("codex"),
        )
        .unwrap();
        assert_eq!(goal.provider, GoalProvider::Codex);
        assert_eq!(goal.status, GoalStatus::Running);
        assert_eq!(goal.lifecycle(), "running");
        assert_eq!(goal.elapsed_seconds, Some(42));
        assert_eq!(goal.steps.as_ref().unwrap().len(), 1);
        assert_eq!(goal.to_value()["timeUsedSeconds"], 42);
        assert_eq!(goal.to_value()["status"], "running");
    }

    #[test]
    fn normalizes_claude_loop_aliases_and_rejects_empty_objectives() {
        let goal = GoalState::from_value(
            &json!({"objective": "Review the changes", "state": "stalled", "source": "anthropic"}),
            None,
        )
        .unwrap();
        assert_eq!(goal.provider, GoalProvider::Claude);
        assert_eq!(goal.status, GoalStatus::Stalled);
        assert_eq!(goal.lifecycle(), "stalled");
        assert!(
            GoalState::from_value(&json!({"objective": "  ", "status": "running"}), None).is_none()
        );
    }

    #[test]
    fn derives_running_then_done_claude_loop_from_plan_updates() {
        let running = GoalState::from_plan_update(&json!({
            "sessionUpdate": "plan",
            "entries": [
                {"content": "Inspect the change", "status": "completed"},
                {"content": "Run the check", "status": "in_progress"}
            ]
        }))
        .unwrap();
        assert_eq!(running.provider, GoalProvider::Claude);
        assert_eq!(running.objective, "Run the check");
        assert_eq!(running.lifecycle(), "running");
        let done = GoalState::from_plan_update(&json!({
            "sessionUpdate": "plan",
            "entries": [{"content": "Run the check", "status": "completed"}]
        }))
        .unwrap();
        assert_eq!(done.lifecycle(), "done");
        let stalled = GoalState::from_plan_update(&json!({
            "sessionUpdate": "plan",
            "entries": [{"content": "Run the check", "status": "blocked"}]
        }))
        .unwrap();
        assert_eq!(stalled.lifecycle(), "stalled");
    }

    #[test]
    fn drops_malformed_legacy_fields_without_failing_the_session() {
        let goal = GoalState::from_value(
            &json!({
                "objective": "Keep going",
                "status": 42,
                "provider": null,
                "tokenBudget": -1,
                "tokensUsed": "unknown",
                "steps": "not-a-list"
            }),
            Some("codex"),
        )
        .unwrap();
        assert_eq!(goal.provider, GoalProvider::Codex);
        assert_eq!(goal.lifecycle(), "running");
        assert_eq!(goal.token_budget, None);
        assert_eq!(goal.steps, None);
    }

    #[test]
    fn persisted_goal_migration_drops_invalid_objects() {
        #[derive(Deserialize)]
        struct Stored {
            #[serde(default, deserialize_with = "crate::goal::deserialize_option")]
            goal: Option<GoalState>,
        }

        let stored: Stored = serde_json::from_value(json!({
            "goal": {
                "objective": "Keep going",
                "status": "running",
                "tokenBudget": "old-format"
            }
        }))
        .unwrap();
        assert_eq!(stored.goal.unwrap().objective, "Keep going");
    }
}
