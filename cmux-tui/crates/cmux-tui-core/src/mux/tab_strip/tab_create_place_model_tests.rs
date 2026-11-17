//! [`PlaceLists`] against the rule that it keeps: for each order of the
//! commits, the tabs of a pane are those of the same requests applied one by
//! one in the order of their arrival.
//!
//! The requests are new tabs with a terminal (the tab comes when the launch
//! ends), new tabs with a page (the tab comes with the request), each at one
//! of the 4 places, and closes. The test keeps the one-by-one list itself
//! ([`OneByOne`]), with no code of the daemon. Its lists have no tab group
//! and no pinned tab: the tests of the requests fix those two rules.
//!
//! The active tab has the same rule: a new tab that asks for it takes it, and
//! a close of the active tab gives it to the next tab, or to the tab before
//! when no next tab is there. The test keeps the active tab of the pane as
//! the daemon does (a tab that the pane has) and compares it when each
//! launch has ended.

use std::collections::HashMap;

use proptest::prelude::*;
use proptest::test_runner::{RngAlgorithm, RngSeed};

use super::super::tab_place::{Anchor, Slot, TabPlace};
use super::{Asked, PlaceLists};
use crate::{PaneId, SurfaceId};

const PANE: PaneId = 7;
const CLIENT: u64 = 3;

/// The tabs of the pane before the first request.
const FIRST: [SurfaceId; 3] = [1, 2, 3];

/// The tab of request `n` (from 0) is `NEW + n`.
const NEW: SurfaceId = 100;

/// One request of the connection.
#[derive(Clone, Debug)]
enum Request {
    /// A new tab. The tab of a page comes with the request; the tab of a
    /// terminal comes when the schedule of the test ends its launch. With
    /// `asks` the tab asks for the active tab.
    Create { tab: SurfaceId, page: bool, name: Option<String>, anchor: Anchor, asks: bool },
    /// The tab closes.
    Close { tab: SurfaceId },
    /// A close of the tab that is refused after its plan: the list gets the
    /// call of a close, and the tab stays.
    Refused { tab: SurfaceId },
}

impl Request {
    /// The tab that the request names by its id. A client has that id only
    /// after the creation of the tab gave it.
    fn names(&self) -> Option<SurfaceId> {
        match self {
            Self::Create { anchor: Anchor::After(tab) | Anchor::Before(tab), .. }
            | Self::Close { tab }
            | Self::Refused { tab } => Some(*tab),
            Self::Create { .. } => None,
        }
    }
}

fn terminal(tab: SurfaceId, name: Option<&str>, anchor: Anchor) -> Request {
    Request::Create { tab, page: false, name: name.map(str::to_string), anchor, asks: true }
}

fn page(tab: SurfaceId, name: Option<&str>, anchor: Anchor) -> Request {
    Request::Create { tab, page: true, name: name.map(str::to_string), anchor, asks: true }
}

/// The open tab of `entries` (each with its tab and if it is open) that gets
/// the active tab when the tab at `at` closes: the nearest open tab after
/// it, else the nearest before it.
fn next_active(entries: &[(SurfaceId, bool)], at: usize) -> Option<SurfaceId> {
    let open_tab = |(tab, open): &(SurfaceId, bool)| open.then_some(*tab);
    let after = entries.iter().skip(at.saturating_add(1)).find_map(open_tab);
    after.or_else(|| entries.iter().take(at).rev().find_map(open_tab))
}

/// The requests applied one by one: each tab that was in the strip, in strip
/// order, and if it is still open; and the active tab. A closed tab keeps
/// its entry, so a request that names its creation gets the place where the
/// tab was.
#[derive(Debug)]
struct OneByOne {
    entries: Vec<(SurfaceId, bool)>,
    made: HashMap<String, SurfaceId>,
    active: SurfaceId,
}

impl OneByOne {
    fn new() -> Self {
        Self {
            entries: FIRST.map(|tab| (tab, true)).to_vec(),
            made: HashMap::new(),
            active: FIRST[0],
        }
    }

