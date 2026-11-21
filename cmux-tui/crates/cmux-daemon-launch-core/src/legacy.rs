//! The one-time adopt of the old shared daemon session by an untagged
//! NIGHTLY, RC or staging build (cx-r650e), and the launch snapshot lookup in
//! a daemon state directory.
//!
//! Before cx-6so.41 these builds ran `cmux-app` in cmux-tui's default root;
//! since then each runs `cmux-app-<channel>` in `cmux-next/tags/<channel>/tui`
//! (classic's `cmux/tags/<channel>/tui` before CmuxNext `StateFolderMove`),
//! and nothing moved the old state. A channel build adopts `cmux-app` in
//! place, once, when this bundle itself ran the old session (its own
//! defaults name the old snapshot), that snapshot lists workspaces, and its
//! own session is untouched. The decision is recorded beside the channel's
//! state directory, so every later launch keeps it. A session the person
//! used is never replaced. The app keeps one answer per process and build.

use crate::{join, parent_path};
use serde_json::Value;
use std::path::Path;
use std::time::SystemTime;

pub const SESSION: &str = "cmux-app";
pub const CHANNELS: [&str; 3] = ["nightly", "rc", "staging"];
pub const MARKER_NAME: &str = "legacy-session-adopted";
/// The daemon's snapshot file name (`LAUNCH_SNAPSHOT_FILE`).
pub const SNAPSHOT_FILE: &str = "launch-snapshot.json";
/// A snapshot larger than this is not read (the daemon caps it at 8 MiB).
pub const SNAPSHOT_MAX_BYTES: u64 = 8 * 1024 * 1024;

/// The channel of an untagged channel build (`com.cmuxterm.app.<channel>`
/// running `cmux-app-<channel>`).
pub fn channel(bundle_id: Option<&str>, session: &str) -> Option<&'static str> {
    CHANNELS.into_iter().find(|c| {
        bundle_id == Some(format!("com.cmuxterm.app.{c}").as_str())
            && session == format!("cmux-app-{c}")
    })
}

