//! `place` of `new-tab`, `new-conversation-tab` and `new-frontend-browser-tab`
//! (`tab-create-place-v1`): the request says where its tab goes in the
//! pane's strip (after a tab, before a tab, after the tab of an earlier
//! creation of the same connection, or first), and the daemon commits the
//! tab there in one step. No client moves a tab after its creation, so each
//! client sees the same order.

use super::super::*;

/// The three requests that take `place`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Terminal,
    Conversation,
    Browser,
}

pub(super) const KINDS: [Kind; 3] = [Kind::Terminal, Kind::Conversation, Kind::Browser];

impl Kind {
    /// The request that makes one tab of this kind in `pane`, with no place.
    pub(super) fn request(self, pane: PaneId) -> Value {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        match self {
            Self::Terminal => json!({"cmd":"new-tab","pane":pane}),
            Self::Conversation => {
                let mutation = format!("place-{}", NEXT.fetch_add(1, Ordering::Relaxed));
                json!({"cmd":"new-conversation-tab","pane":pane,
                       "agent_session":{"host":"install:mac-test"},
                       "origin":"place-test","mutation_id":mutation})
            }
            Self::Browser => json!({"cmd":"new-frontend-browser-tab","pane":pane,
                                    "url":"https://a.test/","engine":"webkit"}),
        }
    }
}

/// `request` with each of `fields` set.
pub(super) fn with<const N: usize>(mut request: Value, fields: [(&str, Value); N]) -> Value {
    for (name, value) in fields {
        request[name] = value;
    }
    request
}

pub(super) fn run_as(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(client), command, &writer)
}

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    run_as(mux, 0, request)
}

/// The surface of the tab that `reply` made.
pub(super) fn surface_of(reply: &Value) -> SurfaceId {
    reply["surface"].as_u64().unwrap_or_else(|| panic!("the reply names no surface: {reply}"))
}

/// Makes a tab of `kind` in `pane` at `place`, on connection 0.
fn place_tab(mux: &Arc<Mux>, kind: Kind, pane: PaneId, place: Value) -> SurfaceId {
    surface_of(&run(mux, with(kind.request(pane), [("place", place)])).unwrap())
}

/// As [`place_tab`], with a `transaction` that a later request can name.
fn place_named(mux: &Arc<Mux>, kind: Kind, pane: PaneId, name: &str, place: Value) -> SurfaceId {
    let request = with(kind.request(pane), [("place", place), ("transaction", json!(name))]);
    surface_of(&run(mux, request).unwrap())
}

pub(super) fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone())).unwrap_or_default()
}

pub(super) fn active_tab(mux: &Mux, pane: PaneId) -> usize {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.active_tab)).unwrap()
}

/// A pane with three terminal tabs `[a, b, c]`, `a` active.
pub(super) fn strip(label: &str) -> (Arc<Mux>, PaneId, [SurfaceId; 3]) {
    let mux =
        Mux::new_for_test(format!("tab-create-place-{label}"), crate::SurfaceOptions::default());
    let a = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(a)).unwrap();
    let b = mux.new_tab(Some(pane), None, None).unwrap().id;
    let c = mux.new_tab(Some(pane), None, None).unwrap().id;
    mux.select_tab(Some(pane), Some(0), None);
    (mux, pane, [a, b, c])
}

/// The members of each tab group run of `pane`, in strip order.
fn group_runs(mux: &Mux, pane: PaneId) -> Vec<Vec<SurfaceId>> {
    let presentation = mux.presentation_snapshot();
    mux.with_state(|state| {
        crate::mux::pane_tab_groups(state, &presentation, pane)
            .into_iter()
            .map(|run| run.members)
            .collect()
    })
}

/// Groups `[a, b]` of a [`strip`].
fn group_first_two(mux: &Arc<Mux>, a: SurfaceId, b: SurfaceId) {
    mux.create_tab_group(&[a, b], None, Some("green".into()), Some("g1".into()), None).unwrap();
}

