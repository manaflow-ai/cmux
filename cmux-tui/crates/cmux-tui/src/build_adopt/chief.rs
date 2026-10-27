//! NEXT's Chief home: an APFS clone of the shared home it used before S0
//! (`<chief root>/<account>`, NIGHTLY's, never changed) into its own home
//! (`<chief root>/com.cmuxterm.app.nightly.cmux-next[.<account>]`).
//!
//! Adopted when NEXT's home has no `adopted.json`. Everything in it came
//! from launches after the update (no build before S0 wrote it), so it is
//! "new": it is set aside whole to `<chief root>/.backups/<name>-post-update-<UTC>`
//! (nothing deleted), never merged (two Chief memories do not merge). NEXT's
//! own brain and owner are stopped first (`cmux chief shutdown` of that home)
//! when they run; NIGHTLY's brain and owner are never stopped.
//!
//! Left out of the clone, as a live process's or another build's: sockets and
//! FIFOs, `state/` (locks, sockets, the shutdown marker), `agent-token` (each
//! home mints its own), NIGHTLY's `adopted.json`, the Chief acpmux home's
//! `hosts/`, `run/`, `router/`, `daemon.pid` and `daemon.lock`, and in `tui/`
//! everything but the Chief session's folder without its workspace registry
//! (bound to the session name; terminal host records name NIGHTLY's live
//! terminals). The session folder is renamed for NEXT's session
//! (`cmux-chief-<FNV-1a 32 of the home path>`), so NEXT's owner opens the
//! conversations. In the clone's `*.json`, `*.toml` and `*.md` files the old
//! home path becomes NEXT's, so no preset or setting points back into
//! NIGHTLY's home.

use std::path::{Path, PathBuf};

use super::copy;
use super::{NEXT_BUNDLE_ID, Outcome, RECORD, Steps};

/// Files of the Chief session folder that belong to the session, not the Chief.
const SESSION_RUNTIME: [&str; 4] = [
    "workspace-registry.sqlite3",
    "writer.lock",
    "launch-snapshot.json",
    "workspace-registry.owner-shutdown",
];
/// The largest text file whose home path is rewritten.
const REWRITE_LIMIT: u64 = 4 << 20;

/// Adopts the shared Chief home into `target` once, when `target` is cmux
/// NEXT's (by its name); every other home: [`Outcome::Nothing`].
pub(crate) fn adopt(target: &Path, exe: Option<&Path>, by: &str) -> Outcome {
    let Some(name) = target.file_name().map(|n| n.to_string_lossy().into_owned()) else {
        return Outcome::Nothing;
    };
    let account = if name == NEXT_BUNDLE_ID {
        "default".to_owned()
    } else if let Some(account) = name.strip_prefix(&format!("{NEXT_BUNDLE_ID}.")) {
        account.to_owned()
    } else {
        return Outcome::Nothing;
    };
    if cmux_blocking::fs::metadata(target.join(RECORD)).is_ok() {
        return Outcome::Done;
    }
    let Some(base) = target.parent() else { return Outcome::Nothing };
    let source = base.join(&account);
    if !has_state(&source) {
        // NEXT's home with no shared home to adopt is final: record it once, so
        // a shared home that appears later (NIGHTLY installed) is never cloned over it.
        if has_state(target) {
            let (_, at) = super::now_stamps();
            let record = serde_json::json!({"from": null, "at": at, "by": by, "mode": "none"});
            let _ = super::write_record(&target.join(RECORD), &record);
        }
        return Outcome::Nothing;
    }
    let mut steps = Steps::new("chief");
    let outcome = adopt_locked(&source, target, base, &name, exe, by, &mut steps);
    if let Outcome::Deferred(why) = &outcome {
        steps.step(format!("deferred to a later launch: {why}"));
    }
    outcome
}

/// A folder with more than runtime state (`state/`).
fn has_state(dir: &Path) -> bool {
    cmux_blocking::fs::read_dir(dir)
        .is_ok_and(|entries| entries.flatten().any(|e| e.file_name() != "state"))
}

