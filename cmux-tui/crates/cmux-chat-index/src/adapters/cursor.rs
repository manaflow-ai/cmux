//! Cursor agent CLI: `<root>/<md5 of cwd>/<chat id>/meta.json`. Only
//! `meta.json` is read. `store.db` holds content blobs and the blob
//! encryption key; it is never opened. Subagent runs have no meta.json.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::argv;
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::title_field;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for group in fs::read_dir(root)?.flatten() {
        let Ok(chats) = fs::read_dir(group.path()) else { continue };
        for chat in chats.flatten() {
            let meta = chat.path().join("meta.json");
            if meta.is_file() {
                out.push(meta);
            }
        }
    }
    Ok(out)
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(meta) = read_whole_json(path)? else { return Ok(None) };
    if meta.get("hasConversation") == Some(&Value::Bool(false)) {
        return Ok(None);
    }
    let Some(session_id) =
        path.parent().and_then(Path::file_name).and_then(|name| name.to_str()).map(str::to_owned)
    else {
        return Ok(None);
    };
    let title = title_field(meta.get("name")).or_else(|| title_field(meta.get("title")));
    Ok(Some(ChatEntry {
        harness: AdapterKind::CursorAgent,
        title_source: title.as_ref().map(|_| TitleSource::Ai),
        title,
        cwd: meta
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
        created_ms: meta.get("createdAtMs").and_then(Value::as_i64),
        updated_ms: meta.get("updatedAtMs").and_then(Value::as_i64).unwrap_or(stamp.mtime_ms),
        message_count: None,
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv {
            argv: argv(&["cursor-agent", "--resume", &session_id]),
            cwd_needed: true,
        },
        session_id,
    }))
}
