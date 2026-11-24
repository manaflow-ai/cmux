//! Settings that belong to one cmux build, not to the Mac account: whether agents get cmux's
//! tools (`agents.cmuxMcp`, `agents.cmuxMcpClaude`, `agents.cmuxMcpCodex`) and every Computer Use
//! permission (`computerUse.*`: on or off, Full access, denied apps, menus, other machines, what a
//! takeover does).
//!
//! NIGHTLY, Release, RC and cmux NEXT all read and write one settings file,
//! `~/.config/cmux/cmux-next.json` (a DEV build has its own, `BuildStatePaths`). So one build's
//! answer or grant applied to every other: turning Computer Use off in NIGHTLY turned it off in
//! Release, and a grant made in Release let NIGHTLY's agents act. Each build's cmux MCP server and
//! Computer Use permission state must be its own. Every other preference stays shared, as before.
//!
//! So a build on the shared file keeps those keys in a file of its own,
//! [`BUILD_SETTINGS_ENV`] (the app names it for its children: `BuildStatePaths.buildSettingsFile`,
//! `~/Library/Application Support/cmux-next/builds/<bundle id[--tag]>/build-settings.json`), and
//! every reader sees the shared file with those keys taken from it ([`overlaid_source`],
//! [`effective_text`]): the daemon's settings owner (so the palette, `cmux settings` and the MCP
//! `settings_*` tools read and write them as before), the app (`build_scope.source`, an app op), and
//! the readers outside the owner (the `claude` and `codex` shims, acpmux, `cmux mcp serve`).
//!
//! The first read of a build that has no file yet copies the shared file's values into it, once
//! ([`build_values`]): a build keeps what the person chose before the split, then the builds part.
//! The shared file keeps its own values for builds that predate the split; a build on it never
//! writes them again. With `CMUX_NEXT_CONFIG_FILE` set (a DEV build, a test launch) the settings
//! file is already the build's own and nothing here applies.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::jsonc;
use crate::location::CONFIG_OVERRIDE;

/// The variable that names this build's file of build-scoped settings (`BuildStatePaths.buildSettingsFileKey`).
pub const BUILD_SETTINGS_ENV: &str = "CMUX_NEXT_BUILD_SETTINGS_FILE";

/// The build-scoped settings, as key paths: each value at one of them (and below it) is the build's.
pub const SCOPED_PATHS: [&[&str]; 4] = [
    &["agents", "cmuxMcp"],
    &["agents", "cmuxMcpClaude"],
    &["agents", "cmuxMcpCodex"],
    &["computerUse"],
];

/// Whether the dotted key `key` is build-scoped (`computerUse.mode`, `agents.cmuxMcp`).
pub fn is_scoped_key(key: &str) -> bool {
    SCOPED_PATHS.iter().any(|path| {
        let dotted = path.join(".");
        key == dotted || key.strip_prefix(dotted.as_str()).is_some_and(|rest| rest.starts_with('.'))
    })
}

/// Whether the key path `path` is or lies under a build-scoped setting.
pub fn is_scoped_path<S: AsRef<str>>(path: &[S]) -> bool {
    SCOPED_PATHS.iter().any(|scoped| {
        path.len() >= scoped.len() && scoped.iter().zip(path).all(|(a, b)| *a == b.as_ref())
    })
}

/// This process's file of build-scoped settings: [`BUILD_SETTINGS_ENV`] (a leading `~` is the
/// home), only while the settings file is the shared one (no `CMUX_NEXT_CONFIG_FILE`, or one that
/// names `~/.config/cmux/cmux-next.json` itself, as the agent shims pass it to `cmux mcp serve`).
pub fn build_file() -> Option<PathBuf> {
    build_file_from(|name| std::env::var_os(name).filter(|value| !value.is_empty()))
}

