//! Claude desktop (macOS) keeps one `local_<id>.json` per Code session under
//! `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`
//! (agent-mode runs under `local-agent-mode-sessions/`, same shape): the
//! desktop's `title` and the `cliSessionId` of the Claude Code transcript in
//! `~/.claude/projects` that the session writes. Those transcripts are already
//! Claude Code chats here; this names each one as the desktop shows it and marks
//! it as started there (`originator`, as Codex Desktop threads are), so a
//! session running in Claude desktop is found in All chats and opens through
//! adopt like any other.
//!
//! Only the default Claude root (`<home>/.claude/projects`) has a desktop
//! store beside it. A title changed in the desktop shows at the session's next
//! transcript write or the next scan: the watcher covers the projects root only.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use serde_json::Value;

use crate::entry::{ChatEntry, TitleSource};
use crate::stamp::FileStamp;
use crate::store_file::read_json_bounded;
use crate::text::title_field;

/// The `originator` of a Claude Code chat the desktop started.
pub(super) const ORIGINATOR: &str = "Claude Desktop";

const STORES: [&str; 2] = ["claude-code-sessions", "local-agent-mode-sessions"];

/// A session file over this is not the desktop's small metadata record.
const FILE_MAX: u64 = 1024 * 1024;

/// One desktop session as this module needs it.
#[derive(Clone, Debug, PartialEq, Eq)]
struct DesktopSession {
    cli_session_id: String,
    title: Option<String>,
}

/// Parsed session files by path, kept while their stamp holds, so a transcript
/// write re-parses only the desktop files that changed since the last one.
static PARSED: Mutex<Option<HashMap<PathBuf, (FileStamp, Option<DesktopSession>)>>> =
    Mutex::new(None);

/// Names and marks the Claude Code chats in `entries` that Claude desktop
/// started, when `root` is a home's default Claude projects folder.
pub(super) fn apply(root: &Path, entries: &mut [ChatEntry]) {
    if entries.is_empty() {
        return;
    }
    let Some(home) = default_root_home(root) else { return };
    let support = home.join("Library/Application Support/Claude");
    let sessions = read_sessions(&support);
    if sessions.is_empty() {
        return;
    }
    apply_sessions(&sessions, entries);
}

/// `<home>` for `<home>/.claude/projects`.
fn default_root_home(root: &Path) -> Option<&Path> {
    let config =
        root.parent().filter(|_| root.file_name().is_some_and(|name| name == "projects"))?;
    config.file_name().is_some_and(|name| name == ".claude").then(|| config.parent()).flatten()
}

fn apply_sessions(sessions: &HashMap<String, DesktopSession>, entries: &mut [ChatEntry]) {
    for entry in entries {
        let Some(session) = sessions.get(&entry.session_id) else { continue };
        entry.originator = Some(ORIGINATOR.to_owned());
        // A name set in the CLI (`/rename`) stays; else the desktop's title wins.
        if entry.title_source == Some(TitleSource::Custom) {
            continue;
        }
        if let Some(title) = &session.title {
            entry.title = Some(title.clone());
            entry.title_source = Some(TitleSource::Custom);
        }
    }
}

/// Every desktop session under `support`, by `cliSessionId`; the newest file wins a repeat.
fn read_sessions(support: &Path) -> HashMap<String, DesktopSession> {
    let files: Vec<(PathBuf, FileStamp)> =
        STORES.iter().flat_map(|store| session_files(&support.join(store))).collect();
    let mut guard = PARSED.lock().unwrap_or_else(PoisonError::into_inner);
    let parsed = guard.get_or_insert_with(HashMap::new);
    let mut fresh = HashMap::with_capacity(files.len());
    let mut out: HashMap<String, (i64, DesktopSession)> = HashMap::new();
    for (path, stamp) in files {
        let session = match parsed.remove(&path) {
            Some((was, session)) if was == stamp => session,
            _ => parse(&path),
        };
        if let Some(session) = &session {
            let newer =
                out.get(&session.cli_session_id).is_none_or(|(at, _)| *at <= stamp.mtime_ms);
            if newer {
                out.insert(session.cli_session_id.clone(), (stamp.mtime_ms, session.clone()));
            }
        }
        fresh.insert(path, (stamp, session));
    }
    // Files gone since the last read leave the cache with this swap.
    *parsed = fresh;
    out.into_iter().map(|(id, (_, session))| (id, session)).collect()
}

/// `<store>/<account>/<org>/local_*.json`.
fn session_files(store: &Path) -> Vec<(PathBuf, FileStamp)> {
    let mut out = Vec::new();
    for account in dirs(store) {
        for org in dirs(&account) {
            let Ok(read) = fs::read_dir(&org) else { continue };
            for item in read.flatten() {
                let name = item.file_name();
                let name = name.to_string_lossy();
                if !(name.starts_with("local_") && name.ends_with(".json")) {
                    continue;
                }
                if let Ok(meta) = item.metadata()
                    && meta.is_file()
                {
                    out.push((item.path(), FileStamp::of(&meta)));
                }
            }
        }
    }
    out
}

