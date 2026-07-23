use crate::adapters::{adapter_sort_key, normalize_adapter_id, ADAPTERS};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HomeState {
    pub sessions: Vec<Session>,
    pub task_prompt: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub id: String,
    pub adapter: &'static str,
    pub session_id: Option<String>,
    pub title: String,
    pub cwd: Option<String>,
    pub branch: Option<String>,
    pub status: SessionStatus,
    pub preview: Option<String>,
    pub details: Option<String>,
    pub updated_at: Option<String>,
    pub resume_command: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SessionStatus {
    Awaiting,
    Working,
    Completed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionGroup {
    pub status: SessionStatus,
    pub sessions: Vec<Session>,
}

impl HomeState {
    pub fn sorted_sessions(&self) -> Vec<Session> {
        let mut sessions = self.sessions.clone();
        sessions.sort_by(|left, right| {
            left.status
                .sort_key()
                .cmp(&right.status.sort_key())
                .then(adapter_sort_key(left.adapter).cmp(&adapter_sort_key(right.adapter)))
                .then(
                    left.title
                        .to_ascii_lowercase()
                        .cmp(&right.title.to_ascii_lowercase()),
                )
                .then(left.id.cmp(&right.id))
        });
        sessions
    }
}

impl Session {
    pub fn resume_session_id(&self) -> &str {
        self.session_id.as_deref().unwrap_or(&self.id)
    }
}

impl SessionStatus {
    pub const ORDERED: [SessionStatus; 3] = [
        SessionStatus::Awaiting,
        SessionStatus::Working,
        SessionStatus::Completed,
    ];

    pub fn label(self) -> &'static str {
        match self {
            SessionStatus::Awaiting => "awaiting",
            SessionStatus::Working => "working",
            SessionStatus::Completed => "completed",
        }
    }

    fn sort_key(self) -> usize {
        Self::ORDERED
            .iter()
            .position(|candidate| *candidate == self)
            .unwrap_or(usize::MAX)
    }
}

pub fn load_state(data_path: Option<&Path>) -> Result<HomeState, String> {
    if let Some(path) = data_path {
        let contents = fs::read_to_string(path)
            .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
        return parse_state(&contents);
    }

    for path in default_state_candidates() {
        if path.is_file() {
            let contents = fs::read_to_string(&path)
                .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
            return parse_state(&contents);
        }
    }

    Ok(fallback_state())
}

pub fn parse_state(contents: &str) -> Result<HomeState, String> {
    let value: Value = serde_json::from_str(contents).map_err(|error| error.to_string())?;
    validate_schema_contract(&value)?;
    let task_prompt = extract_task_prompt(&value)
        .unwrap_or_else(|| "Describe a task for the selected agent...".to_string());
    let mut session_values = Vec::new();
    collect_session_values(&value, &mut session_values);

    let mut sessions = Vec::new();
    for session_value in session_values {
        if let Some(session) = parse_session(session_value) {
            sessions.push(session);
        }
    }

    Ok(HomeState {
        sessions,
        task_prompt,
    })
}

pub fn fallback_state() -> HomeState {
    HomeState {
        task_prompt: "Ask an agent to summarize current branch risk...".to_string(),
        sessions: vec![
            Session {
                id: "claude-demo".to_string(),
                adapter: "claude",
                session_id: Some("claude-demo".to_string()),
                title: "Review sidebar notification polish".to_string(),
                cwd: Some("~/fun/cmux".to_string()),
                branch: Some("feat/home-prototype".to_string()),
                status: SessionStatus::Awaiting,
                preview: Some("Needs approval for edit plan".to_string()),
                details: Some("Claude Code is paused on an approval-style event.".to_string()),
                updated_at: Some("2026-05-12T09:30:00Z".to_string()),
                resume_command: None,
            },
            Session {
                id: "codex-demo".to_string(),
                adapter: "codex",
                session_id: Some("codex-demo".to_string()),
                title: "Implement Ratatui smoke mode".to_string(),
                cwd: Some("~/fun/cmux".to_string()),
                branch: Some("feat/cmux-home".to_string()),
                status: SessionStatus::Working,
                preview: Some("Running parser tests".to_string()),
                details: Some("Codex session is actively building the Rust prototype.".to_string()),
                updated_at: Some("2026-05-12T09:32:00Z".to_string()),
                resume_command: None,
            },
            Session {
                id: "opencode-demo".to_string(),
                adapter: "opencode",
                session_id: Some("opencode-demo".to_string()),
                title: "Sketch OpenCode adapter gaps".to_string(),
                cwd: Some("~/fun/cmux".to_string()),
                branch: None,
                status: SessionStatus::Completed,
                preview: Some("Ready to resume".to_string()),
                details: Some("OpenCode state came from fallback demo data.".to_string()),
                updated_at: Some("2026-05-12T09:20:00Z".to_string()),
                resume_command: None,
            },
            Session {
                id: "pi-demo".to_string(),
                adapter: "pi",
                session_id: Some("pi-demo".to_string()),
                title: "Validate Pi registry assumptions".to_string(),
                cwd: Some("~/fun/cmux".to_string()),
                branch: None,
                status: SessionStatus::Completed,
                preview: Some("Prototype note captured".to_string()),
                details: Some("Pi is shown as a read-only restorable agent.".to_string()),
                updated_at: Some("2026-05-12T09:10:00Z".to_string()),
                resume_command: None,
            },
        ],
    }
}

pub fn group_sessions_by_status(state: &HomeState) -> Vec<SessionGroup> {
    let mut grouped: BTreeMap<SessionStatus, Vec<Session>> = BTreeMap::new();
    for session in state.sorted_sessions() {
        grouped.entry(session.status).or_default().push(session);
    }

    SessionStatus::ORDERED
        .into_iter()
        .filter_map(|status| {
            let sessions = grouped.remove(&status)?;
            if sessions.is_empty() {
                None
            } else {
                Some(SessionGroup { status, sessions })
            }
        })
        .collect()
}

pub fn adapter_counts(state: &HomeState) -> Vec<(&'static str, usize)> {
    let counts = state.sessions.iter().fold(
        HashMap::<&'static str, usize>::new(),
        |mut counts, session| {
            *counts.entry(session.adapter).or_default() += 1;
            counts
        },
    );

    ADAPTERS
        .iter()
        .map(|adapter| {
            (
                adapter.id,
                counts.get(adapter.id).copied().unwrap_or_default(),
            )
        })
        .collect()
}

pub fn status_counts(state: &HomeState) -> Vec<(SessionStatus, usize)> {
    let counts = state.sessions.iter().fold(
        HashMap::<SessionStatus, usize>::new(),
        |mut counts, session| {
            *counts.entry(session.status).or_default() += 1;
            counts
        },
    );

    SessionStatus::ORDERED
        .into_iter()
        .map(|status| (status, counts.get(&status).copied().unwrap_or_default()))
        .collect()
}

fn default_state_candidates() -> Vec<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    vec![
        manifest_dir.join("../state/example.json"),
        manifest_dir.join("../state/cmux-home.json"),
        manifest_dir.join("../example-state.json"),
        manifest_dir.join("example-state.json"),
        PathBuf::from("tools/cmux-home/state/example.json"),
        PathBuf::from("tools/cmux-home/state/cmux-home.json"),
    ]
}

