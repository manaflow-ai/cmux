//! The hang record and where it goes: one JSON line per overdue scope in `hangs-<pid>.jsonl`.

use std::fmt::Write as _;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use crate::{Stack, ThreadKind};

/// One overdue scope.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hang {
    pub pid: u32,
    /// When the watcher saw it, on the watch's [`Clock`].
    pub t_ns: u64,
    /// The thread's name as registered (a catalog string, never a person's text).
    pub thread: String,
    pub kind: ThreadKind,
    /// The thread's id for the sampler and the OS tools: its Mach port on macOS, its tid on Linux,
    /// `GetCurrentThreadId` on Windows.
    pub native_thread_id: u64,
    /// The slot's index in the slot table.
    pub slot: u32,
    /// The scope's deadline, from its open.
    pub deadline_ms: u64,
    /// How far past the deadline the watcher saw it.
    pub overdue_ms: u64,
    /// The hung thread's stack (macOS), None where there is no sampler or the sample failed.
    pub stack: Option<Stack>,
}

impl Hang {
    /// The record as one JSON line, newline included (schema 1 of `hangs-<pid>.jsonl`; the
    /// `stack` member is there only when the thread was sampled).
    pub fn to_json_line(&self) -> String {
        let mut line = String::with_capacity(160);
        let _ =
            write!(line, "{{\"schema\":1,\"pid\":{},\"t_ns\":{},\"thread\":", self.pid, self.t_ns);
        push_json_string(&mut line, &self.thread);
        let _ = write!(
            line,
            ",\"kind\":\"{}\",\"native_thread_id\":{},\"slot\":{},\"deadline_ms\":{},\"overdue_ms\":{}",
            self.kind.as_str(),
            self.native_thread_id,
            self.slot,
            self.deadline_ms,
            self.overdue_ms,
        );
        if let Some(stack) = &self.stack {
            stack.push_json(&mut line);
        }
        line.push_str("}\n");
        line
    }
}

pub(crate) fn push_json_string(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            ch if (ch as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", ch as u32);
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
}

/// Where hang records go. The watcher thread calls it, never a watched thread.
pub trait HangSink: Send + Sync {
    fn record(&self, hang: &Hang) -> io::Result<()>;
}

/// Appends each hang as one line to `hangs-<pid>.jsonl`.
#[derive(Clone, Debug)]
pub struct JsonlSink {
    path: PathBuf,
}

impl JsonlSink {
    /// `<dir>/hangs-<this pid>.jsonl`.
    pub fn in_dir(dir: impl AsRef<Path>) -> JsonlSink {
        JsonlSink { path: dir.as_ref().join(file_name(std::process::id())) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// The hang file of process `pid`.
pub fn file_name(pid: u32) -> String {
    format!("hangs-{pid}.jsonl")
}

impl HangSink for JsonlSink {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&self.path)?;
        // One write of the whole line: an append that small lands whole.
        file.write_all(hang.to_json_line().as_bytes())
    }
}
