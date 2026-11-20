//! Creations of one connection with a `place` (`tab-create-place-v1`) while
//! their terminals still launch. A creation takes its slot when its request
//! arrives, and no request waits for a launch. For each order in which the
//! launches end, the pane's strip is that of the same requests applied one
//! by one in the order of their arrival.

use super::super::tests::captured_writer;
use super::super::*;
use super::tab_create_place_tests::{Kind, active_tab, run_as, strip, surface_of, tabs, with};
use std::cell::RefCell;
use std::sync::mpsc;

/// A safety bound of each wait of the test thread on a signal: the test
/// fails at the bound, and no test passes by it.
const WAIT: Duration = Duration::from_secs(30);

/// One connection whose creations end their launch when the test says.
pub(super) struct HeldConnection {
    mux: Arc<Mux>,
    pub(super) client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    gates: Vec<mpsc::Sender<()>>,
    started: mpsc::Receiver<u64>,
    /// The creations whose launch has started.
    launching: RefCell<HashSet<u64>>,
    ended: mpsc::Receiver<u64>,
    /// Each line that the connection got, from the thread that takes them.
    lines: mpsc::Receiver<Value>,
    /// The replies that the test did not ask for yet, by request id.
    replies: RefCell<HashMap<u64, Value>>,
}

impl Drop for HeldConnection {
    /// Ends the thread that takes the connection's lines.
    fn drop(&mut self) {
        self.outbound.close();
    }
}

impl HeldConnection {
    /// A connection on `mux`. The launch of each of its first `held`
    /// creations waits for [`Self::release`]; a later creation does not wait.
    pub(super) fn new(mux: &Arc<Mux>, held: usize) -> Self {
        let (writer, outbound) = captured_writer();
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let (gates, waits): (Vec<_>, Vec<_>) = (0..held)
            .map(|_| {
                let (gate, wait) = mpsc::channel::<()>();
                (gate, Mutex::new(wait))
            })
            .unzip();
        let (started_tx, started) = mpsc::channel();
        let started_tx = Mutex::new(started_tx);
        let (ended_tx, ended) = mpsc::channel();
        let ended_tx = Mutex::new(ended_tx);
        mux.set_creation_launch_hook_for_test(move |seq, job_ended| {
            if job_ended {
                let _ = ended_tx.lock().unwrap().send(seq);
                return;
            }
            let _ = started_tx.lock().unwrap().send(seq);
            if let Some(wait) = usize::try_from(seq).ok().and_then(|seq| waits.get(seq)) {
                // No clock: the wait ends at the release, or when the
                // connection of the test drops its end of the gate. A test
                // that calls `finish` before the `release` of a held launch
                // waits here with no end: `release` comes first.
                let _ = wait.lock().unwrap().recv();
            }
        });
        let (lines_tx, lines) = mpsc::channel::<Value>();
        let taken = outbound.clone();
        std::thread::spawn(move || {
            while let Some(item) = taken.recv() {
                match item {
                    OutboundItem::Text(text) => {
                        let line = serde_json::from_str::<Value>(&text.to_string());
                        if line.is_ok_and(|line| lines_tx.send(line).is_err()) {
                            return;
                        }
                    }
                    OutboundItem::Flush(flushed) => {
                        let _ = flushed.send(());
                    }
                }
            }
        });
        Self {
            mux: mux.clone(),
            client,
            writer,
            outbound,
            scheduler,
            gates,
            started,
            launching: RefCell::default(),
            ended,
            lines,
            replies: RefCell::default(),
        }
    }

    /// Sends `request` with `id`, as one frame of the connection.
    pub(super) fn send(&self, id: u64, request: Value) {
        let frame = with(request, [("id", json!(id))]);
        assert!(handle_connection_frame(
            &self.mux,
            self.client,
            ClientTransport::Unix,
            &frame.to_string(),
            &self.writer,
            &self.scheduler,
        ));
    }

