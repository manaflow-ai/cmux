//! The order the event log writer writes sessions in while requests wait on it
//! (`hub/request_writes.rs`, `LogWriter::expedite`, `LogWriter::settle`).
//!
//! Fleet job 7bc67123c95ede759d91350d (cmux20, 80 chats streaming, load 36-48, swap 5-7 GB): with
//! the newest waiting session moved to the front of the writer's turn, an early request was passed
//! by every later one. At 80 clients a queue edit waited 20.4-20.5 s at p99 in each of three rounds
//! (the 20 s phase: it waited until the other clients stopped), and a rename or a queue removal
//! waited 237-523 ms at p99 against 2.0-2.4 ms with no wait. The rules:
//! - waiters are served in batches, in arrival order: a request that arrives while a batch is
//!   written goes in the next batch, never ahead of one that waited before it;
//! - between two batches the writer writes one background session, so streaming chats and a
//!   shutdown flush are never starved by a steady stream of requests;
//! - while a request waits, the writer thread runs at the request's QoS (priority inheritance,
//!   `cmux_threads::OwnerBoost`), and at its own Utility QoS when no request waits.
//!
//! The order tests drive the writer's state directly, as its thread does (`State::next`, then the
//! write takes the session's queued lines): no thread and no timing.

use super::*;

/// Queues one line for each of `ids`, in that order (the writer's background turn order).
fn queued(ids: &[&str]) -> State {
    let mut state = State::default();
    for (seq, id) in ids.iter().enumerate() {
        state.queue(id, b"{}\n", seq as u64 + 1);
    }
    state
}

/// The writer's next write: the session it picks, its queued lines taken as the thread takes them.
fn write(state: &mut State) -> Option<String> {
    let id = state.next()?;
    state.queued.remove(&id);
    Some(id)
}

/// Every write until nothing is queued.
fn drain(state: &mut State) -> Vec<String> {
    std::iter::from_fn(|| write(state)).collect()
}

#[test]
fn an_early_waiter_is_written_before_later_waiters() {
    let mut state = queued(&["s0", "s1", "s2", "s3"]);
    // Requests wait on s3, then s2, then s1, in that order.
    for id in ["s3", "s2", "s1"] {
        state.wait_first(id);
    }
    assert_eq!(
        drain(&mut state),
        ["s3", "s2", "s1", "s0"],
        "waiters were not written in the order they arrived"
    );
}

#[test]
fn a_waiter_arriving_during_a_batch_goes_in_the_next_batch() {
    let mut state = queued(&["s0", "s1", "s2", "s3"]);
    state.wait_first("s3");
    state.wait_first("s2");
    // The batch [s3, s2] starts; a request on s1 arrives while s3 is written.
    assert_eq!(write(&mut state).as_deref(), Some("s3"));
    state.wait_first("s1");
    let rest = drain(&mut state);
    let at = |id: &str| rest.iter().position(|w| w == id).unwrap();
    assert!(at("s2") < at("s1"), "a later waiter passed an earlier one: s3 then {rest:?}");
}

#[test]
fn background_writes_go_on_while_requests_keep_arriving() {
    let mut state = queued(&["background"]);
    let mut written = Vec::new();
    // A new request on a new chat arrives before every write, without end.
    for i in 0..8 {
        let id = format!("request-{i}");
        state.queue(&id, b"{}\n", 1);
        state.wait_first(&id);
        written.extend(write(&mut state));
    }
    assert!(
        written.iter().take(3).any(|w| w == "background"),
        "a streaming chat's lines waited behind every request: {written:?}"
    );
}

