//! Moving the Chief's memory between brain hosts (brains/DESIGN-cmux-lawrence.md
//! section 5). `export` writes one tar: a git bundle of the OptChat memory
//! (every message and every summary, so nothing is built again), the user's
//! AGENTS.md and a manifest. `import` clones it into an empty home. host.json
//! never moves: its outbox and cursor belong to the old home's conversation.
//! `--seal` writes `optchat/MOVED`; a sealed home's host does not start, so
//! two brains never grow two different memories of one Chief.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Value, json};

use crate::lock::{HostLock, LockError};
use crate::paths::Paths;

const FORMAT: &str = "optchat-memory-v1";
const BUNDLE: &str = "chat.bundle";
const MANIFEST: &str = "manifest.json";
const INSTRUCTIONS: &str = "AGENTS.md";

#[derive(Debug)]
pub struct Report {
    pub messages: u64,
}

/// The seal file of a moved home.
pub fn seal_path(paths: &Paths) -> PathBuf {
    paths.root.join("MOVED")
}

/// True when this home's memory was moved away (`export --seal`).
pub fn sealed(paths: &Paths) -> bool {
    seal_path(paths).exists()
}

fn run(cmd: &mut Command) -> Result<String, String> {
    let shown = format!("{cmd:?}");
    let out = cmd.output().map_err(|e| format!("{shown}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "{shown}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn no_host(paths: &Paths) -> Result<HostLock, String> {
    if let Some(dir) = paths.host_lock.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    match HostLock::take(&paths.host_lock, now_ms()) {
        Ok(lock) => Ok(lock),
        Err(LockError::Held | LockError::Older(_)) => Err(format!(
            "a Chief host runs for {}; stop it first",
            paths.home.display()
        )),
        Err(LockError::Io(e)) => Err(format!("{}: {e}", paths.host_lock.display())),
    }
}

fn messages(chat: &Path) -> Result<u64, String> {
    let chat = crate::browse::open_offline(chat)?;
    let n = chat.status().messages;
    chat.shutdown();
    Ok(n)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn staging(near: &Path, what: &str) -> Result<PathBuf, String> {
    let dir = near.join(format!(".{what}-{}-{}", std::process::id(), now_ms()));
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    Ok(dir)
}

fn absolute(path: &Path) -> Result<PathBuf, String> {
    if path.is_absolute() {
        Ok(path.to_owned())
    } else {
        std::env::current_dir()
            .map(|d| d.join(path))
            .map_err(|e| e.to_string())
    }
}

/// Writes the memory of `paths` to the tar `out`; with `seal`, marks the home moved.
pub fn export(paths: &Paths, out: &Path, seal: bool) -> Result<Report, String> {
    let _lock = no_host(paths)?;
    if !paths.chat.is_dir() {
        return Err(format!("{} has no memory", paths.home.display()));
    }
    // Everything up to now is in the history (the host commits after each turn).
    crate::persist::snapshot(&paths.chat, "export")?;
    let count = messages(&paths.chat)?;
    let head = run(Command::new("git")
        .arg("-C")
        .arg(&paths.chat)
        .args(["rev-parse", "HEAD"]))?;
    let out = absolute(out)?;
    let parent = out.parent().ok_or("the archive path has no directory")?;
    std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    let stage = staging(parent, "optchat-export")?;
    let result = (|| {
        run(Command::new("git")
            .arg("-C")
            .arg(&paths.chat)
            .args(["bundle", "create", "-q"])
            .arg(stage.join(BUNDLE))
            .arg("--all"))?;
        let has_instructions = paths.instructions.exists();
        if has_instructions {
            std::fs::copy(&paths.instructions, stage.join(INSTRUCTIONS))
                .map_err(|e| e.to_string())?;
        }
        let manifest = json!({
            "format": FORMAT,
            "messages": count,
            "head": head.trim(),
            "home_id": crate::paths::home_id(&paths.home),
            "instructions": has_instructions,
            "exported_at_ms": now_ms(),
        });
        std::fs::write(
            stage.join(MANIFEST),
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .map_err(|e| e.to_string())?;
        run(Command::new("tar")
            .arg("-cf")
            .arg(&out)
            .arg("-C")
            .arg(&stage)
            .arg("."))?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
        Ok::<_, String>(())
    })();
    let _ = std::fs::remove_dir_all(&stage);
    result?;
    if seal {
        let text = json!({"archive": out.display().to_string(), "messages": count, "head": head.trim(), "at_ms": now_ms()});
        std::fs::write(seal_path(paths), serde_json::to_vec_pretty(&text).unwrap())
            .map_err(|e| e.to_string())?;
    }
    Ok(Report { messages: count })
}

/// Clones the memory in the tar `archive` into the empty home `paths`.
pub fn import(paths: &Paths, archive: &Path) -> Result<Report, String> {
    paths
        .create()
        .map_err(|e| format!("{}: {e}", paths.root.display()))?;
    let _lock = no_host(paths)?;
    let occupied = std::fs::read_dir(&paths.chat)
        .map_err(|e| format!("{}: {e}", paths.chat.display()))?
        .next()
        .is_some();
    if occupied {
        let n = messages(&paths.chat).unwrap_or(0);
        return Err(format!(
            "{} already has a memory ({n} messages); import only into an empty home",
            paths.home.display()
        ));
    }
    let archive = absolute(archive)?;
    let stage = staging(&paths.root, "optchat-import")?;
    let result = (|| {
        run(Command::new("tar")
            .arg("-xf")
            .arg(&archive)
            .arg("-C")
            .arg(&stage))?;
        let manifest: Value = serde_json::from_slice(
            &std::fs::read(stage.join(MANIFEST)).map_err(|e| format!("{MANIFEST}: {e}"))?,
        )
        .map_err(|e| format!("{MANIFEST}: {e}"))?;
        if manifest.get("format").and_then(Value::as_str) != Some(FORMAT) {
            return Err(format!("not an {FORMAT} archive"));
        }
        let cloned = stage.join("chat");
        run(Command::new("git")
            .arg("clone")
            .arg("-q")
            .arg(stage.join(BUNDLE))
            .arg(&cloned))?;
        // The bundle's path means nothing on this machine.
        run(Command::new("git")
            .arg("-C")
            .arg(&cloned)
            .args(["remote", "remove", "origin"]))?;
        std::fs::remove_dir(&paths.chat).map_err(|e| format!("{}: {e}", paths.chat.display()))?;
        std::fs::rename(&cloned, &paths.chat)
            .map_err(|e| format!("{}: {e}", paths.chat.display()))?;
        let instructions = stage.join(INSTRUCTIONS);
        if instructions.exists() && !paths.instructions.exists() {
            std::fs::copy(&instructions, &paths.instructions).map_err(|e| e.to_string())?;
        }
        let expected = manifest
            .get("messages")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let count = messages(&paths.chat)?;
        if count != expected {
            return Err(format!(
                "imported {count} messages, the archive says {expected}"
            ));
        }
        Ok(count)
    })();
    let _ = std::fs::remove_dir_all(&stage);
    if result.is_err() && paths.chat.read_dir().is_err() {
        let _ = std::fs::create_dir_all(&paths.chat);
    }
    result.map(|messages| Report { messages })
}