fn validate_schema_contract(value: &Value) -> Result<(), String> {
    let Some(root) = value.as_object() else {
        return Ok(());
    };
    let Some(version) = root
        .get("schemaVersion")
        .or_else(|| root.get("schema_version"))
    else {
        return Ok(());
    };
    if version.as_u64() != Some(1) {
        return Err("unsupported cmux home schemaVersion, expected 1".to_string());
    }
    if let Some(sessions) = root.get("sessions").and_then(Value::as_array) {
        for (index, session) in sessions.iter().enumerate() {
            let status = session
                .as_object()
                .and_then(|session| session.get("status"))
                .and_then(Value::as_str)
                .ok_or_else(|| format!("sessions[{index}].status is required"))?;
            if !matches!(status, "awaiting" | "working" | "completed") {
                return Err(format!(
                    "sessions[{index}].status must be awaiting, working, or completed"
                ));
            }
        }
    }
    Ok(())
}

fn collect_session_values<'a>(value: &'a Value, out: &mut Vec<&'a Value>) {
    match value {
        Value::Array(items) => {
            for item in items {
                if looks_like_session(item) {
                    out.push(item);
                } else {
                    collect_session_values(item, out);
                }
            }
        }
        Value::Object(map) => {
            if looks_like_session(value) {
                out.push(value);
                return;
            }

            for key in ["sessions", "workstreams", "items", "agents", "state"] {
                if let Some(child) = map.get(key) {
                    collect_session_values(child, out);
                }
            }
        }
        _ => {}
    }
}

