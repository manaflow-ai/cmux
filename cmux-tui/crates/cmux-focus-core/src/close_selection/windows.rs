//! The close-selection rule's state for the workspaces of every window
//! (plans/cmux-next/close-focus.md, "One close-selection rule"; Lawrence
//! 2026-11-10: "we need to copy how google chrome does it"). One
//! [`WindowCloseSelection`] for the app; a window's workspaces are one strip.
//!
//! A workspace a person makes in the foreground (Cmd-N, the plus button, the
//! menu, the palette, a row menu's New Workspace) keeps an opener: the
//! workspace its window showed before. Closing it returns there. Its
//! lifetime follows the placement (decision 2026-11-10, Chrome 156
//! observed): put after the current row (the default), the relation lasts as
//! a link tab's does ([`OpenerKind::Task`]), until the person selects an
//! unrelated workspace; put at the end or the top, it is the quick look-up
//! ([`OpenerKind::Quick`]) and ends when the window's selection leaves the
//! new workspace. A workspace made by the CLI, the socket, MCP, a script, a
//! restore, a move, a duplicate or a drag has no opener ([`create_relation`]).
//! A relation never crosses windows.
//!
//! The shell (the macOS app) holds no part of this: it reports facts
//! (`expect_create`, `shown`, `left`, `renamed`, the answers of `settle`) and
//! applies the pick.
//!
//! Cost: with no relation held and no create waited for, `shown`, `left`,
//! `settle_questions` and `settle` are each a few emptiness checks of a
//! map: O(1), no allocation, and no call walks a window's members. With some
//! held, `shown` and `left` read the workspaces of those relations only, and
//! `settle` asks about those workspaces only (a few at most, on a membership
//! change, never on a switch) and reads no row list.

use super::{OpenerKind, Openers};
use std::collections::HashMap;
use std::hash::Hash;

mod press;
mod settle;

pub use settle::{SettleFacts, SettleQuestions};

/// The facts of one create of a workspace into a window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CreateFacts {
    /// The create opens the New Tab page (a duplicate, a template, a move, a
    /// session transfer, an import and a command workspace never do).
    pub opens_new_tab_page: bool,
    /// The run that creates is a person's own action (not the CLI, the
    /// socket, MCP or a script).
    pub persons_action: bool,
    /// The run may change the view.
    pub may_change_view: bool,
    /// The placement setting puts the new row after the current one.
    pub after_current: bool,
}

/// The relation a create starts, None for none. Only a person's own New
/// Workspace gets one: it opens the New Tab page in a run that is the
/// person's and may change the view. Put after the current row it is a
/// [`OpenerKind::Task`] relation; put at the top or the end it is the quick
/// look-up. (The macOS app's `WorkspaceSpawn.quickOpener(setting:)`.)
pub fn create_relation(facts: CreateFacts) -> Option<OpenerKind> {
    if !(facts.opens_new_tab_page && facts.persons_action && facts.may_change_view) {
        return None;
    }
    Some(if facts.after_current { OpenerKind::Task } else { OpenerKind::Quick })
}

/// The selection of a window that needs no pick after its members changed:
/// the first of `preferred` (the workspaces a person just moved in) that is
/// a member, else `current` when it is still a member. None: ask
/// [`WindowCloseSelection::pick`].
pub fn kept<T: PartialEq + Clone>(
    current: Option<&T>,
    members: &[T],
    preferred: &[T],
) -> Option<T> {
    preferred
        .iter()
        .find(|id| members.contains(*id))
        .or_else(|| current.filter(|id| members.contains(*id)))
        .cloned()
}

/// Whether the selection of `pick` by a selection repair is the repair's
/// own (true), not a person's: it is the person's only when the caller says
/// so (`gesture`) and `pick` is a workspace they just moved in.
pub fn is_repair<T: PartialEq>(gesture: bool, pick: Option<&T>, preferred: &[T]) -> bool {
    !(gesture && pick.is_some_and(|pick| preferred.contains(pick)))
}

/// A person's new workspace its window does not show yet.
#[derive(Debug, Clone)]
struct Expected<W> {
    window: W,
    kind: OpenerKind,
}

/// One selection repair that runs.
#[derive(Debug, Clone)]
struct Repair<T> {
    /// This repair or one around it selects for a close, not for a person.
    is_repair: bool,
    /// The workspace whose row the press of a close hid, while it holds a
    /// quick relation: the selection this repair makes does not end it.
    hidden: Option<T>,
}

