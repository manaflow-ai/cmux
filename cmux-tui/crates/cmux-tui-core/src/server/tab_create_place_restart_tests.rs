//! The order of a pane's tabs over a stop and a start of the daemon on one
//! session folder (`tab-create-place-v1`, 2026-11-16). The list of the
//! places that the creations took is in memory only: a start has the tabs
//! that were committed, and these tests show that it has them in the order
//! that the strip had at the stop. Each test compares the public ids of the
//! tabs, because a start can give a tab another surface number.

use super::super::*;
use super::tab_create_place_chain_tests::{HeldConnection, terminal};
use super::tab_create_place_tests::{Kind, run_as, surface_of, tabs, with};
use crate::resource::TabPublicId;

/// One session folder. Each [`Self::open`] is a daemon on it.
struct Session {
    root: std::path::PathBuf,
    name: &'static str,
}

impl Session {
    fn new(name: &'static str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "cmux-tab-place-restart-{name}-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        Self { root, name }
    }

    fn open(&self) -> Arc<Mux> {
        let registry = crate::WorkspaceRegistry::open(&self.root, self.name).unwrap();
        Mux::from_workspace_registry(
            self.name.into(),
            crate::SurfaceOptions::default(),
            registry,
            crate::mux::ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }

    /// Stops `mux` and starts a daemon on the same folder.
    fn restart(&self, mux: Arc<Mux>) -> Arc<Mux> {
        mux.shutdown();
        drop(mux);
        self.open()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// A new workspace: its first tab and the pane of that tab.
fn first_tab(mux: &Arc<Mux>) -> (SurfaceId, PaneId) {
    let first = mux.new_workspace(None, None).unwrap().id;
    (first, mux.with_state(|state| state.pane_of(first)).unwrap())
}

/// Makes one tab with `request`, on connection 0.
fn make(mux: &Arc<Mux>, request: Value) -> SurfaceId {
    surface_of(&run_as(mux, 0, request).unwrap())
}

fn id_of(mux: &Mux, tab: SurfaceId) -> TabPublicId {
    mux.with_state(|state| state.resource_indexes.tab_ids.get(&tab).cloned())
        .unwrap_or_else(|| panic!("tab {tab} has no public id"))
}

/// The public ids of the tabs of `pane`, in strip order.
fn ids(mux: &Mux, pane: PaneId) -> Vec<TabPublicId> {
    tabs(mux, pane).into_iter().map(|tab| id_of(mux, tab)).collect()
}

/// The pane that holds one of the tabs `known` after a start. The pane's
/// number can change over a start, so a tab of before the stop finds it.
fn pane_after_start(mux: &Mux, known: &[TabPublicId]) -> Option<PaneId> {
    mux.with_state(|state| {
        known.iter().find_map(|tab| {
            let surface = state.resource_indexes.tabs.get(tab).copied()?;
            state.pane_of(surface)
        })
    })
}

/// The public ids, in strip order, of the pane that holds one of the tabs
/// `known` after a start. Empty when the start has none of them.
fn ids_after_start(mux: &Mux, known: &[TabPublicId]) -> Vec<TabPublicId> {
    pane_after_start(mux, known).map(|pane| ids(mux, pane)).unwrap_or_default()
}

/// Session 1: each tab comes from a request with no `place`, as a client
/// from before `tab-create-place-v1` sends them, and that client then moves
/// one tab. The strip is not in the order of the creations at the stop, and
/// the start gives the same strip.
#[test]
fn tabs_of_requests_with_no_place_keep_their_order_over_a_restart() {
    let session = Session::new("no-place");
    let mux = session.open();
    let (first, pane) = first_tab(&mux);
    let second = make(&mux, Kind::Terminal.request(pane));
    let page = make(&mux, Kind::Browser.request(pane));
    let moved = make(&mux, Kind::Terminal.request(pane));
    run_as(&mux, 0, json!({"cmd":"move-tab","surface":moved,"pane":pane,"index":0})).unwrap();
    let strip = tabs(&mux, pane);
    assert_eq!(strip.len(), 4, "the four tabs {first}, {second}, {page}, {moved}: {strip:?}");
    assert_eq!(strip[0], moved, "the tab that the client moved is the first: {strip:?}");
    let before = ids(&mux, pane);

    let mux = session.restart(mux);
    assert_eq!(
        ids_after_start(&mux, &before),
        before,
        "the strip after the start is the strip of before the stop"
    );
    mux.shutdown();
}

/// Session 2: tabs with a `place` of each form (after a tab, before a tab,
/// first, after an earlier creation). The start gives the same strip.
#[test]
fn tabs_of_requests_with_a_place_keep_their_order_over_a_restart() {
    let session = Session::new("place");
    let mux = session.open();
    let (a, pane) = first_tab(&mux);
    let b = make(&mux, Kind::Terminal.request(pane));
    let after_a = make(&mux, terminal(pane, "t1", json!({"after": a})));
    let before_b = make(&mux, with(Kind::Browser.request(pane), [("place", json!({"before": b}))]));
    let start = make(&mux, with(Kind::Terminal.request(pane), [("place", json!({"start": true}))]));
    let chained =
        make(&mux, with(Kind::Browser.request(pane), [("place", json!({"after_creation": "t1"}))]));
    assert_eq!(tabs(&mux, pane), [start, a, after_a, chained, before_b, b]);
    let before = ids(&mux, pane);

    let mux = session.restart(mux);
    assert_eq!(
        ids_after_start(&mux, &before),
        before,
        "the strip after the start is the strip of before the stop"
    );
    mux.shutdown();
}

/// After a start the list of places is empty. A request after
/// the start whose `place` names a tab of before the stop gets its slot
/// next to that tab, for each form that names a tab or the start.
#[test]
fn a_place_names_a_tab_of_before_the_stop_over_a_restart() {
    let session = Session::new("place-later");
    let mux = session.open();
    let (_, pane) = first_tab(&mux);
    make(&mux, Kind::Terminal.request(pane));
    make(&mux, Kind::Browser.request(pane));
    let before = ids(&mux, pane);
    assert_eq!(before.len(), 3);

    let mux = session.restart(mux);
    assert_eq!(ids_after_start(&mux, &before), before);
    let pane = pane_after_start(&mux, &before).unwrap();
    let [first, second, third]: [SurfaceId; 3] =
        tabs(&mux, pane).try_into().expect("the start gave another count of tabs than 3");
    let after_first = make(&mux, terminal(pane, "t1", json!({"after": first})));
    let before_third =
        make(&mux, with(Kind::Browser.request(pane), [("place", json!({"before": third}))]));
    let start = make(&mux, with(Kind::Terminal.request(pane), [("place", json!({"start": true}))]));
    assert_eq!(tabs(&mux, pane), [start, first, after_first, second, before_third, third]);
    mux.shutdown();
}

/// What a stop gave while the launch of one creation was held.
struct HeldAtStop {
    /// The tabs that were committed at the stop, in strip order.
    before: Vec<TabPublicId>,
    /// The tab that the held creation named: its slot is right after it.
    named: TabPublicId,
    /// The tab of the held creation, when the daemon that stopped committed
    /// it at the end of the launch.
    late: Option<TabPublicId>,
    /// The strip after the start.
    after: Vec<TabPublicId>,
}

/// Session 3, a stop with an open slot: a strip `[a, b]`; a terminal creation takes the slot after `a`
/// and its launch is held; a page that names that creation commits. The
/// daemon stops with the slot of the held creation open. The launch job
/// ends after the stop began (in a test the process lives on, so the job
/// must end before the folder opens again), then a daemon starts.
fn stop_with_a_held_launch(name: &'static str) -> HeldAtStop {
    let session = Session::new(name);
    let mux = session.open();
    let (a, pane) = first_tab(&mux);
    let b = make(&mux, Kind::Terminal.request(pane));
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, terminal(pane, "t1", json!({"after": a})));
    connection
        .send(2, with(Kind::Browser.request(pane), [("place", json!({"after_creation": "t1"}))]));
    let page = connection.surface(2);
    connection.launching(0);
    let committed = tabs(&mux, pane);
    assert_eq!(committed, [a, page, b], "the launch is held");
    let before = ids(&mux, pane);
    let named = id_of(&mux, a);

    mux.shutdown();
    connection.release(0);
    let late: Vec<SurfaceId> =
        tabs(&mux, pane).into_iter().filter(|tab| !committed.contains(tab)).collect();
    assert!(late.len() <= 1, "one creation was held: {late:?}");
    let late = late.first().map(|tab| id_of(&mux, *tab));
    drop(connection);
    drop(mux);

    let mux = session.open();
    let after = ids_after_start(&mux, &before);
    mux.shutdown();
    HeldAtStop { before, named, late, after }
}

/// The tabs that were committed at a stop with an open slot keep their
/// order over the start. The start has the tab of the held creation only if
/// the daemon that stopped committed it, and then that tab is at its slot.
#[test]
fn committed_tabs_keep_their_order_with_a_launch_held_at_the_stop_over_a_restart() {
    let HeldAtStop { before, named, late, after } = stop_with_a_held_launch("held-order");
    let committed: Vec<TabPublicId> =
        after.iter().filter(|tab| Some(*tab) != late.as_ref()).cloned().collect();
    assert_eq!(committed, before, "the committed tabs after the start: {after:?}");
    if let Some(late) = &late {
        let place = |tab: &TabPublicId| after.iter().position(|other| other == tab);
        assert_eq!(
            place(late),
            place(&named).map(|at| at + 1),
            "the tab of the held creation is right after the tab that it named: {after:?}"
        );
    }
}

/// Which of the two results the stop of
/// [`committed_tabs_keep_their_order_with_a_launch_held_at_the_stop_over_a_restart`]
/// gives: the launch job that ends after the stop began commits its tab,
/// and the start has that tab.
#[test]
fn a_launch_that_ends_after_the_stop_began_commits_its_tab() {
    let HeldAtStop { late, after, .. } = stop_with_a_held_launch("held-commit");
    let late = late.expect("the daemon that stopped did not commit the tab of the held creation");
    assert!(after.contains(&late), "the start has no tab {late:?}: {after:?}");
}
