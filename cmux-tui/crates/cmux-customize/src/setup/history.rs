//! Undo and redo across setups: every install, update, remove, swap,
//! variant pick and live reload is one step, and one step puts back the
//! whole state it changed, never half of it.
//!
//! A step keeps the state before and after it: the generation that was
//! live, the library file (its entries and the base under them) and the
//! setups' receipts. Undo makes the `before` state live again through a
//! generation restore (what was live and differs is kept as a generation of
//! its own, so a hand edit made since is never lost), then writes the
//! library and receipts back as they were; redo does the same with `after`.
//! This is the theme packs' cursor model (`cmux pack undo|redo`) over whole
//! setups instead of theme files.
//!
//! Extensions are the caller's: an undo names the ones a step installed or
//! removed, and leaves them as they are.
//!
//! The history is `<state dir>/setup-history.json`. One that does not parse
//! starts over, never fatal.

use serde::{Deserialize, Serialize};

use super::{Receipt, ReceiptsFile};
use crate::store::Kind;
use crate::{Customize, Error};

/// At most this many steps are kept; the oldest go first.
pub const MAX_STEPS: usize = 64;

/// What one side of a step had live.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetupState {
    /// The generation that was live (`None`: none yet).
    #[serde(default)]
    pub generation: Option<u32>,
    /// The library file as it was (`None`: there was none).
    #[serde(default)]
    pub library: Option<String>,
    /// The installed setups' receipts, newest first.
    #[serde(default)]
    pub receipts: Vec<Receipt>,
}

/// One undoable change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetupStep {
    /// Unique per step; a live reload amends the step it started.
    pub id: String,
    /// `install`, `update`, `remove`, `swap`, `variant` or `reload`.
    pub verb: String,
    /// What it did, in one line.
    pub label: String,
    pub before: SetupState,
    pub after: SetupState,
    pub at_ms: u64,
}

/// The steps, oldest first, and how many of them are applied.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SetupSteps {
    #[serde(default)]
    pub steps: Vec<SetupStep>,
    /// How many steps are applied: `steps[cursor - 1]` is the newest one.
    #[serde(default)]
    pub cursor: usize,
}

impl Customize {
    fn setup_history_path(&self) -> std::path::PathBuf {
        self.roots().state_dir.join("setup-history.json")
    }

    /// The setup history; a missing or unreadable one is empty.
    pub fn setup_history(&self) -> SetupSteps {
        let mut history = std::fs::read_to_string(self.setup_history_path())
            .ok()
            .and_then(|text| serde_json::from_str::<SetupSteps>(&text).ok())
            .unwrap_or_default();
        history.cursor = history.cursor.min(history.steps.len());
        history
    }

    fn write_setup_history(&self, history: &SetupSteps) -> Result<(), Error> {
        let text = serde_json::to_string(history).map_err(std::io::Error::other)?;
        cmux_config::fsio::write_atomic(&self.setup_history_path(), text.as_bytes())?;
        Ok(())
    }

    /// What is live now, as a step's side. Takes a baseline first, so the
    /// state before the first setup has a generation to go back to.
    pub fn setup_state(&self, now_ms: u64) -> Result<SetupState, Error> {
        self.ensure_baseline(now_ms)?;
        let _lock = self.store().lock()?;
        self.setup_state_locked()
    }

    fn setup_state_locked(&self) -> Result<SetupState, Error> {
        let library = self
            .library_snapshot()?
            .map(|bytes| {
                String::from_utf8(bytes)
                    .map_err(|_| Error::Setup("library.json is not text".to_owned()))
            })
            .transpose()?;
        Ok(SetupState {
            generation: self.current_generation()?,
            library,
            receipts: self.read_setup_receipts()?.setups,
        })
    }

    /// Records a step from `before` to what is live now, dropping the redo
    /// tail. With `amend`, when the newest applied step has that id (a live
    /// reload of the same session) and nothing was undone since, its
    /// `after` moves instead, so saving twenty times is one undo step.
    /// Returns the step's id.
    pub fn record_setup_step(
        &self,
        verb: &str,
        label: &str,
        before: SetupState,
        amend: Option<&str>,
        now_ms: u64,
    ) -> Result<String, Error> {
        let _lock = self.store().lock()?;
        let after = self.setup_state_locked()?;
        let mut history = self.setup_history();
        if let Some(id) = amend
            && history.cursor == history.steps.len()
            && let Some(last) = history.steps.last_mut()
            && last.id == id
        {
            last.after = after;
            last.label = label.to_owned();
            last.at_ms = now_ms;
            self.write_setup_history(&history)?;
            return Ok(id.to_owned());
        }
        if before == after {
            return Ok(String::new());
        }
        history.steps.truncate(history.cursor);
        let id = format!("{now_ms}-{}", history.steps.len());
        history.steps.push(SetupStep {
            id: id.clone(),
            verb: verb.to_owned(),
            label: label.to_owned(),
            before,
            after,
            at_ms: now_ms,
        });
        let over = history.steps.len().saturating_sub(MAX_STEPS);
        history.steps.drain(..over);
        history.cursor = history.steps.len();
        self.write_setup_history(&history)?;
        Ok(id)
    }

    /// Puts back what was live before the newest applied step.
    pub fn undo_setup(&self, origin: &str, now_ms: u64) -> Result<SetupStep, Error> {
        self.move_setup_history(false, origin, now_ms)
    }

    /// Applies the step the last undo took back.
    pub fn redo_setup(&self, origin: &str, now_ms: u64) -> Result<SetupStep, Error> {
        self.move_setup_history(true, origin, now_ms)
    }

    fn move_setup_history(
        &self,
        forward: bool,
        origin: &str,
        now_ms: u64,
    ) -> Result<SetupStep, Error> {
        self.no_preview_open()?;
        let _lock = self.store().lock()?;
        let mut history = self.setup_history();
        let index = if forward {
            (history.cursor < history.steps.len()).then_some(history.cursor)
        } else {
            history.cursor.checked_sub(1)
        };
        let Some(index) = index else {
            let what = if forward { "redo" } else { "undo" };
            return Err(Error::Setup(format!("there is no setup step to {what}")));
        };
        let step = history.steps[index].clone();
        let target = if forward { &step.after } else { &step.before };
        let Some(n) = target.generation else {
            return Err(Error::Setup(format!(
                "{}: no generation was live to go back to",
                step.label
            )));
        };
        let library = self.library_snapshot()?;
        let receipts = self.read_setup_receipts()?;
        let word = if forward { "redo" } else { "undo" };
        let label = format!("setup {word}: {}", step.label);
        let moved = self
            .restore_locked(n, Kind::Autosaved, origin, &label, now_ms)
            .and_then(|_| self.library_write_back(target.library.as_ref().map(String::as_bytes)))
            .and_then(|()| {
                self.write_setup_receipts(&ReceiptsFile { setups: target.receipts.clone() })
            });
        if let Err(error) = moved {
            // All or nothing: the library and receipts as they were.
            let _ = self.library_write_back(library.as_deref());
            let _ = self.write_setup_receipts(&receipts);
            return Err(error);
        }
        history.cursor = if forward { index + 1 } else { index };
        self.write_setup_history(&history)?;
        Ok(step)
    }
}
