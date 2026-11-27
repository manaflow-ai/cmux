//! `__files-lister`: the Files pane's folder reads, out of the app's process.
//!
//! macOS charges a Files and Folders check (Desktop, Documents, Downloads, …) to the responsible
//! process of the code that reads. A DEV build of cmux NEXT starts this mode under the pinned
//! helper "cmux Files (dev)" (`cmux-files-host run -- cmux-tui __files-lister`), so listing
//! `~/Downloads` in the Files pane asks once for every DEV build, as the terminals do, instead of
//! once per tag (docs/cmux-files-host.md, "The Files pane"). Shipped builds never start it.
//!
//! The protocol is one JSON object per line on stdin and one reply per line on stdout, in order:
//!
//! - `{"id": 1, "op": "list", "path": "/abs/folder"}` answers `{"id": 1, "entries": [ENTRY, …]}`;
//! - `{"id": 2, "op": "entry", "path": "/abs/item"}` answers `{"id": 2, "entry": ENTRY}` or
//!   `{"id": 2, "entry": null}` when the item is gone;
//! - a folder that cannot be read answers `{"id": 1, "errno": 13}`; a line that is not a request
//!   answers `{"id": null, "error": "..."}` (and the id when the line had one).
//!
//! `ENTRY` is `{"n": name, "k": "dir"|"file"|"link"|"other", "s": bytes, "m": modified, "c":
//! created, "h": hidden}`, dates in seconds since 1970 (fractional), `h` for a dot name or the
//! `UF_HIDDEN` flag, `s` 0 for anything but a file. Symlinks are never followed. The mode ends
//! at the end of stdin, which is when the app that started it goes away.

use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{BufRead, Read, Write};
use std::path::Path;

/// The argv mode (private_mode.rs).
pub(crate) const MODE: &str = "__files-lister";

/// The longest request line read; a path is far shorter.
const MAX_LINE: usize = 64 * 1024;

#[derive(Deserialize)]
struct Request {
    id: Value,
    op: String,
    path: String,
}

/// Serves requests from stdin until it ends.
pub(crate) fn run() -> i32 {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    match serve(stdin.lock(), stdout.lock()) {
        Ok(()) => 0,
        Err(error) => {
            crate::client_log::stderr_log!("startup", "cmux-tui {MODE}: {error}");
            1
        }
    }
}

/// One reply per request line, flushed after each, until `input` ends.
pub(crate) fn serve(mut input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = Read::take(&mut input, MAX_LINE as u64 + 1).read_until(b'\n', &mut line)?;
        if read == 0 {
            return Ok(());
        }
        let reply = if line.len() > MAX_LINE && line.last() != Some(&b'\n') {
            // Drop the rest of the oversized line, then refuse it.
            let mut rest = Vec::new();
            input.read_until(b'\n', &mut rest)?;
            json!({ "id": Value::Null, "error": "request line too long" })
        } else {
            answer(&line)
        };
        serde_json::to_writer(&mut output, &reply)?;
        output.write_all(b"\n")?;
        output.flush()?;
    }
}

fn answer(line: &[u8]) -> Value {
    let request: Request = match serde_json::from_slice(line) {
        Ok(request) => request,
        Err(error) => {
            let id = serde_json::from_slice::<Value>(line)
                .ok()
                .and_then(|value| value.get("id").cloned())
                .unwrap_or(Value::Null);
            return json!({ "id": id, "error": format!("bad request: {error}") });
        }
    };
    let path = Path::new(&request.path);
    if !path.is_absolute() {
        return json!({ "id": request.id, "error": "the path is not absolute" });
    }
    match request.op.as_str() {
        "list" => match list(path) {
            Ok(entries) => json!({ "id": request.id, "entries": entries }),
            Err(error) => {
                json!({ "id": request.id, "errno": error.raw_os_error().unwrap_or(libc::EIO) })
            }
        },
        "entry" => {
            let name = path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            let entry =
                std::fs::symlink_metadata(path).ok().map(|metadata| encode(&name, &metadata));
            json!({ "id": request.id, "entry": entry })
        }
        other => json!({ "id": request.id, "error": format!("unknown op {other}") }),
    }
}

/// Every child of `folder`, hidden ones included. A child that vanishes between the read and its
/// `lstat` is left out, as the listing would have been a moment later.
fn list(folder: &Path) -> std::io::Result<Vec<Value>> {
    let mut entries = Vec::new();
    for child in std::fs::read_dir(folder)? {
        let child = child?;
        // DirEntry::metadata is an lstat: a symlink is reported as itself.
        let Ok(metadata) = child.metadata() else { continue };
        entries.push(encode(&child.file_name().to_string_lossy(), &metadata));
    }
    Ok(entries)
}

fn encode(name: &str, metadata: &std::fs::Metadata) -> Value {
    use std::os::unix::fs::MetadataExt;
    let kind = metadata.file_type();
    let kind = if kind.is_symlink() {
        "link"
    } else if kind.is_dir() {
        "dir"
    } else if kind.is_file() {
        "file"
    } else {
        "other"
    };
    let size = if kind == "file" { metadata.size() } else { 0 };
    let modified = seconds(metadata.mtime(), metadata.mtime_nsec());
    let created = birth(metadata).unwrap_or(modified);
    json!({
        "n": name,
        "k": kind,
        "s": size,
        "m": modified,
        "c": created,
        "h": name.starts_with('.') || hidden_flag(metadata),
    })
}

