//! The reply/event order rule (spec/transports.md "Reply and event order"):
//! control replies and control events share one FIFO, so a reply is written
//! after every event its request emitted, whatever other streams have queued.

use super::*;

const FLOOD_STREAMS: u64 = 8;
const FLOOD_ITEMS: usize = 32;

fn position(messages: &[Value], matches: impl Fn(&Value) -> bool) -> usize {
    messages.iter().position(matches).expect("the message was written")
}

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

/// Runs `request` on a subscribed connection under a stream flood and
/// returns the written lines with the index of its `echo` event and of its
/// reply. The test acts as the socket writer while the flood stays full: it
/// pops one line at a time and refills the flood stream it came from, until
/// the subscription has handed `echo` to the writer (the admit-time emit of
/// p05-ipc-120 makes that true before the reply; here the test waits for it).
fn run_under_flood(mux: &Arc<Mux>, request: Value, echo: &str) -> (Vec<Value>, usize, usize) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    handle_command(mux, client, json_command(json!({"cmd": "subscribe"})), &writer).unwrap();
    let flood = flood(&writer);

    let data = handle_command(mux, client, json_command(request), &writer).unwrap();
    let needle = format!("\"event\":\"{echo}\"");
    let is_echo = |line: &str| line.contains(&needle);
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut written = Vec::new();
    while !written.iter().any(|line: &String| is_echo(line))
        && !outbound.wait_until_queued(is_echo, Duration::ZERO)
    {
        assert!(Instant::now() < deadline, "the request emitted no {echo}");
        let Some(line) = outbound.try_pop() else { continue };
        let message: Value = serde_json::from_str(&line).unwrap();
        if let Some(surface) = message["flood"].as_u64() {
            writer
                .send_stream(
                    &json!({"event": "output", "flood": surface}),
                    &flood[surface as usize],
                )
                .unwrap();
        }
        written.push(line);
    }
    let enqueued_at = written.len();
    writer.send_control(&json!({"id": 7, "ok": true, "data": data})).unwrap();
    written.extend(std::iter::from_fn(|| outbound.try_pop()));

    let written =
        written.iter().map(|line| serde_json::from_str(line).unwrap()).collect::<Vec<Value>>();
    let echo_at = position(&written, |message| message["event"] == echo);
    let reply = position(&written, |message| message["id"] == 7);
    assert!(
        written[enqueued_at..reply].iter().all(|message| message.get("flood").is_none()),
        "a control reply waited behind stream output"
    );
    (written, echo_at, reply)
}

#[test]
fn reply_event_order_new_tab_under_stream_flood_writes_its_tree_event_before_reply() {
    let mux = test_mux();
    let workspace = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(workspace)).unwrap();
    let (_, echo, reply) =
        run_under_flood(&mux, json!({"cmd": "new-tab", "pane": pane}), "tree-changed");
    assert!(echo < reply, "the reply overtook its tree-changed: {echo} >= {reply}");
}

#[test]
fn reply_event_order_split_ratio_under_stream_flood_writes_layout_changed_before_reply() {
    let mux = test_mux();
    let workspace = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(workspace).unwrap());
    mux.split(pane, SplitDir::Right, None).unwrap();
    let listed =
        handle_command(&mux, mux.local_test_client(0), Command::ListWorkspaces, &test_writer())
            .unwrap();
    let split = listed["workspaces"][0]["screens"][0]["layout"]["split"].as_u64().unwrap();
    let (_, echo, reply) = run_under_flood(
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
