//! Wire tests for `split {before: true}` (`split-before-v1`, Split Up and
//! Split Left): the new pane opens before the target on the split axis in the
//! one split commit, under the caller's client-minted pane, tab and split ids,
//! focused, at the even ratio; the layout equals what `split` then
//! `swap-pane` made before, so a client that showed it at the key sees no
//! swap. A keyed retry replays it.

use super::*;

const PANE_ID: &str = "pane_0123456789abcdef0123456789abcdef";
const TAB_ID: &str = "tab_0123456789abcdef0123456789abcdef";
const SPLIT_ID: &str = "split_0123456789abcdef0123456789abcdef";

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    /// One workspace whose screen holds one pane. Returns it.
    fn with_one_pane() -> (Self, PaneId) {
        let mux = Mux::new_for_test("split-before", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        (Self { mux, outbound, writer, next_id: 1 }, pane)
    }

    fn send(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        handle_message(
            &self.mux,
            self.mux.local_test_client(7),
            &request.to_string(),
            &self.writer,
        );
        let response: Value = serde_json::from_str(&self.outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id, "response must answer the request: {response}");
        response
    }

    /// The reply's data and the pane the request created.
    fn created(&mut self, request: Value) -> (Value, PaneId) {
        let response = self.send(request.clone());
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        let surface: SurfaceId =
            serde_json::from_value(response["data"]["surface"].clone()).unwrap();
        let pane = self.mux.with_state(|state| state.pane_of(surface).unwrap());
        (response["data"].clone(), pane)
    }

    /// The first screen's root: its split's direction, ratio, public id and
    /// its two leaves in order (`a`, `b`).
    fn root_split(&self) -> (SplitDir, f32, Option<String>, PaneId, PaneId) {
        self.mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let Node::Split { id, dir, ratio, a, b, .. } = &screen.root else {
                panic!("the screen is not split: {:?}", screen.root);
            };
            let (Node::Leaf(a), Node::Leaf(b)) = (&**a, &**b) else {
                panic!("the split's sides are not leaves: {:?}", screen.root);
            };
            let public = state.resource_indexes.split_ids.get(id).map(ToString::to_string);
            (*dir, *ratio, public, *a, *b)
        })
    }

    fn active_pane(&self) -> PaneId {
        self.mux.with_state(|state| state.workspaces[0].screens[0].active_pane)
    }

    fn public_id(&self, pane: PaneId) -> String {
        self.mux.with_state(|state| state.panes[&pane].public_id.to_string())
    }
}

#[test]
fn split_before_capability_is_advertised() {
    let (mut wire, _) = Wire::with_one_pane();
    let identity = wire.send(json!({"cmd": "identify"}));
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "split-before-v1"),
        "{identity}"
    );
}

/// Split Up: `dir: "down"` with `before` puts the new pane above its target,
/// under the caller's ids, focused, at the even ratio.
#[test]
fn split_up_puts_the_new_pane_above_its_target_under_the_client_ids() {
    let (mut wire, target) = Wire::with_one_pane();
    let (data, new) = wire.created(json!({
        "cmd": "split", "pane": target, "dir": "down", "before": true, "cols": 80, "rows": 10,
        "pane_id": PANE_ID, "tab_id": TAB_ID, "split_id": SPLIT_ID,
    }));
    assert_eq!(data["pane_id"], PANE_ID, "{data}");
    assert_eq!(data["tab_id"], TAB_ID, "{data}");
    assert_eq!(wire.public_id(new), PANE_ID);
    let (dir, ratio, split_id, a, b) = wire.root_split();
    assert_eq!(dir, SplitDir::Down);
    assert!((ratio - 0.5).abs() < 1e-6, "{ratio}");
    assert_eq!(split_id.as_deref(), Some(SPLIT_ID));
    assert_eq!((a, b), (new, target), "the new pane must be above its target");
    assert_eq!(wire.active_pane(), new);
}

/// Split Left: `dir: "right"` with `before` puts the new pane left of its
/// target; without `before` (or `before: false`) it goes right, as before.
#[test]
fn split_left_puts_the_new_pane_left_and_no_before_keeps_it_after() {
    let (mut wire, target) = Wire::with_one_pane();
    let (_, new) = wire.created(json!({
        "cmd": "split", "pane": target, "dir": "right", "before": true, "cols": 38, "rows": 22,
    }));
    let (dir, _, _, a, b) = wire.root_split();
    assert_eq!(dir, SplitDir::Right);
    assert_eq!((a, b), (new, target), "the new pane must be left of its target");
    assert_eq!(wire.active_pane(), new);

    let (mut wire, target) = Wire::with_one_pane();
    let (_, new) = wire.created(json!({
        "cmd": "split", "pane": target, "dir": "right", "before": false, "cols": 38, "rows": 22,
    }));
    let (_, _, _, a, b) = wire.root_split();
    assert_eq!((a, b), (target, new), "before:false keeps the new pane after its target");
}

/// The before split's layout is the one `split` then `swap-pane` made, which
/// older clients still send: the same leaves on the same sides.
#[test]
fn split_up_matches_split_then_swap_pane() {
    let (mut swapped, target) = Wire::with_one_pane();
    let split = json!({"cmd": "split", "pane": target, "dir": "down", "cols": 80, "rows": 10});
    let (_, new) = swapped.created(split);
    let response = swapped.send(json!({"cmd": "swap-pane", "pane": target, "dir": "down"}));
    assert_eq!(response["ok"], true, "{response}");
    let (dir, ratio, _, a, b) = swapped.root_split();
    assert_eq!((a, b), (new, target), "swap-pane must put the new pane first");

    let (mut placed, target) = Wire::with_one_pane();
    let (_, new) = placed.created(json!({
        "cmd": "split", "pane": target, "dir": "down", "before": true, "cols": 80, "rows": 10,
    }));
    let (placed_dir, placed_ratio, _, placed_a, placed_b) = placed.root_split();
    assert_eq!((placed_dir, placed_a, placed_b), (dir, new, target));
    assert!((placed_ratio - ratio).abs() < 1e-6, "{placed_ratio} vs {ratio}");
}

/// A keyed retry of a before split (a late start, `split-client-keys-v1`)
/// returns the first result and changes nothing.
#[test]
fn a_keyed_retry_of_a_split_up_replays_it() {
    let (mut wire, target) = Wire::with_one_pane();
    let request = json!({
        "cmd": "split", "pane": target, "dir": "down", "before": true, "cols": 80, "rows": 10,
        "pane_id": PANE_ID, "tab_id": TAB_ID, "split_id": SPLIT_ID,
    });
    let (first, new) = wire.created(request.clone());
    let layout = wire.root_split();
    let (again, again_pane) = wire.created(request);
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(again["surface"], first["surface"]);
    assert_eq!(again_pane, new);
    assert_eq!(wire.root_split(), layout);
}

/// `before` must be a boolean: anything else is a bad request that creates
/// nothing.
#[test]
fn a_non_boolean_before_is_refused_and_creates_nothing() {
    let (mut wire, target) = Wire::with_one_pane();
    let request = json!({"cmd": "split", "pane": target, "dir": "down", "before": "up"});
    let response = wire.send(request);
    assert_eq!(response["ok"], false, "{response}");
    assert!(
        wire.mux.with_state(|state| matches!(state.workspaces[0].screens[0].root, Node::Leaf(_))),
        "a refused split changed the layout"
    );
}