    /// The active tab after `requests`.
    fn active_of(requests: &[Request]) -> SurfaceId {
        let mut list = Self::new();
        for request in requests {
            list.apply(request);
        }
        list.active
    }

    fn of(requests: &[Request]) -> Vec<SurfaceId> {
        let mut list = Self::new();
        for request in requests {
            list.apply(request);
        }
        list.tabs()
    }

    fn tabs(&self) -> Vec<SurfaceId> {
        self.entries.iter().filter(|(_, open)| *open).map(|(tab, _)| *tab).collect()
    }

    fn entry(&self, tab: SurfaceId) -> Option<usize> {
        self.entries.iter().position(|(entry, _)| *entry == tab)
    }

    fn apply(&mut self, request: &Request) {
        match request {
            Request::Create { tab, name, anchor, asks, .. } => {
                if *asks {
                    self.active = *tab;
                }
                let index = match anchor {
                    Anchor::After(anchor) => self.entry(*anchor).map(|index| index + 1),
                    Anchor::AfterCreation(creation) => {
                        let made = self.made.get(creation).copied();
                        made.and_then(|made| self.entry(made)).map(|index| index + 1)
                    }
                    Anchor::Before(anchor) => self.entry(*anchor),
                    Anchor::Start => Some(0),
                };
                self.entries.insert(index.unwrap_or(self.entries.len()), (*tab, true));
                if let Some(name) = name {
                    self.made.insert(name.clone(), *tab);
                }
            }
            Request::Close { tab } => {
                if let Some(index) = self.entry(*tab) {
                    self.entries[index].1 = false;
                    if self.active == *tab {
                        self.active = next_active(&self.entries, index).unwrap_or(*tab);
                    }
                }
            }
            Request::Refused { .. } => {}
        }
    }
}

fn slots(tabs: &[SurfaceId]) -> Vec<Slot> {
    tabs.iter().map(|tab| Slot { tab: Some(*tab), pinned: false, group: None }).collect()
}

/// `request`, a new tab, arrives: its creation takes its slot in the list
/// under test. Gives the number of the creation.
fn admit(places: &mut PlaceLists, real: &[SurfaceId], request: &Request) -> u64 {
    let Request::Create { name, anchor, asks, .. } = request else {
        panic!("{request:?} makes no tab");
    };
    let place = TabPlace { anchor: anchor.clone(), joins: false };
    let asked = Asked {
        client: CLIENT,
        transaction: name.as_deref(),
        place: Some(&place),
        activate: *asks,
    };
    places.admit(PANE, &slots(real), &[], asked)
}

/// The creation `number` of `request` made its tab: the tab goes into `real`
/// where the list under test says. Gives if the tab takes the active tab.
fn commit(
    places: &mut PlaceLists,
    real: &mut Vec<SurfaceId>,
    number: u64,
    request: &Request,
) -> bool {
    let Request::Create { tab, name, anchor, asks, .. } = request else {
        panic!("{request:?} makes no tab");
    };
    let place = TabPlace { anchor: anchor.clone(), joins: false };
    let asked = Asked {
        client: CLIENT,
        transaction: name.as_deref(),
        place: Some(&place),
        activate: *asks,
    };
    let (settled, active) = places.commit(PANE, &slots(real), &[], Some(number), asked, *tab);
    assert!(settled.index <= real.len(), "{settled:?} is not a slot of {real:?}");
    real.insert(settled.index, *tab);
    active
}

/// The pane as the daemon keeps it while the list under test takes the
/// requests: its tabs, and its active tab.
struct Pane {
    places: PlaceLists,
    tabs: Vec<SurfaceId>,
    active: Option<SurfaceId>,
    /// The pane had no tab at one time. The daemon removes such a pane, so
    /// the active tab of such a case is not compared.
    was_empty: bool,
}

impl Pane {
    fn new() -> Self {
        Self {
            places: PlaceLists::default(),
            tabs: FIRST.to_vec(),
            active: Some(FIRST[0]),
            was_empty: false,
        }
    }

