//! The reply/event order rule (spec/transports.md "Reply and event order").
//!
//! The `*_under_stream_flood_*` tests run a request through the server's
//! request path (`handle_message`: the command runs, then its reply is
//! enqueued at once, as the connection loop does). The request emits its
//! event before it returns, but the subscription thread moves that event from
//! the subscriber mailbox to the writer later, so today the reply is written
//! first. They stay red, and ignored, until p05-ipc-120 emits a request's
//! events into the writer before its reply is enqueued; run them with
//! `cargo test -p cmux-tui-core --lib reply_event_order -- --include-ignored`.
//! The other tests check the writer's FIFOs alone.

use super::*;

const FLOOD_STREAMS: u64 = 8;
const FLOOD_ITEMS: usize = 32;
const REPLY_ID: u64 = 7;

/// Fills `FLOOD_STREAMS` attach-like streams with queued output.
fn flood(writer: &MessageWriter) -> Vec<OutboundStream> {
    (0..FLOOD_STREAMS)
        .map(|surface| {
            let stream = writer.start_stream(&attach_overflow_json(1_000 + surface)).unwrap();
            for sequence in 0..FLOOD_ITEMS {
                writer
                    .send_stream(
                        &json!({"event": "output", "flood": surface, "n": sequence}),
                        &stream,
                    )
                    .unwrap();
            }
            stream
        })
        .collect()
}

/// Runs `request` on a subscribed connection under a stream flood, through
/// the server's request path, and returns the write positions of its first
/// `echo` event and of its reply. The test is the socket writer: it pops one
/// line at a time and refills the flood stream the line came from, so the
/// flood stays full until both lines are written.
fn run_under_flood(mux: &Arc<Mux>, mut request: Value, echo: &str) -> (usize, usize) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    assert!(handle_message(
        mux,
        client,
        &json!({"id": 1, "cmd": "subscribe"}).to_string(),
        &writer
    ));
    let flood = flood(&writer);

    request["id"] = json!(REPLY_ID);
    assert!(handle_message(mux, client, &request.to_string(), &writer));
    let deadline = Instant::now() + Duration::from_secs(10);
    let (mut echo_at, mut reply_at) = (None, None);
    let mut position = 0;
    while echo_at.is_none() || reply_at.is_none() {
        assert!(Instant::now() < deadline, "the request wrote no {echo} or no reply");
        let Some(line) = outbound.try_pop() else { continue };
        let message: Value = serde_json::from_str(&line).unwrap();
        if let Some(surface) = message["flood"].as_u64() {
            writer
                .send_stream(
                    &json!({"event": "output", "flood": surface}),
                    &flood[surface as usize],
                )
                .unwrap();
        } else if message["event"] == echo {
            echo_at.get_or_insert(position);
        } else if message["id"] == REPLY_ID {
            assert_eq!(message["ok"], true, "{message}");
            reply_at = Some(position);
        }
        position += 1;
    }
    (echo_at.unwrap(), reply_at.unwrap())
}

/// new-tab changes the tree, not a screen's split layout: its echo is
/// `tree-changed` (the request emits no `layout-changed`; set-split-ratio
/// below is the `layout-changed` case).
#[test]
#[ignore = "red until p05-ipc-120: the subscriber mailbox hop writes the reply first"]
fn reply_event_order_new_tab_under_stream_flood_writes_its_tree_event_before_reply() {
    let mux = test_mux();
    let workspace = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(workspace)).unwrap();
    let (echo, reply) =
        run_under_flood(&mux, json!({"cmd": "new-tab", "pane": pane}), "tree-changed");
    assert!(echo < reply, "the reply overtook its tree-changed: {echo} >= {reply}");
}

#[test]
#[ignore = "red until p05-ipc-120: the subscriber mailbox hop writes the reply first"]
fn reply_event_order_split_ratio_under_stream_flood_writes_layout_changed_before_reply() {
    let mux = test_mux();
    let workspace = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(workspace).unwrap());
    mux.split(pane, SplitDir::Right, None).unwrap();
    let listed =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap();
    let split = listed["workspaces"][0]["screens"][0]["layout"]["split"].as_u64().unwrap();
    let (echo, reply) = run_under_flood(
        &mux,
        json!({"cmd": "set-split-ratio", "split": split, "ratio": 0.7}),
        "layout-changed",
    );
    assert!(echo < reply, "the reply overtook its layout-changed: {echo} >= {reply}");
}

