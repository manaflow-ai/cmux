//! The last tool list of each of a chat's other MCP servers (`upstream.rs`),
//! kept on disk so `cmux mcp serve` answers `tools/list` without starting
//! them. A harness lists its servers' tools as it starts (Codex once per
//! thread), so starting each upstream to list it put one `cmux-cua` helper
//! under every chat's `cmux` server whether or not it ever used computer use:
//! 93 to 131 idle helpers on one Mac (2026-10-29). With a stored list, a
//! server starts on its first call, which lists it again and stores the list.
//!
//! An entry is keyed by what decides the list: the server's command and args,
//! the names (not the values: tokens and session ids) of its env, the
//! command's size and modification time (an app update is a new key), and
//! this cmux's version. The folder is the person's own (`0700`, files `0600`)
//! and an entry is written whole (a temporary file renamed into place), so a
//! torn or foreign entry reads as none and the server starts as before.

use std::path::{Path, PathBuf};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::upstream::Spec;

/// What a start learned: the server's tools and its `initialize`
/// instructions, as it gave them.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Listing {
    pub tools: Vec<Value>,
    pub instructions: Option<String>,
}

/// The person's folder: `~/.cache/cmux/mcp-upstreams`.
pub(super) fn default_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").filter(|h| !h.is_empty())?;
    Some(Path::new(&home).join(".cache").join("cmux").join("mcp-upstreams"))
}

/// A file’s identity for a key: its real path, size and modification time.
fn stamp(path: &Path) -> Option<Value> {
    let real = path.canonicalize().ok()?;
    let meta = std::fs::metadata(&real).ok()?;
    let modified = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
    Some(json!([real, meta.len(), modified.to_string()]))
}

/// The entry name for `spec`, or None when its command cannot be read (it
/// then starts to be listed, as before). It names the file `PATH` resolves
/// the command to, so another `PATH` is another entry, and every arg that
/// names a file (a script an interpreter runs, `server.py` included: the
/// server starts in this process's directory, where a relative arg resolves
/// the same way), so editing it is a new entry.
pub(super) fn key(spec: &Spec) -> Option<String> {
    let program = stamp(&resolve(spec)?)?;
    let files: Vec<Value> =
        spec.args.iter().map(Path::new).filter(|arg| arg.is_file()).filter_map(stamp).collect();
    let mut env: Vec<&str> = spec.env.iter().map(|(k, _)| k.as_str()).collect();
    env.sort_unstable();
    env.dedup();
    let mut what = json!({
        "name": spec.name,
        "command": spec.command,
        "program": program,
        "args": spec.args,
        "files": files,
        "env": env,
        "cmux": env!("CARGO_PKG_VERSION"),
    });
    // A server in a shared process lists what that process gives it: its launch is in the key,
    // with its env's names only, as the server's own.
    if let Some(shared) = &spec.shared {
        let mut env: Vec<&str> = shared.env.iter().map(|(k, _)| k.as_str()).collect();
        env.sort_unstable();
        env.dedup();
        what.set("shared", json!({"command": shared.command, "args": shared.args, "env": env}));
    }
    let digest = Sha256::digest(what.to_string().as_bytes());
    Some(digest.iter().map(|b| format!("{b:02x}")).collect())
}

/// The file `spec`'s command runs: itself when it names a path, else the
/// first executable of that name on the `PATH` the server starts with (its
/// own env's, else this process's), as `Command` picks it.
fn resolve(spec: &Spec) -> Option<PathBuf> {
    let command = &spec.command;
    if command.components().count() > 1 {
        return executable(command).then(|| command.clone());
    }
    let path = match spec.env.iter().rev().find(|(k, _)| k == "PATH") {
        Some((_, value)) => std::ffi::OsString::from(value),
        None => std::env::var_os("PATH")?,
    };
    std::env::split_paths(&path).map(|dir| dir.join(command)).find(|at| executable(at))
}

/// Whether `path` is a file someone may run.
fn executable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    #[cfg(unix)]
    let runs = std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o111 != 0;
    #[cfg(not(unix))]
    let runs = true;
    meta.is_file() && runs
}

/// Whether `path` is this user's own and not a symlink: a folder only they
/// can write, or a file only they can read and write. Another user's entry,
/// or a link to one, is never read or written through.
fn private(path: &Path, folder: bool) -> bool {
    let Ok(meta) = std::fs::symlink_metadata(path) else { return false };
    if folder != meta.is_dir() || (!folder && !meta.is_file()) {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        // SAFETY: geteuid has no preconditions.
        let own = unsafe { libc::geteuid() };
        let open = if folder { 0o022 } else { 0o077 };
        if meta.uid() != own || meta.mode() & open != 0 {
            return false;
        }
    }
    true
}

/// The stored list of `spec`, if there is a whole one.
pub(super) fn load(dir: &Path, spec: &Spec) -> Option<Listing> {
    let file = dir.join(key(spec)?);
    if !private(dir, true) || !private(&file, false) {
        return None;
    }
    let value: Value = serde_json::from_slice(&std::fs::read(file).ok()?).ok()?;
    let tools = value.get("tools")?.as_array()?.clone();
    if tools.iter().any(|tool| tool.get("name").and_then(Value::as_str).is_none()) {
        return None;
    }
    let instructions = value.get("instructions").and_then(Value::as_str).map(str::to_owned);
    Some(Listing { tools, instructions })
}

/// Stores `listing` under `key`, the key `spec` had before its server
/// started: when the command changed since (an update mid-start), nothing
/// is stored. Best effort: a failure only means the next `cmux mcp serve`
/// starts the server to list it.
pub(super) fn store(dir: &Path, spec: &Spec, key: &str, listing: &Listing) {
    if self::key(spec).as_deref() != Some(key) {
        return;
    }
    if std::fs::symlink_metadata(dir).is_err() {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        if builder.create(dir).is_err() {
            return;
        }
    }
    if !private(dir, true) {
        return;
    }
    let body = json!({"tools": listing.tools, "instructions": listing.instructions}).to_string();
    let tmp = dir.join(format!(".{key}.{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let written = options.open(&tmp).and_then(|mut file| {
        std::io::Write::write_all(&mut file, body.as_bytes())?;
        file.sync_all()
    });
    if written.is_err() || std::fs::rename(&tmp, dir.join(key)).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests;
