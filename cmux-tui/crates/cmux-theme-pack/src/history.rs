//! Swap, undo, redo and live edit across a whole pack.
//!
//! Each applied pack (or edit of one) is one generation: the compiled theme
//! file text and the name it applies as. Undo and redo move a cursor and
//! write that generation's text back, so one step always restores a whole
//! pack, never half of one. The generation before the first is the theme
//! file that was in use (or none), kept as `before`.
//!
//! The history is a small JSON file beside the packs
//! (`<config dir>/packs/.history.json`). A history that does not parse is
//! started over, never fatal. Its names become file paths, so reading it
//! drops any name that is not a plain theme file name, and any generation or
//! written name without the `pack-` prefix every compiled file has.

use std::path::{Path, PathBuf};

use cmux_config::theme_file;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// At most this many generations are kept; the oldest go first.
pub const MAXIMUM_GENERATIONS: usize = 64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Generation {
    /// The pack's id.
    pub pack: String,
    /// The pack folder it was read from.
    pub dir: PathBuf,
    /// The theme file name it applies as.
    pub theme: String,
    /// The compiled theme file.
    pub text: String,
    /// Live edits over the pack's own values (dotted keys).
    #[serde(default)]
    pub edits: Map<String, Value>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct History {
    /// `appearance.themeFile` before the first pack applied, or the theme
    /// file the person picked themselves since (the store starts the history
    /// over from it; see `Store`).
    #[serde(default)]
    pub before: Option<String>,
    #[serde(default)]
    pub generations: Vec<Generation>,
    /// How many generations are applied: 0 is `before`, `n` is generation `n - 1`.
    #[serde(default)]
    pub cursor: usize,
    /// Theme file names this store wrote and has not removed: the only
    /// files pruning may delete (never a theme of the person's own).
    #[serde(default)]
    pub written: Vec<String>,
}

/// What applying a step writes: a theme file and the setting that picks it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    /// Write `text` to `themes/<theme>.json`, then pick `theme`.
    Apply { theme: String, text: String },
    /// Back to the theme file in use before any pack (`None`: no theme file).
    Restore(Option<String>),
}

impl History {
    /// The history in `path`; a missing or unreadable one is empty. Names
    /// that could leave the themes folder, or that no compiled file has, are
    /// dropped (a generation with one goes, and the cursor moves with it).
    pub fn read(path: &Path) -> History {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str::<History>(&text).ok())
            .map(History::clamped)
            .map(History::sanitized)
            .unwrap_or_default()
    }

    pub fn write(&self, path: &Path) -> std::io::Result<()> {
        let text = serde_json::to_string(self).map_err(std::io::Error::other)?;
        crate::store::replace(path, text.as_bytes())
    }

    fn clamped(mut self) -> History {
        self.cursor = self.cursor.min(self.generations.len());
        self
    }

    /// Only names the store may turn into paths: `before` a valid theme
    /// file name, every generation's and written name a valid `pack-` one
    /// (an `off` generation names none).
    fn sanitized(mut self) -> History {
        let applied = self.cursor;
        let mut cursor = applied;
        let mut kept = Vec::with_capacity(self.generations.len());
        for (index, generation) in std::mem::take(&mut self.generations).into_iter().enumerate() {
            if generation.is_off() || is_compiled_name(&generation.theme) {
                kept.push(generation);
            } else if index < applied {
                cursor = cursor.saturating_sub(1);
            }
        }
        self.generations = kept;
        self.cursor = cursor.min(self.generations.len());
        self.written.retain(|name| is_compiled_name(name));
        self.before = self.before.filter(|name| theme_file::is_valid_name(name));
        self
    }

    /// The theme file the history has applied: the current generation's, or
    /// `before` with no pack applied (or after `off`).
    pub fn applied(&self) -> Option<&str> {
        match self.current() {
            Some(generation) if !generation.is_off() => Some(generation.theme.as_str()),
            _ => self.before.as_deref(),
        }
    }

    /// Starts over from `in_use` as `before`, with no generations. `written`
    /// stays, so the files it lists are still bounded by pruning.
    pub fn restart(&mut self, in_use: Option<String>) {
        self.before = in_use;
        self.generations.clear();
        self.cursor = 0;
    }

    /// The applied generation, if a pack is applied.
    pub fn current(&self) -> Option<&Generation> {
        self.cursor.checked_sub(1).and_then(|index| self.generations.get(index))
    }

    /// Applies `generation` after the current one, dropping the redo tail.
    /// `in_use` is the theme file picked now, kept as `before` when no pack
    /// is applied, unless it is a file this history wrote (`written`, never
    /// the name's prefix): then the setting is stale (an undo whose settings
    /// write never landed) and `before` stays. A theme of the person's own is
    /// kept whatever its name.
    pub fn push(&mut self, generation: Generation, in_use: Option<String>) -> Step {
        if self.cursor == 0 && in_use.as_ref().is_none_or(|name| !self.written.contains(name)) {
            self.before = in_use;
        }
        self.generations.truncate(self.cursor);
        self.generations.push(generation);
        if self.generations.len() > MAXIMUM_GENERATIONS {
            let extra = self.generations.len().saturating_sub(MAXIMUM_GENERATIONS);
            self.generations.drain(..extra);
        }
        self.cursor = self.generations.len();
        self.step()
    }

    /// Replaces the applied generation in place (a live edit of a pack's
    /// files while it is being worked on), so saving twenty times is not
    /// twenty undo steps. With nothing applied it is a push.
    pub fn replace(&mut self, generation: Generation, in_use: Option<String>) -> Step {
        let cursor = self.cursor;
        let current = cursor.checked_sub(1).and_then(|index| self.generations.get_mut(index));
        match current {
            Some(current) if current.pack == generation.pack => {
                // A live edit keeps the file name it replaces: the app is
                // already reading that file and repaints on the rewrite.
                let theme = std::mem::take(&mut current.theme);
                *current = Generation { theme, ..generation };
                self.generations.truncate(cursor);
                self.step()
            }
            _ => self.push(generation, in_use),
        }
    }

    /// One generation back; `None` when there is none.
    pub fn undo(&mut self) -> Option<Step> {
        self.cursor = self.cursor.checked_sub(1)?;
        Some(self.step())
    }

    /// One generation forward; `None` when there is none.
    pub fn redo(&mut self) -> Option<Step> {
        if self.cursor >= self.generations.len() {
            return None;
        }
        self.cursor = self.cursor.saturating_add(1);
        Some(self.step())
    }

    /// Takes every pack off: back to `before`, as one generation, so undo
    /// puts the pack back.
    pub fn off(&mut self) -> Option<Step> {
        if self.current().is_none_or(Generation::is_off) {
            return None;
        }
        let off = Generation {
            pack: String::new(),
            dir: PathBuf::new(),
            theme: String::new(),
            text: String::new(),
            edits: Map::new(),
        };
        Some(self.push(off, None))
    }

    fn step(&self) -> Step {
        match self.current() {
            Some(generation) if !generation.is_off() => {
                Step::Apply { theme: generation.theme.clone(), text: generation.text.clone() }
            }
            _ => Step::Restore(self.before.clone()),
        }
    }
}

