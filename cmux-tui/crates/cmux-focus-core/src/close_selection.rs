//! The one close-selection rule for tabs in a pane and workspaces in the
//! sidebar: which item is selected after the selected one closed, and the
//! opener relations that decide it (plans/cmux-next/close-focus.md, "One
//! close-selection rule").
//!
//! A strip is one pane's tabs or one window's workspaces. [`Openers`] is the
//! state: who opened which item (Chromium's `TabModel::opener`), with
//! Chromium's lifetime (`TabStripModel::AddTab`, `InsertTabAtImpl`,
//! `OnActiveTabChanged`, `TabNavigating`, `FixOpeners`; tab_strip_model.cc
//! at 157.0.8103.50). The pick is `TabStripModel::DetermineNewSelectedIndex`
//! ([`close_focus::tab`]'s ranks) for both kinds:
//!
//! - R0 closing an item that is not selected never moves the selection;
//! - R1 closing the selected item selects, first match: an item it opened
//!   (the first after it, else the nearest before it), an item its opener
//!   opened, its opener, its group's or section's neighbor, else the NEXT
//!   item, and the previous one only when it was the last;
//! - R2 a person's new item (Cmd-T, the plus button, New Workspace) keeps a
//!   [`OpenerKind::Quick`] opener, wherever the new item is put (Chromium's
//!   "quick look-up" of a new tab at the end of the strip; a tab Chromium
//!   puts in the middle, "New Tab to the Right", keeps its opener as a
//!   link's tab does, and the caller's `kind` and `foreground` can say
//!   that); a link's or a tab action's new tab keeps a [`OpenerKind::Task`]
//!   opener; nothing else has one;
//! - R3 a deliberate selection of an unrelated item, and a typed navigation
//!   that is not a just-made tab's first, forget every relation of the strip;
//! - R4 a relation holds inside one strip only ([`Openers::left`]);
//! - R5 where the new item is put changes none of this ([`Openers::slot`]
//!   names a background child's place).
//!
//! Ids are compared by identity only (the app's strings, or the integers its
//! C ABI maps them to). One `Openers` may hold the relations of many strips:
//! each call names its strip by its items.
//!
//! [`windows::WindowCloseSelection`] is the whole state of the workspaces of
//! every window: these relations, the creates a window waits for, and the
//! window of each relation.

use crate::close_focus::{self, TabRelations};
use std::collections::{HashMap, HashSet};
use std::hash::Hash;

pub mod windows;

/// How long an opener relation lives (R2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenerKind {
    /// A person made the item in the foreground. Forgotten when the
    /// selection leaves the item for any reason (Chromium's
    /// `reset_opener_on_active_tab_change`).
    Quick,
    /// A link, or an action inside the opener, made the item, in the
    /// foreground or the background. Kept until R3 or R4 clears it.
    Task,
}

#[derive(Debug, Clone)]
struct Relation<T> {
    opener: T,
    kind: OpenerKind,
}

/// The opener relations of tabs or of workspaces (R2 to R4), and the pick
/// after a close (R0, R1).
#[derive(Debug, Clone)]
pub struct Openers<T> {
    /// Child to its opener.
    relation: HashMap<T, Relation<T>>,
    /// A person's new items that have not navigated yet (the new-tab page
    /// with one history entry, in Chromium's terms).
    fresh: HashSet<T>,
}

impl<T> Default for Openers<T> {
    fn default() -> Self {
        Self { relation: HashMap::new(), fresh: HashSet::new() }
    }
}

impl<T: Eq + Hash + Clone> Openers<T> {
    pub fn new() -> Self {
        Self::default()
    }