    /// The creation `number` of `request` made its tab.
    fn commit(&mut self, number: u64, request: &Request) {
        let Request::Create { tab, .. } = request else { return };
        let takes = commit(&mut self.places, &mut self.tabs, number, request);
        // A pane with no tab has no active tab to keep: the new tab is it.
        if takes || self.active.is_none() {
            self.active = Some(*tab);
        }
    }

    /// The list gets the call of the close of `tab`, as the close path of
    /// the daemon gives it: only when the pane keeps a tab.
    fn tell_close(&mut self, tab: SurfaceId) {
        if self.tabs.len() > 1 && self.tabs.contains(&tab) {
            self.places.tab_closes(PANE, &self.tabs, tab, self.active == Some(tab));
        }
    }

    /// `tab` closes. The pane gives the active tab to a tab that it has.
    fn close(&mut self, tab: SurfaceId) {
        let Some(index) = self.tabs.iter().position(|open| *open == tab) else { return };
        self.tell_close(tab);
        self.tabs.remove(index);
        if self.active == Some(tab) {
            let next = self.tabs.get(index).or_else(|| self.tabs.last());
            self.active = next.copied();
        }
        self.was_empty |= self.tabs.is_empty();
    }
}

/// The tabs of the pane after `requests`, when the list under test takes
/// each request at its arrival and the launches end as `next` says; and the
/// active tab of the pane, or none for a pane that had no tab at one time.
///
/// Before the arrival of request `step`, `next(step, waiting)` gives the
/// launch that ends then: its place among the `waiting` launches, in the
/// order of their requests; or none. After the last request (`step` is the
/// count of the requests) `next` is asked until no launch is left; none is
/// then the first launch.
fn daemon_with_active(
    requests: &[Request],
    mut next: impl FnMut(usize, usize) -> Option<usize>,
) -> (Vec<SurfaceId>, Option<SurfaceId>) {
    let mut pane = Pane::new();
    // Each creation whose terminal still launches: its number and its request.
    let mut waiting: Vec<(u64, usize)> = Vec::new();
    for (step, request) in requests.iter().enumerate() {
        if let Some(pick) = next(step, waiting.len()).filter(|pick| *pick < waiting.len()) {
            let (number, launched) = waiting.remove(pick);
            pane.commit(number, &requests[launched]);
        }
        // The request names a tab by its id: the launch of that tab ended.
        let named = request.names().and_then(|named| {
            waiting.iter().position(|(_, launching)| {
                matches!(&requests[*launching], Request::Create { tab, .. } if *tab == named)
            })
        });
        if let Some(pick) = named {
            let (number, launched) = waiting.remove(pick);
            pane.commit(number, &requests[launched]);
        }
        match request {
            Request::Create { page, .. } => {
                let number = admit(&mut pane.places, &pane.tabs, request);
                if *page {
                    pane.commit(number, request);
                } else {
                    waiting.push((number, step));
                }
            }
            Request::Close { tab } => pane.close(*tab),
            Request::Refused { tab } => pane.tell_close(*tab),
        }
    }
    while !waiting.is_empty() {
        let pick = next(requests.len(), waiting.len()).filter(|pick| *pick < waiting.len());
        let (number, launched) = waiting.remove(pick.unwrap_or(0));
        pane.commit(number, &requests[launched]);
    }
    let active = pane.active.filter(|_| !pane.was_empty);
    (pane.tabs, active)
}

/// The tabs of [`daemon_with_active`].
fn daemon(requests: &[Request], next: impl FnMut(usize, usize) -> Option<usize>) -> Vec<SurfaceId> {
    daemon_with_active(requests, next).0
}

/// Each launch ends after the last request, in request order.
fn launches_end_last(_step: usize, _waiting: usize) -> Option<usize> {
    None
}

/// A terminal tab after `1` still launches. A page takes the slot after `1`,
/// and a second page the slot after the first page: the second page names a
/// tab, so it stays next to it, before the terminal's tab.
#[test]
fn a_page_after_a_page_stays_before_the_tab_that_still_launches() {
    let requests = [
        terminal(100, None, Anchor::After(1)),
        page(101, None, Anchor::After(1)),
        page(102, None, Anchor::After(101)),
    ];
    assert_eq!(OneByOne::of(&requests), [1, 101, 102, 100, 2, 3]);
    assert_eq!(daemon(&requests, launches_end_last), [1, 101, 102, 100, 2, 3]);
}