/// [`build_file`] with an injected environment.
pub fn build_file_from(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> Option<PathBuf> {
    if env(CONFIG_OVERRIDE).is_some_and(|value| !value.is_empty()) {
        let shared = crate::location::config_path_from(|name| {
            if name == CONFIG_OVERRIDE { None } else { env(name) }
        });
        if crate::location::config_path_from(&env) != shared {
            return None;
        }
    }
    let path = PathBuf::from(env(BUILD_SETTINGS_ENV).filter(|value| !value.is_empty())?);
    if let Ok(rest) = path.strip_prefix("~") {
        return Some(PathBuf::from(env("HOME")?).join(rest));
    }
    path.is_absolute().then_some(path)
}

/// The build-scoped values of a settings document `root`, as one nested object (`{"agents":
/// {"cmuxMcp": "off"}, "computerUse": {...}}`). A flat key (`"agents.cmuxMcp"`,
/// `"computerUse.mode"`) counts as its nested form; for the cmux tools answer an `"off"` in either
/// form wins (as `AgentsCmuxMcp` reads it), for the rest the nested value does.
pub fn extract(root: &Value) -> Value {
    let mut out = Value::Object(Map::new());
    let Some(members) = root.as_object() else { return out };
    for path in SCOPED_PATHS {
        let nested = path.iter().try_fold(root, |node, key| node.get(*key)).cloned();
        let flat = members.get(&path.join(".")).cloned();
        let off = Value::String("off".into());
        let value = if *path == ["agents", "cmuxMcp"] && flat.as_ref() == Some(&off) {
            Some(off)
        } else {
            nested.or(flat)
        };
        if let Some(value) = value {
            insert(&mut out, path, value);
        }
    }
    // Flat keys below a scoped object (`"computerUse.mode"`) fill what the nested object leaves out.
    for (key, value) in members {
        let parts: Vec<&str> = key.split('.').collect();
        if parts.len() > 1
            && is_scoped_path(&parts)
            && !SCOPED_PATHS.iter().any(|p| p.join(".") == *key)
        {
            let present = parts.iter().try_fold(&out, |node, key| node.get(*key)).is_some();
            if !present {
                insert(&mut out, &parts, value.clone());
            }
        }
    }
    out
}

fn insert(root: &mut Value, path: &[&str], value: Value) {
    let Some((last, parents)) = path.split_last() else { return };
    let mut node = root;
    for key in parents {
        let Value::Object(map) = node else { return };
        node = map.entry((*key).to_string()).or_insert_with(|| Value::Object(Map::new()));
    }
    if let Value::Object(map) = node {
        map.insert((*last).to_string(), value);
    }
}

/// `source` (a settings file's JSONC text) with every build-scoped member taken out, flat or
/// nested, and `values` (an [`extract`] object) put in, everything else byte for byte. A text that
/// does not parse comes back unchanged: the owner keeps reading its last good document.
pub fn overlaid_source(source: &str, values: &Value) -> String {
    let base = if source.trim().is_empty() { "{}\n".to_string() } else { source.to_string() };
    let Ok(root @ Value::Object(_)) = jsonc::parse(&base) else { return source.to_string() };
    let mut text = base;
    // A path the build sets is replaced in place (`jsonc::set` keeps its position and the comments
    // around it); a path it does not set, and every flat spelling, is taken out, every copy of it.
    let mut removals: Vec<Vec<String>> = SCOPED_PATHS
        .iter()
        .filter(|path| path.iter().try_fold(values, |node, key| node.get(*key)).is_none())
        .map(|path| path.iter().map(|key| (*key).to_string()).collect())
        .collect();
    for key in root.as_object().into_iter().flat_map(Map::keys) {
        if key.contains('.') && is_scoped_key(key) {
            removals.push(vec![key.clone()]);
        }
    }
    for path in removals {
        // `jsonc::remove` takes the last member of a repeated key: repeat until none is left.
        loop {
            match jsonc::remove(&text, &path) {
                Ok(next) if next == text => break,
                Ok(next) => text = next,
                Err(_) => return source.to_string(),
            }
        }
    }
    for path in SCOPED_PATHS {
        let Some(value) = path.iter().try_fold(values, |node, key| node.get(*key)) else {
            continue;
        };
        let owned: Vec<String> = path.iter().map(|key| (*key).to_string()).collect();
        match jsonc::set(&text, &owned, value) {
            Ok(next) => text = next,
            Err(_) => return source.to_string(),
        }
    }
    // An `agents` object left empty by the removal (the shared file held only scoped keys) stays
    // as written: an empty object reads as no value.
    if source.trim().is_empty() && values.as_object().is_none_or(Map::is_empty) {
        return source.to_string();
    }
    text
}

/// The build's values from its file `build_file`, made from `shared` (the shared file's text) on
/// the first read: the file is then written once, never over one another process wrote first. A
/// shared file that does not parse right then (a typo, a save half done) writes nothing: its values
/// are read as none for now and the next good read makes the file, so a broken moment never resets
/// the person's grants. A build file that does not parse gives the shared values and is left for
/// the person to fix (the owner refuses to write over it: [`build_file_is_broken`]).
pub fn build_values(build_file: &Path, shared: &str) -> Value {
    match std::fs::read_to_string(build_file) {
        Ok(text) => match jsonc::parse(&text) {
            Ok(value @ Value::Object(_)) => value,
            _ => migrated(shared).unwrap_or_else(|| Value::Object(Map::new())),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let Some(values) = migrated(shared) else { return Value::Object(Map::new()) };
            match write_new(build_file, &render(&values)) {
                Ok(()) => values,
                // Another reader wrote it first: its copy is the build's.
                Err(_) => match std::fs::read_to_string(build_file).map(|text| jsonc::parse(&text))
                {
                    Ok(Ok(value @ Value::Object(_))) => value,
                    _ => values,
                },
            }
        }
        Err(_) => migrated(shared).unwrap_or_else(|| Value::Object(Map::new())),
    }
}

/// Whether `build_file` exists but is not a JSON object (a hand edit gone wrong): a write must not
/// replace it.
pub fn build_file_is_broken(build_file: &Path) -> bool {
    match std::fs::read_to_string(build_file) {
        Ok(text) => !matches!(jsonc::parse(&text), Ok(Value::Object(_))),
        Err(error) => error.kind() != io::ErrorKind::NotFound,
    }
}

/// The build-scoped values of the shared file's text; `None` when it does not parse.
fn migrated(shared: &str) -> Option<Value> {
    match jsonc::parse(if shared.trim().is_empty() { "{}" } else { shared }) {
        Ok(root @ Value::Object(_)) => Some(extract(&root)),
        _ => None,
    }
}

/// The file text of `values`.
pub fn render(values: &Value) -> String {
    let mut text = serde_json::to_string_pretty(values).unwrap_or_else(|_| "{}".into());
    text.push('\n');
    text
}

/// Writes `text` to `path` only when no file is there (a temp file linked into place), 0600.
fn write_new(path: &Path, text: &str) -> io::Result<()> {
    let directory = path.parent().ok_or_else(|| io::Error::other("no folder"))?;
    std::fs::create_dir_all(directory)?;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = directory.join(format!(".{name}.{}.new", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&temporary)?;
        io::Write::write_all(&mut file, text.as_bytes())?;
        file.sync_all()?;
        std::fs::hard_link(&temporary, path)
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}

/// The settings text a reader outside the owner sees for the file at `shared_path`: the file
/// (empty when missing) with this build's values over it ([`build_file`]); the file itself when the
/// build has no file of its own.
pub fn effective_text(shared_path: &Path) -> io::Result<String> {
    effective_text_with(shared_path, build_file().as_deref())
}

/// `shared` (the shared settings file's text, as read) with this build's values over it
/// ([`build_file`]); unchanged for a build without a file of its own.
pub fn overlay_text(shared: String) -> String {
    match build_file() {
        Some(build_file) => {
            let values = build_values(&build_file, &shared);
            overlaid_source(&shared, &values)
        }
        None => shared,
    }
}

/// [`effective_text`] with an explicit build file.
pub fn effective_text_with(shared_path: &Path, build_file: Option<&Path>) -> io::Result<String> {
    let shared = match std::fs::read_to_string(shared_path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound && build_file.is_some() => {
            String::new()
        }
        Err(error) => return Err(error),
    };
    let Some(build_file) = build_file else { return Ok(shared) };
    Ok(overlaid_source(&shared, &build_values(build_file, &shared)))
}

/// What the owner publishes after a write that left `merged` (the overlaid text it edits): the
/// build's values, and the shared file's next text with its own build-scoped members as they are
/// on disk (`shared_on_disk`), or `None` when nothing but build-scoped values changed (the shared
/// file is then left alone).
pub fn split(merged: &str, shared_on_disk: &str) -> Option<(Value, Option<String>)> {
    let merged_root = jsonc::parse(merged).ok()?;
    let values = extract(&merged_root);
    let disk_values = migrated(shared_on_disk)?;
    let shared_next = overlaid_source(merged, &disk_values);
    let unscoped =
        |text: &str| jsonc::parse(&overlaid_source(text, &Value::Object(Map::new()))).ok();
    let changed = unscoped(&shared_next) != unscoped(shared_on_disk)
        || (shared_on_disk.trim().is_empty() && !is_empty_document(&shared_next));
    Some((values, changed.then_some(shared_next)))
}

fn is_empty_document(text: &str) -> bool {
    jsonc::parse(text).is_ok_and(|root| root.as_object().is_some_and(Map::is_empty))
}

#[cfg(test)]
#[path = "build_scope_tests.rs"]
mod tests;
