//! The strip of a pane with a hole for each tab creation that has no tab yet
//! (`tab-create-place-v1`).
//!
//! A create request takes its slot when it arrives ([`PlaceLists::admit`]).
//! Its tab comes later, when its terminal has launched
//! ([`PlaceLists::commit`]); other creates and closes of the pane commit in
//! between. The rule that this list keeps: for each order of the commits, the
//! tabs of the pane are those of the same requests applied one by one in the
//! order of their arrival. The active tab follows the same rule among the
//! creations: a tab that comes after the tab of a later request does not take
//! the active tab from it ([`PlaceLists::takes_active`]), and a tab whose
//! slot a close of the active tab picked takes it when it comes
//! ([`PlaceLists::tab_closes`]), if no request changed the active tab of the
//! pane after that close.
//!
//! The list is a pure value: it reads the pane's tabs and its active tab
//! from its caller and holds no lock.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use cmux_focus_core::close_focus;

use super::tab_place::{Anchor, Settled, Slot, TabPlace, Wanted, settle};
use crate::{PaneId, SurfaceId};

/// The most creations with a `transaction` that the record keeps. A request
/// that names an older one gets the end of the strip.
const KEPT: usize = 256;

/// What a create request asked for, as its creation gives it to the list.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Asked<'a> {
    /// The connection of the request.
    pub(crate) client: u64,
    /// The `transaction` of the request: a later request of the connection
    /// names the creation by it (`place.after_creation`).
    pub(crate) transaction: Option<&'a str>,
    /// The `place` of the request; none is the end of the strip.
    pub(crate) place: Option<&'a TabPlace>,
    /// The tab asks for the active tab of its pane when it comes.
    pub(crate) activate: bool,
}

/// The active tab of a pane and the stamp of its last change by a request
/// (`Pane::active_at`), as the caller reads them from the pane. A select, a
/// focus of the pane and a new tab that takes the active tab write a new
/// stamp. A close writes none.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ActiveNow {
    /// The active tab; none for a pane with no tab.
    pub(crate) tab: Option<SurfaceId>,
    pub(crate) at: u64,
}

/// The strip of a pane when a creation commits its tab.
#[derive(Clone, Copy, Debug)]
pub(crate) struct StripNow<'a> {
    /// The pane's tabs.
    pub(crate) tabs: &'a [Slot],
    /// The id of each tab group run of `tabs`.
    pub(crate) groups: &'a [String],
    pub(crate) active: ActiveNow,
}

/// One entry of the list of a pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Entry {
    /// A tab of the pane.
    Tab(SurfaceId),
    /// The slot of the creation with this number: its tab is not there yet,
    /// or it left the pane (it closed, it moved away, or the creation
    /// failed) and a later request can still name the creation.
    Hole(u64),
}

/// One tab creation of the record.
#[derive(Clone, Debug)]
struct Creation {
    number: u64,
    /// The connection of the request.
    client: u64,
    /// The name of the creation. A creation with no name leaves the record
    /// when it ends: no request can name it.
    transaction: Option<Arc<str>>,
    pane: PaneId,
    /// The tab that the creation made.
    tab: Option<SurfaceId>,
    /// The tab group that the tab joins when it comes.
    group: Option<String>,
    /// The creation has not ended.
    pending: bool,
}

impl Creation {
    fn is_named(&self) -> bool {
        self.transaction.is_some()
    }
}

/// A close of the active tab picked the slot of a creation that had no tab
/// yet.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Awaited {
    /// The creation.
    number: u64,
    /// The tab that closed.
    closed: SurfaceId,
    /// The stamp of the pane's active tab after that close.
    at: u64,
    /// Each tab that a close made the active tab of the pane while the
    /// creation had no tab: the pane keeps its active tab on a tab that it
    /// has. More than one: a later close of such a tab gives the active tab
    /// to the next one, and a close plan that is refused leaves it where it
    /// was.
    stand_ins: Vec<SurfaceId>,
}

impl Awaited {
    /// The active tab of the pane is still where a close left it: no request
    /// wrote a new stamp, and the active tab is one of the stand-ins.
    fn holds(&self, now: ActiveNow) -> bool {
        self.at == now.at && now.tab.is_some_and(|tab| self.stand_ins.contains(&tab))
    }
}

/// The record of the active tab of one pane that has a creation.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct ActiveTab {
    /// The number of the creation that last took the active tab by its own
    /// request.
    last: u64,
    awaited: Option<Awaited>,
}

