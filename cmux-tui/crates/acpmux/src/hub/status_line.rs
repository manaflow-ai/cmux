//! Part of `Hub`; see `hub/mod.rs`. A chat's own status line (`crate::status_line`): the page that
//! shows the chat's composer asks for it (`_acpmux/status_line`, `server/status_line.rs`) when the
//! chat opens and after each turn; acpmux runs the command the settings file names with the
//! chat's session JSON on stdin, shaped as Claude Code's `statusLine` input, and answers
//! `{line}`: the line to show, or null when no command is set or it printed nothing.

use super::*;
use crate::status_line;
use std::time::{Duration, Instant};

/// How long an answer is reused for the same chat and command: several views of one chat asking
/// together run the command once.
const REUSE: Duration = Duration::from_millis(500);

/// The session JSON on the command's stdin: Claude Code's `statusLine` fields where the chat has
/// them (`session_id`, `cwd`, `model`, `workspace`, `version`), plus cmux's own (`session_name`,
/// `title`, `harness`, `mode`, `status`, `turn_count`, `usage`).
pub(super) fn input(meta: &SessionMeta) -> Value {
    let model_id = super::model_options::current_model(meta);
    let model_name = model_id.as_deref().and_then(|id| {
        meta.models
            .as_ref()
            .and_then(|m| m.get("availableModels"))
            .and_then(Value::as_array)?
            .iter()
            .find(|m| m.get("modelId").and_then(Value::as_str) == Some(id))?
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_owned)
    });
    let mode = meta.modes.as_ref().and_then(|m| m.get("currentModeId")).and_then(Value::as_str);
    let cwd = meta.cwd.display().to_string();
    json!({
        "hook_event_name": "Status",
        "session_id": meta.id,
        "session_name": meta.name,
        "title": meta.title,
        "harness": meta.harness,
        "cwd": cwd,
        "model": {
            "id": model_id,
            "display_name": model_name.clone().or_else(|| model_id.clone()),
        },
        "workspace": {"current_dir": cwd, "project_dir": cwd},
        "mode": mode,
        "status": meta.status.as_str(),
        "turn_count": meta.turn_count,
        "usage": meta.usage,
        "version": env!("CARGO_PKG_VERSION"),
    })
}

/// The last answer per chat: (chat id, command) to (when, line).
type Recent = StdMutex<HashMap<(String, String), (Instant, Option<String>)>>;

fn recent() -> &'static Recent {
    static RECENT: std::sync::OnceLock<Recent> = std::sync::OnceLock::new();
    RECENT.get_or_init(Default::default)
}

impl Hub {
    /// `session`'s status line now: `{line}`, null when the settings name no command, or it did
    /// not print a line in time (logged, never an error to the page: the row just stays empty).
    pub(crate) async fn status_line(&self, session: &Arc<Session>) -> Result<Value, RpcError> {
        let settings = tokio::task::spawn_blocking(crate::user_settings::read)
            .await
            .map_err(|e| RpcError::internal(format!("settings read: {e}")))?;
        let Some(command) = status_line::command(&settings) else {
            return Ok(json!({"line": null}));
        };
        let key = (session.id.clone(), command.clone());
        {
            let now = Instant::now();
            let mut recent = recent().lock().unwrap_or_else(|e| e.into_inner());
            recent.retain(|_, (at, _)| now.duration_since(*at) < REUSE);
            if let Some((_, line)) = recent.get(&key) {
                return Ok(json!({"line": line}));
            }
        }
        let meta = session.meta();
        let line = match status_line::run(&command, &meta.cwd, &input(&meta)).await {
            Ok(line) => (!line.is_empty()).then_some(line),
            Err(why) => {
                tracing::debug!(session = %session.id, "status line: {why}");
                None
            }
        };
        recent()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(key, (Instant::now(), line.clone()));
        Ok(json!({"line": line}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_input_names_the_chat_as_claude_code_does() {
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat-1", "name": "fix-tests",
            "harness": "claude", "cwd": "/work/repo", "status": "idle",
            "createdAt": 1, "updatedAt": 1, "turnCount": 3,
            "models": {
                "currentModelId": "opus",
                "availableModels": [{"modelId": "opus", "name": "Opus 5.5"}],
            },
            "modes": {"currentModeId": "plan"},
        }))
        .unwrap();
        let v = input(&meta);
        assert_eq!(v["session_id"], "chat-1");
        assert_eq!(v["session_name"], "fix-tests");
        assert_eq!(v["cwd"], "/work/repo");
        assert_eq!(v["workspace"]["current_dir"], "/work/repo");
        assert_eq!(v["model"], json!({"id": "opus", "display_name": "Opus 5.5"}));
        assert_eq!(v["mode"], "plan");
        assert_eq!(v["turn_count"], 3);
    }
}
