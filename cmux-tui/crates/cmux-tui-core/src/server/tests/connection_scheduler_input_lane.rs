//! Input precedence on a connection's surface scheduler: a
//! person's input runs before other surfaces' queued requests, one surface's
//! requests keep their order, and a long read runs on the mux's work lane
//! instead of the connection's control sequence or a thread of its own.

use super::*;
use crate::panic_free::RecoverPoison;
use cmux_threads::work::Lane;
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Instant;

fn request(line: Value) -> Request {
    serde_json::from_value(line).expect("test request parses")
}

fn queued(admission: &Arc<ServerSurfaceOperationAdmission>, line: Value) -> SequencedItem {
    SequencedItem::Request(PendingSurfaceRequest {
        request: request(line),
        arrival: RequestArrival::now(),
        cause: crate::event_cause::EventCause::Program,
        frame_call: None,
        retained_bytes: 0,
        _bytes_permit: admission.try_reserve_bytes(0).unwrap(),
        stream_barrier: None,
    })
}

/// The ids in the order the control sequence takes them, with no worker running.
fn drain_order(lines: Vec<Value>) -> Vec<u64> {
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let mut state = ConnectionSurfaceState::default();
    for line in lines {
        state.requests.push_back(queued(&admission, line));
    }
    let mut order = Vec::new();
    while let Some(index) = ConnectionSurfaceScheduler::next_runnable_index(&state) {
        let Some(SequencedItem::Request(pending)) = state.requests.remove(index) else {
            panic!("only requests are queued");
        };
        order.push(pending.request.id.unwrap().as_u64().unwrap());
    }
    assert!(state.requests.is_empty(), "requests left unrunnable: {}", state.requests.len());
    order
}

fn send(id: u64, surface: u64) -> Value {
    json!({"id": id, "cmd": "send", "surface": surface, "text": "x"})
}

fn read_screen(id: u64, surface: u64) -> Value {
    json!({"id": id, "cmd": "read-screen", "surface": surface})
}

fn read_scrollback(id: u64, surface: u64) -> Value {
    json!({"id": id, "cmd": "read-scrollback", "surface": surface, "start": 0, "count": 100})
}

#[test]
fn input_runs_before_other_surfaces_queued_reads() {
    assert_eq!(drain_order(vec![read_screen(1, 1), read_scrollback(2, 1), send(3, 2)]), [3, 1, 2]);
}

#[test]
fn two_sends_around_a_resize_keep_their_order() {
    let resize = json!({"id": 3, "cmd": "resize-surface", "surface": 2, "cols": 90, "rows": 30});
    assert_eq!(drain_order(vec![read_screen(1, 1), send(2, 2), resize, send(4, 2)]), [2, 1, 3, 4]);
}

#[test]
fn input_keeps_its_order_and_never_passes_a_request_without_a_surface() {
    let list = json!({"id": 3, "cmd": "list-workspaces"});
    assert_eq!(
        drain_order(vec![read_screen(1, 1), send(2, 2), list, send(4, 3), send(5, 2)]),
        [2, 1, 3, 4, 5]
    );
}

#[test]
fn a_send_without_a_surface_does_not_jump_the_queue() {
    let unnamed = json!({"id": 2, "cmd": "send", "text": "focused"});
    assert_eq!(drain_order(vec![read_screen(1, 1), unnamed]), [1, 2]);
}

#[test]
fn a_running_long_read_holds_its_surface_and_lets_other_input_run() {
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let mut state = ConnectionSurfaceState::default();
    state.active_read_surfaces.insert(1);
    for line in [send(1, 1), read_screen(2, 2), send(3, 3)] {
        state.requests.push_back(queued(&admission, line));
    }
    assert_eq!(ConnectionSurfaceScheduler::next_runnable_index(&state), Some(2));
    state.requests.remove(2);
    assert_eq!(
        ConnectionSurfaceScheduler::next_runnable_index(&state),
        None,
        "a non-input request ran beside a long read, or input passed its own surface's read"
    );
}

#[test]
fn a_barrier_overtaker_does_not_pass_a_request_that_could_run() {
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let mut state = ConnectionSurfaceState::default();
    state.active_clear_surfaces.insert(1);
    let clear = json!({"id": 2, "cmd": "clear-history", "surface": 3});
    for line in [read_screen(1, 2), clear] {
        state.requests.push_back(queued(&admission, line));
    }
    assert_eq!(ConnectionSurfaceScheduler::next_runnable_index(&state), None);
}

#[test]
fn long_reads_run_on_the_work_lane() {
    for line in [
        read_scrollback(1, 1),
        json!({"id": 1, "cmd": "copy", "surface": 1, "mode": "scrollback"}),
        json!({"id": 1, "cmd": "vt-state", "surface": 1}),
    ] {
        assert!(request(line).cmd.is_long_read());
    }
    for line in [read_screen(1, 1), json!({"id": 1, "cmd": "copy", "surface": 1, "mode": "screen"})]
    {
        assert!(!request(line).cmd.is_long_read());
    }
}