/// The index and the transaction of each `tab-added` of `surface` so far.
fn added(
    events: &crate::MuxEventReceiver,
    surface: SurfaceId,
) -> Vec<(Option<usize>, Option<String>)> {
    std::iter::from_fn(|| events.try_recv().ok())
        .filter_map(|event| match event {
            MuxEvent::TreeDelta(delta)
                if delta.kind == TreeDeltaKind::TabAdded && delta.surface == Some(surface) =>
            {
                Some((delta.index, delta.transaction.map(|transaction| transaction.to_string())))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn identify_advertises_the_place_of_a_new_tab() {
    let mux = Mux::new_for_test("tab-create-place-identify", crate::SurfaceOptions::default());
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "tab-create-place-v1"), "{identity}");
}

#[test]
fn a_tab_placed_after_a_tab_lands_right_after_it() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("after-{kind:?}"));
        let new = place_tab(&mux, kind, pane, json!({"after": a}));
        assert_eq!(tabs(&mux, pane), [a, new, b, c], "{kind:?}");
        mux.shutdown();
    }
}

#[test]
fn a_tab_placed_before_a_tab_lands_right_before_it() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("before-{kind:?}"));
        let new = place_tab(&mux, kind, pane, json!({"before": c}));
        assert_eq!(tabs(&mux, pane), [a, b, new, c], "{kind:?}");
        mux.shutdown();
    }
}