fn looks_like_session(value: &Value) -> bool {
    let Some(map) = value.as_object() else {
        return false;
    };
    let has_adapter = first_string(
        map,
        &["adapter", "agent", "source", "_source", "provider", "kind"],
    )
    .and_then(normalize_adapter_id)
    .is_some();
    let has_id = first_string(
        map,
        &[
            "agentSessionId",
            "agent_session_id",
            "sessionId",
            "session_id",
            "threadId",
            "thread_id",
            "workstreamId",
            "workstream_id",
            "id",
        ],
    )
    .is_some();

    has_adapter && has_id
}

fn parse_session(value: &Value) -> Option<Session> {
    let map = value.as_object()?;
    let workspace = object_field(map, "workspace");
    let workspace_git = workspace.and_then(|workspace| object_field(workspace, "git"));
    let resume = object_field(map, "resume");
    let activity = object_field(map, "activity");
    let attention = object_field(map, "attention");
    let adapter = first_string(
        map,
        &["adapter", "agent", "source", "_source", "provider", "kind"],
    )
    .and_then(normalize_adapter_id)?;
    let id = first_string(
        map,
        &[
            "id",
            "agentSessionId",
            "agent_session_id",
            "sessionId",
            "session_id",
            "threadId",
            "thread_id",
            "workstreamId",
            "workstream_id",
        ],
    )?
    .to_string();
    let session_id = first_string(
        map,
        &[
            "agentSessionId",
            "agent_session_id",
            "sessionId",
            "session_id",
            "threadId",
            "thread_id",
            "workstreamId",
            "workstream_id",
        ],
    )
    .map(ToString::to_string)
    .or_else(|| Some(id.clone()));
    let title = first_string(map, &["title", "name", "summary", "prompt"])
        .map(clean_line)
        .filter(|title| !title.is_empty())
        .unwrap_or_else(|| format!("{adapter} {}", session_id.as_deref().unwrap_or(&id)));

    Some(Session {
        id,
        adapter,
        session_id,
        title,
        cwd: first_string(
            map,
            &[
                "cwd",
                "workingDirectory",
                "working_directory",
                "repo",
                "workspace",
            ],
        )
        .or_else(|| workspace.and_then(|workspace| first_string(workspace, &["cwd"])))
        .map(ToString::to_string),
        branch: first_string(map, &["branch", "gitBranch", "git_branch"])
            .or_else(|| {
                workspace_git
                    .and_then(|git| first_string(git, &["branch", "gitBranch", "git_branch"]))
            })
            .map(ToString::to_string),
        status: parse_status(
            map.get("status")
                .or_else(|| map.get("state"))
                .or_else(|| activity.and_then(|activity| activity.get("phase"))),
        ),
        preview: first_string(
            map,
            &[
                "preview",
                "lastMessage",
                "last_message",
                "message",
                "body",
                "text",
                "prompt",
            ],
        )
        .or_else(|| {
            activity.and_then(|activity| first_string(activity, &["lastMessage", "last_message"]))
        })
        .or_else(|| {
            attention
                .and_then(|attention| first_string(attention, &["promptSummary", "prompt_summary"]))
        })
        .map(clean_line)
        .filter(|value| !value.is_empty()),
        details: first_string(
            map,
            &[
                "details",
                "detail",
                "transcript",
                "lastAssistantMessage",
                "last_assistant_message",
                "description",
            ],
        )
        .map(clean_line)
        .filter(|value| !value.is_empty()),
        updated_at: first_string(
            map,
            &[
                "updatedAt",
                "updated_at",
                "modified",
                "lastUpdated",
                "last_updated",
            ],
        )
        .map(ToString::to_string),
        resume_command: resume
            .and_then(|resume| resume.get("command"))
            .and_then(command_array_value),
    })
}