fn adopt_locked(
    source: &Path,
    target: &Path,
    base: &Path,
    name: &str,
    exe: Option<&Path>,
    by: &str,
    steps: &mut Steps,
) -> Outcome {
    let _adopting = match super::wait_lock(&base.join(format!(".adopt-{name}.lock"))) {
        Ok(Some(lock)) => lock,
        Ok(None) => return Outcome::Deferred("another adoption of this home runs".into()),
        Err(error) => return Outcome::Deferred(format!("adoption lock: {error}")),
    };
    if cmux_blocking::fs::metadata(target.join(RECORD)).is_ok() {
        return Outcome::Done;
    }
    // Partial clones a crash left (only this adoption makes them, under this lock).
    for entry in cmux_blocking::fs::read_dir(base).into_iter().flatten().flatten() {
        if entry.file_name().to_string_lossy().starts_with(&format!(".adopt-partial-{name}-")) {
            let _ = cmux_blocking::fs::remove_dir_all(entry.path());
        }
    }
    steps.step(format!("shared home {} found; NEXT's home {}", source.display(), target.display()));
    let (stamp, at) = super::now_stamps();
    let mut set_aside = None;
    if cmux_blocking::fs::read_dir(target).is_ok_and(|mut e| e.next().is_some()) {
        if let Err(why) = stop_own_chief(target, exe, steps) {
            return Outcome::Deferred(why);
        }
        let backups = base.join(".backups");
        let aside = backups.join(format!("{name}-post-update-{stamp}"));
        let moved = cmux_blocking::fs::create_dir_all(&backups)
            .and_then(|()| cmux_blocking::fs::rename(target, &aside));
        if let Err(error) = moved {
            return Outcome::Deferred(format!("set aside {}: {error}", target.display()));
        }
        steps.step(format!("NEXT's post-update Chief home kept at {}", aside.display()));
        set_aside = Some(aside);
    }
    let partial = base.join(format!(".adopt-partial-{name}-{}", super::random_hex(6)));
    let result = clone_home(source, target, &partial, steps);
    let (skipped, raw, rewritten) = match result {
        Ok(found) => found,
        Err(error) => {
            let _ = cmux_blocking::fs::remove_dir_all(&partial);
            if let Some(aside) = &set_aside {
                let _ = cmux_blocking::fs::rename(aside, target);
            }
            return Outcome::Deferred(format!("clone of {}: {error}", source.display()));
        }
    };
    let record = serde_json::json!({
        "from": source, "at": at, "by": by, "post_update_kept": set_aside,
        "skipped": skipped, "raw": raw, "rewritten": rewritten, "steps": steps.lines,
    });
    let placed = super::write_record(&partial.join(RECORD), &record)
        .and_then(|()| cmux_blocking::fs::rename(&partial, target));
    if let Err(error) = placed {
        let _ = cmux_blocking::fs::remove_dir_all(&partial);
        if let Some(aside) = &set_aside {
            let _ = cmux_blocking::fs::rename(aside, target);
        }
        return Outcome::Deferred(format!("place {}: {error}", target.display()));
    }
    steps.step(format!("cloned {} into {}", source.display(), target.display()));
    Outcome::Adopted("clone")
}

type Cloned = (Vec<String>, Vec<PathBuf>, Vec<String>);

/// Clones `source` to `partial` as NEXT's home `target` will hold it.
fn clone_home(
    source: &Path,
    target: &Path,
    partial: &Path,
    steps: &mut Steps,
) -> std::io::Result<Cloned> {
    let skip = |rel: &[String]| -> bool {
        let rel: Vec<&str> = rel.iter().map(String::as_str).collect();
        matches!(
            rel.as_slice(),
            ["state" | "agent-token" | "tui" | "adopted.json"]
                // NIGHTLY's live memory inspector: its port and secret.
                | ["optchat", "inspector.json"]
                | ["acpmux", "hosts" | "run" | "router" | "daemon.pid" | "daemon.lock"]
                | ["c", _, "state" | "a" | "agent-token"]
        )
    };
    let cloned = copy::clone_tree(source, partial, &skip)?;
    let mut skipped = cloned.skipped;
    let mut raw = cloned.raw;
    let (from_session, to_session) = (session_name(source), session_name(target));
    if let Some(session_dir) = find_session_dir(&source.join("tui"), &from_session) {
        let tui = partial.join("tui");
        cmux_blocking::fs::create_dir_all(&tui)?;
        let to = tui.join(storage_component(&to_session));
        let session_skip =
            |rel: &[String]| rel.len() == 1 && SESSION_RUNTIME.contains(&rel[0].as_str());
        let session = copy::clone_tree(&session_dir, &to, &session_skip)?;
        skipped.extend(session.skipped.into_iter().map(|s| format!("tui/<session>/{s}")));
        raw.extend(session.raw);
        steps
            .step(format!("Chief conversations moved from session {from_session} to {to_session}"));
    } else {
        steps.step("the shared home has no Chief session folder: no conversations to keep");
    }
    let (from, to) = (source.to_string_lossy(), target.to_string_lossy());
    let mut rewritten = Vec::new();
    rewrite_tree(partial, partial, &from, &to, &mut rewritten);
    // The Chief acpmux's web listener and token are NIGHTLY's: NEXT's daemon makes its own.
    if drop_websocket(&partial.join("acpmux/config.json")) {
        steps.step("dropped the shared Chief acpmux's websocket listener and token from the clone");
    }
    if !rewritten.is_empty() {
        steps.step(format!("{} file(s) named the shared home: now NEXT's", rewritten.len()));
    }
    Ok((skipped, raw, rewritten))
}