#[test]
fn a_tab_placed_at_the_start_is_the_first_tab() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("start-{kind:?}"));
        let new = place_tab(&mux, kind, pane, json!({"start": true}));
        assert_eq!(tabs(&mux, pane), [new, a, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// The one `tab-added` of a placed tab has its index, and the transaction
/// of the request; the reply has the transaction also.
#[test]
fn the_tab_added_of_a_placed_tab_has_its_index_and_its_transaction() {
    for kind in KINDS {
        let (mux, pane, [a, _, _]) = strip(&format!("event-{kind:?}"));
        let events = mux.subscribe();
        let request = with(
            kind.request(pane),
            [("place", json!({"after": a})), ("transaction", json!("txn-place-1"))],
        );
        let reply = run(&mux, request).unwrap();
        assert_eq!(
            added(&events, surface_of(&reply)),
            [(Some(1), Some("txn-place-1".to_string()))],
            "{kind:?}"
        );
        assert_eq!(reply["transaction"], "txn-place-1", "{kind:?}: {reply}");
        mux.shutdown();
    }
}

/// A new terminal tab is its pane's active tab, at its place.
#[test]
fn a_placed_terminal_tab_is_the_active_tab() {
    let (mux, pane, [a, b, c]) = strip("active");
    mux.select_tab(Some(pane), Some(2), None);
    let new = place_tab(&mux, Kind::Terminal, pane, json!({"after": a}));
    assert_eq!(tabs(&mux, pane), [a, new, b, c]);
    assert_eq!(active_tab(&mux, pane), 1);
    mux.shutdown();
}

/// A background tab put before the active tab keeps that tab active.
#[test]
fn a_background_tab_placed_before_the_active_tab_keeps_it_active() {
    let (mux, pane, [a, b, c]) = strip("background");
    mux.select_tab(Some(pane), Some(2), None);
    let request = with(
        Kind::Browser.request(pane),
        [("place", json!({"before": a})), ("activate", json!(false))],
    );
    let new = surface_of(&run(&mux, request).unwrap());
    assert_eq!(tabs(&mux, pane), [new, a, b, c]);
    assert_eq!(active_tab(&mux, pane), 3, "`c` stays the active tab");
    mux.shutdown();
}

/// The product state of this test is a restored pane with no tab: a restore
/// accepts such a pane. A background page that goes into it is its only
/// tab, and the active index of the pane stays 0, the index of that tab.
/// The index does not move right of a tab that is not there. The state is
/// made by hand, not by a restore: the test takes the 3 tabs out of the
/// strip (their surfaces stay in the session until the shutdown) and makes
/// the page by the function that the create of a page calls.
#[test]
fn a_background_page_in_a_pane_with_no_tab_leaves_the_active_index_at_0() {
    let (mux, pane, _) = strip("empty-pane");
    {
        let mut state = mux.state.lock().unwrap();
        let emptied = state.panes.get_mut(&pane).expect("the pane of the strip");
        emptied.tabs.clear();
        emptied.active_tab = 0;
    }
    let placement = crate::mux::FrontendTabPlacement { activate: false, ..Default::default() };
    let identity = crate::resource::TabResourceIdentity::browser().unwrap();
    let page = mux
        .new_browser_tab_reserved(
            "about:blank#empty-pane".to_string(),
            Some(pane),
            None,
            identity,
            None,
            placement,
            Default::default(),
        )
        .unwrap();
    assert_eq!(tabs(&mux, pane), [page.id]);
    assert_eq!(active_tab(&mux, pane), 0, "the active index names the only tab");
    mux.shutdown();
}

/// No place puts a tab among the pinned tabs: a place there gives the first
/// slot after them.
#[test]
fn a_placed_tab_never_lands_among_the_pinned_tabs() {
    for kind in KINDS {
        for place in ["after-first", "before-first", "before-second", "start"] {
            let (mux, pane, [a, b, c]) = strip(&format!("pinned-{place}-{kind:?}"));
            mux.set_tab_pinned(a, true).unwrap();
            mux.set_tab_pinned(b, true).unwrap();
            assert_eq!(tabs(&mux, pane), [a, b, c], "the pinned tabs are first");
            let request = match place {
                "after-first" => json!({"after": a}),
                "before-first" => json!({"before": a}),
                "before-second" => json!({"before": b}),
                _ => json!({"start": true}),
            };
            let new = place_tab(&mux, kind, pane, request);
            assert_eq!(tabs(&mux, pane), [a, b, new, c], "{kind:?} {place}");
            mux.shutdown();
        }
    }
}

/// Without `joins` a tab does not split the run of a tab group: a slot
/// inside the run gives the nearest slot outside it, on the side asked for.
#[test]
fn a_tab_that_does_not_join_stays_outside_the_group_of_its_anchor() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("outside-after-{kind:?}"));
        group_first_two(&mux, a, b);
        let new = place_tab(&mux, kind, pane, json!({"after": a}));
        assert_eq!(tabs(&mux, pane), [a, b, new, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), [vec![a, b]], "{kind:?}");
        mux.shutdown();

        let (mux, pane, [a, b, c]) = strip(&format!("outside-before-{kind:?}"));
        group_first_two(&mux, a, b);
        let new = place_tab(&mux, kind, pane, json!({"before": b}));
        assert_eq!(tabs(&mux, pane), [new, a, b, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), [vec![a, b]], "{kind:?}");
        mux.shutdown();
    }
}

/// With `joins` the tab takes its slot and is a member of its anchor's tab
/// group; an anchor with no group gives a tab with no group.
#[test]
fn a_tab_that_joins_is_a_member_of_the_group_of_its_anchor() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("joins-after-{kind:?}"));
        group_first_two(&mux, a, b);
        let new = place_tab(&mux, kind, pane, json!({"after": a, "joins": true}));
        assert_eq!(tabs(&mux, pane), [a, new, b, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), [vec![a, new, b]], "{kind:?}");
        let last = place_tab(&mux, kind, pane, json!({"after": b, "joins": true}));
        assert_eq!(tabs(&mux, pane), [a, new, b, last, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), [vec![a, new, b, last]], "{kind:?}");
        mux.shutdown();

        let (mux, pane, [a, b, c]) = strip(&format!("joins-before-{kind:?}"));
        group_first_two(&mux, a, b);
        let new = place_tab(&mux, kind, pane, json!({"before": a, "joins": true}));
        assert_eq!(tabs(&mux, pane), [new, a, b, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), [vec![new, a, b]], "{kind:?}");
        let alone = place_tab(&mux, kind, pane, json!({"before": c, "joins": true}));
        assert_eq!(tabs(&mux, pane), [new, a, b, alone, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), [vec![new, a, b]], "{kind:?}");
        mux.shutdown();
    }
}