fn seconds(seconds: i64, nanoseconds: i64) -> f64 {
    seconds as f64 + nanoseconds as f64 / 1_000_000_000.0
}

#[cfg(target_os = "macos")]
fn birth(metadata: &std::fs::Metadata) -> Option<f64> {
    use std::os::macos::fs::MetadataExt;
    Some(seconds(metadata.st_birthtime(), metadata.st_birthtime_nsec()))
}

#[cfg(not(target_os = "macos"))]
fn birth(metadata: &std::fs::Metadata) -> Option<f64> {
    let created = metadata.created().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
    Some(created.as_secs_f64())
}

#[cfg(target_os = "macos")]
fn hidden_flag(metadata: &std::fs::Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    metadata.st_flags() & libc::UF_HIDDEN != 0
}

#[cfg(not(target_os = "macos"))]
fn hidden_flag(_metadata: &std::fs::Metadata) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::serve;
    use serde_json::Value;

    fn replies(input: &str) -> Vec<Value> {
        let mut output = Vec::new();
        serve(input.as_bytes(), &mut output).expect("serve");
        String::from_utf8(output)
            .expect("utf-8")
            .lines()
            .map(|line| serde_json::from_str(line).expect("json"))
            .collect()
    }

    #[test]
    fn lists_a_folder_with_kinds_sizes_and_hidden_flags() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("a.txt"), b"hello").expect("write");
        std::fs::write(dir.path().join(".secret"), b"").expect("write");
        std::fs::create_dir(dir.path().join("sub")).expect("mkdir");
        std::os::unix::fs::symlink("a.txt", dir.path().join("link")).expect("symlink");
        let request =
            format!("{{\"id\":7,\"op\":\"list\",\"path\":{}}}\n", serde_json::json!(dir.path()));
        let reply = &replies(&request)[0];
        assert_eq!(reply["id"], 7);
        let mut entries = reply["entries"].as_array().expect("entries").clone();
        entries.sort_by_key(|entry| entry["n"].as_str().unwrap_or_default().to_owned());
        let summary: Vec<(String, String, u64, bool)> = entries
            .iter()
            .map(|entry| {
                (
                    entry["n"].as_str().unwrap_or_default().to_owned(),
                    entry["k"].as_str().unwrap_or_default().to_owned(),
                    entry["s"].as_u64().unwrap_or(99),
                    entry["h"].as_bool().unwrap_or_default(),
                )
            })
            .collect();
        assert_eq!(
            summary,
            vec![
                (".secret".into(), "file".into(), 0, true),
                ("a.txt".into(), "file".into(), 5, false),
                ("link".into(), "link".into(), 0, false),
                ("sub".into(), "dir".into(), 0, false),
            ]
        );
        assert!(entries[1]["m"].as_f64().unwrap_or_default() > 1_000_000_000.0);
    }

    #[test]
    fn answers_errno_for_a_missing_folder_and_null_for_a_gone_item() {
        let lines = "{\"id\":1,\"op\":\"list\",\"path\":\"/nonexistent-cmux-files-lister\"}\n\
                     {\"id\":2,\"op\":\"entry\",\"path\":\"/nonexistent-cmux-files-lister\"}\n";
        let replies = replies(lines);
        assert_eq!(replies[0]["errno"], libc::ENOENT);
        assert_eq!(replies[1], serde_json::json!({"id": 2, "entry": null}));
    }

    #[test]
    fn answers_one_item_and_refuses_bad_lines_in_order() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("b.bin"), b"123").expect("write");
        let path = dir.path().join("b.bin");
        let lines = format!(
            "not json\n{{\"id\":3,\"op\":\"entry\",\"path\":{}}}\n{{\"id\":4,\"op\":\"list\",\"path\":\"relative\"}}\n{{\"id\":5,\"op\":\"rm\",\"path\":\"/\"}}\n",
            serde_json::json!(path)
        );
        let replies = replies(&lines);
        assert_eq!(replies.len(), 4);
        assert!(replies[0]["error"].is_string());
        assert_eq!(replies[1]["entry"]["n"], "b.bin");
        assert_eq!(replies[1]["entry"]["s"], 3);
        assert_eq!(replies[2]["id"], 4);
        assert!(replies[2]["error"].is_string());
        assert_eq!(replies[3]["id"], 5);
        assert!(replies[3]["error"].as_str().unwrap_or_default().contains("unknown op"));
    }

    #[test]
    fn refuses_an_oversized_line_and_keeps_serving() {
        let lines = format!(
            "{}\n{{\"id\":9,\"op\":\"entry\",\"path\":\"/\"}}\n",
            "x".repeat(super::MAX_LINE + 10)
        );
        let replies = replies(&lines);
        assert_eq!(replies.len(), 2);
        assert_eq!(replies[0]["error"], "request line too long");
        assert_eq!(replies[1]["id"], 9);
        assert_eq!(replies[1]["entry"]["k"], "dir");
    }
}