fn parse_status(value: Option<&Value>) -> SessionStatus {
    match value {
        Some(Value::String(value)) => parse_status_string(value),
        Some(Value::Object(map)) => {
            if map.contains_key("pending") {
                SessionStatus::Awaiting
            } else if map.contains_key("resolved") || map.contains_key("expired") {
                SessionStatus::Completed
            } else if map.contains_key("telemetry") {
                SessionStatus::Working
            } else {
                map.keys()
                    .next()
                    .map(|key| parse_status_string(key))
                    .unwrap_or(SessionStatus::Completed)
            }
        }
        Some(Value::Bool(true)) => SessionStatus::Working,
        _ => SessionStatus::Completed,
    }
}

fn parse_status_string(value: &str) -> SessionStatus {
    match value.trim().to_ascii_lowercase().replace('_', "-").as_str() {
        "awaiting" | "awaiting-user" | "awaitinguser" | "awaiting user" | "waiting" | "pending"
        | "needs-input" | "needs input" | "blocked" | "paused" => SessionStatus::Awaiting,
        "running" | "active" | "busy" | "working" | "in-progress" | "telemetry" => {
            SessionStatus::Working
        }
        "idle" | "stopped" | "ready" => SessionStatus::Completed,
        "done" | "complete" | "completed" | "finished" | "resolved" | "expired" => {
            SessionStatus::Completed
        }
        "failed" | "failure" | "error" | "crashed" => SessionStatus::Awaiting,
        _ => SessionStatus::Completed,
    }
}

fn object_field<'a>(
    map: &'a serde_json::Map<String, Value>,
    key: &str,
) -> Option<&'a serde_json::Map<String, Value>> {
    map.get(key).and_then(Value::as_object)
}

fn command_array_value(value: &Value) -> Option<String> {
    let values = value.as_array()?;
    let mut parts = Vec::with_capacity(values.len());
    for value in values {
        let part = value_as_string(value)?.trim();
        if part.is_empty() {
            return None;
        }
        parts.push(shell_word(part));
    }
    Some(parts.join(" "))
}