/// `place` is the newer field: with both, the old `after` of
/// `new-frontend-browser-tab` has no effect.
#[test]
fn place_wins_over_the_old_after_field() {
    let (mux, pane, [a, b, c]) = strip("both-fields");
    let request =
        with(Kind::Browser.request(pane), [("after", json!(b)), ("place", json!({"after": a}))]);
    let new = surface_of(&run(&mux, request).unwrap());
    assert_eq!(tabs(&mux, pane), [a, new, b, c]);
    mux.shutdown();
}

/// A place that names not exactly one position, or `joins` with no anchor,
/// is refused before a tab is made.
#[test]
fn a_place_that_is_not_one_position_is_refused() {
    let (mux, pane, [a, b, c]) = strip("refused");
    for place in [
        json!({}),
        json!({"after": a, "start": true}),
        json!({"after": a, "before": b}),
        json!({"start": false}),
        json!({"start": true, "joins": true}),
        json!({"after_creation": ""}),
    ] {
        for kind in KINDS {
            let request = with(kind.request(pane), [("place", place.clone())]);
            let refused = run(&mux, request).map(|reply| reply.to_string());
            let error = refused.expect_err("a refusal").to_string();
            assert!(error.contains("bad request"), "{kind:?} {place}: {error}");
        }
    }
    for kind in [Kind::Terminal, Kind::Browser] {
        let request = with(kind.request(pane), [("transaction", json!(""))]);
        let refused = run(&mux, request).map(|reply| reply.to_string());
        let error = refused.expect_err("a refusal").to_string();
        assert!(error.contains("bad request"), "{kind:?}: {error}");
    }
    assert_eq!(tabs(&mux, pane), [a, b, c], "a refused request makes no tab");
    mux.shutdown();
}

/// `request` of `kind`, for a new pane split from `pane` (`split`) or for
/// the workspace of `pane` (no `split`) in place of the pane itself.
fn elsewhere(mux: &Mux, kind: Kind, pane: PaneId, split: bool) -> Value {
    let mut request = kind.request(pane);
    if split {
        request["split"] = json!({"direction": "right"});
    } else {
        let workspace = mux
            .with_state(|state| state.screen_of(pane).map(|(index, _)| state.workspaces[index].id));
        request["workspace"] = json!(workspace.expect("the workspace of the pane"));
        request.as_object_mut().expect("a request object").remove("pane");
    }
    request
}

/// The count of the tabs of each pane, with the count of the panes.
fn tab_counts(mux: &Mux) -> (usize, usize) {
    mux.with_state(|state| {
        (state.panes.len(), state.panes.values().map(|pane| pane.tabs.len()).sum())
    })
}

/// `place` names a position in the strip of `pane`. A request for a new
/// pane (`split`) or for a workspace names no such strip, so a
/// conversation tab and a page refuse `place` there, before a tab is made.
#[test]
fn a_place_with_a_workspace_or_a_split_is_refused() {
    let (mux, pane, [a, b, c]) = strip("refused-elsewhere");
    let before = tab_counts(&mux);
    for kind in [Kind::Conversation, Kind::Browser] {
        for split in [true, false] {
            let request = elsewhere(&mux, kind, pane, split);
            let request = with(request, [("place", json!({"start": true}))]);
            let refused = run(&mux, request).map(|reply| reply.to_string());
            let error = refused.expect_err("a refusal").to_string();
            let named = error.contains("bad request") && error.contains("workspace or split");
            assert!(named, "{kind:?}, split {split}: {error}");
        }
    }
    assert_eq!(tab_counts(&mux), before, "a refused request makes no tab and no pane");
    assert_eq!(tabs(&mux, pane), [a, b, c]);
    mux.shutdown();
}