/// The tab creations that have a `place` or a `transaction`, and the list of
/// each pane that has one.
#[derive(Clone, Debug, Default)]
pub(crate) struct PlaceLists {
    /// The number of the last creation.
    last: u64,
    /// The creations, the oldest first.
    creations: VecDeque<Creation>,
    /// The list of each pane that has a creation of the record.
    lists: HashMap<PaneId, Vec<Entry>>,
    /// The record of the active tab of each pane that has a creation of the
    /// record.
    active: HashMap<PaneId, ActiveTab>,
}

impl PlaceLists {
    /// A create request for `pane` arrived: its creation takes its slot among
    /// `tabs` (the pane's tabs now, with the id of each tab group run in
    /// `groups`). Gives the number of the creation.
    pub(crate) fn admit(
        &mut self,
        pane: PaneId,
        tabs: &[Slot],
        groups: &[String],
        asked: Asked<'_>,
    ) -> u64 {
        self.repair(pane, tabs);
        self.last = self.last.saturating_add(1);
        let number = self.last;
        let slots = self.slots(pane, tabs, groups);
        let joins = asked.place.is_some_and(|place| place.joins);
        let settled = settle(&slots, self.wanted(pane, &asked), joins);
        let list = self.lists.entry(pane).or_default();
        list.insert(settled.index.min(list.len()), Entry::Hole(number));
        self.creations.push_back(Creation {
            number,
            client: asked.client,
            transaction: asked.transaction.map(Arc::from),
            pane,
            tab: None,
            group: settled.joined.and_then(|run| groups.get(run).cloned()),
            pending: true,
        });
        self.prune();
        number
    }

    /// The creation `hole` made `tab`: gives the index among the tabs of
    /// `strip` (the pane now) that the tab takes and the run that it joins,
    /// and if the tab takes the active tab of the pane
    /// ([`PlaceLists::takes_active`]). A creation that the list does not
    /// know takes its slot now, as the last creation.
    pub(crate) fn commit(
        &mut self,
        pane: PaneId,
        strip: StripNow<'_>,
        hole: Option<u64>,
        asked: Asked<'_>,
        tab: SurfaceId,
    ) -> (Settled, bool) {
        let StripNow { tabs, groups, active: now } = strip;
        let known = hole.filter(|number| {
            self.creations.iter().any(|creation| {
                creation.number == *number
                    && creation.pane == pane
                    && creation.client == asked.client
                    && creation.pending
            })
        });
        let number = known.unwrap_or_else(|| self.admit(pane, tabs, groups, asked));
        self.repair(pane, tabs);
        let group = self.creation(number).and_then(|creation| creation.group.as_deref());
        let joined = group.and_then(|group| groups.iter().position(|id| id == group));
        let list = self.lists.entry(pane).or_default();
        let at = list.iter().position(|entry| *entry == Entry::Hole(number));
        // After the repair the tabs of the list are `tabs`, in their order.
        let is_tab = |entry: &&Entry| matches!(entry, Entry::Tab(_));
        let slot = at.map_or(tabs.len(), |at| list.iter().take(at).filter(is_tab).count());
        let before = asked.place.is_some_and(|place| matches!(place.anchor, Anchor::Before(_)));
        let index =
            if joined.is_some() { slot.min(tabs.len()) } else { outside_runs(tabs, slot, before) };
        match at {
            Some(at) if index == slot => {
                if let Some(entry) = list.get_mut(at) {
                    *entry = Entry::Tab(tab);
                }
            }
            _ => {
                list.retain(|entry| *entry != Entry::Hole(number));
                let tabs_of_list = list.iter().enumerate().filter(|(_, entry)| is_tab(entry));
                let at = tabs_of_list.map(|(at, _)| at).nth(index).unwrap_or(list.len());
                list.insert(at, Entry::Tab(tab));
            }
        }
        // Before the creation leaves the record: a pane with no creation
        // has no record of its active tab.
        let open = |tab: SurfaceId| tabs.iter().any(|slot| slot.tab == Some(tab));
        let active = self.takes_active(pane, number, asked.activate, open, now);
        if let Some(position) = self.creations.iter().position(|creation| creation.number == number)
        {
            self.finish(position, Some(tab));
        }
        self.prune();
        (Settled { index, joined }, active)
    }