fn dirs(path: &Path) -> Vec<PathBuf> {
    let Ok(read) = fs::read_dir(path) else { return Vec::new() };
    read.flatten()
        .filter(|item| item.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|item| item.path())
        .collect()
}

fn parse(path: &Path) -> Option<DesktopSession> {
    let value: Value = read_json_bounded(path, FILE_MAX)?;
    let cli_session_id =
        value.get("cliSessionId").and_then(Value::as_str).filter(|id| !id.is_empty())?.to_owned();
    Some(DesktopSession { cli_session_id, title: title_field(value.get("title")) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entry::{AdapterKind, Resume};

    fn entry(id: &str, title: Option<(&str, TitleSource)>) -> ChatEntry {
        ChatEntry {
            harness: AdapterKind::ClaudeCode,
            session_id: id.to_owned(),
            title: title.map(|(text, _)| text.to_owned()),
            title_source: title.map(|(_, source)| source),
            cwd: None,
            created_ms: None,
            updated_ms: 0,
            message_count: None,
            source_path: PathBuf::new(),
            originator: None,
            archived: false,
            resume: Resume::Adopt,
        }
    }

    fn write_session(support: &Path, store: &str, file: &str, body: &Value) {
        let dir = support.join(store).join("account").join("org");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), serde_json::to_vec(body).unwrap()).unwrap();
    }

    #[test]
    fn a_desktop_session_takes_the_desktop_title_and_originator() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join(".claude/projects");
        fs::create_dir_all(&root).unwrap();
        let support = home.path().join("Library/Application Support/Claude");
        write_session(
            &support,
            "claude-code-sessions",
            "local_a.json",
            &serde_json::json!({"sessionId": "local_a", "cliSessionId": "cli-a", "title": "Fix the sidebar footer"}),
        );
        write_session(
            &support,
            "local-agent-mode-sessions",
            "local_b.json",
            &serde_json::json!({"sessionId": "local_b", "cliSessionId": "cli-b", "title": "Agent run"}),
        );
        let mut entries = vec![
            entry("cli-a", Some(("first prompt", TitleSource::Prompt))),
            entry("cli-b", None),
            entry("cli-other", Some(("terminal chat", TitleSource::Ai))),
        ];
        apply(&root, &mut entries);
        assert_eq!(entries[0].title.as_deref(), Some("Fix the sidebar footer"));
        assert_eq!(entries[0].title_source, Some(TitleSource::Custom));
        assert_eq!(entries[0].originator.as_deref(), Some(ORIGINATOR));
        assert_eq!(entries[1].title.as_deref(), Some("Agent run"));
        assert_eq!(entries[1].originator.as_deref(), Some(ORIGINATOR));
        assert_eq!(entries[2].title.as_deref(), Some("terminal chat"));
        assert_eq!(entries[2].originator, None);
    }

    #[test]
    fn a_cli_rename_outranks_the_desktop_title() {
        let mut sessions = HashMap::new();
        sessions.insert(
            "cli-a".to_owned(),
            DesktopSession {
                cli_session_id: "cli-a".to_owned(),
                title: Some("Desktop".to_owned()),
            },
        );
        let mut entries = vec![entry("cli-a", Some(("Renamed", TitleSource::Custom)))];
        apply_sessions(&sessions, &mut entries);
        assert_eq!(entries[0].title.as_deref(), Some("Renamed"));
        assert_eq!(entries[0].originator.as_deref(), Some(ORIGINATOR));
    }

    #[test]
    fn only_a_default_projects_root_has_a_desktop_store() {
        assert_eq!(default_root_home(Path::new("/u/.claude/projects")), Some(Path::new("/u")));
        assert_eq!(default_root_home(Path::new("/u/custom-claude/projects")), None);
        assert_eq!(default_root_home(Path::new("/u/.claude")), None);
    }

    #[test]
    fn a_session_file_without_a_cli_id_or_too_large_is_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("local_x.json");
        fs::write(&path, br#"{"sessionId":"local_x","title":"No transcript yet"}"#).unwrap();
        assert_eq!(parse(&path), None);
        fs::write(&path, br#"{"cliSessionId":"","title":"t"}"#).unwrap();
        assert_eq!(parse(&path), None);
        fs::write(&path, br#"{"cliSessionId":"c","title":"  \n Line two"}"#).unwrap();
        assert_eq!(
            parse(&path),
            Some(DesktopSession {
                cli_session_id: "c".to_owned(),
                title: Some("Line two".to_owned())
            })
        );
    }
}