fn shell_word(value: &str) -> String {
    if value.chars().all(|ch| {
        ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '/' | ':' | '=' | '+' | '-')
    }) {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn first_string<'a>(map: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<&'a str> {
    for key in keys {
        if let Some(value) = map.get(*key).and_then(value_as_string) {
            return Some(value);
        }
    }
    None
}

fn value_as_string(value: &Value) -> Option<&str> {
    match value {
        Value::String(value) => Some(value),
        _ => None,
    }
}

fn clean_line(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn extract_task_prompt(value: &Value) -> Option<String> {
    match value {
        Value::Object(map) => first_string(
            map,
            &[
                "taskPrompt",
                "task_prompt",
                "promptPlaceholder",
                "prompt_placeholder",
            ],
        )
        .map(ToString::to_string)
        .or_else(|| map.get("state").and_then(extract_task_prompt)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_root_sessions_shape() {
        let state = parse_state(
            r#"{
              "taskPrompt": "Ask an agent...",
              "sessions": [
                {
                  "id": "item-1",
                  "session_id": "claude-session",
                  "source": "claude",
                  "status": "pending",
                  "title": "Fix tabs",
                  "cwd": "/tmp/cmux",
                  "branch": "feat/tabs",
                  "preview": "Needs approval"
                }
              ]
            }"#,
        )
        .unwrap();

        assert_eq!(state.task_prompt, "Ask an agent...");
        assert_eq!(state.sessions.len(), 1);
        assert_eq!(state.sessions[0].adapter, "claude");
        assert_eq!(state.sessions[0].status, SessionStatus::Awaiting);
        assert_eq!(state.sessions[0].resume_session_id(), "claude-session");
        assert_eq!(state.sessions[0].preview.as_deref(), Some("Needs approval"));
    }

    #[test]
    fn parses_nested_state_shape() {
        let state = parse_state(
            r#"{
              "state": {
                "sessions": [
                  {"id": "codex-1", "agent": "codex", "status": "running", "title": "Build it"}
                ]
              }
            }"#,
        )
        .unwrap();

        assert_eq!(state.sessions.len(), 1);
        assert_eq!(state.sessions[0].adapter, "codex");
        assert_eq!(state.sessions[0].status, SessionStatus::Working);
    }

    #[test]
    fn groups_sessions_by_status_in_home_order() {
        let state = HomeState {
            task_prompt: "Task".to_string(),
            sessions: vec![
                Session {
                    id: "completed".to_string(),
                    adapter: "pi",
                    session_id: None,
                    title: "Completed".to_string(),
                    cwd: None,
                    branch: None,
                    status: SessionStatus::Completed,
                    preview: None,
                    details: None,
                    updated_at: None,
                    resume_command: None,
                },
                Session {
                    id: "awaiting".to_string(),
                    adapter: "claude",
                    session_id: None,
                    title: "Awaiting".to_string(),
                    cwd: None,
                    branch: None,
                    status: SessionStatus::Awaiting,
                    preview: None,
                    details: None,
                    updated_at: None,
                    resume_command: None,
                },
            ],
        };

        let groups = group_sessions_by_status(&state);

        assert_eq!(
            groups.iter().map(|group| group.status).collect::<Vec<_>>(),
            vec![SessionStatus::Awaiting, SessionStatus::Completed]
        );
    }

    #[test]
    fn counts_all_known_adapters() {
        let state = parse_state(
            r#"[
              {"id": "c1", "adapter": "claude", "status": "idle"},
              {"id": "c2", "adapter": "codex", "status": "idle"}
            ]"#,
        )
        .unwrap();

        assert_eq!(
            adapter_counts(&state),
            vec![("claude", 1), ("codex", 1), ("opencode", 0), ("pi", 0)]
        );
    }

    #[test]
    fn rejects_unsupported_schema_version() {
        let error = parse_state(r#"{"schemaVersion":2,"sessions":[]}"#).unwrap_err();

        assert!(error.contains("schemaVersion"));
    }

    #[test]
    fn rejects_schema_status_outside_contract() {
        let error = parse_state(
            r#"{
              "schemaVersion": 1,
              "sessions": [
                {"id": "bad", "agent": "codex", "agentSessionId": "bad", "status": "failed"}
              ]
            }"#,
        )
        .unwrap_err();

        assert!(error.contains("status"));
    }

    #[test]
    fn parses_canonical_schema_fields() {
        let state = parse_state(
            r#"{
              "schemaVersion": 1,
              "sessions": [
                {
                  "id": "codex:canonical",
                  "agent": "codex",
                  "agentSessionId": "canonical",
                  "title": "Canonical",
                  "status": "awaiting",
                  "updatedAt": "2026-05-12T16:00:00Z",
                  "workspace": {
                    "id": "workspace-id",
                    "cwd": "/tmp/cmux",
                    "git": {"branch": "feat/canonical"}
                  },
                  "activity": {"phase": "awaitingUser", "lastMessage": "Permission requested"},
                  "attention": {"promptSummary": "Run tests"},
                  "resume": {"command": ["codex", "resume", "canonical"]}
                }
              ]
            }"#,
        )
        .unwrap();

        let session = &state.sessions[0];
        assert_eq!(session.resume_session_id(), "canonical");
        assert_eq!(session.cwd.as_deref(), Some("/tmp/cmux"));
        assert_eq!(session.branch.as_deref(), Some("feat/canonical"));
        assert_eq!(session.preview.as_deref(), Some("Permission requested"));
        assert_eq!(
            session.resume_command.as_deref(),
            Some("codex resume canonical")
        );
    }
}