    /// Lets the launch of the creation with number `seq` (its place in the
    /// connection's creations, from 0) end, and waits until its job on the
    /// terminal work pool has committed what it could.
    pub(super) fn release(&self, seq: usize) {
        self.gates[seq].send(()).unwrap();
        loop {
            let ended = self.ended.recv_timeout(WAIT);
            let ended = ended.unwrap_or_else(|_| panic!("the launch job {seq} did not end"));
            if usize::try_from(ended) == Ok(seq) {
                return;
            }
        }
    }

    /// Waits until the launch of the creation with number `seq` has started.
    /// Its request arrived before that: what the test does to the pane after
    /// this wait comes after the request.
    pub(super) fn launching(&self, seq: usize) {
        let seq = seq as u64;
        while !self.launching.borrow().contains(&seq) {
            let started = self.started.recv_timeout(WAIT);
            let started = started.unwrap_or_else(|_| panic!("the launch job {seq} did not start"));
            self.launching.borrow_mut().insert(started);
        }
    }

    /// Waits for the reply to request `id`.
    pub(super) fn reply(&self, id: u64) -> Value {
        loop {
            if let Some(reply) = self.replies.borrow_mut().remove(&id) {
                return reply;
            }
            let line = self.lines.recv_timeout(WAIT);
            let line = line.unwrap_or_else(|_| panic!("no reply to request {id}"));
            if let Some(of) = line.get("id").and_then(Value::as_u64) {
                self.replies.borrow_mut().insert(of, line);
            }
        }
    }

    /// Waits for the reply to request `id`: the surface of the tab that the
    /// request made.
    pub(super) fn surface(&self, id: u64) -> SurfaceId {
        let reply = self.reply(id);
        assert_ne!(reply["ok"], json!(false), "{reply}");
        surface_of(&reply["data"])
    }

    /// Waits for all work of the connection, then gives the surface that
    /// each request of `ids` made.
    pub(super) fn finish<const N: usize>(&self, ids: [u64; N]) -> [SurfaceId; N] {
        self.scheduler.finish_and_wait();
        ids.map(|id| self.surface(id))
    }
}

/// A new terminal tab with `transaction` at `place`.
pub(super) fn terminal(pane: PaneId, transaction: &str, place: Value) -> Value {
    with(Kind::Terminal.request(pane), [("transaction", json!(transaction)), ("place", place)])
}

/// Each order of the numbers 0 to 3.
fn orders() -> Vec<[usize; 4]> {
    let mut orders = Vec::new();
    for first in 0..4 {
        for second in (0..4).filter(|n| *n != first) {
            for third in (0..4).filter(|n| *n != first && *n != second) {
                let fourth = 6 - first - second - third;
                orders.push([first, second, third, fourth]);
            }
        }
    }
    orders
}

/// 4 new tabs in a chain: the first names a tab, each next one names the
/// creation before it. For each of the 24 orders in which the 4 launches can
/// end, the strip has the 4 tabs in request order after the named tab. Then
/// 2 of them close, and a tab that names a closed one lands where it was.
/// The terminal tabs of one connection commit in the order of their
/// requests, so the 24 orders of the launches give one order of the commits.
/// A commit of a later request first is in the tests with a page and in
/// `a_tab_of_another_connection_commits_before_a_tab_that_still_launches`.
#[test]
fn tabs_in_a_chain_keep_the_request_order_for_each_launch_order() {
    let orders = orders();
    assert_eq!(orders.len(), 24);
    for order in orders {
        let label = order.map(|n| n.to_string()).concat();
        let (mux, pane, [a, b, c]) = strip(&format!("chain-{label}"));
        let connection = HeldConnection::new(&mux, 4);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, terminal(pane, "t2", json!({"after_creation": "t1"})));
        connection.send(3, terminal(pane, "t3", json!({"after_creation": "t2"})));
        connection.send(4, terminal(pane, "t4", json!({"after_creation": "t3"})));
        for seq in order {
            connection.release(seq);
        }
        let [first, second, third, fourth] = connection.finish([1, 2, 3, 4]);
        assert_eq!(
            tabs(&mux, pane),
            [a, first, second, third, fourth, b, c],
            "launches ended in the order {order:?}"
        );
        mux.close_surface(second).unwrap();
        mux.close_surface(fourth).unwrap();
        assert_eq!(tabs(&mux, pane), [a, first, third, b, c], "{order:?}");
        let request =
            with(Kind::Terminal.request(pane), [("place", json!({"after_creation": "t4"}))]);
        let after_closed = surface_of(&run_as(&mux, connection.client, request).unwrap());
        assert_eq!(tabs(&mux, pane), [a, first, third, after_closed, b, c], "{order:?}");
        mux.shutdown();
    }
}