    /// The tab of the creation `number` goes into `pane`; `asks` says if it
    /// asks for the active tab of the pane, `open` says if a tab is in the
    /// pane now, and `now` is the active tab of the pane. Gives if the tab
    /// takes the active tab.
    ///
    /// A tab that asks gets the active tab if no creation with a later number
    /// took it: the requests applied one by one in the order of their arrival
    /// leave the tab of the last of them active. A tab whose slot a close of
    /// the active tab picked ([`PlaceLists::tab_closes`]) gets it with no
    /// such condition: one by one, that close made it the active tab. It
    /// gets it only while the active tab of the pane is where a close left
    /// it ([`Awaited::holds`]): one by one, a request that changed the
    /// active tab after the close is the later change.
    pub(crate) fn takes_active(
        &mut self,
        pane: PaneId,
        number: u64,
        asks: bool,
        open: impl Fn(SurfaceId) -> bool,
        now: ActiveNow,
    ) -> bool {
        let record = self.active.entry(pane).or_default();
        // The tab that the close took away is in the pane: that close did
        // not happen (a close plan that was refused). Or a request changed
        // the active tab after the close.
        if record
            .awaited
            .as_ref()
            .is_some_and(|awaited| open(awaited.closed) || !awaited.holds(now))
        {
            record.awaited = None;
        }
        if record.awaited.as_ref().is_some_and(|awaited| awaited.number == number) {
            record.awaited = None;
            if asks {
                record.last = record.last.max(number);
            }
            return true;
        }
        if !asks || record.last > number {
            return false;
        }
        *record = ActiveTab { last: number, awaited: None };
        true
    }

    /// `closed`, a tab of `pane`, closes: `tabs` are the pane's tabs before
    /// the close, `was_active` says if `closed` was the active tab, and
    /// `then` is the active tab of the pane after the close.
    ///
    /// The pane gives its active tab to a tab that it has. One by one, the
    /// close gives it to the next entry of the strip, or to the entry before
    /// when no next one is there, and that entry can be the slot of a
    /// creation whose tab is not there yet. The record then keeps that
    /// creation, and its tab takes the active tab when it comes
    /// ([`PlaceLists::takes_active`]). The record keeps the creation while
    /// it has no tab and each close is a close of the tab that a close made
    /// active: one by one, such a close is not a close of the active tab.
    ///
    /// The caller can be a close plan on a copy of the session state, which
    /// can be refused after this call. So this call stores no list of the
    /// pane, the record keeps `closed` and drops the creation when `closed`
    /// is seen in the pane after that, and the record keeps each tab that a
    /// close made active, not only the last one.
    ///
    /// The cost: a pane with no creation of the record, and a close of a
    /// tab that is not the active tab while no creation is kept, return
    /// before a read of the creations.
    pub(crate) fn tab_closes(
        &mut self,
        pane: PaneId,
        tabs: &[SurfaceId],
        closed: SurfaceId,
        was_active: bool,
        then: ActiveNow,
    ) {
        if !self.lists.contains_key(&pane) {
            return;
        }
        let old = self.active.get(&pane).cloned().unwrap_or_default();
        if old.awaited.is_none() && !was_active {
            return;
        }
        let waits: HashSet<u64> = self
            .creations
            .iter()
            .filter(|creation| creation.pane == pane && creation.pending)
            .map(|creation| creation.number)
            .collect();
        // The creation that an earlier close picked still has no tab, that
        // close happened, and `closed` is a tab that a close made active
        // with no request after it.
        let before_close = ActiveNow { tab: Some(closed), at: then.at };
        let kept = old.awaited.as_ref().filter(|awaited| {
            waits.contains(&awaited.number)
                && !tabs.contains(&awaited.closed)
                && awaited.holds(before_close)
        });
        let awaited = if !was_active {
            // An earlier close of this tab did not happen, and this one
            // gives the active tab to no tab.
            old.awaited.as_ref().filter(|awaited| awaited.closed != closed).cloned()
        } else if let Some(kept) = kept {
            let mut kept = kept.clone();
            kept.stand_ins.extend(then.tab);
            Some(kept)
        } else if waits.is_empty() {
            None
        } else {
            let slots: Vec<Slot> = tabs
                .iter()
                .map(|tab| Slot { tab: Some(*tab), pinned: false, group: None })
                .collect();
            let list = self.repaired(pane, &slots);
            let waits_or_tab = |entry: &&Entry| match entry {
                Entry::Tab(_) => true,
                Entry::Hole(number) => waits.contains(number),
            };
            let before: Vec<Entry> = list.iter().filter(waits_or_tab).copied().collect();
            let closed_entry = Entry::Tab(closed);
            let after: Vec<Entry> =
                before.iter().filter(|entry| **entry != closed_entry).copied().collect();
            let shown: HashSet<Entry> = after.iter().copied().collect();
            // The rule of the pane's own close, with no relations: the
            // nearest entry after the closed tab, else the nearest before.
            let relations = close_focus::TabRelations::<Entry>::default();
            match close_focus::tab(Some(&closed_entry), &before, &after, &shown, &relations) {
                Some(Entry::Hole(number)) => Some(Awaited {
                    number,
                    closed,
                    at: then.at,
                    stand_ins: then.tab.into_iter().collect(),
                }),
                _ => None,
            }
        };
        if awaited != old.awaited {
            self.active.insert(pane, ActiveTab { awaited, ..old });
        }
    }

