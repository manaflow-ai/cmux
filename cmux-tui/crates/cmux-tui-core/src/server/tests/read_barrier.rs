//! #32408: a `list-workspaces` reply names how many lines its connection had written when the
//! command read the tree (`lines_written_before_read`). The connection writes events from another
//! thread than the reply, so an event emitted after the read can reach the socket before the
//! reply; a client that took every line before the reply as part of the snapshot dropped it (a
//! workspace stayed with no screens in the app's store).

use super::*;

#[test]
fn a_tree_reply_names_the_lines_written_before_its_read() {
    let mux = test_mux();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    // Three lines reach the socket before the request; one more is queued, not yet written.
    for index in 0..3 {
        writer.send_control(&json!({"event": "written", "index": index})).unwrap();
        assert!(outbound.try_pop().is_some());
    }
    writer.send_control(&json!({"event": "queued"})).unwrap();
    let request = json!({"id": 7, "cmd": "list-workspaces"});
    assert!(handle_connection_frame(
        &mux,
        client,
        ClientTransport::Unix,
        &request.to_string(),
        &writer,
        &scheduler
    ));
    // The command may answer from a worker thread: wait for its reply without taking a line (taking
    // one while the command runs would change what it reads).
    let deadline = Instant::now() + Duration::from_secs(10);
    while outbound.state.lock().unwrap().control.len() < 2 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut reply = None;
    while let Some(line) = outbound.try_pop() {
        let value: Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 7 {
            reply = Some(value);
        }
    }
    let reply = reply.expect("list-workspaces answered within 10 s");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(
        reply["data"]["lines_written_before_read"],
        json!(3),
        "the reply must name the lines written before the tree read, not those queued: {reply}"
    );
}