/// A lexical `URL.standardizedFileURL.path`: no `.` or empty components, a
/// `..` drops the one before it.
fn standardized(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

/// `<session>-<id>` with one id part, so `cmux-app-a` never takes
/// `cmux-app-a-b`'s registry.
fn is_registry(name: &str, session: &str) -> bool {
    name.strip_prefix(session)
        .and_then(|rest| rest.strip_prefix('-'))
        .is_some_and(|id| !id.contains('-'))
}

fn entries(dir: &str) -> Vec<String> {
    std::fs::read_dir(dir)
        .map(|read| {
            read.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

/// The newest launch snapshot of `session` in a daemon state directory,
/// where cmux-tui keeps each registry in `<session>-<id>/`.
pub fn find_snapshot(session: &str, state_directory: &str) -> Option<String> {
    let mut newest: Option<(String, SystemTime)> = None;
    for name in entries(state_directory) {
        if !is_registry(&name, session) {
            continue;
        }
        let file = join(&join(state_directory, &name), SNAPSHOT_FILE);
        let Ok(modified) = std::fs::metadata(&file).and_then(|m| m.modified()) else { continue };
        if newest.as_ref().is_none_or(|(_, best)| modified > *best) {
            newest = Some((file, modified));
        }
    }
    newest.map(|(path, _)| path)
}

/// The workspaces of a launch snapshot that are not Home or ephemeral; with
/// `touched_only`, only those the person may have used (one listing no tab,
/// or with a tab that is not an unused New Tab page). An unreadable file
/// counts as one touched workspace, so it never leads to an adopt.
pub fn workspaces(path: &str, touched_only: bool) -> usize {
    let unreadable = usize::from(touched_only);
    let Ok(meta) = std::fs::metadata(path) else { return unreadable };
    if meta.len() > SNAPSHOT_MAX_BYTES {
        return unreadable;
    }
    let Ok(text) = std::fs::read(path) else { return unreadable };
    workspaces_in(&text, touched_only)
}

/// [`workspaces`] of a snapshot's bytes.
pub fn workspaces_in(bytes: &[u8], touched_only: bool) -> usize {
    let unreadable = usize::from(touched_only);
    let Ok(Value::Object(file)) = serde_json::from_slice::<Value>(bytes) else { return unreadable };
    let Some(list) = file.get("tree").and_then(|t| t.get("workspaces")).and_then(Value::as_array)
    else {
        return unreadable;
    };
    if !list.iter().all(Value::is_object) {
        return unreadable;
    }
    list.iter()
        .filter(|ws| {
            if ws.get("kind").and_then(Value::as_str) == Some("home")
                || ws.get("ephemeral").and_then(Value::as_bool) == Some(true)
            {
                return false;
            }
            if !touched_only {
                return true;
            }
            let tabs = tabs(ws);
            tabs.is_empty() || tabs.iter().any(|t| is_touched(t))
        })
        .count()
}

fn array<'a>(value: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    value.get(key).and_then(Value::as_array).into_iter().flatten().filter(|v| v.is_object())
}

fn tabs(workspace: &Value) -> Vec<&Value> {
    array(workspace, "screens")
        .flat_map(|s| array(s, "panes"))
        .flat_map(|p| array(p, "tabs"))
        .collect()
}

fn is_touched(tab: &Value) -> bool {
    if tab.get("kind").and_then(Value::as_str) != Some("conversation") {
        return true;
    }
    let binding = tab.get("conversation");
    if binding.and_then(|b| b.get("conversation")).is_some_and(|c| !c.is_null()) {
        return true;
    }
    binding
        .and_then(|b| b.get("agent_session"))
        .and_then(|a| a.get("session"))
        .is_some_and(|s| !s.is_null())
}

/// The build's own session never ran (no registry), or its launch snapshot
/// shows no workspace the person touched. A registry without a snapshot
/// counts as touched.
pub fn is_untouched(session: &str, state_directory: &str) -> bool {
    if !entries(state_directory).iter().any(|name| is_registry(name, session)) {
        return true;
    }
    find_snapshot(session, state_directory).is_some_and(|snapshot| workspaces(&snapshot, true) == 0)
}

/// One adopt question: the build's own names and what its defaults
/// remember of the old session's snapshot.
pub struct AdoptInput<'a> {
    pub application_support: &'a str,
    pub bundle_id: Option<&'a str>,
    pub session: &'a str,
    pub state_directory: Option<&'a str>,
    pub remembered_snapshot: Option<&'a str>,
    /// When the adopt is recorded (ISO 8601).
    pub now: &'a str,
}

/// True when the channel build uses the old session: recorded earlier, or
/// decided now (and recorded; an adopt that cannot be recorded is refused,
/// never one for this launch only).
pub fn adopts(input: &AdoptInput<'_>) -> bool {
    let (Some(_), Some(state_directory)) =
        (channel(input.bundle_id, input.session), input.state_directory)
    else {
        return false;
    };
    let marker = join(&parent_path(state_directory), MARKER_NAME);
    if Path::new(&marker).exists() {
        return true;
    }
    let legacy_root = join(input.application_support, "cmux-tui/sessions");
    let Some(legacy) = input.remembered_snapshot else { return false };
    if standardized(&parent_path(&parent_path(legacy))) != standardized(&legacy_root)
        || workspaces(legacy, false) == 0
        || !is_untouched(input.session, state_directory)
    {
        return false;
    }
    let record =
        serde_json::json!({"adopted_at": input.now, "session": SESSION, "state_root": legacy_root});
    write_atomic(&marker, record.to_string().as_bytes()).is_ok()
}

fn write_atomic(path: &str, bytes: &[u8]) -> std::io::Result<()> {
    let parent = parent_path(path);
    std::fs::create_dir_all(&parent)?;
    let temporary = format!("{path}.tmp-{}", std::process::id());
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(&temporary, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}
