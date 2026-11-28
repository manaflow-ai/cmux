//! Where the host agent's commands come from.
//!
//! [`SpoolSource`] takes commands from a local folder, written by `acpmux machine hypervisor
//! apply` (or anything else that writes one JSON file per command); [`super::hub::HubSource`]
//! leases them from the hub (RFD 0100 step 4). Both sit behind [`CommandSource`], so the loop
//! is the same for either.

use super::{PauseMode, SlotName, SlotSpec, SlotState, lease::Lease};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// One command, idempotent by slot name.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "verb", rename_all = "camelCase")]
pub enum Command {
    Create {
        slot: SlotName,
        #[serde(default)]
        spec: SlotSpec,
        #[serde(default)]
        lease: Lease,
    },
    Pause {
        slot: SlotName,
        #[serde(default)]
        mode: PauseMode,
    },
    Resume {
        slot: SlotName,
    },
    Destroy {
        slot: SlotName,
    },
    /// The hub renews the slot's lease, optionally replacing it.
    Renew {
        slot: SlotName,
        #[serde(default)]
        lease: Option<Lease>,
    },
    /// The guest reports activity, which restarts the idle clock.
    Touch {
        slot: SlotName,
    },
    /// The guest's session ended: destroy with `deleteOnEnd`, else pause to disk.
    End {
        slot: SlotName,
    },
}

/// A command as leased: its id, which its outcome is reported under.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    pub id: String,
    #[serde(flatten)]
    pub command: Command,
}

/// What the host did with a command.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<SlotState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub trait CommandSource {
    /// The commands waiting now, oldest first. Ones not yet acknowledged come again.
    fn take(&mut self) -> Result<Vec<Envelope>>;
    /// Report a command's outcome; it is not handed out again.
    fn ack(&mut self, envelope: &Envelope, outcome: &Outcome) -> Result<()>;
}

impl CommandSource for Box<dyn CommandSource> {
    fn take(&mut self) -> Result<Vec<Envelope>> {
        (**self).take()
    }
    fn ack(&mut self, envelope: &Envelope, outcome: &Outcome) -> Result<()> {
        (**self).ack(envelope, outcome)
    }
}

/// A folder of commands: `inbox/<id>.json` waits, `done/<id>.json` holds the command and
/// its outcome after.
pub struct SpoolSource {
    pub dir: PathBuf,
}

impl SpoolSource {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    fn inbox(&self) -> PathBuf {
        self.dir.join("inbox")
    }

    fn done(&self) -> PathBuf {
        self.dir.join("done")
    }

    /// Queue a command; the id is made from the clock and the slot when absent.
    pub fn submit(&self, command: Command, id: Option<String>, now_ms: u64) -> Result<Envelope> {
        let slot = match &command {
            Command::Create { slot, .. }
            | Command::Pause { slot, .. }
            | Command::Resume { slot }
            | Command::Destroy { slot }
            | Command::Renew { slot, .. }
            | Command::Touch { slot }
            | Command::End { slot } => slot.clone(),
        };
        let id = id.unwrap_or_else(|| format!("{now_ms:013}-{slot}"));
        anyhow::ensure!(
            !id.is_empty()
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
            "command id {id:?}: use a-z, A-Z, 0-9, - and _"
        );
        let envelope = Envelope { id, command };
        crate::home_fs::create_dirs(self.inbox())?;
        let path = self.inbox().join(format!("{}.json", envelope.id));
        let tmp = self.inbox().join(format!(".{}.tmp", envelope.id));
        crate::home_fs::write(&tmp, serde_json::to_vec(&envelope)?)?;
        crate::home_fs::rename(&tmp, &path)?;
        Ok(envelope)
    }
}

fn read_envelope(path: &Path) -> Result<Envelope> {
    let bytes = std::fs::read(path)?;
    serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))
}

impl CommandSource for SpoolSource {
    fn take(&mut self) -> Result<Vec<Envelope>> {
        let mut paths: Vec<PathBuf> = match std::fs::read_dir(self.inbox()) {
            Ok(rd) => rd
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.extension().is_some_and(|x| x == "json")
                        && !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.'))
                })
                .collect(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        paths.sort();
        let mut out = Vec::new();
        for path in paths {
            match read_envelope(&path) {
                Ok(env) => out.push(env),
                // An unreadable command is set aside with its error, never retried forever.
                Err(e) => {
                    crate::home_fs::create_dirs(self.done())?;
                    let name = path
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    crate::home_fs::write(
                        self.done().join(format!("{name}.error")),
                        format!("{e:#}\n"),
                    )?;
                    crate::home_fs::rename(&path, self.done().join(name))?;
                }
            }
        }
        Ok(out)
    }

    fn ack(&mut self, envelope: &Envelope, outcome: &Outcome) -> Result<()> {
        crate::home_fs::create_dirs(self.done())?;
        let record = serde_json::json!({"command": envelope, "outcome": outcome});
        crate::home_fs::write(
            self.done().join(format!("{}.json", envelope.id)),
            serde_json::to_vec_pretty(&record)?,
        )?;
        match crate::home_fs::remove_file(self.inbox().join(format!("{}.json", envelope.id))) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}