    /// `item` was made while `opener` was the selected item of `strip` (the
    /// strip's items, with or without the new one). `foreground`: the new
    /// item is selected. A foreground item first forgets every relation of
    /// the strip, so one family is live at a time (`InsertTabAtImpl`). A
    /// `Quick` item that is not in the foreground has no opener (R2). Items
    /// made by automation, a restore, a move or a drag are not reported here.
    pub fn made(
        &mut self,
        item: &T,
        opener: Option<&T>,
        kind: OpenerKind,
        foreground: bool,
        strip: &[T],
    ) {
        if kind == OpenerKind::Quick {
            if !foreground {
                return;
            }
            self.fresh.insert(item.clone());
        }
        let Some(opener) = opener.filter(|opener| *opener != item) else { return };
        if foreground {
            self.forget_all(strip);
        }
        self.relation.insert(item.clone(), Relation { opener: opener.clone(), kind });
    }

    /// The strip's selection moved from `old` to `new`. `gesture`: a person
    /// chose `new` (a click, a shortcut, the palette, the switcher); a close
    /// and the selection it causes, and automation, are not one. A `Quick`
    /// relation of `old` ends on any move. A gesture forgets every relation
    /// of the strip unless `new` and `old` have the same opener (or both
    /// none), or one is the other's opener (`OnActiveTabChanged`). With no
    /// relation held the call reads nothing of `strip`.
    pub fn selected(&mut self, old: Option<&T>, new: &T, gesture: bool, strip: &[T]) {
        if old == Some(new) || self.relation.is_empty() {
            return;
        }
        let members: HashSet<&T> = strip.iter().collect();
        let old_opener = old.and_then(|old| self.opener_among(old, &members)).cloned();
        if let Some(old) = old
            && self.relation.get(old).is_some_and(|relation| relation.kind == OpenerKind::Quick)
        {
            self.relation.remove(old);
        }
        let new_opener = self.opener_among(new, &members).cloned();
        if gesture
            && new_opener != old_opener
            && new_opener.as_ref() != old
            && old_opener.as_ref() != Some(new)
        {
            self.forget_all(strip);
        }
    }

    /// A typed navigation (the address bar, a bookmark, a generated one; not
    /// a link click) in `tab`: the person starts another task there, so every
    /// relation of the strip is forgotten, except at the first one in a tab
    /// the person just made (`TabNavigating`: "one navigation ... for the use
    /// case of opening a new tab to do a quick look-up").
    pub fn typed_navigation(&mut self, tab: &T, strip: &[T]) {
        if !self.fresh.remove(tab) {
            self.forget_all(strip);
        }
    }

    /// Any other navigation committed in `tab` (a link click, a redirect, a
    /// script's): the tab is no longer one the person just made, so its next
    /// typed navigation forgets (`IsNewTabAtEndOfTabStrip` wants one history
    /// entry). No relation changes. Not for the new tab's own first page
    /// load, and not for the commit of a typed navigation (that one is
    /// [`Openers::typed_navigation`]'s): either would end "just made" before
    /// the person's first address.
    pub fn navigated(&mut self, tab: &T) {
        self.fresh.remove(tab);
    }

    /// `item` left its strip (closed, or moved to another strip or place):
    /// the items it opened take its opener, and its own relation ends
    /// (`FixOpeners`; R4). Report every item that closes: it is what ends an
    /// item's state here.
    pub fn left(&mut self, item: &T) {
        self.fresh.remove(item);
        if self.relation.is_empty() {
            return;
        }
        let parent = self.relation.remove(item).map(|relation| relation.opener);
        self.relation.retain(|child, relation| {
            if relation.opener != *item {
                return true;
            }
            match &parent {
                Some(parent) if parent != child => {
                    relation.opener = parent.clone();
                    true
                }
                _ => false,
            }
        });
    }

    /// Forgets every relation of the items of `strip` (`ForgetAllOpeners`).
    pub fn forget_all(&mut self, strip: &[T]) {
        if self.relation.is_empty() {
            return;
        }
        for item in strip {
            self.relation.remove(item);
        }
    }

    /// The live opener of `item`, with its kind.
    pub fn opener(&self, item: &T) -> Option<(&T, OpenerKind)> {
        self.relation.get(item).map(|relation| (&relation.opener, relation.kind))
    }

    /// No relation and no just-made item is held.
    pub fn is_empty(&self) -> bool {
        self.relation.is_empty() && self.fresh.is_empty()
    }