/// The bench's shape (review of 69d858ce9764, finding 1): every chat streams (a line after each
/// write), the same chats are waited for on every cycle, and one chat is never waited for. A chat
/// written in a batch kept its entry in the background turn's list and its next line added another,
/// so the list grew by about the batch size each cycle and the chat that is never waited for was
/// not written again. With one entry per chat it is written, but only once every chat had a
/// background turn too: a batch write must count as the chat's turn.
#[test]
fn chats_waited_for_on_every_cycle_never_starve_a_streaming_chat() {
    let waited = ["r0", "r1", "r2", "r3"];
    let chats = waited.len() + 1;
    let mut state = queued(&["background"]);
    let mut since_background = 0;
    let mut longest_gap = 0;
    for cycle in 0..50u64 {
        for id in waited {
            state.queue(id, b"{}\n", cycle + 2);
            state.wait_first(id);
        }
        for _ in 0..chats {
            match write(&mut state).as_deref() {
                Some("background") => since_background = 0,
                Some(_) => since_background += 1,
                None => {}
            }
            longest_gap = longest_gap.max(since_background);
            // Every chat streams its next line while the write goes on.
            for id in waited.iter().chain(&["background"]) {
                state.queue(id, b"{}\n", cycle + 2);
            }
        }
        assert!(
            state.order.len() <= chats,
            "cycle {cycle}: the background turn lists {} entries for {chats} chats",
            state.order.len()
        );
    }
    assert!(
        longest_gap <= waited.len(),
        "the chat that is never waited for waited {longest_gap} writes (a batch is {})",
        waited.len()
    );
}

#[test]
fn a_waiter_whose_lines_are_being_written_and_who_queued_more_waits_for_the_next_batch() {
    let mut state = queued(&["s0", "s1"]);
    // s1's first line is being written (taken by the writer); then s1 queues another and a
    // request waits for it.
    state.wait_first("s1");
    assert_eq!(write(&mut state).as_deref(), Some("s1"));
    state.queue("s1", b"{}\n", 3);
    state.wait_first("s1");
    let rest = drain(&mut state);
    assert!(rest.contains(&"s1".to_owned()), "s1's later line was never written: {rest:?}");
}

/// `forget` drops a session's queued lines, waits for a write of it in progress, then stops
/// counting its lines (a `settle` of it waits no more). A line appended while it waits must not be
/// counted as written while it is still queued: the writer would write it later, into the folder
/// the caller deletes, and a waiter would have been told it was on disk before it was.
#[test]
fn a_line_appended_while_forget_waits_is_never_counted_before_it_is_written() {
    let mut state = queued(&["s"]);
    // The writer takes s's first line and writes it.
    let id = state.next().unwrap();
    let first = state.queued.remove(&id).unwrap();
    state.writing = Some(id);
    state.writing_ticket = first.ticket;
    // forget begins and waits for that write; a line is appended meanwhile.
    state.drop_queued("s");
    state.queue("s", b"{}\n", 2);
    let appended = state.tickets;
    // The write ends (as `run` records it); forget ends.
    state.writing = None;
    if let Some(done) = state.done.get_mut("s") {
        *done = (*done).max(first.ticket);
    }
    state.forgotten("s");
    assert!(
        !(state.written("s", appended) && state.pending("s").is_some()),
        "a queued line of a forgotten session is counted as written"
    );
    assert_eq!(state.next(), None, "the writer still writes a forgotten session's line");
}

/// A request that waits on the writer raises it to the request's QoS while it waits
/// (`cmux_threads::OwnerBoost`): the writer runs at Utility, and under CPU load a Utility thread
/// waits behind every Default thread while the person's request waits on it.
#[test]
fn a_waiting_request_raises_the_writer_to_its_qos() {
    let root = std::env::temp_dir().join(format!(
        "acpmux-write-order-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    crate::config::private_state_dir(&root).unwrap();
    // Each write is held, so the writer is still writing when the request waits.
    let writer = Arc::new(LogWriter::start_with_write_delay(
        root.clone(),
        1 << 20,
        8,
        &crate::supervised::embedded(),
        Some(std::time::Duration::from_millis(200)),
    ));
    writer.append("background", b"{}\n".to_vec(), 1).unwrap();
    writer.append("chat", b"{}\n".to_vec(), 1).unwrap();
    // The waiter: a thread at the class a request runs at.
    let w = writer.clone();
    std::thread::spawn(move || {
        cmux_threads::register_current("request", cmux_threads::ThreadQos::UserInitiated);
        w.settle("chat");
    })
    .join()
    .unwrap();
    let counts = writer.boost_counts();
    #[cfg(target_vendor = "apple")]
    assert!(counts.started >= 1, "the writer was not raised while a request waited: {counts:?}");
    // Linux lowers the writer's nice value only where the process may (root, RLIMIT_NICE).
    #[cfg(not(target_vendor = "apple"))]
    assert!(counts.started + counts.refused >= 1, "no raise was tried: {counts:?}");
    drop(writer);
    let _ = std::fs::remove_dir_all(&root);
}
