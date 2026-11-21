//! Presets whose spawn env was approved ahead of time in a reviewed, root-owned file.
//!
//! A spawn env runs code (`NODE_OPTIONS`, `LD_PRELOAD`, `PATH`), so a preset or defaults write
//! that sets one is the person's own (`hub/person.rs`). That also refused a coordinator's
//! `acpmux preset NAME harness=codex env.CODEX_HOME=/home/leo/.codex-other`, on hosts where no
//! cmux app is ever connected to approve it. This file lets an approval made ahead of time count
//! for exactly such a write, and nothing wider:
//!
//! - Linux only. The list is [`SYSTEM_PATH`], a fixed path, never one a request or the daemon's
//!   flags name. It counts only when the file is a regular file (not a symlink) owned by root and
//!   writable by no one else, and every directory above it (symlinks resolved) is owned by root
//!   and not writable by group or others (a sticky world-writable one aside). An agent runs as
//!   the daemon's user and cannot write it. Root can; on Linux root can also read a keyed
//!   daemon's memory or replace its binary, so the file trusts no one the person key does not
//!   already trust (a Cloud machine's daemon takes its person key from uid 0 too,
//!   `daemon/provision.rs`). On a Mac code signing keeps root out of a Team-signed daemon, so
//!   root is less than the person there and nothing is approved this way. Where the daemon's
//!   user has passwordless sudo, an agent can write the file, and can equally defeat the person
//!   key: on such a host this file is the reviewed record, not a wall, and what bounds it is the
//!   rule below on which env it may approve at all.
//!   Any doubt (missing, wrong owner, unreadable, over [`MAX_BYTES`], unparsable, a schema
//!   other than 1, an unknown field) approves nothing.
//! - An entry approves one preset write: the same `name`, the same `harness` named in the
//!   request, and a request env that is the entry's env map exactly (no key more or less, no
//!   null, the same values). The write merges that env into the stored preset's
//!   (`server/requests/presets.rs`), whose other keys were set by the person. Everything else in the request is checked as before: a policy
//!   that does not ask, a mode that does not ask and `approveMode` stay the person's own.
//!   `_acpmux/defaults` never takes an env from this list, and remote connections are refused
//!   any env before this check (`server/remote_guard.rs`).
//! - An entry counts only when every key is in [`ENV_KEYS`] (a harness's config folder) and
//!   every value is an absolute path below the daemon user's home (the account database's, never
//!   `HOME`), in normal form (no `.`, `..`, `//` or trailing `/`), with no `$` or `~` (the spawn
//!   expands `${model}`, `${home}` and a leading `~/` in env values, `config.rs`), whose existing
//!   part resolves below the home when the preset is written. So even a file root wrote by
//!   mistake approves no `PATH`, `LD_*`, `DYLD_*`, `NODE_OPTIONS` or secret. A config folder
//!   below the home grants nothing the default one (`~/.codex`, `~/.claude`) does not: the
//!   user, and so an agent, can already write either.
//!
//! The file is meant to be rendered from a reviewed registry by a root deploy step
//! (`install -o root -m 0644`); the daemon reads it at each check, so a new entry needs no
//! restart.

use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// Where the approved presets live. Root-owned; see the module docs.
pub const SYSTEM_PATH: &str = "/etc/acpmux/approved-presets.json";
/// The env keys an approved preset may set: a harness's config folder.
pub const ENV_KEYS: &[&str] = &["CODEX_HOME", "CLAUDE_CONFIG_DIR"];
/// A larger file is not read.
pub const MAX_BYTES: u64 = 64 * 1024;

/// Which file to read, whose it must be, and the home its paths must stay under.
#[derive(Clone, Debug)]
pub struct Source {
    pub path: PathBuf,
    /// The owner the file and its directories must have: root, except in tests.
    pub owner_uid: u32,
    /// The daemon user's home; None approves nothing.
    pub home: Option<PathBuf>,
}