/// A terminal tab after `1` still launches. A page names that creation and a
/// second page names `1`: the first page stays after the terminal's tab and
/// the second page goes before it.
#[test]
fn a_page_after_a_creation_stays_after_the_tab_that_still_launches() {
    let requests = [
        terminal(100, Some("t1"), Anchor::After(1)),
        page(101, None, Anchor::AfterCreation("t1".to_string())),
        page(102, None, Anchor::After(1)),
    ];
    assert_eq!(OneByOne::of(&requests), [1, 102, 100, 101, 2, 3]);
    assert_eq!(daemon(&requests, launches_end_last), [1, 102, 100, 101, 2, 3]);
}

/// The tab that a terminal tab names closes while the terminal launches:
/// the new tab lands where the closed tab was.
#[test]
fn a_tab_whose_anchor_closed_while_it_launched_lands_where_the_anchor_was() {
    let requests = [terminal(100, None, Anchor::After(2)), Request::Close { tab: 2 }];
    assert_eq!(OneByOne::of(&requests), [1, 100, 3]);
    assert_eq!(daemon(&requests, launches_end_last), [1, 100, 3]);
}

/// A terminal tab after `1` still launches when a page comes: the page is
/// the active tab. The terminal's tab comes later and does not take the
/// active tab, as when the two requests are applied one by one. The tab of
/// a request that arrives after that takes it.
#[test]
fn a_tab_that_launched_late_does_not_take_the_active_tab_of_a_later_page() {
    let requests = [
        terminal(100, None, Anchor::After(1)),
        page(101, None, Anchor::After(1)),
        terminal(102, None, Anchor::After(1)),
    ];
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &requests[0]);
    let second = admit(&mut places, &real, &requests[1]);
    assert!(commit(&mut places, &mut real, second, &requests[1]), "the page: the last request");
    assert!(
        !commit(&mut places, &mut real, first, &requests[0]),
        "the terminal's tab took the active tab of the page"
    );
    let third = admit(&mut places, &real, &requests[2]);
    assert!(commit(&mut places, &mut real, third, &requests[2]), "the last request");
    assert_eq!(real, OneByOne::of(&requests));
}

/// A page that stays in the background (it does not ask for the active tab)
/// does not keep the active tab from the terminal's tab that comes after it.
#[test]
fn a_page_in_the_background_leaves_the_active_tab_to_a_tab_that_launched_late() {
    let mut places = PlaceLists::default();
    let real = FIRST.to_vec();
    let place = TabPlace { anchor: Anchor::After(1), joins: false };
    let asked = Asked { client: CLIENT, transaction: None, place: Some(&place), activate: true };
    let background = Asked { activate: false, ..asked };
    let first = places.admit(PANE, &slots(&real), &[], asked);
    let second = places.admit(PANE, &slots(&real), &[], background);
    let (_, active) = places.commit(PANE, &slots(&real), &[], Some(second), background, 101);
    assert!(!active, "a tab that did not ask took the active tab");
    let (_, active) = places.commit(PANE, &slots(&[1, 101, 2, 3]), &[], Some(first), asked, 100);
    assert!(active, "the terminal's tab did not take the active tab");
}

/// A page takes the active tab from a terminal tab that still launches, and
/// closes before that tab comes. `after_the_terminal` says where the page
/// is: after the slot of the terminal's tab (the page is the last tab), or
/// before it. Gives the list, the pane's tabs after the close, and the
/// number of the terminal's creation with its request.
fn a_page_closed_while_a_tab_launches(
    after_the_terminal: bool,
) -> (PlaceLists, Vec<SurfaceId>, u64, Request) {
    let late = terminal(100, Some("t1"), Anchor::After(3));
    let anchor =
        if after_the_terminal { Anchor::AfterCreation("t1".to_string()) } else { Anchor::After(3) };
    let later = page(101, None, anchor);
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &late);
    let second = admit(&mut places, &real, &later);
    assert!(commit(&mut places, &mut real, second, &later), "the page: the last request");
    assert_eq!(real, [1, 2, 3, 101]);
    places.tab_closes(PANE, &real, 101, true);
    real.retain(|tab| *tab != 101);
    (places, real, first, late)
}