/// The `tab-added` of a page in a new pane or in a workspace carries no
/// `transaction`, so the request refuses `transaction` there: a client
/// does not wait for a transaction that no event brings.
#[test]
fn a_page_transaction_with_a_workspace_or_a_split_is_refused() {
    let (mux, pane, [a, b, c]) = strip("refused-transaction");
    let before = tab_counts(&mux);
    for split in [true, false] {
        let request = elsewhere(&mux, Kind::Browser, pane, split);
        let request = with(request, [("transaction", json!("t1"))]);
        let refused = run(&mux, request).map(|reply| reply.to_string());
        let error = refused.expect_err("a refusal").to_string();
        let named = error.contains("bad request") && error.contains("workspace or split");
        assert!(named, "split {split}: {error}");
    }
    assert_eq!(tab_counts(&mux), before, "a refused request makes no tab and no pane");
    assert_eq!(tabs(&mux, pane), [a, b, c]);
    mux.shutdown();
}

/// `place` names a position in the strip of `pane`: each of the three
/// requests refuses a `place` with no `pane`, before a tab is made.
#[test]
fn a_place_with_no_pane_is_refused() {
    let (mux, pane, [a, b, c]) = strip("refused-no-pane");
    let before = tab_counts(&mux);
    for kind in KINDS {
        let mut request = with(kind.request(pane), [("place", json!({"start": true}))]);
        request.as_object_mut().expect("a request object").remove("pane");
        let refused = run(&mux, request).map(|reply| reply.to_string());
        let error = refused.expect_err("a refusal").to_string();
        let named = error.contains("bad request") && error.contains("place needs pane");
        assert!(named, "{kind:?}: {error}");
    }
    assert_eq!(tab_counts(&mux), before, "a refused request makes no tab and no pane");
    assert_eq!(tabs(&mux, pane), [a, b, c]);
    mux.shutdown();
}

/// `transaction` names a creation in the strip of `pane`: `new-tab` and
/// `new-frontend-browser-tab` refuse a `transaction` with no `pane`, before
/// a tab is made. `new-conversation-tab` had `transaction` before `place`
/// (`conversation-tab-transaction-v1`) and keeps it with no `pane`: its tab
/// goes to the active pane.
#[test]
fn a_transaction_with_no_pane_is_refused() {
    let (mux, pane, [a, b, c]) = strip("refused-transaction-no-pane");
    let before = tab_counts(&mux);
    let no_pane = |kind: Kind, name: &str| {
        let mut request = with(kind.request(pane), [("transaction", json!(name))]);
        request.as_object_mut().expect("a request object").remove("pane");
        request
    };
    for kind in [Kind::Terminal, Kind::Browser] {
        let refused = run(&mux, no_pane(kind, "t1")).map(|reply| reply.to_string());
        let error = refused.expect_err("a refusal").to_string();
        let named = error.contains("bad request") && error.contains("transaction needs pane");
        assert!(named, "{kind:?}: {error}");
    }
    assert_eq!(tab_counts(&mux), before, "a refused request makes no tab and no pane");
    assert_eq!(tabs(&mux, pane), [a, b, c]);
    let made = surface_of(&run(&mux, no_pane(Kind::Conversation, "t2")).unwrap());
    assert_eq!(tabs(&mux, pane), [a, b, c, made]);
    mux.shutdown();
}

/// A tab that names the creation before it lands right after that
/// creation's tab, for each kind of both; a transaction that the connection
/// never used gives the end.
#[test]
fn a_tab_placed_after_a_creation_lands_right_after_its_tab() {
    for first_kind in KINDS {
        for next_kind in KINDS {
            let (mux, pane, [a, b, c]) = strip(&format!("creation-{first_kind:?}-{next_kind:?}"));
            let first = place_named(&mux, first_kind, pane, "t1", json!({"after": a}));
            let second = place_named(&mux, next_kind, pane, "t2", json!({"after_creation": "t1"}));
            let third = place_tab(&mux, next_kind, pane, json!({"after_creation": "t2"}));
            assert_eq!(
                tabs(&mux, pane),
                [a, first, second, third, b, c],
                "{first_kind:?} {next_kind:?}"
            );
            let unknown = place_tab(&mux, next_kind, pane, json!({"after_creation": "t9"}));
            assert_eq!(tabs(&mux, pane), [a, first, second, third, b, c, unknown]);
            mux.shutdown();
        }
    }
}

