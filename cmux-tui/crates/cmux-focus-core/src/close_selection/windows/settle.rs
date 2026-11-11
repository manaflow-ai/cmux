//! The settle of [`WindowCloseSelection`]: after a selection repair, the
//! creates and relations of workspaces that closed, moved, or whose window
//! is gone leave the state. The shell answers questions with facts; the
//! decision is here.

use super::WindowCloseSelection;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;

/// What [`WindowCloseSelection::settle`] must know about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettleQuestions<T, W> {
    /// For each: the window that lists it now, and whether it is a create
    /// its window waits for.
    pub workspaces: Vec<T>,
    /// For each: whether the window is registered.
    pub windows: Vec<W>,
}

/// The answers to [`SettleQuestions`]. A question with no answer reads as:
/// listed by no window, not claimed, not registered.
#[derive(Debug, Clone)]
pub struct SettleFacts<T, W> {
    /// A workspace to the window that lists it now.
    pub owner: HashMap<T, W>,
    /// The workspaces that are creates their window waits for.
    pub claimed: HashSet<T>,
    /// The windows that are registered.
    pub existing: HashSet<W>,
}

impl<T, W> Default for SettleFacts<T, W> {
    fn default() -> Self {
        Self { owner: HashMap::new(), claimed: HashSet::new(), existing: HashSet::new() }
    }
}

impl<T: Eq + Hash + Clone, W: Eq + Hash + Clone> WindowCloseSelection<T, W> {
    /// A create is waited for or a relation is held: `settle` has questions.
    pub fn has_questions(&self) -> bool {
        !(self.expected.is_empty() && self.home.is_empty())
    }

    /// What `settle` of `window` must know: the workspaces of `window` the
    /// state holds, and the other windows it holds a workspace of. With
    /// nothing held both lists are empty and nothing is allocated: O(1).
    /// Else O(held workspaces); never a walk of a window's members.
    pub fn settle_questions(&self, window: &W) -> SettleQuestions<T, W> {
        let mut questions = SettleQuestions { workspaces: Vec::new(), windows: Vec::new() };
        let made = self.expected.iter().map(|(workspace, made)| (workspace, &made.window));
        for (workspace, at) in made.chain(self.home.iter()) {
            if at != window {
                if !questions.windows.contains(at) {
                    questions.windows.push(at.clone());
                }
            } else if !questions.workspaces.contains(workspace) {
                questions.workspaces.push(workspace.clone());
            }
        }
        questions
    }

    /// After the selection repair of `window`: a workspace of the state that
    /// no window lists any more (its close is committed), or that another
    /// window lists (moved), leaves the state, and so does one whose window
    /// is gone. A row that only left the window's rows (hidden at the press
    /// of a close that can still be cancelled or refused, or in another
    /// room) keeps its relation. A create the window lists and did not show
    /// in this repair is not in the foreground, and one that is neither
    /// listed nor waited for failed, as did one whose window is gone: no
    /// opener. `facts` answers [`WindowCloseSelection::settle_questions`];
    /// with nothing held it is not read.
    pub fn settle(&mut self, window: &W, facts: &SettleFacts<T, W>) {
        if !self.expected.is_empty() {
            self.expected.retain(|workspace, made| {
                if made.window != *window {
                    return facts.existing.contains(&made.window);
                }
                !facts.owner.contains_key(workspace) && facts.claimed.contains(workspace)
            });
        }
        if self.home.is_empty() {
            return;
        }
        let gone = |workspace: &T, at: &W| {
            if at != window {
                return !facts.existing.contains(at);
            }
            facts.owner.get(workspace) != Some(window) && !facts.claimed.contains(workspace)
        };
        let leaving: Vec<T> = self
            .home
            .iter()
            .filter(|&(workspace, at)| gone(workspace, at))
            .map(|(workspace, _)| workspace.clone())
            .collect();
        for workspace in &leaving {
            self.left(workspace);
        }
    }
}