/// A tab with no terminal that names a terminal creation whose launch has
/// not ended takes the slot after that creation's slot: when the launch
/// ends, the terminal's tab lands before it.
#[test]
fn a_tab_that_names_a_creation_that_still_launches_lands_after_its_tab() {
    for kind in [Kind::Conversation, Kind::Browser] {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-waits-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(
            2,
            with(
                kind.request(pane),
                [("transaction", json!("t2")), ("place", json!({"after_creation": "t1"}))],
            ),
        );
        connection.send(3, with(kind.request(pane), [("place", json!({"after_creation": "t2"}))]));
        connection.release(0);
        let [first, second, third] = connection.finish([1, 2, 3]);
        assert_eq!(tabs(&mux, pane), [a, first, second, third, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// Two tabs that name the same tab, the first with a terminal whose launch
/// has not ended: the tab of the later request is nearer to the named tab,
/// as when the two requests are applied one by one.
#[test]
fn two_tabs_after_one_tab_land_in_request_order_while_the_first_launches() {
    for kind in [Kind::Conversation, Kind::Browser] {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-same-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, with(kind.request(pane), [("place", json!({"after": a}))]));
        connection.release(0);
        let [first, second] = connection.finish([1, 2]);
        assert_eq!(tabs(&mux, pane), [a, second, first, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// The two kinds of tab with no terminal: a page of each commits when its
/// request arrives.
const PAGES: [Kind; 2] = [Kind::Conversation, Kind::Browser];

/// A page that names a creation whose terminal still launches does not wait
/// for the launch: its reply comes while the launch is held.
#[test]
fn a_placed_page_commits_while_a_launch_is_held() {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-no-wait-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, with(kind.request(pane), [("place", json!({"after_creation": "t1"}))]));
        let second = connection.surface(2);
        assert_eq!(tabs(&mux, pane), [a, second, b, c], "{kind:?}: the launch is held");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, first, second, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// A page with no `place` and no `transaction` is as it was before
/// `tab-create-place-v1`: it does not wait for a launch of its connection
/// that is held, and its tab goes to the end of the strip. The tab of the
/// terminal then takes the slot that its request took. The page's creation
/// took no slot, so the record of the active tab does not have it: the
/// terminal's tab takes the active tab from the page when it comes, as a
/// late terminal tab did before `tab-create-place-v1`.
#[test]
fn a_page_with_no_place_commits_at_the_end_while_a_launch_is_held() {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-no-place-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, kind.request(pane));
        let second = connection.surface(2);
        assert_eq!(tabs(&mux, pane), [a, b, c, second], "{kind:?}: the launch is held");
        assert_eq!(active_tab(&mux, pane), 3, "{kind:?}: the page is the active tab");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, first, b, c, second], "{kind:?}");
        assert_eq!(active_tab(&mux, pane), 1, "{kind:?}: the terminal's tab is the active tab");
        mux.shutdown();
    }
}

/// This test pins the older `after` field of `new-frontend-browser-tab`
/// with no `place`: its order is NOT that of the requests applied one by
/// one. A terminal tab with a `transaction` and no `place` still launches,
/// and its slot is at the end of the strip, right of `c`. The page lands
/// right after `c`, where `after` says, and the slot stays right of the tab
/// on its left. So the terminal's tab lands between `c` and the page, and it
/// takes the active tab: the page's creation took no slot. One by one, the
/// strip is `[a, b, c, page, terminal]` and the page stays active. A client
/// that wants that order sends `place` (the second test below).
#[test]
fn pin_of_the_older_after_field_a_late_terminal_tab_takes_the_active_tab_of_the_page() {
    let (mux, pane, [a, b, c]) = strip("chain-older-after");
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, with(Kind::Terminal.request(pane), [("transaction", json!("t1"))]));
    connection.send(2, with(Kind::Browser.request(pane), [("after", json!(c))]));
    let page = connection.surface(2);
    assert_eq!(tabs(&mux, pane), [a, b, c, page], "the launch is held");
    assert_eq!(active_tab(&mux, pane), 3, "the page is the active tab");
    connection.release(0);
    let [first] = connection.finish([1]);
    assert_eq!(tabs(&mux, pane), [a, b, c, first, page]);
    assert_eq!(active_tab(&mux, pane), 3, "the terminal's tab is the active tab");
    mux.shutdown();
}

/// This test pins the older `after` field with a `transaction` and no
/// `place`: the page lands where `after` says, as in the test above, and a
/// later page that names its creation lands right after it. The terminal's
/// tab then lands between `c` and the two pages, where one by one gives
/// `[a, b, c, page, next, terminal]`. The two pages took a slot, so the last
/// of them stays the active tab.
#[test]
fn pin_of_the_older_after_field_with_a_name_two_pages_land_right_of_a_slot_that_launches() {
    let (mux, pane, [a, b, c]) = strip("chain-older-after-named");
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, with(Kind::Terminal.request(pane), [("transaction", json!("t1"))]));
    let named = [("after", json!(c)), ("transaction", json!("p1"))];
    connection.send(2, with(Kind::Browser.request(pane), named));
    let page = connection.surface(2);
    let names = [("place", json!({"after_creation": "p1"}))];
    connection.send(3, with(Kind::Browser.request(pane), names));
    let next = connection.surface(3);
    assert_eq!(tabs(&mux, pane), [a, b, c, page, next], "the launch is held");
    assert_eq!(active_tab(&mux, pane), 4, "the last page is the active tab");
    connection.release(0);
    let [first] = connection.finish([1]);
    assert_eq!(tabs(&mux, pane), [a, b, c, first, page, next]);
    assert_eq!(active_tab(&mux, pane), 5, "the last page stays the active tab");
    mux.shutdown();
}

/// The state of the two tests above with `place: {after}` in place of the
/// older `after` field: the page takes the slot right after `c`, left of the
/// slot of the terminal tab that still launches. The strip and the active
/// tab are those of the two requests applied one by one.
#[test]
fn a_page_placed_after_the_last_tab_lands_left_of_a_slot_that_still_launches() {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-place-after-last-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, with(Kind::Terminal.request(pane), [("transaction", json!("t1"))]));
        connection.send(2, with(kind.request(pane), [("place", json!({"after": c}))]));
        let page = connection.surface(2);
        assert_eq!(tabs(&mux, pane), [a, b, c, page], "{kind:?}: the launch is held");
        assert_eq!(active_tab(&mux, pane), 3, "{kind:?}: the page is the active tab");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, b, c, page, first], "{kind:?}");
        assert_eq!(active_tab(&mux, pane), 3, "{kind:?}: the page stays the active tab");
        mux.shutdown();
    }
}

