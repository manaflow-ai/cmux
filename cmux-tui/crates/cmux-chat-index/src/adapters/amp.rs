//! Amp: the local thread mirror `<root>/T-<uuid>.json` (whole-file
//! rewrites). The server is the source of truth; local threads carry no
//! folder, and the first user message is the title.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{argv, file_stem};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::prompt_text;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    Ok(fs::read_dir(root)?
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|child| child.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("T-") && name.ends_with(".json"))
        })
        .collect())
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(session_id) = file_stem(path) else { return Ok(None) };
    // Larger than the parse bound: listed without a title or count.
    let thread = read_whole_json(path)?.unwrap_or(Value::Null);
    let messages = thread.get("messages").and_then(Value::as_array);
    let title = messages.into_iter().flatten().find_map(|message| {
        (message.get("role").and_then(Value::as_str) == Some("user"))
            .then(|| message.get("content").and_then(prompt_text))
            .flatten()
    });
    Ok(Some(ChatEntry {
        harness: AdapterKind::Amp,
        title_source: title.as_ref().map(|_| TitleSource::Prompt),
        title,
        cwd: None,
        created_ms: thread.get("created").and_then(Value::as_i64),
        updated_ms: stamp.mtime_ms,
        message_count: messages.map(|messages| messages.len() as u64),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv {
            argv: argv(&["amp", "threads", "continue", &session_id]),
            cwd_needed: false,
        },
        session_id,
    }))
}