#[test]
fn reply_event_order_flood_streams_keep_their_own_fifo() {
    let mux = test_mux();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(&mux, client, json_command(json!({"cmd": "subscribe"})), &writer).unwrap();
    let _flood = flood(&writer);
    writer.send_control(&json!({"id": 1, "ok": true})).unwrap();

    let written = drain_json(&outbound);
    for surface in 0..FLOOD_STREAMS {
        let order = written
            .iter()
            .filter(|message| message["flood"] == surface)
            .map(|message| message["n"].as_u64().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(order, (0..FLOOD_ITEMS as u64).collect::<Vec<_>>(), "stream {surface}");
    }
}

/// The writer half of the rule: a control event enqueued before a reply is
/// written before it, whatever other streams have queued.
#[test]
fn reply_event_order_control_events_and_replies_keep_emit_order() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let events = writer.start_control_stream(&subscription_overflow_json()).unwrap();
    let _flood = flood(&writer);
    for n in 0..4 {
        writer.send_stream(&json!({"event": "tree-changed", "n": n}), &events).unwrap();
        writer.send_control(&json!({"id": n, "ok": true})).unwrap();
    }

    let written = drain_json(&outbound);
    let control = written
        .iter()
        .take(8)
        .map(|message| match message.get("event") {
            Some(_) => format!("e{}", message["n"]),
            None => format!("r{}", message["id"]),
        })
        .collect::<Vec<_>>();
    assert_eq!(control, ["e0", "r0", "e1", "r1", "e2", "r2", "e3", "r3"]);
    assert!(written[8..].iter().all(|message| message.get("flood").is_some()));
}

/// The control FIFO's priority is bounded: a subscription that never empties
/// still leaves the writer time for an attach stream, which therefore never
/// reaches its budget and overflows. The control FIFO keeps its own order.
#[test]
fn reply_event_order_a_refilled_control_stream_does_not_starve_an_attach_stream() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let events = writer.start_control_stream(&subscription_overflow_json()).unwrap();
    let attach = writer.start_stream(&attach_overflow_json(1_000)).unwrap();
    let mut next_event = 0_u64;
    let mut send_event = || {
        writer.send_stream(&json!({"event": "tree-changed", "n": next_event}), &events).unwrap();
        next_event += 1;
    };
    for _ in 0..OUTBOUND_CAPACITY {
        send_event();
    }

    // One attach item per 16 writes: well under the writer's share for
    // regular items, but its whole budget within 16 * OUTBOUND_CAPACITY
    // writes if the control FIFO always went first.
    let (mut sent, mut written, mut last_event) = (0_u64, 0_u64, None);
    for pop in 0..OUTBOUND_CAPACITY * 32 {
        if pop % 16 == 0 {
            writer
                .send_stream(&json!({"event": "output", "n": sent}), &attach)
                .expect("the attach stream overflowed behind the subscription");
            sent += 1;
        }
        let message: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        match message["event"].as_str() {
            Some("output") => {
                assert_eq!(message["n"], written, "the attach stream kept its FIFO");
                written += 1;
            }
            Some("tree-changed") => {
                let n = message["n"].as_u64().unwrap();
                assert!(
                    last_event.is_none_or(|last| n == last + 1),
                    "the control FIFO kept its order"
                );
                last_event = Some(n);
                send_event();
            }
            other => panic!("unexpected line {other:?}: {message}"),
        }
    }
    assert!(sent - written <= 1, "attach output waited behind the subscription: {written}/{sent}");
}

#[test]
fn reply_event_order_control_stream_overflow_purges_only_its_items() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let events = writer.start_control_stream(&subscription_overflow_json()).unwrap();
    let _flood = flood(&writer);
    writer.send_stream(&json!({"event": "tree-changed"}), &events).unwrap();
    writer.send_control(&json!({"id": 1, "ok": true})).unwrap();
    for _ in 1..OUTBOUND_CAPACITY {
        writer.send_stream(&json!({"event": "tree-changed"}), &events).unwrap();
    }
    let error = writer.send_stream(&json!({"event": "tree-changed"}), &events).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);

    let written = drain_json(&outbound);
    assert_eq!(written[0]["id"], 1, "the reply survives its stream's overflow");
    assert_eq!(written[1]["event"], "overflow");
    assert!(written.iter().all(|message| message["event"] != "tree-changed"));
    let flood_items = written.iter().filter(|message| message.get("flood").is_some()).count();
    assert_eq!(flood_items, FLOOD_STREAMS as usize * FLOOD_ITEMS);
    assert!(writer.is_open());
}

#[test]
fn reply_event_order_control_stream_items_do_not_spend_the_control_reserve() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let events = writer.start_control_stream(&subscription_overflow_json()).unwrap();
    for n in 0..OUTBOUND_CAPACITY - 1 {
        writer.send_stream(&json!({"event": "tree-changed", "n": n}), &events).unwrap();
    }
    for id in 0..OUTBOUND_CONTROL_RESERVE {
        writer.send_control(&json!({"id": id, "ok": true})).unwrap();
    }

    let written = drain_json(&outbound);
    assert_eq!(written.len(), OUTBOUND_CAPACITY - 1 + OUTBOUND_CONTROL_RESERVE);
    assert!(writer.is_open());
}