/// One selection repair: the selection a close or a membership change
/// causes ([`WindowCloseSelection::repair_begin`]).
#[derive(Debug, Clone)]
pub struct RepairStart<'a, T> {
    /// The workspace the window showed before the repair.
    pub shown: Option<&'a T>,
    /// The workspace the repair selects.
    pub pick: Option<&'a T>,
    /// The caller says that a person asked, in this turn, for the selection
    /// of a `preferred` workspace (a move in, a drop). A daemon delta's
    /// caller says false.
    pub gesture: bool,
    /// The repair runs at the press of a close that hid rows and that can
    /// still be cancelled or refused. False for a daemon delta, a move, a
    /// room change and every other repair.
    pub pressed: bool,
    /// The window's members now (its rows). A `shown` that is not one of
    /// them lost its row: the press of a close hid it, or it closed or moved.
    pub members: &'a [T],
    /// The workspaces just moved in.
    pub preferred: &'a [T],
}

/// The close-selection state of every window's workspaces. `T` names a
/// workspace, `W` a window; both are compared by identity only.
#[derive(Debug, Clone)]
pub struct WindowCloseSelection<T, W> {
    openers: Openers<T>,
    /// A person's new workspaces their window does not show yet.
    expected: HashMap<T, Expected<W>>,
    /// The window of each workspace `openers` may hold a relation of.
    home: HashMap<T, W>,
    /// The selection repairs that run, the outer one first.
    repairs: Vec<Repair<T>>,
    /// The workspaces a press of a close hid with their quick relation kept
    /// (the close can still be cancelled or refused), each with its window.
    /// Always workspaces of `home`.
    pressed: HashMap<T, W>,
}

impl<T, W> Default for WindowCloseSelection<T, W> {
    fn default() -> Self {
        Self {
            openers: Openers::default(),
            expected: HashMap::new(),
            home: HashMap::new(),
            repairs: Vec::new(),
            pressed: HashMap::new(),
        }
    }
}

impl<T: Eq + Hash + Clone, W: Eq + Hash + Clone> WindowCloseSelection<T, W> {
    pub fn new() -> Self {
        Self::default()
    }

    /// No opener relation is held: every pick is by position.
    pub fn is_empty(&self) -> bool {
        self.home.is_empty()
    }

    /// The state names a workspace or a window: a create it waits for, a
    /// relation, or a repair that runs. While false, `shown`, `left`,
    /// `renamed` and `settle` change nothing, so a shell that numbers its ids
    /// for this state may forget its numbering.
    pub fn holds_ids(&self) -> bool {
        !(self.expected.is_empty()
            && self.home.is_empty()
            && self.repairs.is_empty()
            && self.pressed.is_empty())
    }

    /// The opener relations, to read.
    pub fn openers(&self) -> &Openers<T> {
        &self.openers
    }

    /// A create of `workspace` into `window` starts a relation of `kind`
    /// ([`create_relation`]). Call it before the window can show the
    /// workspace: it gets its opener when the window shows it (`shown`). A
    /// create that failed, or that its window listed and did not show, ends
    /// in `settle`.
    pub fn expect_create(&mut self, workspace: &T, window: &W, kind: OpenerKind) {
        self.expected.insert(workspace.clone(), Expected { window: window.clone(), kind });
    }

    /// A selection repair starts; [`WindowCloseSelection::repair_end`] ends
    /// it. The selection it sets is the close's, never a person's gesture,
    /// unless [`is_repair`] says it is the person's. Repairs nest: inside a
    /// repair every selection is a repair's. One push to a small stack that
    /// keeps its capacity.
    ///
    /// The repair at the press of a close (`pressed`) whose `shown` lost its
    /// row keeps a quick relation of `shown`: the close can still be
    /// cancelled or refused, and the row then comes back with its opener.
    /// The committed close ends the relation (`left`, `settle`), and so does
    /// the next selection of another workspace in that window.
    pub fn repair_begin(&mut self, repair: &RepairStart<'_, T>) {
        let own = is_repair(repair.gesture, repair.pick, repair.preferred);
        let hidden = self.hidden_by(repair);
        self.repairs.push(Repair { is_repair: own, hidden });
    }

    /// The innermost repair ended. With none running it changes nothing.
    pub fn repair_end(&mut self) {
        self.repairs.pop();
    }

    fn is_repairing(&self) -> bool {
        self.repairs.iter().any(|repair| repair.is_repair)
    }

    /// The strip of `window`, as far as the state can read it: each
    /// workspace with a live opener whose window it is, and that opener when
    /// it is of the window too. Never the window's members.
    fn strip(&self, window: &W) -> Vec<T> {
        let mut strip = Vec::new();
        for (child, relation) in &self.openers.relation {
            if self.home.get(child) != Some(window) {
                continue;
            }
            strip.push(child.clone());
            if self.home.get(&relation.opener) == Some(window) {
                strip.push(relation.opener.clone());
            }
        }
        strip
    }

