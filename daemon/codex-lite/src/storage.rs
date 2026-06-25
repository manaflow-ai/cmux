use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

const TRAJECTORY_STRING_LIMIT: usize = 8 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Idle,
    Running,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMeta {
    pub session_id: Uuid,
    pub cwd: PathBuf,
    pub created_at_unix_ms: u64,
    pub updated_at_unix_ms: u64,
    pub status: SessionStatus,
    pub previous_response_id: Option<String>,
    pub current_tool: Option<String>,
    pub last_handoff_preview: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoffResponse {
    pub session_id: Uuid,
    pub handoff: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionFileResponse {
    pub path: PathBuf,
    pub opened: bool,
}

#[derive(Debug, Clone)]
pub struct SessionStore {
    root: PathBuf,
}

impl SessionStore {
    pub async fn new(root: PathBuf) -> Result<Self> {
        tokio::fs::create_dir_all(&root)
            .await
            .with_context(|| format!("creating session store {}", root.display()))?;
        Ok(Self { root })
    }

    pub async fn create_session(&self, session_id: Uuid, cwd: PathBuf) -> Result<SessionMeta> {
        let now = now_ms();
        let meta = SessionMeta {
            session_id,
            cwd,
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
            status: SessionStatus::Idle,
            previous_response_id: None,
            current_tool: None,
            last_handoff_preview: None,
        };
        tokio::fs::create_dir_all(self.session_dir(session_id)).await?;
        self.write_meta(&meta).await?;
        self.write_handoff(session_id, "No handoff yet.\n").await?;
        let _ = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.trajectory_path(session_id))
            .await?;
        Ok(meta)
    }

    pub async fn list_sessions(&self) -> Result<Vec<SessionMeta>> {
        let mut sessions = Vec::new();
        let mut entries = tokio::fs::read_dir(&self.root)
            .await
            .with_context(|| format!("reading session store {}", self.root.display()))?;
        while let Some(entry) = entries.next_entry().await? {
            if !entry.file_type().await?.is_dir() {
                continue;
            }
            let meta_path = entry.path().join("meta.json");
            let Ok(bytes) = tokio::fs::read(&meta_path).await else {
                continue;
            };
            if let Ok(meta) = serde_json::from_slice::<SessionMeta>(&bytes) {
                sessions.push(meta);
            }
        }
        sessions.sort_by(|a, b| b.updated_at_unix_ms.cmp(&a.updated_at_unix_ms));
        Ok(sessions)
    }

    pub async fn read_meta(&self, session_id: Uuid) -> Result<SessionMeta> {
        let path = self.meta_path(session_id);
        let bytes = tokio::fs::read(&path)
            .await
            .with_context(|| format!("reading {}", path.display()))?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    pub async fn write_meta(&self, meta: &SessionMeta) -> Result<()> {
        let path = self.meta_path(meta.session_id);
        let bytes = serde_json::to_vec_pretty(meta)?;
        tokio::fs::write(&path, bytes)
            .await
            .with_context(|| format!("writing {}", path.display()))
    }

    pub async fn append_event<T>(&self, session_id: Uuid, event: &T) -> Result<()>
    where
        T: Serialize + ?Sized,
    {
        let mut event = serde_json::to_value(event)?;
        compact_json(&mut event);
        let record = json!({
            "ts_unix_ms": now_ms(),
            "event": event,
        });
        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.trajectory_path(session_id))
            .await?;
        file.write_all(&serde_json::to_vec(&record)?).await?;
        file.write_all(b"\n").await?;
        Ok(())
    }

    pub async fn read_handoff(&self, session_id: Uuid) -> Result<String> {
        let path = self.handoff_path(session_id);
        tokio::fs::read_to_string(&path)
            .await
            .with_context(|| format!("reading {}", path.display()))
    }

    pub async fn write_handoff(&self, session_id: Uuid, text: &str) -> Result<()> {
        let path = self.handoff_path(session_id);
        tokio::fs::write(&path, text)
            .await
            .with_context(|| format!("writing {}", path.display()))
    }

    pub async fn open_trajectory(&self, session_id: Uuid) -> Result<SessionFileResponse> {
        self.open_session_file(session_id, SessionFile::Trajectory)
            .await
    }

    pub async fn open_handoff(&self, session_id: Uuid) -> Result<SessionFileResponse> {
        self.open_session_file(session_id, SessionFile::Handoff)
            .await
    }

    async fn open_session_file(
        &self,
        session_id: Uuid,
        file: SessionFile,
    ) -> Result<SessionFileResponse> {
        let path = match file {
            SessionFile::Trajectory => self.trajectory_path(session_id),
            SessionFile::Handoff => self.handoff_path(session_id),
        };
        let path = path
            .canonicalize()
            .with_context(|| format!("canonicalizing {}", path.display()))?;
        let root = self
            .root
            .canonicalize()
            .with_context(|| format!("canonicalizing {}", self.root.display()))?;
        if !path.starts_with(&root) {
            return Err(anyhow!("session file is outside state dir"));
        }
        open_in_editor(&path)?;
        Ok(SessionFileResponse { path, opened: true })
    }

    fn session_dir(&self, session_id: Uuid) -> PathBuf {
        self.root.join(session_id.to_string())
    }

    fn meta_path(&self, session_id: Uuid) -> PathBuf {
        self.session_dir(session_id).join("meta.json")
    }

    fn trajectory_path(&self, session_id: Uuid) -> PathBuf {
        self.session_dir(session_id).join("trajectory.jsonl")
    }

    fn handoff_path(&self, session_id: Uuid) -> PathBuf {
        self.session_dir(session_id).join("handoff.md")
    }
}

enum SessionFile {
    Trajectory,
    Handoff,
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub fn preview(text: &str, max_chars: usize) -> String {
    let mut out = String::new();
    for ch in text.chars().take(max_chars) {
        out.push(ch);
    }
    if text.chars().count() > max_chars {
        out.push_str("...");
    }
    out.replace('\n', " ")
}

fn compact_json(value: &mut Value) {
    match value {
        Value::Array(items) => {
            for item in items {
                compact_json(item);
            }
        }
        Value::Object(map) => {
            for (key, value) in map.iter_mut() {
                if matches!(key.as_str(), "inline" | "head" | "tail") && value.is_string() {
                    if let Some(text) = value.as_str() {
                        *value = Value::String(compact_string(text));
                    }
                } else {
                    compact_json(value);
                }
            }
        }
        Value::String(text) => {
            if text.len() > TRAJECTORY_STRING_LIMIT {
                *text = compact_string(text);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn compact_string(text: &str) -> String {
    if text.len() <= TRAJECTORY_STRING_LIMIT {
        return text.to_string();
    }
    let mut out = String::new();
    for ch in text.chars() {
        if out.len() + ch.len_utf8() > TRAJECTORY_STRING_LIMIT {
            break;
        }
        out.push(ch);
    }
    out.push_str("\n[truncated in trajectory; use blob ref for full output]");
    out
}

fn open_in_editor(path: &Path) -> Result<()> {
    if spawn_editor("zed", path).is_ok() {
        return Ok(());
    }
    if let Ok(editor) = std::env::var("VISUAL")
        && spawn_editor(&editor, path).is_ok()
    {
        return Ok(());
    }
    if let Ok(editor) = std::env::var("EDITOR")
        && spawn_editor(&editor, path).is_ok()
    {
        return Ok(());
    }
    if cfg!(target_os = "macos") {
        Command::new("open")
            .args(["-a", "Zed"])
            .arg(path)
            .spawn()
            .context("opening file in Zed")?;
        return Ok(());
    }
    Command::new("xdg-open")
        .arg(path)
        .spawn()
        .context("opening file")?;
    Ok(())
}

fn spawn_editor(command: &str, path: &Path) -> Result<()> {
    let mut parts = command.split_whitespace();
    let Some(program) = parts.next() else {
        return Err(anyhow!("empty editor command"));
    };
    Command::new(program)
        .args(parts)
        .arg(path)
        .spawn()
        .with_context(|| format!("spawning editor `{program}`"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn persists_session_meta_handoff_and_trajectory() {
        let temp = tempfile::tempdir().unwrap();
        let store = SessionStore::new(temp.path().join("sessions"))
            .await
            .unwrap();
        let session_id = Uuid::new_v4();
        let meta = store
            .create_session(session_id, temp.path().to_path_buf())
            .await
            .unwrap();
        assert_eq!(meta.status, SessionStatus::Idle);

        store
            .append_event(
                session_id,
                &json!({"type": "test", "inline": "x".repeat(9000)}),
            )
            .await
            .unwrap();
        store.write_handoff(session_id, "handoff\n").await.unwrap();

        assert_eq!(store.list_sessions().await.unwrap().len(), 1);
        assert_eq!(store.read_handoff(session_id).await.unwrap(), "handoff\n");
        let trajectory = tokio::fs::read_to_string(
            temp.path()
                .join("sessions")
                .join(session_id.to_string())
                .join("trajectory.jsonl"),
        )
        .await
        .unwrap();
        assert!(trajectory.contains("truncated in trajectory"));
    }
}
