//! Copy-mode scrollback search: the prompt being typed, and the active
//! search with its matches, current match, and smart-case rule.

use super::engine::CopyPoint;
use super::grid::TerminalGrid;
use crate::ui::input::TextInput;

/// The most matches one search keeps. Past this the newest are kept and the
/// count shows a `+`.
pub(crate) const SEARCH_MATCH_LIMIT: usize = 10_000;

/// The search prompt while the needle is typed.
#[derive(Debug, Clone)]
pub(crate) struct SearchInput {
    pub(crate) text: TextInput,
    /// `/` searches forward (toward newer output), `?` backward.
    pub(crate) forward: bool,
}

impl SearchInput {
    pub(crate) fn new(forward: bool) -> Self {
        Self { text: TextInput::new(String::new()), forward }
    }
}

/// A submitted search.
#[derive(Debug, Clone)]
pub(crate) struct SearchState {
    pub(crate) needle: String,
    pub(crate) forward: bool,
    /// Inclusive match ranges, top to bottom.
    pub(crate) matches: Vec<(CopyPoint, CopyPoint)>,
    pub(crate) truncated: bool,
    /// Index into `matches` of the match under the cursor.
    pub(crate) current: Option<usize>,
}

/// Smart case: a needle with an uppercase letter matches case-sensitively.
pub(crate) fn smart_case_sensitive(needle: &str) -> bool {
    needle.chars().any(char::is_uppercase)
}

impl SearchState {
    pub(crate) fn new(needle: String, forward: bool) -> Self {
        Self { needle, forward, matches: Vec::new(), truncated: false, current: None }
    }

    /// Search the terminal again, so live output and evicted history are
    /// reflected before moving.
    pub(crate) fn refresh(&mut self, grid: &mut TerminalGrid<'_>) {
        let sensitive = smart_case_sensitive(&self.needle);
        let (matches, truncated) = grid.search(&self.needle, sensitive, SEARCH_MATCH_LIMIT);
        self.matches = matches;
        self.truncated = truncated;
        self.current = None;
    }

    /// Select the first match strictly after (`forward`) or before `from`,
    /// wrapping around past either end, and return its start.
    pub(crate) fn step(&mut self, from: CopyPoint, forward: bool) -> Option<CopyPoint> {
        if self.matches.is_empty() {
            self.current = None;
            return None;
        }
        let key = from.key();
        let index = if forward {
            self.matches.iter().position(|(start, _)| start.key() > key).unwrap_or(0)
        } else {
            self.matches
                .iter()
                .rposition(|(start, _)| start.key() < key)
                .unwrap_or(self.matches.len() - 1)
        };
        self.current = Some(index);
        self.matches.get(index).map(|(start, _)| *start)
    }

    /// The `k/n` count for the mode line; `n+` when the search was truncated.
    pub(crate) fn count_label(&self) -> String {
        let total = self.matches.len();
        let plus = if self.truncated { "+" } else { "" };
        match self.current {
            Some(index) => format!("{}/{total}{plus}", index + 1),
            None => format!("0/{total}{plus}"),
        }
    }

    /// The matches that touch rows `top..=bottom`, for highlighting.
    pub(crate) fn matches_in_rows(&self, top: u64, bottom: u64) -> &[(CopyPoint, CopyPoint)] {
        let first = self.matches.partition_point(|(_, end)| end.row < top);
        let last = self.matches.partition_point(|(start, _)| start.row <= bottom);
        self.matches.get(first..last.max(first)).unwrap_or_default()
    }
}