    /// The creation `number` ended with no commit: with `tab` it names that
    /// tab from now on (a create that gave a tab which was there already, or
    /// a tab that took the slot of its kind); with none it made no tab, and
    /// a creation with a name keeps its slot for the requests that name it,
    /// and a close that picked its slot gives the active tab to no later
    /// tab. Nothing for a creation that has ended.
    pub(crate) fn end(&mut self, number: u64, tab: Option<SurfaceId>) {
        let pending = |creation: &Creation| creation.number == number && creation.pending;
        if let Some(position) = self.creations.iter().position(pending) {
            if tab.is_none() {
                let pane = self.creations.get(position).map(|creation| creation.pane);
                let record = pane.and_then(|pane| self.active.get_mut(&pane));
                if let Some(record) = record
                    && record.awaited.as_ref().is_some_and(|awaited| awaited.number == number)
                {
                    record.awaited = None;
                }
            }
            self.finish(position, tab);
            self.prune();
        }
    }

    /// The connection `client` closed: no later request names its creations.
    /// A creation that has not ended keeps its slot, with no name.
    pub(crate) fn forget_client(&mut self, client: u64) {
        self.creations.retain_mut(|creation| {
            if creation.client != client {
                return true;
            }
            creation.transaction = None;
            creation.pending
        });
        self.prune();
    }

    fn creation(&self, number: u64) -> Option<&Creation> {
        self.creations.iter().find(|creation| creation.number == number)
    }

    /// The creation at `position` of the record ended with `tab`.
    fn finish(&mut self, position: usize, tab: Option<SurfaceId>) {
        if !self.creations.get(position).is_some_and(Creation::is_named) {
            drop(self.creations.remove(position));
            return;
        }
        if let Some(creation) = self.creations.get_mut(position) {
            creation.tab = tab;
            creation.group = None;
            creation.pending = false;
        }
    }

    /// The list of `pane` gets the pane's tabs of now, in their order
    /// ([`PlaceLists::repaired`]).
    fn repair(&mut self, pane: PaneId, tabs: &[Slot]) {
        let list = self.repaired(pane, tabs);
        self.lists.insert(pane, list);
    }

    /// The list of `pane` with the pane's tabs of now, in their order. A hole
    /// stays right of the nearest tab on its left that is still in the pane.
    /// A tab that left the pane leaves a hole if a creation of the record
    /// made it, and no entry if not.
    fn repaired(&self, pane: PaneId, tabs: &[Slot]) -> Vec<Entry> {
        let open: HashSet<SurfaceId> = tabs.iter().filter_map(|slot| slot.tab).collect();
        let old = self.lists.get(&pane).map(Vec::as_slice).unwrap_or_default();
        let mut list = Vec::with_capacity(old.len().max(tabs.len()));
        let mut holes_after: HashMap<SurfaceId, Vec<Entry>> = HashMap::new();
        let mut left = None;
        for entry in old.iter().copied() {
            let hole = match entry {
                Entry::Tab(tab) if open.contains(&tab) => {
                    left = Some(tab);
                    continue;
                }
                Entry::Tab(tab) => {
                    let made =
                        |creation: &&Creation| creation.pane == pane && creation.tab == Some(tab);
                    self.creations.iter().rev().find(made).map(|creation| creation.number)
                }
                Entry::Hole(number) => self
                    .creation(number)
                    .filter(|creation| creation.pane == pane)
                    .filter(|creation| creation.tab.is_none_or(|tab| !open.contains(&tab)))
                    .map(|creation| creation.number),
            };
            let Some(hole) = hole else { continue };
            match left {
                Some(tab) => holes_after.entry(tab).or_default().push(Entry::Hole(hole)),
                None => list.push(Entry::Hole(hole)),
            }
        }
        for tab in tabs.iter().filter_map(|slot| slot.tab) {
            list.push(Entry::Tab(tab));
            list.extend(holes_after.remove(&tab).unwrap_or_default());
        }
        list
    }

