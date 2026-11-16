//! Creations of one connection that name each other (`place.after_creation`,
//! `tab-create-place-v1`) while their terminals still launch. The launches
//! end in each possible order; the pane's strip has the order that the
//! requests asked for, because the creations of a connection commit in
//! request order.

use super::super::tests::captured_writer;
use super::super::*;
use super::tab_create_place_tests::{Kind, run_as, strip, surface_of, tabs, with};
use std::sync::mpsc;

/// A safety bound of each wait on a signal; no test passes by it.
const WAIT: Duration = Duration::from_secs(30);

/// One connection whose creations end their launch when the test says.
pub(super) struct HeldConnection {
    mux: Arc<Mux>,
    pub(super) client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    gates: Vec<mpsc::Sender<()>>,
    ended: mpsc::Receiver<u64>,
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
        let (ended_tx, ended) = mpsc::channel();
        let ended_tx = Mutex::new(ended_tx);
        mux.set_creation_launch_hook_for_test(move |seq, job_ended| {
            if job_ended {
                let _ = ended_tx.lock().unwrap().send(seq);
            } else if let Some(wait) = usize::try_from(seq).ok().and_then(|seq| waits.get(seq)) {
                let _ = wait.lock().unwrap().recv_timeout(WAIT);
            }
        });
        Self { mux: mux.clone(), client, writer, outbound, scheduler, gates, ended }
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

    /// The replies that the connection has now, by request id.
    pub(super) fn replies(&self) -> HashMap<u64, Value> {
        std::iter::from_fn(|| self.outbound.try_pop())
            .map(|line| serde_json::from_str::<Value>(&line).unwrap())
            .filter_map(|reply| Some((reply.get("id")?.as_u64()?, reply)))
            .collect()
    }

    /// Waits for all work of the connection, then gives the surface that
    /// each request of `ids` made.
    pub(super) fn finish<const N: usize>(&self, ids: [u64; N]) -> [SurfaceId; N] {
        self.scheduler.finish_and_wait();
        let replies = self.replies();
        ids.map(|id| {
            let reply = replies.get(&id).unwrap_or_else(|| panic!("no reply to request {id}"));
            assert_ne!(reply["ok"], json!(false), "{reply}");
            surface_of(&reply["data"])
        })
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
/// not ended waits for it: it lands after that creation's tab, not before
/// the tab exists.
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
/// as when the two commit in request order.
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