/// A name a compiled pack file can have: a valid theme file name with the
/// `pack-` prefix `load::theme_name` gives every pack.
fn is_compiled_name(name: &str) -> bool {
    name.starts_with("pack-") && theme_file::is_valid_name(name)
}

impl Generation {
    /// The generation `off` records: no pack.
    pub fn is_off(&self) -> bool {
        self.theme.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn generation(pack: &str, text: &str) -> Generation {
        Generation {
            pack: pack.into(),
            dir: PathBuf::from("/packs").join(pack),
            theme: format!("pack-{pack}"),
            text: text.into(),
            edits: Map::new(),
        }
    }

    fn applied(step: Option<Step>) -> String {
        match step {
            Some(Step::Apply { text, .. }) => text,
            Some(Step::Restore(before)) => format!("restore {before:?}"),
            None => "none".into(),
        }
    }

    #[test]
    fn undo_and_redo_move_whole_packs() {
        let mut history = History::default();
        history.push(generation("a", "A"), Some("harbor".into()));
        history.push(generation("b", "B"), Some("pack-a".into()));
        assert_eq!(applied(history.undo()), "A");
        assert_eq!(applied(history.undo()), "restore Some(\"harbor\")");
        assert_eq!(applied(history.undo()), "none");
        assert_eq!(applied(history.redo()), "A");
        assert_eq!(applied(history.redo()), "B");
        assert_eq!(applied(history.redo()), "none");
    }

    #[test]
    fn a_new_pack_after_undo_drops_the_redo_tail() {
        let mut history = History::default();
        history.push(generation("a", "A"), None);
        history.push(generation("b", "B"), None);
        history.undo();
        history.push(generation("c", "C"), None);
        assert_eq!(history.generations.len(), 2);
        assert_eq!(applied(history.redo()), "none");
        assert_eq!(applied(history.undo()), "A");
    }

    #[test]
    fn live_edits_replace_the_applied_generation() {
        let mut history = History::default();
        history.push(generation("a", "A1"), None);
        history.replace(generation("a", "A2"), None);
        history.replace(generation("a", "A3"), None);
        assert_eq!(history.generations.len(), 1);
        assert_eq!(applied(history.undo()), "restore None");
        assert_eq!(applied(history.redo()), "A3");
    }

    #[test]
    fn off_is_one_undoable_step() {
        let mut history = History::default();
        history.push(generation("a", "A"), Some("phosphor".into()));
        assert_eq!(applied(history.off()), "restore Some(\"phosphor\")");
        assert_eq!(applied(history.off()), "none");
        assert_eq!(applied(history.undo()), "A");
        assert_eq!(applied(history.redo()), "restore Some(\"phosphor\")");
        // A pack after off keeps the look before the first pack as `before`.
        history.push(generation("b", "B"), None);
        assert_eq!(applied(history.undo()), "restore Some(\"phosphor\")");
        assert_eq!(applied(history.undo()), "A");
    }

    #[test]
    fn history_is_bounded() {
        let mut history = History::default();
        for index in 0..(MAXIMUM_GENERATIONS + 10) {
            history.push(generation("a", &index.to_string()), None);
        }
        assert_eq!(history.generations.len(), MAXIMUM_GENERATIONS);
        assert_eq!(history.cursor, MAXIMUM_GENERATIONS);
    }

    #[test]
    fn a_garbage_history_file_starts_over() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".history.json");
        std::fs::write(&path, "{not json").unwrap();
        assert_eq!(History::read(&path), History::default());
        std::fs::write(&path, r#"{"generations":[],"cursor":99}"#).unwrap();
        assert_eq!(History::read(&path).cursor, 0);
    }
}
