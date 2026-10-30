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

/// The entry name for `spec`, or None when its command cannot be read (it
/// then starts to be listed, as before).
fn key(spec: &Spec) -> Option<String> {
    let meta = std::fs::metadata(resolve(&spec.command)?).ok()?;
    let modified = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_nanos();
    let mut env: Vec<&str> = spec.env.iter().map(|(k, _)| k.as_str()).collect();
    env.sort_unstable();
    env.dedup();
    let what = json!({
        "name": spec.name,
        "command": spec.command,
        "args": spec.args,
        "env": env,
        "len": meta.len(),
        "modified": modified.to_string(),
        "cmux": env!("CARGO_PKG_VERSION"),
    });
    let digest = Sha256::digest(what.to_string().as_bytes());
    Some(digest.iter().map(|b| format!("{b:02x}")).collect())
}

/// The file `command` runs: itself when it names a path, else the first
/// executable of that name on `PATH`.
fn resolve(command: &Path) -> Option<PathBuf> {
    if command.components().count() > 1 {
        return Some(command.to_path_buf());
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(command)).find(|at| at.is_file())
}

/// The stored list of `spec`, if there is a whole one.
pub(super) fn load(dir: &Path, spec: &Spec) -> Option<Listing> {
    let file = dir.join(key(spec)?);
    let value: Value = serde_json::from_slice(&std::fs::read(file).ok()?).ok()?;
    let tools = value.get("tools")?.as_array()?.clone();
    if tools.iter().any(|tool| tool.get("name").and_then(Value::as_str).is_none()) {
        return None;
    }
    let instructions = value.get("instructions").and_then(Value::as_str).map(str::to_owned);
    Some(Listing { tools, instructions })
}

/// Stores `listing` for `spec`. Best effort: a failure only means the next
/// `cmux mcp serve` starts the server to list it.
pub(super) fn store(dir: &Path, spec: &Spec, listing: &Listing) {
    let Some(key) = key(spec) else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    let body = json!({"tools": listing.tools, "instructions": listing.instructions}).to_string();
    let tmp = dir.join(format!(".{key}.{}", std::process::id()));
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

    #[test]
    fn a_list_is_shared_by_chats_and_dropped_when_the_server_changes() {
        let home = tempfile::tempdir().unwrap();
        let binary = home.path().join("cmux-cua");
        std::fs::write(&binary, "v1").unwrap();
        let a = spec(&binary, "token-a");
        let listing = Listing {
            tools: vec![json!({"name": "look", "inputSchema": {"type": "object"}})],
            instructions: Some("Ask first.".into()),
        };
        let folder = home.path().join("listings");
        assert_eq!(load(&folder, &a), None, "nothing stored yet");
        store(&folder, &a, &listing);
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
        store(&folder, &a, &listing);
        let entry = std::fs::read_dir(&folder)
            .unwrap()
            .filter_map(Result::ok)
            .find(|e| !e.file_name().to_string_lossy().starts_with('.'))
            .unwrap()
            .path();
        std::fs::write(&entry, "{\"tools\": [").unwrap();
        assert_eq!(load(&folder, &a), None);
        // A missing command has no key: nothing is stored or read.
        let gone = spec(&home.path().join("missing"), "t");
        store(&folder, &gone, &listing);
        assert_eq!(load(&folder, &gone), None);
    }
}