/// The page was the last tab, after the slot of the terminal's tab. One by
/// one, its close gives the active tab to the tab before it, the terminal's
/// tab: that tab takes the active tab when it comes.
#[test]
fn a_tab_that_launched_late_takes_the_active_tab_after_the_later_tab_closed() {
    let (mut places, mut real, first, late) = a_page_closed_while_a_tab_launches(true);
    assert!(commit(&mut places, &mut real, first, &late), "the terminal's tab is the active tab");
    assert_eq!(real, [1, 2, 3, 100]);
}

/// The page was before the slot of the terminal's tab. One by one, its close
/// gives the active tab to the next tab, the terminal's tab.
#[test]
fn a_tab_that_launched_late_takes_the_active_tab_after_the_tab_before_it_closed() {
    let (mut places, mut real, first, late) = a_page_closed_while_a_tab_launches(false);
    assert!(commit(&mut places, &mut real, first, &late), "the terminal's tab is the active tab");
    assert_eq!(real, [1, 2, 3, 100]);
}

/// A close of the active tab is planned and then refused: the list got the
/// call of the close, and the page stays. The terminal's tab does not take
/// the active tab of the page when it comes.
#[test]
fn a_refused_close_gives_no_active_tab_to_a_tab_that_launched_late() {
    let late = terminal(100, Some("t1"), Anchor::After(3));
    let later = page(101, None, Anchor::AfterCreation("t1".to_string()));
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &late);
    let second = admit(&mut places, &real, &later);
    assert!(commit(&mut places, &mut real, second, &later), "the page: the last request");
    places.tab_closes(PANE, &real, 101, true);
    assert!(
        !commit(&mut places, &mut real, first, &late),
        "the terminal's tab took the active tab of a page that did not close"
    );
    assert_eq!(real, [1, 2, 3, 100, 101]);
}

/// The limit of the record, kept here so that a change of it shows. A close
/// of the active tab is planned and then refused, and then that tab leaves
/// the pane with no close (a move to another pane). The list does not see a
/// move: it reads a tab that is not in the pane as closed. So the terminal's
/// tab takes the active tab when it comes, whichever tab the move left
/// active.
#[test]
fn limit_a_refused_close_and_then_a_move_of_that_tab_reads_as_its_close() {
    let late = terminal(100, Some("t1"), Anchor::After(3));
    let later = page(101, None, Anchor::AfterCreation("t1".to_string()));
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &late);
    let second = admit(&mut places, &real, &later);
    assert!(commit(&mut places, &mut real, second, &later), "the page: the last request");
    places.tab_closes(PANE, &real, 101, true);
    // The move: the tab leaves the pane, and the list gets no call.
    real.retain(|tab| *tab != 101);
    assert!(commit(&mut places, &mut real, first, &late), "this is the limit");
}

/// A tab that does not ask for the active tab can get it from a close: its
/// slot is next to the tab that closed. That is not a request of its own, so
/// it does not keep the active tab from the tab of an earlier request that
/// asks and comes after it. A guard: in one form of the rule the record kept
/// the number of each tab that took the active tab, and this row was wrong.
#[test]
fn a_tab_that_only_a_close_made_active_leaves_the_turn_of_an_earlier_tab_that_asks() {
    let asks = terminal(100, None, Anchor::After(3));
    let quiet = Request::Create {
        tab: 101,
        page: false,
        name: None,
        anchor: Anchor::After(1),
        asks: false,
    };
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &asks);
    let second = admit(&mut places, &real, &quiet);
    // No new tab is there yet: the active tab of the pane is `1`.
    places.tab_closes(PANE, &real, 1, true);
    real.retain(|tab| *tab != 1);
    assert!(commit(&mut places, &mut real, second, &quiet), "the close picked its slot");
    assert!(commit(&mut places, &mut real, first, &asks), "no later request took the active tab");
    assert_eq!(real, [101, 2, 3, 100]);
}

