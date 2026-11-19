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
//! started over, never fatal.

use std::path::{Path, PathBuf};

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
    /// `appearance.themeFile` before the first pack applied.
    #[serde(default)]
    pub before: Option<String>,
    #[serde(default)]
    pub generations: Vec<Generation>,
    /// How many generations are applied: 0 is `before`, `n` is generation `n - 1`.
    #[serde(default)]
    pub cursor: usize,
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
    /// The history in `path`; a missing or unreadable one is empty.
    pub fn read(path: &Path) -> History {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str::<History>(&text).ok())
            .map(History::clamped)
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

    /// The applied generation, if a pack is applied.
    pub fn current(&self) -> Option<&Generation> {
        self.cursor.checked_sub(1).and_then(|index| self.generations.get(index))
    }

    /// Applies `generation` after the current one, dropping the redo tail.
    /// `in_use` is the theme file picked now, kept as `before` when no pack is applied.
    pub fn push(&mut self, generation: Generation, in_use: Option<String>) -> Step {
        if self.cursor == 0 {
            self.before = in_use.filter(|name| !name.starts_with("pack-"));
        }
        self.generations.truncate(self.cursor);
        self.generations.push(generation);
        if self.generations.len() > MAXIMUM_GENERATIONS {
            let extra = self.generations.len() - MAXIMUM_GENERATIONS;
            self.generations.drain(..extra);
        }
        self.cursor = self.generations.len();
        self.step()
    }

    /// Replaces the applied generation in place (a live edit of a pack's
    /// files while it is being worked on), so saving twenty times is not
    /// twenty undo steps. With nothing applied it is a push.
    pub fn replace(&mut self, generation: Generation, in_use: Option<String>) -> Step {
        match self.cursor.checked_sub(1) {
            Some(index) if self.generations[index].pack == generation.pack => {
                // A live edit keeps the file name it replaces: the app is
                // already reading that file and repaints on the rewrite.
                let theme = std::mem::take(&mut self.generations[index].theme);
                self.generations[index] = Generation { theme, ..generation };
                self.generations.truncate(self.cursor);
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
        self.cursor += 1;
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
