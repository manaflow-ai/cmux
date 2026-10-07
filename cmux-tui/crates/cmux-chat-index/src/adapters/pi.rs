//! Pi: `<sessions dir>/--<encoded cwd>--/<time>_<uuid>.jsonl`. Line 1 is the
//! session header; `session_info` records rename (last wins, empty clears).
//! A version migration rewrites the file, which the stamp sees as a rewrite.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{argv, files_one_level_down};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_line};
use crate::time::parse_rfc3339_ms;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    files_one_level_down(root, |name| name.ends_with(".jsonl"))
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let header = read_first_record(path)?
        .filter(|record| record.get("type").and_then(Value::as_str) == Some("session"));
    let Some(header) = header else {
        return Ok(FileRead {
            entry: None,
            state: FileState { stamp, offset: stamp.size, ..FileState::default() },
        });
    };
    let (from, mut tally) = FileState::resume_point(prev, &stamp);
    let offset = fold_lines(path, from, |line| {
        if contains(line, br#""type":"message""#) {
            tally.messages += 1;
            if tally.first_prompt.is_none() {
                let record: Option<Value> = serde_json::from_slice(line).ok();
                let message = record.as_ref().and_then(|record| record.get("message"));
                if message.and_then(|message| message.get("role")).and_then(Value::as_str)
                    == Some("user")
                {
                    tally.first_prompt =
                        message.and_then(|message| message.get("content")).and_then(prompt_text);
                }
            }
        } else if contains(line, br#""type":"session_info""#)
            && let Ok(record) = serde_json::from_slice::<Value>(line)
        {
            tally.name = record.get("name").and_then(Value::as_str).and_then(title_line);
        }
    })?;
    let (title, title_source) = match (&tally.name, &tally.first_prompt) {
        (Some(name), _) => (Some(name.clone()), Some(TitleSource::Custom)),
        (None, Some(prompt)) => (Some(prompt.clone()), Some(TitleSource::Prompt)),
        (None, None) => (None, None),
    };
    let session_id = header.get("id").and_then(Value::as_str).map(str::to_owned);
    let entry = session_id.map(|session_id| ChatEntry {
        harness: AdapterKind::Pi,
        session_id,
        title,
        title_source,
        cwd: header
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
        created_ms: header.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms),
        updated_ms: stamp.mtime_ms,
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        // The file path is exact and works from any folder.
        resume: Resume::Argv {
            argv: argv(&["pi", "--session", &path.display().to_string()]),
            cwd_needed: false,
        },
    });
    Ok(FileRead { entry, state: FileState { stamp, offset, tally } })
}