/// A close of a pane with the tabs `1, 2, 3`, where `2` is the active tab,
/// is planned on a copy of the session state while a terminal tab after `1`
/// still launches. The list gets the call of each close of the plan; the
/// second call has the strip of the copy, which has no `1`. The plan is
/// refused and the pane keeps its tabs: the terminal's tab lands after `1`,
/// as with no close plan.
#[test]
fn a_refused_close_of_more_than_one_tab_keeps_the_slot_of_a_tab_that_still_launches() {
    let late = terminal(100, Some("t1"), Anchor::After(1));
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &late);
    // The plan closes its tabs in strip order. The close of the last tab of
    // a pane gives the list no call.
    places.tab_closes(PANE, &[1, 2, 3], 1, false);
    places.tab_closes(PANE, &[2, 3], 2, true);
    assert!(commit(&mut places, &mut real, first, &late), "the only request");
    assert_eq!(real, [1, 100, 2, 3]);
}

/// The page was the last tab, and its close gave the active tab of the pane
/// to `3`. Then `3` closes too, before the terminal's tab comes. One by one,
/// the terminal's tab was the active tab from the first close, so the close
/// of `3` is not a close of the active tab: the terminal's tab takes the
/// active tab when it comes.
#[test]
fn a_tab_that_launched_late_takes_the_active_tab_after_two_closes() {
    let (mut places, mut real, first, late) = a_page_closed_while_a_tab_launches(true);
    places.tab_closes(PANE, &real, 3, true);
    real.retain(|tab| *tab != 3);
    assert!(commit(&mut places, &mut real, first, &late), "the terminal's tab is the active tab");
    assert_eq!(real, [1, 2, 100]);
}

/// The limit of the record, kept here so that a change of it shows. Two
/// terminal tabs still launch, the second after the first, when a page
/// after the second is the active tab and closes: the close picks the slot
/// of the second terminal's tab. Then the launch of the second terminal
/// fails. One by one, a request that makes no tab leaves no entry, so the
/// close gives the active tab to the first terminal's tab. The record does
/// not pick again when a launch fails: the first terminal's tab does not
/// take the active tab when it comes, and the tab that the pane made active
/// at the close stays the active tab.
#[test]
fn limit_a_failed_launch_that_a_close_picked_gives_no_active_tab_to_the_tab_before_it() {
    let first_late = terminal(100, Some("t1"), Anchor::After(3));
    let second_late = terminal(101, Some("t2"), Anchor::AfterCreation("t1".to_string()));
    let later = page(102, None, Anchor::AfterCreation("t2".to_string()));
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    let first = admit(&mut places, &real, &first_late);
    let second = admit(&mut places, &real, &second_late);
    let third = admit(&mut places, &real, &later);
    assert!(commit(&mut places, &mut real, third, &later), "the page: the last request");
    places.tab_closes(PANE, &real, 102, true);
    real.retain(|tab| *tab != 102);
    places.end(second, None);
    assert!(!commit(&mut places, &mut real, first, &first_late), "this is the limit");
    assert_eq!(real, [1, 2, 3, 100]);
}

/// One step of a generated case: a request that names its tab or its
/// creation by a place among those that the strip has at that step.
#[derive(Clone, Debug)]
enum Step {
    Create { page: bool, named: bool, form: u8, anchor: prop::sample::Index, asks: bool },
    Close { tab: prop::sample::Index },
    Refused { tab: prop::sample::Index },
}

/// 4 creates for each close, and 1 refused close for each 2 closes. 4 of 5
/// new tabs ask for the active tab.
fn step() -> impl Strategy<Value = Step> {
    let create = (
        any::<bool>(),
        any::<bool>(),
        0..4u8,
        any::<prop::sample::Index>(),
        prop::bool::weighted(0.8),
    );
    prop_oneof![
        8 => create.prop_map(|(page, named, form, anchor, asks)| {
            Step::Create { page, named, form, anchor, asks }
        }),
        2 => any::<prop::sample::Index>().prop_map(|tab| Step::Close { tab }),
        1 => any::<prop::sample::Index>().prop_map(|tab| Step::Refused { tab }),
    ]
}

