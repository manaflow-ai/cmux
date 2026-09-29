//! Collapse state for the transcript hierarchy: a turn (your message and
//! everything the agent did until your next one), a group of consecutive
//! tool calls, or one tool call or thought. Turns and groups start open;
//! tool details and thoughts start closed. `toggled` records the flips.

use super::*;

impl App {
    fn toggled_set(&self) -> Option<&std::collections::HashSet<Toggle>> {
        self.selected_id().and_then(|id| self.toggled.get(&id))
    }

    /// Whether a collapsible is open right now, with its default applied.
    pub(super) fn is_open(&self, t: Toggle) -> bool {
        let flipped = self.toggled_set().map(|s| s.contains(&t)).unwrap_or(false);
        let default_open = match t {
            Toggle::Turn(_) | Toggle::Group(_) => true,
            Toggle::Item(i) => {
                let is_thought = self.selected_id().and_then(|id| self.transcripts.get(&id)).and_then(|tr| tr.items.get(i)).map(|it| matches!(it, crate::transcript::Item::Thought { .. })).unwrap_or(false);
                is_thought && self.show_thoughts
            }
        };
        default_open ^ flipped
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
                crate::transcript::Item::User { .. } => Toggle::Turn(i),
                crate::transcript::Item::Tool { .. } | crate::transcript::Item::Thought { .. } => Toggle::Item(i),
                _ => continue,
            };
            let default_open = matches!(t, Toggle::Turn(_)) || (matches!(it, crate::transcript::Item::Thought { .. }) && self.show_thoughts);
            if default_open != open {
                set.insert(t);
            }
        }
        // Groups start open; when closing, flip every group too. The
        // renderer keys groups by their first tool, so flip every tool index
        // as a group key as well; unused keys are harmless.
        if !open {
            for (i, it) in tr.items.iter().enumerate() {
                if matches!(it, crate::transcript::Item::Tool { .. }) {
                    set.insert(Toggle::Group(i));
                }
            }
        }
        self.toggled.insert(id, set);
    }
}