    /// The list of `pane` as the place rules see it: each tab as in `tabs`,
    /// and each hole in the run that its tab joins.
    fn slots(&self, pane: PaneId, tabs: &[Slot], groups: &[String]) -> Vec<Slot> {
        let of_tab: HashMap<SurfaceId, &Slot> =
            tabs.iter().filter_map(|slot| Some((slot.tab?, slot))).collect();
        let list = self.lists.get(&pane).map(Vec::as_slice).unwrap_or_default();
        list.iter()
            .map(|entry| match *entry {
                Entry::Tab(tab) => of_tab
                    .get(&tab)
                    .map_or(Slot { tab: Some(tab), pinned: false, group: None }, |slot| **slot),
                Entry::Hole(number) => {
                    let group =
                        self.creation(number).and_then(|creation| creation.group.as_deref());
                    let run = group.and_then(|group| groups.iter().position(|id| id == group));
                    Slot { tab: None, pinned: false, group: run }
                }
            })
            .collect()
    }

    /// The entry of the list of `pane` that `asked` names. A tab that is not
    /// in the pane, and a creation that the record does not have for this
    /// connection and this pane, give the end.
    fn wanted(&self, pane: PaneId, asked: &Asked<'_>) -> Wanted {
        let Some(place) = asked.place else { return Wanted::End };
        let list = self.lists.get(&pane).map(Vec::as_slice).unwrap_or_default();
        let at = |entry: Entry| list.iter().position(|listed| *listed == entry);
        match &place.anchor {
            Anchor::Start => Wanted::Start,
            Anchor::After(tab) => at(Entry::Tab(*tab)).map_or(Wanted::End, Wanted::After),
            Anchor::Before(tab) => at(Entry::Tab(*tab)).map_or(Wanted::End, Wanted::Before),
            Anchor::AfterCreation(name) => {
                let named = |creation: &&Creation| {
                    creation.client == asked.client
                        && creation.pane == pane
                        && creation.transaction.as_deref() == Some(name.as_str())
                };
                // The newest creation with the name: a connection can use a name again.
                let creation = self.creations.iter().rev().find(named);
                let entry = creation.and_then(|creation| {
                    let tab = creation.tab.and_then(|tab| at(Entry::Tab(tab)));
                    tab.or_else(|| at(Entry::Hole(creation.number)))
                });
                entry.map_or(Wanted::End, Wanted::After)
            }
        }
    }

    /// Keeps the record in its bound: the oldest creation with a name that
    /// has ended leaves first. A pane with no creation has no list, and no
    /// record of its active tab: each later creation has a later number.
    fn prune(&mut self) {
        let mut named = self.creations.iter().filter(|creation| creation.is_named()).count();
        while named > KEPT {
            let ended = |creation: &Creation| creation.is_named() && !creation.pending;
            let Some(oldest) = self.creations.iter().position(ended) else { break };
            drop(self.creations.remove(oldest));
            named = named.saturating_sub(1);
        }
        let panes: HashSet<PaneId> = self.creations.iter().map(|creation| creation.pane).collect();
        self.lists.retain(|pane, _| panes.contains(pane));
        self.active.retain(|pane, _| panes.contains(pane));
    }
}

/// `slot` of `tabs`, moved out of the pinned tabs and out of a tab group run
/// that it would split: to the start of the run for a tab put `before` its
/// anchor, to the end of the run if not.
fn outside_runs(tabs: &[Slot], slot: usize, before: bool) -> usize {
    let floor = tabs.iter().rposition(|slot| slot.pinned).map_or(0, |last| last.saturating_add(1));
    let index = slot.clamp(floor, tabs.len());
    let run_of = |at: Option<usize>| at.and_then(|at| tabs.get(at)).and_then(|slot| slot.group);
    let Some(run) = run_of(index.checked_sub(1)).filter(|run| run_of(Some(index)) == Some(*run))
    else {
        return index;
    };
    let in_run = |slot: &Slot| slot.group == Some(run);
    if before {
        tabs.iter().position(in_run).unwrap_or(index).max(floor)
    } else {
        tabs.iter().rposition(in_run).map_or(index, |last| last.saturating_add(1))
    }
}

#[cfg(test)]
#[path = "tab_create_place_model_tests.rs"]
mod tab_create_place_model_tests;
