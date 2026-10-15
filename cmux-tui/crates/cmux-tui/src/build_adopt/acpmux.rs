//! NEXT's acpmux home: `<root>/tags/cmux-next` (before S2) becomes
//! `<root>/builds/<key>` (`BuildIdentity::acpmux_home`).
//!
//! - New home absent: the old one is renamed to it (atomic, one directory).
//! - New home there without `adopted.json`: "post-update only". No binary
//!   before S2 writes `builds/<NEXT key>`, and S2 reached NEXT users in the
//!   same update, so everything in it came from launches after the update;
//!   timestamps are not trusted. It is set aside, the old home renamed in,
//!   and the aside home's sessions (with their agent host records) moved
//!   into the adopted one; a session id that is there already gets a new id
//!   (the newer session is renamed, both kept). The old `config.json` wins;
//!   everything else of the aside home stays in `adopted-post-update-<UTC>/`
//!   inside the adopted home, so nothing is deleted.
//! - Afterwards the old path is a link to the new home: an agent host kept
//!   running through the stop below (or an older NEXT binary) still names
//!   the old path and reaches the same, only home. No copy exists.
//!
//! Never while a daemon of either home runs: a running one is stopped
//! through its own socket with `daemon shutdown --keep-agents` (only that
//! NEXT daemon); if it does not stop, the adoption waits for a later launch.
//! Both homes' daemon locks (and router locks) are held through the moves.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::{LEGACY_TAG, Outcome, RECORD, Steps};

/// How long a stopped daemon (and its router) may take to let go of its lock.
const STOP_WAIT: Duration = Duration::from_secs(45);

/// Adopts NEXT's old acpmux home into `home` (`<root>/builds/<key>`) once.
/// `exe` is this binary (it stops a running daemon); `by` names the caller.
pub(crate) fn adopt(home: &Path, exe: Option<&Path>, by: &str) -> Outcome {
    if home.join(RECORD).exists() {
        return Outcome::Done;
    }
    let Some(root) = home.parent().and_then(Path::parent) else { return Outcome::Nothing };
    let legacy = root.join("tags").join(LEGACY_TAG);
    if !is_real_dir(&legacy) {
        return Outcome::Nothing;
    }
    let mut steps = Steps::new("acpmux");
    let outcome = adopt_locked(home, &legacy, exe, by, &mut steps);
    if let Outcome::Deferred(why) = &outcome {
        steps.step(format!("deferred to a later launch: {why}"));
    }
    outcome
}

fn adopt_locked(
    home: &Path,
    legacy: &Path,
    exe: Option<&Path>,
    by: &str,
    steps: &mut Steps,
) -> Outcome {
    let key = home.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let builds = home.parent().map(Path::to_path_buf).unwrap_or_default();
    // One adoption at a time (the app's and a CLI's): the second waits, then finds the record.
    let _adopting = match super::wait_lock(&builds.join(format!(".adopt-{key}.lock"))) {
        Ok(Some(lock)) => lock,
        Ok(None) => return Outcome::Deferred("another adoption of this home runs".into()),
        Err(error) => return Outcome::Deferred(format!("adoption lock: {error}")),
    };
    if home.join(RECORD).exists() {
        return Outcome::Done;
    }
    if !is_real_dir(legacy) {
        return Outcome::Nothing;
    }
    steps.step(format!("old home {} found; new home {}", legacy.display(), home.display()));
    let new_exists = std::fs::symlink_metadata(home).is_ok();
    let mut locks: Vec<File> = Vec::new();
    for dir in [Some(legacy), new_exists.then_some(home)].into_iter().flatten() {
        match quiesce(dir, exe, steps) {
            Ok(mut held) => locks.append(&mut held),
            Err(why) => return Outcome::Deferred(why),
        }
    }
    let (stamp, at) = super::now_stamps();
    let mut record = serde_json::json!({
        "from": legacy, "at": at, "by": by, "mode": "rename",
    });
    if !new_exists {
        if let Err(error) = std::fs::rename(legacy, home) {
            return Outcome::Deferred(format!(
                "rename {} -> {}: {error}",
                legacy.display(),
                home.display()
            ));
        }
        steps.step("renamed the old home to the new home (the new home did not exist)");
    } else {
        let aside = builds.join(format!(".post-update-{key}-{stamp}"));
        if let Err(error) = std::fs::rename(home, &aside) {
            return Outcome::Deferred(format!("set aside {}: {error}", home.display()));
        }
        if let Err(error) = std::fs::rename(legacy, home) {
            let _ = std::fs::rename(&aside, home);
            return Outcome::Deferred(format!(
                "rename {} -> {}: {error}",
                legacy.display(),
                home.display()
            ));
        }
        steps.step("renamed the old home to the new home; merging the post-update sessions");
        let merged = merge_sessions(&aside, home, steps);
        let kept = home.join(format!("adopted-post-update-{stamp}"));
        match std::fs::rename(&aside, &kept) {
            Ok(()) => {
                steps.step(format!("kept the rest of the post-update home in {}", kept.display()));
            }
            Err(error) => {
                steps.step(format!("post-update home stays at {}: {error}", aside.display()));
            }
        }
        record["mode"] = "merge".into();
        record["merged_sessions"] = merged.0.into();
        record["renamed_sessions"] = serde_json::json!(merged.1);
        record["post_update_kept"] = serde_json::json!(kept);
    }
    // The old path names the one home from now on.
    let link = Path::new("..").join("builds").join(&key);
    match std::os::unix::fs::symlink(&link, legacy) {
        Ok(()) => steps.step(format!("{} is now a link to {}", legacy.display(), link.display())),
        Err(error) => steps.step(format!("no link at {}: {error}", legacy.display())),
    }
    record["steps"] = serde_json::json!(steps.lines);
    if let Err(error) = super::write_record(&home.join(RECORD), &record) {
        steps.step(format!("record not written: {error}"));
    }
    drop(locks);
    Outcome::Adopted(if new_exists { "merge" } else { "rename" })
}