    /// `window` now shows `new`; it showed `old` before. `gesture`: the code
    /// running at the change is a person's own action (not the CLI, the
    /// socket, MCP or a script). Report every selection change of a window.
    /// Inside a repair the change is the close's, whatever `gesture` says.
    pub fn shown(&mut self, new: &T, old: Option<&T>, window: &W, gesture: bool) {
        if !self.pressed.is_empty() {
            self.pressed_window_shows(new, window);
        }
        if !self.expected.is_empty()
            && let Some(made) = self.expected.remove(new)
            && made.window == *window
            && let Some(old) = old
        {
            // The two modes of the decision: after the current row is a task
            // opener, not reported as foreground (the older relations of the
            // window stay); else the quick look-up. The move itself first: it
            // ends a quick relation of the workspace the window leaves.
            let strip = self.strip(window);
            self.openers.selected(Some(old), new, false, &strip);
            let strip = self.strip(window);
            let foreground = made.kind == OpenerKind::Quick;
            self.openers.made(new, Some(old), made.kind, foreground, &strip);
            self.home.insert(new.clone(), window.clone());
            self.home.insert(old.clone(), window.clone());
            return;
        }
        if self.home.is_empty() {
            return;
        }
        let gesture = gesture && !self.is_repairing();
        let strip = self.strip(window);
        let kept = old.filter(|old| *old != new).and_then(|old| self.kept_at_press(old));
        self.openers.selected(old, new, gesture, &strip);
        if let Some((hidden, relation)) = kept {
            self.keep_pressed(hidden, relation, window);
        }
        self.forget_when_empty();
    }

    /// `workspace` closed or left its window. Call it after the pick for the
    /// close. A few map reads for a workspace the state does not hold.
    pub fn left(&mut self, workspace: &T) {
        if !self.expected.is_empty() {
            self.expected.remove(workspace);
        }
        if !self.pressed.is_empty() {
            self.pressed.remove(workspace);
        }
        if self.home.remove(workspace).is_none() {
            return;
        }
        self.openers.left(workspace);
        self.forget_when_empty();
    }

    /// Window `old` took the identity `new` (the launch window adopts the
    /// frontmost saved window): its creates and relations follow it.
    pub fn renamed(&mut self, old: &W, new: &W) {
        for made in self.expected.values_mut().filter(|made| made.window == *old) {
            made.window = new.clone();
        }
        for at in self.home.values_mut().filter(|at| **at == *old) {
            *at = new.clone();
        }
        for at in self.pressed.values_mut().filter(|at| **at == *old) {
            *at = new.clone();
        }
    }

    /// The workspace a window shows after `shown` left it: a workspace it
    /// opened, one its opener opened, its opener, else the next row below as
    /// drawn, and the row above only when it was the last. `previous` is the
    /// window's members before, `members` its members now, `orders` the
    /// sidebar's row orders before the close (the rows as drawn, then the
    /// model's). A row's group or section is not read (decision 2026-11-10,
    /// Chrome 156 as observed). A `shown` that is a member stays. Call it
    /// before [`WindowCloseSelection::left`] for the closed workspaces.
    ///
    /// A close of several rows in one gesture (a multi-selection, Close
    /// Others, Close Below, Close Above, a group close) is this same pick:
    /// `members` holds the survivors, and an opener that closes with `shown`
    /// is no candidate (Chrome 156 as observed).
    ///
    /// The caller gives the orders as they are. While a relation is held the
    /// pick prepares them itself: an opener of `shown` that is a member and
    /// that no order lists (a tile no sidebar row lists) goes first in each
    /// order that lists `shown`, and `previous` is the last order, so a
    /// workspace no row lists yet is picked with the opener rank too. With
    /// no relation held, or a `shown` that stays, nothing is copied.
    pub fn pick(
        &self,
        shown: Option<&T>,
        previous: &[T],
        members: &[T],
        orders: &[Vec<T>],
    ) -> Option<T> {
        let group: HashMap<T, u32> = HashMap::new();
        let closed = shown.filter(|shown| !self.is_empty() && !members.contains(shown));
        let Some(closed) = closed else {
            return self.openers.successor_in_orders(shown, previous, members, orders, &group);
        };
        let mut prepared = orders.to_vec();
        if let Some((opener, _)) = self.openers.opener(closed)
            && members.contains(opener)
            && !prepared.iter().any(|order| order.contains(opener))
        {
            for order in prepared.iter_mut().filter(|order| order.contains(closed)) {
                order.insert(0, opener.clone());
            }
        }
        prepared.push(previous.to_vec());
        self.openers.successor_in_orders(shown, previous, members, &prepared, &group)
    }

    /// With no relation left, nothing of the state is kept.
    fn forget_when_empty(&mut self) {
        if self.home.is_empty() || self.openers.has_relations() {
            return;
        }
        for workspace in self.home.keys() {
            self.openers.left(workspace);
        }
        self.home.clear();
        self.pressed.clear();
    }
}