/// A tab that names a surface which was never a tab of the pane goes to the
/// end, as with the old `after` field.
#[test]
fn an_anchor_that_was_never_in_the_pane_gives_the_end() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("never-{kind:?}"));
        let placed = place_tab(&mux, kind, pane, json!({"after": a}));
        assert_eq!(tabs(&mux, pane), [a, placed, b, c], "{kind:?}");
        let after = place_tab(&mux, kind, pane, json!({"after": 999_999}));
        let before = place_tab(&mux, kind, pane, json!({"before": 999_998}));
        assert_eq!(tabs(&mux, pane), [a, placed, b, c, after, before], "{kind:?}");
        mux.shutdown();
    }
}

/// The tab of a named creation closed before the next request came: the
/// next tab lands where that tab was, after its nearest left neighbor that
/// is still in the pane; with no such neighbor it is the first tab.
#[test]
fn a_creation_whose_tab_closed_gives_the_place_where_it_was() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("closed-{kind:?}"));
        let first = place_named(&mux, kind, pane, "t1", json!({"after": b}));
        assert_eq!(tabs(&mux, pane), [a, b, first, c], "{kind:?}");
        mux.close_surface(first).unwrap();
        let second = place_tab(&mux, kind, pane, json!({"after_creation": "t1"}));
        assert_eq!(tabs(&mux, pane), [a, b, second, c], "{kind:?}");
        mux.close_surface(b).unwrap();
        let third = place_tab(&mux, kind, pane, json!({"after_creation": "t1"}));
        assert_eq!(tabs(&mux, pane), [a, third, second, c], "{kind:?}");
        mux.close_surface(a).unwrap();
        let fourth = place_tab(&mux, kind, pane, json!({"after_creation": "t1"}));
        assert_eq!(tabs(&mux, pane), [fourth, third, second, c], "{kind:?}");
        mux.shutdown();
    }
}

/// The tab of a named creation moved to another pane: in its first pane the
/// next tab lands where that tab was. A creation whose tab was never in the
/// request's pane gives the end there.
#[test]
fn a_creation_whose_tab_moved_away_gives_the_place_where_it_was() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("moved-{kind:?}"));
        let other = mux.split(pane, SplitDir::Down, None).unwrap().id;
        let other_pane = mux.with_state(|state| state.pane_of(other)).unwrap();
        let first = place_named(&mux, kind, pane, "t1", json!({"after": a}));
        assert_eq!(tabs(&mux, pane), [a, first, b, c], "{kind:?}");
        assert!(mux.move_tab(first, other_pane, 0), "{kind:?}");
        let second = place_named(&mux, kind, pane, "t2", json!({"after_creation": "t1"}));
        assert_eq!(tabs(&mux, pane), [a, second, b, c], "{kind:?}");
        assert_eq!(tabs(&mux, other_pane), [first, other], "{kind:?}");
        // `t2` made its tab in the first pane and the tab is there: in the
        // other pane it names no place, so the end.
        let third = place_tab(&mux, kind, other_pane, json!({"after_creation": "t2"}));
        assert_eq!(tabs(&mux, other_pane), [first, other, third], "{kind:?}");
        mux.shutdown();
    }
}