/// Removes `websocket` from an acpmux `config.json`; true when it had one.
fn drop_websocket(path: &Path) -> bool {
    let Ok(text) = cmux_blocking::fs::read_to_string(path) else { return false };
    let Ok(mut config) = serde_json::from_str::<serde_json::Value>(&text) else { return false };
    let dropped = config.as_object_mut().and_then(|c| c.remove("websocket")).is_some();
    dropped && super::write_record(path, &config).is_ok()
}

/// The session folder of `session` in a `tui/` state root, else its only
/// Chief session folder (with several, the one whose conversations changed
/// last); None without one.
fn find_session_dir(tui: &Path, session: &str) -> Option<PathBuf> {
    let exact = tui.join(storage_component(session));
    if cmux_blocking::fs::metadata(&exact).is_ok_and(|metadata| metadata.is_dir()) {
        return Some(exact);
    }
    let entries = cmux_blocking::fs::read_dir(tui).ok()?;
    let found: Vec<PathBuf> = entries
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("cmux-chief-"))
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .collect();
    // More than one (another spelling of the root, old test sessions): the one
    // whose conversations changed last (hq-6d, 2026-10-15).
    let modified = |dir: &PathBuf| {
        cmux_blocking::fs::metadata(dir.join("conversations.sqlite3"))
            .and_then(|m| m.modified())
            .ok()
    };
    found
        .iter()
        .filter(|d| modified(d).is_some())
        .max_by_key(|d| modified(d))
        .cloned()
        .or_else(|| found.first().cloned())
}

fn rewrite_tree(dir: &Path, top: &Path, from: &str, to: &str, out: &mut Vec<String>) {
    let Ok(entries) = cmux_blocking::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            rewrite_tree(&path, top, from, to, out);
            continue;
        }
        // A link into the shared home points into NEXT's clone instead.
        if kind.is_symlink() {
            let link =
                crate::blocking::fs::read_link(&path).map(|t| t.to_string_lossy().into_owned());
            if let Ok(link) = link
                && let Some(rest) = link.strip_prefix(from)
                && (rest.is_empty() || rest.starts_with('/'))
                && cmux_blocking::fs::remove_file(&path).is_ok()
                && std::os::unix::fs::symlink(format!("{to}{rest}"), &path).is_ok()
            {
                out.push(path.strip_prefix(top).unwrap_or(&path).to_string_lossy().into_owned());
            }
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let text = [".json", ".toml", ".md"].iter().any(|ext| name.ends_with(ext));
        let small = entry.metadata().is_ok_and(|m| m.len() <= REWRITE_LIMIT);
        if kind.is_file() && text && small && copy::rewrite_root(&path, from, to).unwrap_or(false) {
            out.push(path.strip_prefix(top).unwrap_or(&path).to_string_lossy().into_owned());
        }
    }
}

/// Stops NEXT's own Chief (brain and owner) of `home` when one runs.
fn stop_own_chief(home: &Path, exe: Option<&Path>, steps: &mut Steps) -> Result<(), String> {
    if !chief_running(home) {
        return Ok(());
    }
    let Some(exe) = exe else {
        return Err("NEXT's Chief runs; only the app stops it (at its next launch)".into());
    };
    steps.step(format!("NEXT's post-update Chief runs in {}: stopping it", home.display()));
    let _ = cmux_process::Command::new(exe)
        .args(["chief", "shutdown", "--chief-home"])
        .arg(home)
        .env(super::CHILD_ENV, "1")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .status();
    if chief_running(home) {
        return Err(format!("NEXT's Chief in {} did not stop", home.display()));
    }
    steps.step("NEXT's post-update Chief stopped");
    Ok(())
}

/// Whether a brain holds `state/host.lock` or an owner holds a session lock.
fn chief_running(home: &Path) -> bool {
    if super::held(&home.join("state/host.lock")) {
        return true;
    }
    cmux_blocking::fs::read_dir(home.join("tui/session-locks")).is_ok_and(|entries| {
        entries.flatten().any(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            name.ends_with(".lock") && !name.starts_with('.') && super::held(&e.path())
        })
    })
}

/// `cmux-chief-<FNV-1a 32 of the root path>` (cli/chief/home.rs `session`).
fn session_name(root: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.to_string_lossy().as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("cmux-chief-{hash:08x}")
}

/// The session's folder name in a state root (cmux-tui-core
/// workspace_registry.rs `session_storage_component`).
fn storage_component(session: &str) -> String {
    let mut readable = String::new();
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in session.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
        if readable.len() < 48 {
            readable.push(if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_') {
                char::from(byte)
            } else {
                '_'
            });
        }
    }
    if readable.is_empty() {
        readable.push_str("session");
    }
    format!("{readable}-{hash:016x}")
}
