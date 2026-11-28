//! A run VM's rows: one line of `$ACPMUX_HOME/run-vm.jsonl` per run ([`Row`]: where it ran, fork
//! and first-output times, files back, exit, the fallback's cause), bounded ([`bound_rows`]),
//! which is what RFD 0144's thresholds are re-measured from.

use serde::Serialize;
use std::path::{Path, PathBuf};

/// Where a run ended up, one row of `run-vm.jsonl`.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub class: String,
    /// The ladder size the run VM was asked for, when above the source's (RFD 0144 piece 8).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    /// `fork` when it ran on a run VM, `here` when it fell back.
    pub ran: &'static str,
    /// What sent it: `hook` (Claude Code's Bash call), `shim` (a PATH shim, any process), `cli`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub via: Option<&'static str>,
    /// The program it ran (its first word's file name, never its arguments).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    /// Bytes of file changes the run VM sent back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patch_bytes: Option<usize>,
    /// Bytes of output the run VM streamed back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub out_bytes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fork: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fork_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_output_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wall_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fork_deleted: Option<bool>,
    /// Why it ran here instead, or why its files did not come back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}

/// The rows file: `$ACPMUX_HOME/run-vm.jsonl`.
pub fn rows_path() -> PathBuf {
    crate::config::home().join("run-vm.jsonl")
}

pub fn write_row(row: &Row) {
    let mut v = serde_json::to_value(row).unwrap_or_default();
    if let Some(o) = v.as_object_mut() {
        o.insert("at".into(), serde_json::json!(chrono::Utc::now().to_rfc3339()));
    }
    let path = rows_path();
    if let Some(dir) = path.parent() {
        let _ = crate::home_fs::create_dirs(dir);
    }
    bound_rows(&path, ROWS_MAX_BYTES);
    if let Ok(mut f) = crate::home_fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = std::io::Write::write_all(&mut f, format!("{v}\n").as_bytes());
    }
}

/// The rows file's bound: past it the older half is dropped before the next row.
pub const ROWS_MAX_BYTES: u64 = 4 * 1024 * 1024;

/// Keep `path` under `max` bytes: past it, keep its newer half (whole lines).
pub fn bound_rows(path: &Path, max: u64) {
    if std::fs::metadata(path).map(|m| m.len()).unwrap_or(0) <= max {
        return;
    }
    let Ok(text) = std::fs::read_to_string(path) else { return };
    // The newer half from the first line start past the middle. Found by bytes, so a middle
    // that falls inside a multi-byte character cannot panic; just past a '\n' is always a char
    // boundary, so `get` finds it.
    let cut = text.len() / 2;
    let newer = text
        .as_bytes()
        .iter()
        .skip(cut)
        .position(|&b| b == b'\n')
        .and_then(|i| cut.checked_add(i)?.checked_add(1))
        .and_then(|start| text.get(start..))
        .unwrap_or("");
    // Made whole: a copy beside it, renamed over it.
    let _ = crate::home_fs::write(path, newer);
}

/// The program `command` runs, file name only, never a `VAR=value` or an argument: the first
/// heavy-table program among its commands, else its first command's.
pub fn program_of(command: &str) -> Option<String> {
    let heavy = super::run_vm::heavy_programs();
    let (mut first, mut listed) = (None, None);
    crate::host_load::for_each_command(command, &mut |argv: &[&str]| {
        let Some(name) =
            argv.iter().find(|w| !w.contains('=')).map(|w| w.rsplit('/').next().unwrap_or(w))
        else {
            return;
        };
        first.get_or_insert_with(|| name.to_owned());
        if listed.is_none() && heavy.contains(&name) {
            listed = Some(name.to_owned());
        }
    });
    listed.or(first)
}

/// A row for a command the conformance switch kept here (`CMUX_EXEC_ROUTE=local`).
pub fn write_forced_here(command: &str, via: &'static str) {
    write_row(&Row {
        class: super::run_vm::heavy_class(command).unwrap_or("a command").to_owned(),
        ran: "here",
        via: Some(via),
        program: program_of(command),
        cause: Some(format!("{}=local", super::exec_router::FORCE_ENV)),
        ..Row::default()
    });
}
