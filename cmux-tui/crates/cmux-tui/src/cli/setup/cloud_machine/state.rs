//! What `cmux setup cloud-machine` keeps between runs:
//! `<state root>/setup/cloud-machine.json`, beside the daemon's `sessions`,
//! and the `cloud-machine.lock` that lets one run at a time decide.

use std::fs::{File, OpenOptions};
use std::path::PathBuf;

use serde_json::{Value, json};

use super::super::Refusal;

/// The machine setup made, or what it asked for and has not seen become
/// one: the create's idempotency key (kept before the create goes out),
/// the creation the app answered, and the machines and creations there
/// were before it asked (`known_creations` is None in a state from before
/// it was kept).
#[derive(Default)]
pub(super) struct Saved {
    pub(super) machine_id: Option<String>,
    pub(super) creation_id: Option<String>,
    pub(super) key: Option<String>,
    pub(super) known: Vec<String>,
    pub(super) known_creations: Option<Vec<String>>,
}

/// An exclusive `flock` on the lock file, held while a run reads cmux's
/// list, decides, saves and creates; closing the file releases it.
pub(super) struct Lock {
    _file: File,
}

fn failed(error: impl std::fmt::Display) -> Refusal {
    Refusal::Failed(format!("cmux: setup cloud-machine: cannot keep its state: {error}"))
}

impl Saved {
    fn path() -> Result<PathBuf, Refusal> {
        let sessions = cmux_tui_core::platform::workspace_state_dir()
            .ok_or_else(|| failed("no state folder (HOME is unset)"))?;
        let root = sessions.parent().unwrap_or(sessions.as_path());
        Ok(root.join("setup").join("cloud-machine.json"))
    }

    /// Whether setup has asked for or made a machine.
    pub(super) fn is_empty(&self) -> bool {
        self.machine_id.is_none() && self.creation_id.is_none() && self.key.is_none()
    }

    /// Waits for any other run to finish deciding, then holds the lock.
    pub(super) fn lock() -> Result<Lock, Refusal> {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let path = Self::path()?.with_extension("lock");
        if let Some(parent) = path.parent() {
            cmux_blocking::fs::create_dir_all(parent).map_err(failed)?;
        }
        let file = crate::blocking::fs::open_with(
            OpenOptions::new().create(true).truncate(false).write(true).mode(0o600),
            &path,
        )
        .map_err(failed)?;
        loop {
            // SAFETY: `file` owns an open descriptor for the whole call, and
            // flock touches nothing but that descriptor's lock.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                return Ok(Lock { _file: file });
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(failed(error));
            }
        }
    }

    pub(super) fn load() -> Self {
        let text = Self::path().ok().and_then(|path| cmux_blocking::fs::read_to_string(path).ok());
        let value = text.and_then(|text| serde_json::from_str::<Value>(&text).ok());
        let Some(value) = value else { return Self::default() };
        let text =
            |key: &str| value[key].as_str().filter(|text| !text.is_empty()).map(str::to_owned);
        let ids = |key: &str| {
            value[key].as_array().map(|ids| {
                ids.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>()
            })
        };
        Self {
            machine_id: text("machine_id"),
            creation_id: text("creation_id"),
            key: text("key"),
            known: ids("known").unwrap_or_default(),
            known_creations: ids("known_creations"),
        }
    }

    /// What is kept, as the report shows it.
    pub(super) fn to_json(&self) -> Value {
        json!({
            "machine_id": self.machine_id,
            "creation_id": self.creation_id,
            "key": self.key,
            "known": self.known,
            "known_creations": self.known_creations,
        })
    }

    /// Writes the state whole (a temporary file renamed over it), or
    /// removes it when there is nothing to keep.
    pub(super) fn save(&self) -> Result<(), Refusal> {
        let path = Self::path()?;
        if self.is_empty() {
            return match cmux_blocking::fs::remove_file(&path) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(failed(error)),
                _ => Ok(()),
            };
        }
        if let Some(parent) = path.parent() {
            cmux_blocking::fs::create_dir_all(parent).map_err(failed)?;
        }
        let temporary = path.with_extension(format!("json.{}.tmp", std::process::id()));
        cmux_blocking::fs::write(&temporary, format!("{}\n", self.to_json()))
            .and_then(|()| cmux_blocking::fs::rename(&temporary, &path))
            .map_err(|error| {
                let _ = cmux_blocking::fs::remove_file(&temporary);
                failed(error)
            })
    }
}
