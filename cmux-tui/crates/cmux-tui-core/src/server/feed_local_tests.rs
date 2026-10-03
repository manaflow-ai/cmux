//! Wire tests for the local feed owner commands (`feed-local-owner-v1`).

use super::super::*;

/// Run `request` as a trusted local (Unix) client, or as client 0 (not
/// registered, so not trusted) when `local` is false.
fn run_as(mux: &Arc<Mux>, local: bool, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let client =
        if local { mux.control_clients.register(ClientTransport::Unix, writer.clone()) } else { 0 };
    let mut request = request;
    request["id"] = json!(7);
    let request: Request = serde_json::from_str(&request.to_string())?;
    handle_command(mux, client, request.cmd, &writer)
}

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    run_as(mux, true, request)
}

#[test]
fn capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"feed-local-owner-v1"));
}

#[test]
fn handoff_commands_list_move_and_refuse_reads() {
    let mux = Mux::new_for_test("feed-local-wire", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, None).unwrap();
    run(&mux, json!({"cmd":"notify","title":"done","body":"","surface":surface.id})).unwrap();
    let listed = run(&mux, json!({"cmd":"feed-local-list"})).unwrap();
    let item = listed["items"][0]["id"].as_str().unwrap().to_string();
    assert_eq!(listed["items"][0]["state"], "open");

    let begin = json!({"cmd":"feed-local-handoff-begin","item":item});
    let remote = run_as(&mux, false, begin.clone()).unwrap_err();
    assert!(remote.to_string().contains("trusted local connection"), "{remote}");
    let begun = run(&mux, begin).unwrap();
    assert_eq!(begun["item"]["state"], "handing_off");
    let queue = run(&mux, json!({"cmd":"feed-local-list","state":"handing_off"})).unwrap();
    assert_eq!(queue["items"].as_array().unwrap().len(), 1);
    let open = run(&mux, json!({"cmd":"feed-local-list","state":"open"})).unwrap();
    assert!(open["items"].as_array().unwrap().is_empty());

    let done = json!({"cmd":"feed-local-handoff-done","item":item,"home":"cloud"});
    let moved = run(&mux, done.clone()).unwrap();
    assert_eq!(moved["item"]["state"], "moved");
    assert_eq!(moved["item"]["home"], "cloud");
    assert_eq!(run(&mux, done).unwrap(), moved, "a repeated done is idempotent");

    let error = run(&mux, json!({"cmd":"feed-local-read","items":[item]})).unwrap_err();
    assert_eq!(response_error_code(&error).as_deref(), Some("owner.unreachable"));
    let ack = run(&mux, json!({"cmd":"ack-tab-notifications","surface":surface.id})).unwrap();
    assert_eq!(ack["refused"][0]["code"], "owner.unreachable");
    assert_eq!(ack["refused"][0]["retryable"], true);
    let missing = run(&mux, json!({"cmd":"feed-local-handoff-begin","item":"nope"})).unwrap_err();
    assert_eq!(response_error_code(&missing).as_deref(), Some("not_found"));
}
