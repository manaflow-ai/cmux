//! Factory Droid: `<root>/<encoded cwd>/<uuid>.jsonl` (and a legacy flat
//! `<root>/<id>.jsonl`). Line 1 is `session_start` with the id, title and
//! folder; a rename rewrites it in place. Messages are
//! `{type:"message", timestamp, message:{role, content}}`. A session started
//! by another one (`callingSessionId`) is a subagent run, not a chat.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, argv, file_stem, files_one_level_down, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record, read_head_tail};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

fn is_session_name(name: &str) -> bool {
    name.ends_with(".jsonl")
}

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = files_one_level_down(root, is_session_name)?;
    for child in fs::read_dir(root)?.flatten() {
        let name = child.file_name();
        if child.file_type().is_ok_and(|kind| kind.is_file())
            && name.to_str().is_some_and(is_session_name)
        {
            out.push(child.path());
        }
    }
    Ok(out)
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let session = matches!(parts, [name] | [_, name] if is_session_name(name));
    role(session, false)
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let skip = || FileRead {
        entry: None,
        state: FileState { stamp, offset: stamp.size, ..FileState::default() },
    };
    let Some(header) = read_first_record(path)?
        .filter(|record| record.get("type").and_then(Value::as_str) == Some("session_start"))
    else {
        return Ok(skip());
    };
    if header.get("callingSessionId").and_then(Value::as_str).is_some_and(|id| !id.is_empty()) {
        return Ok(skip());
    }
    let (from, mut tally) = FileState::resume_point(prev, &stamp, path);
    let offset = fold_lines(path, from, |line| {
        if !contains(line, br#""type":"message""#) {
            return;
        }
        tally.messages += 1;
        if tally.first_prompt.is_none()
            && let Ok(record) = serde_json::from_slice::<Value>(line)
            && record.pointer("/message/role").and_then(Value::as_str) == Some("user")
        {
            tally.first_prompt = record.pointer("/message/content").and_then(prompt_text);
        }
    })?;
    let created_ms = read_head_tail(path)?.head.iter().skip(1).find_map(|record| {
        record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms)
    });
    let manual = header.get("isSessionTitleManuallySet") == Some(&Value::Bool(true));
    let (title, title_source) = match (title_field(header.get("title")), &tally.first_prompt) {
        (Some(title), _) => {
            (Some(title), Some(if manual { TitleSource::Custom } else { TitleSource::Ai }))
        }
        (None, Some(prompt)) => (Some(prompt.clone()), Some(TitleSource::Prompt)),
        (None, None) => (None, None),
    };
    let session_id = header
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .or_else(|| file_stem(path));
    let entry = session_id.map(|session_id| ChatEntry {
        harness: AdapterKind::Droid,
        title,
        title_source,
        cwd: header
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
        created_ms,
        updated_ms: stamp.mtime_ms,
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv { argv: argv(&["droid", "--resume", &session_id]), cwd_needed: true },
        session_id,
    });
    Ok(FileRead { entry, state: FileState::folded(path, stamp, offset, tally) })
}
