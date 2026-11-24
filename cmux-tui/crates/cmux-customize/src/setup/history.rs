//! Undo and redo across setups: every install, update, remove, swap,
//! variant pick and live reload is one step, and one step puts back the
//! whole state it changed, never half of it.
//!
//! A step keeps the state before and after it: the generation that was
//! live, the library file (its entries and the base under them), the
//! setups' receipts and each setup's views layer (its folder under the
//! setups folder; the receipts write `layers.json`). Undo makes the `before` state live again through a
//! generation restore (what was live and differs is kept as a generation of
//! its own, so a hand edit made since is never lost), then writes the
//! library and receipts back as they were; redo does the same with `after`.
//! This is the theme packs' cursor model (`cmux pack undo|redo`) over whole
//! setups instead of theme files.
//!
//! Extensions are the caller's: an undo names the ones a step installed or
//! removed, and leaves them as they are. So are a setup's font files: an
//! undo leaves `fonts/` as it is.
//!
//! The history is `<state dir>/setup-history.json`. One that does not parse
//! starts over, never fatal.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::{Receipt, ReceiptsFile, layers};
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
    /// Each receipt's views layer, by folder name: its files, at their
    /// paths inside the folder.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub layers: BTreeMap<String, BTreeMap<String, String>>,
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
        let receipts = self.read_setup_receipts()?.setups;
        Ok(SetupState {
            generation: self.current_generation()?,
            library,
            layers: self.layer_snapshot(&receipts)?,
            receipts,
        })
    }

    /// The views layers `receipts` name, as they are on disk.
    fn layer_snapshot(
        &self,
        receipts: &[Receipt],
    ) -> Result<BTreeMap<String, BTreeMap<String, String>>, Error> {
        let setups_dir = self.roots().setups_dir();
        let mut snapshot = BTreeMap::new();
        for layer in receipts.iter().filter_map(|receipt| receipt.layer.as_deref()) {
            snapshot.insert(layer.to_owned(), layers::read_layer(&setups_dir, layer)?);
        }
        Ok(snapshot)
    }

    /// Makes the layer folders exactly `target`'s: each one it names as it
    /// was, and one `now` names that it does not, gone.
    fn put_layers(
        &self,
        now: &BTreeMap<String, BTreeMap<String, String>>,
        target: &BTreeMap<String, BTreeMap<String, String>>,
    ) -> Result<(), Error> {
        let setups_dir = self.roots().setups_dir();
        for (layer, files) in target {
            if now.get(layer) != Some(files) {
                layers::put_layer(&setups_dir, layer, files)?;
            }
        }
        for layer in now.keys().filter(|layer| !target.contains_key(*layer)) {
            layers::remove_layer(&setups_dir, layer)?;
        }
        Ok(())
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

    /// Makes `state` live again outside the history (a swap whose second
    /// half failed puts back what was there before its first).
    pub fn restore_setup_state(
        &self,
        state: &SetupState,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<(), Error> {
        let _lock = self.store().lock()?;
        self.put_setup_state_locked(state, label, origin, now_ms)
    }

    /// The generation, library, layers and receipts of `target`, all or
    /// nothing.
    fn put_setup_state_locked(
        &self,
        target: &SetupState,
        label: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<(), Error> {
        let Some(n) = target.generation else {
            return Err(Error::Setup(format!("{label}: no generation was live to go back to")));
        };
        let library = self.library_snapshot()?;
        let receipts = self.read_setup_receipts()?;
        let layers_now = self.layer_snapshot(&receipts.setups)?;
        let moved = self
            .restore_locked(n, Kind::Autosaved, origin, label, now_ms)
            .and_then(|_| self.library_write_back(target.library.as_ref().map(String::as_bytes)))
            .and_then(|()| self.put_layers(&layers_now, &target.layers))
            .and_then(|()| {
                self.write_setup_receipts(&ReceiptsFile {
                    format: super::RECEIPTS_FORMAT,
                    setups: target.receipts.clone(),
                })
            });
        if let Err(error) = moved {
            // All or nothing: the library, layers and receipts as they were.
            let _ = self.library_write_back(library.as_deref());
            let _ = self.put_layers(&target.layers, &layers_now);
            let _ = self.write_setup_receipts(&receipts);
            return Err(error);
        }
        Ok(())
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
        let Some((index, step)) =
            index.and_then(|index| Some((index, history.steps.get(index)?.clone())))
        else {
            let what = if forward { "redo" } else { "undo" };
            return Err(Error::Setup(format!("there is no setup step to {what}")));
        };
        let target = if forward { &step.after } else { &step.before };
        let word = if forward { "redo" } else { "undo" };
        self.put_setup_state_locked(
            target,
            &format!("setup {word}: {}", step.label),
            origin,
            now_ms,
        )?;
        history.cursor = if forward { index.saturating_add(1) } else { index };
        self.write_setup_history(&history)?;
        Ok(step)
    }
}