/// The requests of `steps`. A request names an open tab of the one-by-one
/// list, or a creation of an earlier request (its tab can be closed). The
/// last open tab does not close.
fn requests(steps: &[Step]) -> Vec<Request> {
    let mut list = OneByOne::new();
    let mut names: Vec<String> = Vec::new();
    let mut requests = Vec::new();
    for step in steps {
        let open = list.tabs();
        let number = requests.len();
        let request = match step {
            Step::Close { tab } if open.len() > 1 => {
                Request::Close { tab: open[tab.index(open.len())] }
            }
            Step::Close { .. } => continue,
            Step::Refused { tab } => Request::Refused { tab: open[tab.index(open.len())] },
            Step::Create { page, named, form, anchor, asks } => {
                let anchor = match *form {
                    0 => Anchor::After(open[anchor.index(open.len())]),
                    1 => Anchor::Before(open[anchor.index(open.len())]),
                    2 if !names.is_empty() => {
                        Anchor::AfterCreation(names[anchor.index(names.len())].clone())
                    }
                    _ => Anchor::Start,
                };
                let name = named.then(|| format!("t{number}"));
                names.extend(name.clone());
                let tab = NEW + number as u64;
                Request::Create { tab, page: *page, name, anchor, asks: *asks }
            }
        };
        list.apply(&request);
        requests.push(request);
    }
    requests
}

/// The most steps of one case.
const STEPS: usize = 24;

/// The configuration of the property test. The seed and the generator are
/// fixed here and a failed case writes no file. `PROPTEST_CASES` sets the
/// case count (default 256); a value that is 0 or is not a count panics
/// here, because a run with no case would pass. The `proptest!` macro
/// applies the `PROPTEST_` variables on top of this configuration:
/// `PROPTEST_RNG_SEED` gives other cases for one run. With no such variable,
/// each run with one count has the same cases.
fn property_config() -> ProptestConfig {
    let cases = std::env::var_os("PROPTEST_CASES").map(|text| {
        let count =
            text.to_str().and_then(|value| value.parse::<u32>().ok()).filter(|count| *count > 0);
        count.unwrap_or_else(|| panic!("PROPTEST_CASES must be a count above 0, not {text:?}"))
    });
    ProptestConfig {
        cases: cases.unwrap_or(256),
        rng_seed: RngSeed::Fixed(0x5EED_2026),
        rng_algorithm: RngAlgorithm::ChaCha,
        failure_persistence: None,
        ..ProptestConfig::default()
    }
}

proptest! {
    #![proptest_config(property_config())]

    /// `early` says for each request if a launch ends before it arrives, and
    /// which; `late` gives the order in which the other launches end after
    /// the last request. The active tab is compared when each launch has
    /// ended, for each case where the pane had a tab at each time.
    #[test]
    fn the_tabs_are_those_of_the_requests_one_by_one_for_each_order_of_the_commits(
        steps in prop::collection::vec(step(), 1..=STEPS),
        early in prop::collection::vec(any::<Option<prop::sample::Index>>(), STEPS),
        late in prop::collection::vec(any::<prop::sample::Index>(), STEPS),
    ) {
        let requests = requests(&steps);
        let mut late = late.iter();
        let (tabs, active) = daemon_with_active(&requests, |step, waiting| {
            let pick = if step < requests.len() { early[step] } else { late.next().copied() };
            pick.filter(|_| waiting > 0).map(|pick| pick.index(waiting))
        });
        prop_assert_eq!(tabs, OneByOne::of(&requests), "the requests: {:?}", requests);
        if let Some(active) = active {
            let one_by_one = OneByOne::active_of(&requests);
            prop_assert_eq!(active, one_by_one, "the active tab; the requests: {:?}", requests);
        }
    }
}
