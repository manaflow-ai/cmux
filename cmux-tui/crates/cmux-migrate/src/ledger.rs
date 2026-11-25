//! What earlier runs made, per source and project, so a rerun makes nothing twice, a run cut off
//! resumes at the step it was on, and `undo` knows exactly what to delete. Modeled on the
//! Conductor import's ledger. Lives at `~/.cmux/migrate/ledger.json` for a person, and one per
//! person under an org's run folder for a team migration.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ledger {
    pub version: u32,
    /// By `"{source.id}/{project.key}"`.
    #[serde(default)]
    pub projects: BTreeMap<String, Entry>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub stage: Stage,
    /// The machine made for it, once made: what undo deletes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<String>,
    /// Steps finished, by their kebab name (`create-machine`, `deliver-secrets`...).
    #[serde(default)]
    pub done: Vec<String>,
    /// Unix ms when the first step started and when the machine's first chat answered: the
    /// time-to-first-working-chat number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_chat_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    /// A run started and has not finished: resumed next time.
    #[default]
    Pending,
    Done,
    Failed,
    /// Undone: the machine was deleted; the source was never touched.
    Undone,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Load {
    None,
    Ledger(Ledger),
    /// Written by a newer cmux: left alone.
    Newer(u32),
    Unreadable(String),
}

/// What undo does for one project.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UndoStep {
    pub key: String,
    /// `cloud kill-machine --target machine:<id>`; chats moved there come back first with `cloud
    /// bring-back`.
    pub machine_id: String,
}

impl Ledger {
    pub fn new() -> Self {
        Self { version: VERSION, ..Self::default() }
    }

    pub fn load(path: &Path) -> Load {
        match std::fs::read(path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Load::None,
            Err(error) => Load::Unreadable(error.to_string()),
            Ok(bytes) => match serde_json::from_slice::<Ledger>(&bytes) {
                Ok(ledger) if ledger.version > VERSION => Load::Newer(ledger.version),
                Ok(ledger) => Load::Ledger(ledger),
                Err(error) => Load::Unreadable(error.to_string()),
            },
        }
    }

    /// Written to a sibling temp file and renamed, so a crash leaves the old ledger whole.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(tmp, path)
    }

    pub fn key(source_id: &str, project_key: &str) -> String {
        format!("{source_id}/{project_key}")
    }

    pub fn entry(&self, source_id: &str, project_key: &str) -> Option<&Entry> {
        self.projects.get(&Self::key(source_id, project_key))
    }

    pub fn entry_mut(&mut self, source_id: &str, project_key: &str) -> &mut Entry {
        self.projects.entry(Self::key(source_id, project_key)).or_default()
    }

    /// Whether a step for this project already finished (a rerun skips it).
    pub fn is_done(&self, source_id: &str, project_key: &str, step: &str) -> bool {
        self.entry(source_id, project_key).is_some_and(|e| e.done.iter().any(|d| d == step))
    }

    /// Every machine this source's migration made and has not undone, for `undo`.
    pub fn undo_steps(&self, source_id: &str) -> Vec<UndoStep> {
        let prefix = format!("{source_id}/");
        self.projects
            .iter()
            .filter_map(|(key, entry)| {
                let project = key.strip_prefix(&prefix)?;
                if entry.stage == Stage::Undone {
                    return None;
                }
                Some(UndoStep { key: project.to_owned(), machine_id: entry.machine_id.clone()? })
            })
            .collect()
    }

    /// Done over attempted, and the median time to first working chat, across every source.
    /// Only projects count: an older run's `_machine-wide` carry entry (never a project) is left out.
    pub fn stats(&self) -> Stats {
        let projects = || {
            self.projects
                .iter()
                .filter(|(key, _)| !key.ends_with(&format!("/{}", crate::apply::MACHINE_WIDE)))
                .map(|(_, entry)| entry)
        };
        let attempted = projects().filter(|e| e.stage != Stage::Undone).count();
        let done = projects().filter(|e| e.stage == Stage::Done).count();
        let mut times: Vec<i64> = projects()
            .filter_map(|e| e.first_chat_ms?.checked_sub(e.started_ms?))
            .filter(|ms| *ms >= 0)
            .collect();
        times.sort_unstable();
        Stats {
            attempted,
            done,
            median_first_chat_ms: times.get(times.len() / 2).copied().filter(|_| !times.is_empty()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stats {
    pub attempted: usize,
    pub done: usize,
    pub median_first_chat_ms: Option<i64>,
}