    /// An opener relation is held, in any strip. While none is, a selection
    /// change needs no call and a pick is positional. A close still reports
    /// [`Openers::left`].
    pub fn has_relations(&self) -> bool {
        !self.relation.is_empty()
    }

    fn opener_among(&self, item: &T, members: &HashSet<&T>) -> Option<&T> {
        self.relation
            .get(item)
            .map(|relation| &relation.opener)
            .filter(|opener| members.contains(opener))
    }

    /// The relations among the items of `strip` (child to opener).
    fn among(&self, strip: &[T]) -> HashMap<T, T> {
        if self.relation.is_empty() {
            return HashMap::new();
        }
        let members: HashSet<&T> = strip.iter().collect();
        strip
            .iter()
            .filter_map(|item| Some((item.clone(), self.opener_among(item, &members)?.clone())))
            .collect()
    }

    /// The tab a pane selects after `selected` closed (R0, R1). `old` is the
    /// strip before the close, `surviving` the tabs left, `shown` the
    /// surviving tabs that are not hidden (a collapsed group's are), `group`
    /// each grouped tab's group. Call it before [`Openers::left`] for the
    /// closed tabs. A surviving selection stays; none left gives none.
    pub fn successor<G: Eq + Clone>(
        &self,
        selected: Option<&T>,
        old: &[T],
        surviving: &[T],
        shown: &HashSet<T>,
        group: &HashMap<T, G>,
    ) -> Option<T> {
        let relations = TabRelations { opener: self.among(old), group: group.clone() };
        close_focus::tab(selected, old, surviving, shown, &relations)
    }

    /// The workspace a window shows after `shown` left it (R0, R1). `old` is
    /// the window's members before, `surviving` its members now, `orders` the
    /// sidebar's row orders before the close, most preferred first (the rows
    /// as drawn, then the model's rows), `group` each row's group or section.
    /// The first order that lists `shown` and has a pick decides: only its
    /// rows can be picked, so a drawn row hands off to a drawn row and never
    /// to a workspace no row lists while a row is left. `old` decides last.
    pub fn successor_in_orders<G: Eq + Clone>(
        &self,
        shown: Option<&T>,
        old: &[T],
        surviving: &[T],
        orders: &[Vec<T>],
        group: &HashMap<T, G>,
    ) -> Option<T> {
        let live: HashSet<&T> = surviving.iter().collect();
        let Some(shown) = shown else { return surviving.first().cloned() };
        if live.contains(shown) {
            return Some(shown.clone());
        }
        let members: HashSet<&T> = old.iter().collect();
        let relations = TabRelations { opener: self.among(old), group: group.clone() };
        for order in orders.iter().filter(|order| order.contains(shown)) {
            let rows: Vec<T> =
                order.iter().filter(|id| *id == shown || members.contains(id)).cloned().collect();
            let left: Vec<T> = rows.iter().filter(|id| live.contains(id)).cloned().collect();
            let drawn: HashSet<T> = left.iter().cloned().collect();
            if !left.is_empty() {
                return close_focus::tab(Some(shown), &rows, &left, &drawn, &relations);
            }
        }
        close_focus::neighbor(shown, old, true, |id| live.contains(id))
            .or_else(|| surviving.first())
            .cloned()
    }

    /// The item a background child of `opener` goes after (R5): the last of
    /// the run of `opener`'s descendants that directly follows it in `order`,
    /// else `opener`. A pinned item never ends the run
    /// (`GetIndexOfLastWebContentsOpenedBy`).
    pub fn slot(&self, opener: &T, order: &[T], pinned: &HashSet<T>) -> T {
        let relations = close_focus::live_openers(&self.among(order), order);
        let mut family: HashSet<&T> = HashSet::from([opener]);
        let mut last = opener;
        for item in order.iter().skip_while(|item| *item != opener).skip(1) {
            match relations.get(item) {
                Some(parent) if family.contains(parent) => {
                    family.insert(item);
                    last = item;
                }
                _ if pinned.contains(item) => {}
                _ => break,
            }
        }
        last.clone()
    }
}