/// A `new-tab` with a `transaction` and no `pane`, on a connection: the
/// request is refused when its creation commits, after the launch step of
/// its terminal. The reply names the cause, and the strip is the same
/// before and after. This test reads the reply and the strip; it does not
/// read that the launched terminal host has ended.
#[test]
fn a_new_tab_with_a_transaction_and_no_pane_is_refused_after_its_launch_step() {
    let (mux, pane, [a, b, c]) = strip("chain-refused-no-pane");
    let connection = HeldConnection::new(&mux, 1);
    let mut request = with(Kind::Terminal.request(pane), [("transaction", json!("t1"))]);
    request.as_object_mut().expect("a request object").remove("pane");
    connection.send(1, request);
    connection.launching(0);
    assert_eq!(tabs(&mux, pane), [a, b, c], "the launch is held");
    connection.release(0);
    let reply = connection.reply(1);
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert!(reply.to_string().contains("transaction needs pane"), "{reply}");
    connection.scheduler.finish_and_wait();
    assert_eq!(tabs(&mux, pane), [a, b, c]);
    assert_eq!(active_tab(&mux, pane), 0, "`a` stays the active tab");
    mux.shutdown();
}

/// A terminal tab after `a` still launches. A page takes the slot after `a`,
/// and a second page names the tab of the first page: it stays next to that
/// tab, before the terminal's tab.
#[test]
fn a_page_after_a_page_stays_before_the_tab_that_still_launches() {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-page-page-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, with(kind.request(pane), [("place", json!({"after": a}))]));
        let second = connection.surface(2);
        connection.send(3, with(kind.request(pane), [("place", json!({"after": second}))]));
        let third = connection.surface(3);
        assert_eq!(tabs(&mux, pane), [a, second, third, b, c], "{kind:?}: the launch is held");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, second, third, first, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// A terminal tab after `a` still launches. A page names that creation, and