impl Source {
    /// The daemon's own: [`SYSTEM_PATH`], owned by root, under this user's home.
    pub fn system() -> Self {
        Self { path: PathBuf::from(SYSTEM_PATH), owner_uid: 0, home: account_home() }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    schema: u32,
    #[serde(default)]
    #[allow(dead_code)]
    about: Option<String>,
    presets: Vec<Entry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    name: String,
    harness: String,
    env: BTreeMap<String, String>,
    #[serde(default)]
    #[allow(dead_code)]
    about: Option<String>,
}

/// Whether the non-person preset write `params` (`_acpmux/presets {name, set}`) sets only an
/// env that `source` approves for that preset (module docs). The caller still runs every other
/// check on the request.
pub fn approves(source: &Source, params: &Value) -> bool {
    let Some(home) = source.home.as_deref() else { return false };
    if params.get("clear").and_then(Value::as_bool) == Some(true) {
        return false;
    }
    let Some(name) = params.get("name").and_then(Value::as_str) else { return false };
    let Some(set) = params.get("set").and_then(Value::as_object) else { return false };
    let Some(harness) = set.get("harness").and_then(Value::as_str) else { return false };
    let Some(env) = set.get("env").and_then(Value::as_object) else { return false };
    let mut asked = BTreeMap::new();
    for (k, v) in env {
        let Some(v) = v.as_str() else { return false };
        asked.insert(k.clone(), v.to_owned());
    }
    if asked.is_empty() {
        return false;
    }
    let Some(text) = read_trusted(&source.path, source.owner_uid) else { return false };
    let Ok(file) = serde_json::from_str::<File>(&text) else { return false };
    if file.schema != 1 {
        return false;
    }
    file.presets.iter().any(|e| {
        e.name == name
            && e.harness == harness
            && e.env == asked
            && e.env.iter().all(|(k, v)| env_ok(home, k, v))
    })
}

/// An approvable env pair: a listed key, and a path below `home` that stays there.
fn env_ok(home: &Path, key: &str, value: &str) -> bool {
    if !ENV_KEYS.contains(&key) || value.contains(['\0', '$', '~']) {
        return false;
    }
    let path = Path::new(value);
    let mut parts = path.components();
    if parts.next() != Some(Component::RootDir) {
        return false;
    }
    if !parts.all(|c| matches!(c, Component::Normal(_))) {
        return false;
    }
    // Written in its one normal form: no `/./`, `//` or trailing `/` (which `components` skips).
    if path.components().collect::<PathBuf>().as_os_str() != path.as_os_str() {
        return false;
    }
    if !path.starts_with(home) || path == home {
        return false;
    }
    // Symlinks: the deepest part that exists must resolve below the home.
    let Ok(real_home) = std::fs::canonicalize(home) else { return false };
    let Some(existing) = path.ancestors().find(|a| std::fs::symlink_metadata(a).is_ok()) else {
        return false;
    };
    std::fs::canonicalize(existing).is_ok_and(|real| real.starts_with(&real_home))
}

/// The file's text when it, and every directory above it, is `owner`'s alone (module docs).
#[cfg(target_os = "linux")]
fn read_trusted(path: &Path, owner: u32) -> Option<String> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let parent =
        std::fs::canonicalize(path.parent().filter(|p| !p.as_os_str().is_empty())?).ok()?;
    for dir in parent.ancestors() {
        let m = std::fs::metadata(dir).ok()?;
        let sticky = m.mode() & 0o1000 != 0;
        // Root's directories count too (`owner` is root but in tests).
        if !m.is_dir() || (m.uid() != owner && m.uid() != 0) || (m.mode() & 0o022 != 0 && !sticky) {
            return None;
        }
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(parent.join(path.file_name()?))
        .ok()?;
    let m = file.metadata().ok()?;
    if !m.is_file() || m.uid() != owner || m.mode() & 0o022 != 0 || m.len() > MAX_BYTES {
        return None;
    }
    let mut text = String::new();
    file.take(MAX_BYTES + 1).read_to_string(&mut text).ok()?;
    (text.len() as u64 <= MAX_BYTES).then_some(text)
}

/// Not Linux: nothing is approved (module docs).
#[cfg(not(target_os = "linux"))]
fn read_trusted(_path: &Path, _owner: u32) -> Option<String> {
    None
}

/// This uid's home from the account database, never `HOME`; None when it has none.
#[cfg(target_os = "linux")]
fn account_home() -> Option<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 64 * 1024];
    // SAFETY: every output pointer refers to a live buffer; the strings the entry points to live
    // in `buffer`, which outlives their use below.
    let code = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    // SAFETY: a successful lookup filled `result`; `pw_dir` is checked for null first.
    if code != 0 || result.is_null() || unsafe { (*result).pw_dir }.is_null() {
        return None;
    }
    let dir = unsafe { CStr::from_ptr((*result).pw_dir) };
    let path = PathBuf::from(OsStr::from_bytes(dir.to_bytes()));
    (path.is_absolute() && path != Path::new("/")).then_some(path)
}

#[cfg(not(target_os = "linux"))]
fn account_home() -> Option<PathBuf> {
    None
}