/// A real folder (not a link: an adopted old path is a link).
fn is_real_dir(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_dir())
}

/// Stops the daemon of `home` if one runs (through its own socket, agents
/// kept) and holds its daemon and router locks.
fn quiesce(home: &Path, exe: Option<&Path>, steps: &mut Steps) -> Result<Vec<File>, String> {
    let daemon_lock = home.join("daemon.lock");
    if super::held(&daemon_lock) {
        let Some(exe) = exe else {
            return Err(format!(
                "an acpmux daemon runs in {} and no cmux binary can stop it",
                home.display()
            ));
        };
        steps
            .step(format!("an acpmux daemon runs in {}: stopping it, agents kept", home.display()));
        let status = std::process::Command::new(exe)
            .args(["acp", "daemon", "shutdown", "--keep-agents"])
            .env("ACPMUX_HOME", home)
            .env_remove("ACPMUX_SOCKET")
            .env(super::CHILD_ENV, "1")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        if !super::wait_free(&daemon_lock, STOP_WAIT) {
            return Err(format!(
                "the acpmux daemon in {} did not stop ({status:?})",
                home.display()
            ));
        }
        steps.step(format!("the acpmux daemon in {} stopped", home.display()));
    }
    let mut held = Vec::new();
    let router_lock = home.join("router/router.lock");
    let mut wanted = vec![daemon_lock];
    if router_lock.exists() {
        if !super::wait_free(&router_lock, STOP_WAIT) {
            return Err(format!("the acpmux router in {} still runs", home.display()));
        }
        wanted.push(router_lock);
    }
    for lock in wanted {
        match super::try_lock(&lock) {
            Ok(Some(file)) => held.push(file),
            Ok(None) => return Err(format!("{} was taken while adopting", lock.display())),
            Err(error) => return Err(format!("{}: {error}", lock.display())),
        }
    }
    Ok(held)
}

/// Moves each session of `aside` (and its agent host records) into `home`.
/// Returns how many moved and the renamed ids `(old, new)`.
fn merge_sessions(aside: &Path, home: &Path, steps: &mut Steps) -> (usize, Vec<(String, String)>) {
    let mut moved = 0;
    let mut renamed = Vec::new();
    let Ok(entries) = std::fs::read_dir(aside.join("sessions")) else { return (0, renamed) };
    let _ = std::fs::create_dir_all(home.join("sessions"));
    for entry in entries.flatten() {
        let id = entry.file_name().to_string_lossy().into_owned();
        let mut target_id = id.clone();
        if std::fs::symlink_metadata(home.join("sessions").join(&id)).is_ok() {
            target_id = new_session_id();
        }
        let to = home.join("sessions").join(&target_id);
        if let Err(error) = std::fs::rename(entry.path(), &to) {
            steps.step(format!("session {id} stays in the post-update home: {error}"));
            continue;
        }
        moved += 1;
        if target_id != id {
            set_session_id(&to.join("session.json"), &target_id);
            steps.step(format!(
                "session id {id} was in both homes: the post-update one is now {target_id}"
            ));
            renamed.push((id, target_id));
            continue;
        }
        move_host_records(aside, home, &id);
    }
    steps.step(format!("moved {moved} post-update session(s) into the adopted home"));
    (moved, renamed)
}

/// `hosts/<id>.*` of a moved session: its agent host still finds it.
fn move_host_records(aside: &Path, home: &Path, id: &str) {
    let Ok(entries) = std::fs::read_dir(aside.join("hosts")) else { return };
    let _ = std::fs::create_dir_all(home.join("hosts"));
    let prefix = format!("{id}.");
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy().starts_with(&prefix) && !home.join("hosts").join(&name).exists() {
            let _ = std::fs::rename(entry.path(), home.join("hosts").join(&name));
        }
    }
}

/// A new UUID-shaped session id (version 4).
fn new_session_id() -> String {
    let hex = super::random_hex(16);
    let mut chars: Vec<char> = hex.chars().collect();
    chars[12] = '4';
    chars[16] = ['8', '9', 'a', 'b'][(chars[16].to_digit(16).unwrap_or(0) % 4) as usize];
    let s: String = chars.into_iter().collect();
    format!("{}-{}-{}-{}-{}", &s[0..8], &s[8..12], &s[12..16], &s[16..20], &s[20..32])
}

fn set_session_id(path: &PathBuf, id: &str) {
    let Ok(text) = std::fs::read_to_string(path) else { return };
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(&text) else { return };
    value["id"] = id.into();
    let _ = super::write_record(path, &value);
}