/// a second page names `a`: the first page stays after the terminal's tab,
/// and the second page lands before it.
#[test]
fn a_page_after_a_creation_stays_after_the_tab_that_still_launches() {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-creation-page-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, with(kind.request(pane), [("place", json!({"after_creation": "t1"}))]));
        connection.send(3, with(kind.request(pane), [("place", json!({"after": a}))]));
        let [second, third] = [connection.surface(2), connection.surface(3)];
        assert_eq!(tabs(&mux, pane), [a, third, second, b, c], "{kind:?}: the launch is held");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, third, first, second, b, c], "{kind:?}");
        mux.shutdown();
    }
}

/// A terminal tab still launches when a later request makes a page, which
/// is then the active tab. The terminal's tab comes after that: it does not
/// take the active tab, as when the two requests are applied one by one.
#[test]
fn a_tab_that_launched_late_does_not_take_the_active_tab_of_a_later_page() {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-active-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, terminal(pane, "t1", json!({"after": a})));
        connection.send(2, with(kind.request(pane), [("place", json!({"after": a}))]));
        let second = connection.surface(2);
        assert_eq!(active_tab(&mux, pane), 1, "{kind:?}: the page is the active tab");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, second, first, b, c], "{kind:?}");
        assert_eq!(active_tab(&mux, pane), 1, "{kind:?}: the page stays the active tab");
        mux.shutdown();
    }
}

/// The tab that a new terminal tab names closes while the terminal
/// launches: the new tab lands where the closed tab was.
#[test]
fn a_tab_whose_anchor_closed_while_it_launched_lands_where_the_anchor_was() {
    let (mux, pane, [a, b, c]) = strip("chain-anchor-closed");
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, terminal(pane, "t1", json!({"after": b})));
    connection.launching(0);
    mux.close_surface(b).unwrap();
    connection.release(0);
    let [first] = connection.finish([1]);
    assert_eq!(tabs(&mux, pane), [a, first, c]);
    mux.shutdown();
}

/// A move of a tab comes between the arrival of a create request and the
/// tab of that request. One by one, the new tab is after `a` and the move
/// then puts `c` between the two.
#[test]
#[ignore = "still red: the slot of a tab that launches stays right of the tab on its left, so a tab moved to that side goes after the slot (the next PR of tab-create-place removes this line)"]
fn a_tab_moved_while_a_tab_launches_lands_as_after_the_new_tab() {
    let (mux, pane, [a, b, c]) = strip("chain-move");
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, terminal(pane, "t1", json!({"after": a})));
    connection.launching(0);
    assert!(mux.move_tab(c, pane, 1));
    assert_eq!(tabs(&mux, pane), [a, c, b], "the launch is held");
    connection.release(0);
    let [first] = connection.finish([1]);
    assert_eq!(tabs(&mux, pane), [a, c, first, b]);
    mux.shutdown();
}