/// Holds `surface`'s terminal lock on a helper thread until the returned
/// sender is dropped, so a read of it stays in flight.
fn hold_terminal(surface: &Arc<crate::Surface>) -> (mpsc::Sender<()>, JoinHandle<()>) {
    let (locked_tx, locked_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let holder = surface.clone();
    let handle = std::thread::spawn(move || {
        holder.with_terminal(|_| {
            locked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        });
    });
    locked_rx.recv().expect("terminal lock held");
    (release_tx, handle)
}

/// Waits until the control sequence has taken every queued request.
fn until_control_took_all(scheduler: &ConnectionSurfaceScheduler) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !scheduler.state.lock().recover_poison().requests.is_empty() {
        assert!(Instant::now() < deadline, "the control sequence never took the long read");
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// Surface A's long read `read` is in flight (taken by the control sequence while
/// A's terminal lock is held) when a Send for A and a Send for B arrive: B's
/// Send answers first, then the read, then A's Send.
fn another_surfaces_send_answers_first(read: impl FnOnce(SurfaceId) -> Value) {
    let mux = test_mux();
    let a = mux.new_workspace(None, Some((80, 24))).unwrap();
    let b = mux.new_workspace(None, Some((80, 24))).unwrap();
    a.with_terminal(|term| {
        for line in 0..2_000 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
    });
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let dispatch = |line: Value| {
        let mut pending = Some(request(line));
        assert_eq!(
            scheduler.dispatch(mux.clone(), client, &mut pending, 0, writer.clone()),
            Some(true)
        );
    };

    let (release, holder) = hold_terminal(&a);
    dispatch(read(a.id));
    until_control_took_all(&scheduler);
    dispatch(json!({"id": 2, "cmd": "send", "surface": a.id, "text": "same"}));
    dispatch(json!({"id": 3, "cmd": "send", "surface": b.id, "text": "other"}));
    let first = pop_json(&outbound);
    let early = outbound.try_pop();
    drop(release);
    holder.join().unwrap();
    let rest = [pop_json(&outbound), pop_json(&outbound)];
    let drained = scheduler.close_and_wait(Duration::from_secs(2));
    mux.close_surface(a.id).unwrap();
    mux.close_surface(b.id).unwrap();

    assert_eq!(first["id"], 3, "another surface's send waited behind the long read: {first}");
    assert_eq!(first["ok"], true);
    assert!(early.is_none(), "a reply came while the read held its surface: {early:?}");
    assert_eq!([rest[0]["id"].as_u64(), rest[1]["id"].as_u64()], [Some(1), Some(2)]);
    assert!(rest[0].get("error").is_none(), "{}", rest[0]);
    assert!(drained);
}

#[test]
fn another_surfaces_send_answers_before_a_long_read_in_flight() {
    another_surfaces_send_answers_first(
        |surface| json!({"id": 1, "cmd": "read-scrollback", "surface": surface, "start": 0, "count": 2_000}),
    );
}

#[test]
fn another_surfaces_send_answers_before_a_vt_state_in_flight() {
    another_surfaces_send_answers_first(
        |surface| json!({"id": 1, "cmd": "vt-state", "surface": surface}),
    );
}

#[test]
fn long_reads_run_as_work_lane_items_without_request_threads() {
    const SURFACES: u64 = 4;
    const READS_PER_SURFACE: u64 = 4;
    const READS: u64 = SURFACES * READS_PER_SURFACE;
    let mux = test_mux();
    let surfaces =
        (0..SURFACES).map(|_| mux.new_workspace(None, Some((80, 24))).unwrap()).collect::<Vec<_>>();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let posted = |mux: &Mux| {
        mux.work.stats().into_iter().find(|lane| lane.lane == Lane::Cpu).unwrap().posted
    };
    let before = posted(&mux);
    let workers_before = mux.sequenced_pool.workers_started();

    // Reads of every surface interleave: one surface's reads keep their order,
    // reads of different surfaces may run at once.
    for id in 0..READS {
        let surface = surfaces[(id % SURFACES) as usize].id;
        let mut pending = Some(request(read_scrollback(id, surface)));
        assert_eq!(
            scheduler.dispatch(mux.clone(), client, &mut pending, 0, writer.clone()),
            Some(true)
        );
    }
    let replies = (0..READS).map(|_| pop_json(&outbound)).collect::<Vec<_>>();
    let posted = posted(&mux) - before;
    let workers = mux.sequenced_pool.workers_started() - workers_before;
    let drained = scheduler.close_and_wait(Duration::from_secs(2));
    for surface in &surfaces {
        mux.close_surface(surface.id).unwrap();
    }

    for reply in &replies {
        assert_eq!(reply["ok"], true, "{reply}");
    }
    for surface in 0..SURFACES {
        let ids = replies
            .iter()
            .map(|reply| reply["id"].as_u64().unwrap())
            .filter(|id| id % SURFACES == surface)
            .collect::<Vec<_>>();
        let expected = (0..READS_PER_SURFACE).map(|n| n * SURFACES + surface).collect::<Vec<_>>();
        assert_eq!(ids, expected, "one surface's reads answered out of order");
    }
    assert_eq!(posted, READS, "{posted} Cpu-lane items for {READS} long reads");
    assert!(workers < READS, "{workers} pool workers started for {READS} long reads");
    assert!(drained);
}
