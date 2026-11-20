//! Collapse state for the transcript hierarchy: a turn (your message and
//! everything the agent did until your next one), a group of consecutive
//! tool calls, or one tool call or thought. The live turn and groups start
//! open; finished turns, tool details and thoughts start closed (thoughts
//! open when shown, except the one still streaming). `toggled` records the
//! flips. The defaults here match what the renderer draws.

use super::*;
use crate::transcript::{Item, Transcript};

/// Whether `t` starts open before any flip, as the renderer draws it.
fn default_open(tr: &Transcript, t: Toggle, show_thoughts: bool) -> bool {
    let running = tr.status == "running";
    match t {
        // Finished work starts folded; the turn still running stays open.
        Toggle::Turn(i) => {
            let later_user =
                tr.items.iter().skip(i + 1).any(|x| matches!(x, Item::User { queued: false, .. }));
            running && !later_user
        }
        Toggle::Group(_) => true,
        // The streaming thought shows one line; its details start closed.
        Toggle::Item(i) => {
            let streaming = running && i + 1 == tr.items.len();
            matches!(tr.items.get(i), Some(Item::Thought { .. })) && show_thoughts && !streaming
        }
    }
}

impl App {
    /// Moves session `id`'s flipped folds with their rows after the transcript removed
    /// rows (a promoted queued prompt, a steer replaced by its re-run): a fold on a
    /// removed row goes, and one below it moves up.
    pub(super) fn follow_removed_rows(&mut self, id: &str) {
        let Some(tr) = self.transcripts.get_mut(id) else { return };
        let removed = std::mem::take(&mut tr.removed_items);
        let Some(set) = self.toggled.get_mut(id) else { return };
        for pos in removed {
            *set = set
                .drain()
                .filter_map(|t| {
                    let (i, make): (usize, fn(usize) -> Toggle) = match t {
                        Toggle::Turn(i) => (i, Toggle::Turn),
                        Toggle::Group(i) => (i, Toggle::Group),
                        Toggle::Item(i) => (i, Toggle::Item),
                    };
                    match i.cmp(&pos) {
                        std::cmp::Ordering::Less => Some(t),
                        std::cmp::Ordering::Equal => None,
                        std::cmp::Ordering::Greater => Some(make(i - 1)),
                    }
                })
                .collect();
        }
    }

    /// Moves session `id`'s flipped folds down by `added` rows' worth of items, after an
    /// older page put `added` items before the ones they name.
    pub(super) fn shift_folds(&mut self, id: &str, added: usize) {
        if added == 0 {
            return;
        }
        let Some(set) = self.toggled.get_mut(id) else { return };
        *set = set
            .drain()
            .map(|t| match t {
                Toggle::Turn(i) => Toggle::Turn(i + added),
                Toggle::Group(i) => Toggle::Group(i + added),
                Toggle::Item(i) => Toggle::Item(i + added),
            })
            .collect();
    }

    fn toggled_set(&self) -> Option<&std::collections::HashSet<Toggle>> {
        self.selected_id().and_then(|id| self.toggled.get(&id))
    }

    /// Whether a collapsible is open right now, with its default applied.
    pub(super) fn is_open(&self, t: Toggle) -> bool {
        let flipped = self.toggled_set().map(|s| s.contains(&t)).unwrap_or(false);
        let base = self
            .selected_id()
            .and_then(|id| self.transcripts.get(&id))
            .map(|tr| default_open(tr, t, self.show_thoughts))
            .unwrap_or(matches!(t, Toggle::Group(_)));
        base ^ flipped
    }

    pub(super) fn toggle(&mut self, t: Toggle) {
        let Some(id) = self.selected_id() else { return };
        let set = self.toggled.entry(id).or_default();
        if !set.remove(&t) {
            set.insert(t);
        }
    }

    /// Open or close every collapsible of the selected session.
    pub(super) fn set_all_open(&mut self, open: bool) {
        let Some(id) = self.selected_id() else { return };
        let Some(tr) = self.transcripts.get(&id) else { return };
        let mut set = std::collections::HashSet::new();
        for (i, it) in tr.items.iter().enumerate() {
            let t = match it {
                Item::User { .. } => Toggle::Turn(i),
                Item::Tool { .. } | Item::Thought { .. } => Toggle::Item(i),
                _ => continue,
            };
            if default_open(tr, t, self.show_thoughts) != open {
                set.insert(t);
            }
        }
        // Groups start open; when closing, flip every group too. The
        // renderer keys groups by their first tool, so flip every tool index
        // as a group key as well; unused keys are harmless.
        if !open {
            for (i, it) in tr.items.iter().enumerate() {
                if matches!(it, Item::Tool { .. }) {
                    set.insert(Toggle::Group(i));
                }
            }
        }
        self.toggled.insert(id, set);
    }
}