/// The same move as in the test above, with the strip that the daemon gives
/// today. The rule of the spec: "A `move-tab`, a select or a close between a
/// create request and its tab is applied when it arrives. The slot of the tab
/// that still launches stays right of the tab on its left." So the new tab
/// lands between `a` and the moved tab, not after the moved tab.
#[test]
fn a_tab_moved_while_a_tab_launches_lands_after_the_slot_today() {
    let (mux, pane, [a, b, c]) = strip("chain-move-today");
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, terminal(pane, "t1", json!({"after": a})));
    connection.launching(0);
    assert!(mux.move_tab(c, pane, 1));
    assert_eq!(tabs(&mux, pane), [a, c, b], "the launch is held");
    connection.release(0);
    let [first] = connection.finish([1]);
    assert_eq!(tabs(&mux, pane), [a, first, c, b]);
    mux.shutdown();
}

/// A terminal tab with the name `t1` and no `place` still launches when the
/// later request `page` makes a page: the terminal's tab then lands in the
/// slot that its request took, before the page.
fn named_tab_with_no_place_lands_before(label: &str, page: impl Fn(Kind, PaneId) -> Value) {
    for kind in PAGES {
        let (mux, pane, [a, b, c]) = strip(&format!("chain-{label}-{kind:?}"));
        let connection = HeldConnection::new(&mux, 1);
        connection.send(1, with(Kind::Terminal.request(pane), [("transaction", json!("t1"))]));
        connection.send(2, page(kind, pane));
        let second = connection.surface(2);
        assert_eq!(tabs(&mux, pane), [a, b, c, second], "{kind:?}: the launch is held");
        connection.release(0);
        let [first] = connection.finish([1]);
        assert_eq!(tabs(&mux, pane), [a, b, c, first, second], "{kind:?}");
        assert_eq!(active_tab(&mux, pane), 4, "{kind:?}: the page stays the active tab");
        mux.shutdown();
    }
}

/// A create request with a `transaction` and no `place` takes the slot at
/// the end of the strip when it arrives. A page that names the creation
/// while its terminal still launches lands after the slot: the terminal's
/// tab comes before the page, as when the two requests are applied one by
/// one.
#[test]
fn a_tab_with_a_name_and_no_place_lands_before_a_later_page_that_names_it() {
    named_tab_with_no_place_lands_before("named-end-names", |kind, pane| {
        with(kind.request(pane), [("place", json!({"after_creation": "t1"}))])
    });
}

/// As the test above, with a later page that has a name of its own and no
/// `place`: each of the two requests takes the slot at the end of the strip
/// of its arrival, so the terminal's tab comes before the page.
#[test]
fn a_tab_with_a_name_and_no_place_lands_before_a_later_page_with_a_name() {
    named_tab_with_no_place_lands_before("named-end-named", |kind, pane| {
        with(kind.request(pane), [("transaction", json!("t2"))])
    });
}

/// Two connections make a terminal tab after `a`. The launch of the first
/// request is held, so the tab of the later request commits first. Then the
/// first tab comes: the strip and the active tab are those of the two
/// requests applied one by one in the order of their arrival. (The launch of
/// the second connection is not held: the launch hook of the tests is one
/// for the daemon and gives only the number of a creation in its own
/// connection.)
#[test]
fn a_tab_of_another_connection_commits_before_a_tab_that_still_launches() {
    let (mux, pane, [a, b, c]) = strip("chain-two-connections");
    let connection = HeldConnection::new(&mux, 1);
    connection.send(1, terminal(pane, "t1", json!({"after": a})));
    connection.launching(0);
    let request = terminal(pane, "u1", json!({"after": a}));
    let second = surface_of(&run_as(&mux, connection.client + 100, request).unwrap());
    assert_eq!(tabs(&mux, pane), [a, second, b, c], "the launch is held");
    assert_eq!(active_tab(&mux, pane), 1, "the tab of the later request is active");
    connection.release(0);
    let [first] = connection.finish([1]);
    assert_eq!(tabs(&mux, pane), [a, second, first, b, c]);
    assert_eq!(active_tab(&mux, pane), 1, "the tab of the later request stays active");
    mux.shutdown();
}
