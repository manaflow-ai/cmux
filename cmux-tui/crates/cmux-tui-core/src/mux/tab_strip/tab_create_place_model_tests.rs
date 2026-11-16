//! [`PlaceLists`] against the rule that it keeps: for each order of the
//! commits, the tabs of a pane are those of the same requests applied one by
//! one in the order of their arrival.
//!
//! The requests are new tabs with a terminal (the tab comes when the launch
//! ends), new tabs with a page (the tab comes with the request), each at one
//! of the 4 places, and closes. The test keeps the one-by-one list itself
//! ([`OneByOne`]), with no code of the daemon. Its lists have no tab group
//! and no pinned tab: the tests of the requests fix those two rules.

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
    /// terminal comes when the schedule of the test ends its launch.
    Create { tab: SurfaceId, page: bool, name: Option<String>, anchor: Anchor },
    /// The tab closes.
    Close { tab: SurfaceId },
}

impl Request {
    /// The tab that the request names by its id. A client has that id only
    /// after the creation of the tab gave it.
    fn names(&self) -> Option<SurfaceId> {
        match self {
            Self::Create { anchor: Anchor::After(tab) | Anchor::Before(tab), .. }
            | Self::Close { tab } => Some(*tab),
            Self::Create { .. } => None,
        }
    }
}

fn terminal(tab: SurfaceId, name: Option<&str>, anchor: Anchor) -> Request {
    Request::Create { tab, page: false, name: name.map(str::to_string), anchor }
}

fn page(tab: SurfaceId, name: Option<&str>, anchor: Anchor) -> Request {
    Request::Create { tab, page: true, name: name.map(str::to_string), anchor }
}

/// The requests applied one by one: each tab that was in the strip, in strip
/// order, and if it is still open. A closed tab keeps its entry, so a
/// request that names its creation gets the place where the tab was.
#[derive(Debug)]
struct OneByOne {
    entries: Vec<(SurfaceId, bool)>,
    made: HashMap<String, SurfaceId>,
}

impl OneByOne {
    fn new() -> Self {
        Self { entries: FIRST.map(|tab| (tab, true)).to_vec(), made: HashMap::new() }
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
            Request::Create { tab, name, anchor, .. } => {
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
                }
            }
        }
    }
}

fn slots(tabs: &[SurfaceId]) -> Vec<Slot> {
    tabs.iter().map(|tab| Slot { tab: Some(*tab), pinned: false, group: None }).collect()
}

/// `request`, a new tab, arrives: its creation takes its slot in the list
/// under test. Gives the number of the creation.
fn admit(places: &mut PlaceLists, real: &[SurfaceId], request: &Request) -> u64 {
    let Request::Create { name, anchor, .. } = request else {
        panic!("{request:?} makes no tab");
    };
    let place = TabPlace { anchor: anchor.clone(), joins: false };
    let asked =
        Asked { client: CLIENT, transaction: name.as_deref(), place: Some(&place), activate: true };
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
    let Request::Create { tab, name, anchor, .. } = request else {
        panic!("{request:?} makes no tab");
    };
    let place = TabPlace { anchor: anchor.clone(), joins: false };
    let asked =
        Asked { client: CLIENT, transaction: name.as_deref(), place: Some(&place), activate: true };
    let (settled, active) = places.commit(PANE, &slots(real), &[], Some(number), asked, *tab);
    assert!(settled.index <= real.len(), "{settled:?} is not a slot of {real:?}");
    real.insert(settled.index, *tab);
    active
}

/// The tabs of the pane after `requests`, when the list under test takes
/// each request at its arrival and the launches end as `next` says.
///
/// Before the arrival of request `step`, `next(step, waiting)` gives the
/// launch that ends then: its place among the `waiting` launches, in the
/// order of their requests; or none. After the last request (`step` is the
/// count of the requests) `next` is asked until no launch is left; none is
/// then the first launch.
fn daemon(
    requests: &[Request],
    mut next: impl FnMut(usize, usize) -> Option<usize>,
) -> Vec<SurfaceId> {
    let mut places = PlaceLists::default();
    let mut real = FIRST.to_vec();
    // Each creation whose terminal still launches: its number and its request.
    let mut waiting: Vec<(u64, usize)> = Vec::new();
    for (step, request) in requests.iter().enumerate() {
        if let Some(pick) = next(step, waiting.len()).filter(|pick| *pick < waiting.len()) {
            let (number, launched) = waiting.remove(pick);
            commit(&mut places, &mut real, number, &requests[launched]);
        }
        // The request names a tab by its id: the launch of that tab ended.
        let named = request.names().and_then(|named| {
            waiting.iter().position(|(_, launching)| {
                matches!(&requests[*launching], Request::Create { tab, .. } if *tab == named)
            })
        });
        if let Some(pick) = named {
            let (number, launched) = waiting.remove(pick);
            commit(&mut places, &mut real, number, &requests[launched]);
        }
        match request {
            Request::Create { page, .. } => {
                let number = admit(&mut places, &real, request);
                if *page {
                    commit(&mut places, &mut real, number, request);
                } else {
                    waiting.push((number, step));
                }
            }
            Request::Close { tab } => real.retain(|open| open != tab),
        }
    }
    while !waiting.is_empty() {
        let pick = next(requests.len(), waiting.len()).filter(|pick| *pick < waiting.len());
        let (number, launched) = waiting.remove(pick.unwrap_or(0));
        commit(&mut places, &mut real, number, &requests[launched]);
    }
    real
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

/// One step of a generated case: a request that names its tab or its
/// creation by a place among those that the strip has at that step.
#[derive(Clone, Debug)]
enum Step {
    Create { page: bool, named: bool, form: u8, anchor: prop::sample::Index },
    Close { tab: prop::sample::Index },
}

/// 4 creates for each close.
fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        4 => (any::<bool>(), any::<bool>(), 0..4u8, any::<prop::sample::Index>())
            .prop_map(|(page, named, form, anchor)| Step::Create { page, named, form, anchor }),
        1 => any::<prop::sample::Index>().prop_map(|tab| Step::Close { tab }),
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
            Step::Create { page, named, form, anchor } => {
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
                Request::Create { tab: NEW + number as u64, page: *page, name, anchor }
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
    /// the last request.
    #[test]
    fn the_tabs_are_those_of_the_requests_one_by_one_for_each_order_of_the_commits(
        steps in prop::collection::vec(step(), 1..=STEPS),
        early in prop::collection::vec(any::<Option<prop::sample::Index>>(), STEPS),
        late in prop::collection::vec(any::<prop::sample::Index>(), STEPS),
    ) {
        let requests = requests(&steps);
        let mut late = late.iter();
        let tabs = daemon(&requests, |step, waiting| {
            let pick = if step < requests.len() { early[step] } else { late.next().copied() };
            pick.filter(|_| waiting > 0).map(|pick| pick.index(waiting))
        });
        prop_assert_eq!(tabs, OneByOne::of(&requests), "the requests: {:?}", requests);
    }
}
