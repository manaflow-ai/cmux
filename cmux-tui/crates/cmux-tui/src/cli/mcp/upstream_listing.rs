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
    let what = json!({
        "name": spec.name,
        "command": spec.command,
        "program": program,
        "args": spec.args,
        "files": files,
        "env": env,
        "cmux": env!("CARGO_PKG_VERSION"),
    });
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
mod tests {
    use super::*;

    fn spec(command: &Path, token: &str) -> Spec {
        Spec {
            name: "cmux-cua".into(),
            command: command.to_path_buf(),
            args: vec!["mcp".into()],
            env: vec![("CMUX_CUA_SOCKET_AUTH_TOKEN".into(), token.into())],
            call_timeout: std::time::Duration::from_secs(1),
        }
    }

    /// The key names the program `PATH` runs: a same-named file that is not
    /// executable, earlier on `PATH`, is skipped, and the server's own `PATH`
    /// wins over this process's.
    #[cfg(unix)]
    #[test]
    fn the_key_follows_the_program_the_server_runs() {
        use std::os::unix::fs::PermissionsExt as _;
        let home = tempfile::tempdir().unwrap();
        let (early, late) = (home.path().join("early"), home.path().join("late"));
        for dir in [&early, &late] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(early.join("srv"), "not a program").unwrap();
        std::fs::set_permissions(early.join("srv"), std::fs::Permissions::from_mode(0o644))
            .unwrap();
        std::fs::write(late.join("srv"), "#!/bin/sh").unwrap();
        std::fs::set_permissions(late.join("srv"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::join_paths([&early, &late]).unwrap().into_string().unwrap();
        let mut named = spec(Path::new("srv"), "t");
        named.env.push(("PATH".into(), path));
        assert_eq!(resolve(&named), Some(late.join("srv")));
        // A path that names a file nobody may run is no program.
        assert_eq!(resolve(&spec(&early.join("srv"), "t")), None);
        // A script an interpreter runs is part of the key: editing it is a new key.
        let script = home.path().join("server.py");
        std::fs::write(&script, "v1").unwrap();
        let mut by_script = spec(&late.join("srv"), "t");
        by_script.args = vec![script.to_string_lossy().into_owned()];
        let before = key(&by_script).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&script, "version two").unwrap();
        assert_ne!(key(&by_script).unwrap(), before);
        assert!(key(&named).is_some());
        // A bare relative script (`python3 server.py`) counts too: the server
        // starts in this process's directory, so the arg names the same file.
        let bare = tempfile::NamedTempFile::new_in(".").unwrap();
        std::fs::write(bare.path(), "v1").unwrap();
        let name = bare.path().file_name().unwrap().to_string_lossy().into_owned();
        assert_eq!(Path::new(&name).components().count(), 1);
        let mut relative = spec(&late.join("srv"), "t");
        relative.args = vec![name];
        let before = key(&relative).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(bare.path(), "version two").unwrap();
        assert_ne!(key(&relative).unwrap(), before);
        // Without the servers own PATH entry, this processs PATH (no `srv`) finds nothing.
        assert_eq!(resolve(&spec(Path::new("srv-not-on-any-path"), "t")), None);
    }

    #[test]
    fn a_list_is_shared_by_chats_and_dropped_when_the_server_changes() {
        let home = tempfile::tempdir().unwrap();
        let binary = home.path().join("cmux-cua");
        std::fs::write(&binary, "v1").unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(&binary, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let a = spec(&binary, "token-a");
        let listing = Listing {
            tools: vec![json!({"name": "look", "inputSchema": {"type": "object"}})],
            instructions: Some("Ask first.".into()),
        };
        let folder = home.path().join("listings");
        assert_eq!(load(&folder, &a), None, "nothing stored yet");
        store(&folder, &a, &key(&a).unwrap(), &listing);
        assert_eq!(load(&folder, &a), Some(listing.clone()));
        // Another chat's spec differs only in its token's value: the same list.
        assert_eq!(load(&folder, &spec(&binary, "token-b")), Some(listing.clone()));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&folder).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
        }
        // An updated server binary is a new key.
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&binary, "version two").unwrap();
        assert_eq!(load(&folder, &a), None);
        // A torn entry reads as none.
        store(&folder, &a, &key(&a).unwrap(), &listing);
        assert_eq!(load(&folder, &a), Some(listing.clone()));
        for entry in std::fs::read_dir(&folder).unwrap().filter_map(Result::ok) {
            std::fs::write(entry.path(), "{\"tools\": [").unwrap();
        }
        assert_eq!(load(&folder, &a), None);
        // A missing command has no key: nothing is stored or read.
        let gone = spec(&home.path().join("missing"), "t");
        assert_eq!(key(&gone), None);
        assert_eq!(load(&folder, &gone), None);
        // A list read before an update is not stored under the old key.
        let before = key(&a).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&binary, "version three!").unwrap();
        store(&folder, &a, &before, &listing);
        assert_eq!(load(&folder, &a), None);
        store(&folder, &a, &key(&a).unwrap(), &listing);
        assert_eq!(load(&folder, &a), Some(listing));
        // An entry others may read, or a link, is not read.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let entry = folder.join(key(&a).unwrap());
            std::fs::set_permissions(&entry, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert_eq!(load(&folder, &a), None);
            std::fs::set_permissions(&entry, std::fs::Permissions::from_mode(0o600)).unwrap();
            let elsewhere = home.path().join("elsewhere");
            std::fs::rename(&entry, &elsewhere).unwrap();
            std::os::unix::fs::symlink(&elsewhere, &entry).unwrap();
            assert_eq!(load(&folder, &a), None);
        }
    }
}