/// A creation that failed made no tab: a request that names it lands where
/// the failed tab would be.
#[test]
fn a_creation_that_failed_gives_the_place_it_asked_for() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = strip(&format!("failed-{kind:?}"));
        // An environment name that no terminal takes: the place is read, and the create fails.
        let failing = with(
            Kind::Terminal.request(pane),
            [
                ("place", json!({"after": a})),
                ("transaction", json!("t1")),
                ("env", json!({"A=B": "1"})),
            ],
        );
        let failed = run(&mux, failing).map(|reply| reply.to_string());
        assert!(failed.is_err(), "the create with a bad environment made {failed:?}");
        assert_eq!(tabs(&mux, pane), [a, b, c], "{kind:?}");
        let next = place_named(&mux, kind, pane, "t2", json!({"after_creation": "t1"}));
        let last = place_tab(&mux, kind, pane, json!({"after_creation": "t2"}));
        assert_eq!(tabs(&mux, pane), [a, next, last, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// A transaction names a creation of its own connection only.
#[test]
fn a_creation_of_another_connection_gives_the_end() {
    let (mux, pane, [a, b, c]) = strip("other-connection");
    let first = place_named(&mux, Kind::Browser, pane, "t1", json!({"after": a}));
    let own = place_tab(&mux, Kind::Browser, pane, json!({"after_creation": "t1"}));
    assert_eq!(tabs(&mux, pane), [a, first, own, b, c]);
    let request = with(Kind::Browser.request(pane), [("place", json!({"after_creation": "t1"}))]);
    let foreign = surface_of(&run_as(&mux, 7, request).unwrap());
    assert_eq!(tabs(&mux, pane), [a, first, own, b, c, foreign]);
    mux.shutdown();
}

/// The creations of a connection leave the record when the connection
/// closes: a later connection with the same number names none of them.
#[test]
fn the_creations_of_a_connection_leave_the_record_when_it_closes() {
    const CLIENT: u64 = 41;
    let (mux, pane, [a, b, c]) = strip("closed-connection");
    let named = with(
        Kind::Browser.request(pane),
        [("place", json!({"after": a})), ("transaction", json!("t1"))],
    );
    let first = surface_of(&run_as(&mux, CLIENT, named).unwrap());
    let after_first =
        || with(Kind::Browser.request(pane), [("place", json!({"after_creation": "t1"}))]);
    let second = surface_of(&run_as(&mux, CLIENT, after_first()).unwrap());
    assert_eq!(tabs(&mux, pane), [a, first, second, b, c]);
    assert!(disconnect_client(&mux, CLIENT, false), "the connection was open");
    let third = surface_of(&run_as(&mux, CLIENT, after_first()).unwrap());
    assert_eq!(tabs(&mux, pane), [a, first, second, b, c, third]);
    mux.shutdown();
}

/// The record keeps the last 256 creations of all connections. A request
/// that names an older one gets the end, with no failure; one that names a
/// creation still in the record gets its place.
#[test]
fn a_creation_that_the_record_no_longer_keeps_gives_the_end() {
    const KEPT: usize = 256;
    let (mux, pane, [_, _, c]) = strip("bound");
    let mut made = Vec::new();
    for n in 0..=KEPT {
        let name = format!("t{n}");
        made.push(place_named(&mux, Kind::Browser, pane, &name, json!({"start": true})));
    }
    let index = |surface: SurfaceId| {
        tabs(&mux, pane).iter().position(|tab| *tab == surface).expect("the tab is in the pane")
    };
    let oldest = place_tab(&mux, Kind::Browser, pane, json!({"after_creation": "t0"}));
    assert_eq!(tabs(&mux, pane).last(), Some(&oldest), "`t0` is out of the record: the end");
    assert_eq!(index(oldest), index(c) + 1);
    let kept = place_tab(&mux, Kind::Browser, pane, json!({"after_creation": "t1"}));
    assert_eq!(index(kept), index(made[1]) + 1, "`t1` is in the record");
    let newest = place_tab(&mux, Kind::Browser, pane, json!({"after_creation": "t256"}));
    assert_eq!(index(newest), index(made[KEPT]) + 1, "`t256` is in the record");
    mux.shutdown();
}
