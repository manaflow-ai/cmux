//! The frame path parses a request line into a `Value` at most once, and the
//! hooks that share that parse answer as their own parse did.
use super::super::*;
use super::{LineValue, parses_for_test};

fn writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

/// One line through the connection's own frame path: its reply and the
/// `LineValue` parses it took.
fn send(mux: &Arc<Mux>, client: u64, line: &str) -> (Value, u64) {
    let (writer, outbound) = writer();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let transport = mux.control_clients.transport_of(client).unwrap();
    let before = parses_for_test();
    handle_connection_frame(mux, client, transport, line, &writer, &scheduler);
    let parses = parses_for_test() - before;
    (serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap(), parses)
}

#[test]
fn a_request_line_is_parsed_into_a_value_once_on_the_frame_path() {
    let mux = Mux::new_for_test("line-value", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer().0);
    let (reply, parses) = send(&mux, client, r#"{"id":1,"cmd":"ping"}"#);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(parses, 1, "a legacy line: one parse for every hook");
    let v2 = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "line-value-1",
        "operation": "session.ping", "params": {"machine": "current", "session": "current"},
    });
    let (reply, parses) = send(&mux, client, &v2.to_string());
    assert_eq!(reply["id"], json!("line-value-1"), "{reply}");
    assert_eq!(parses, 1, "a v2 line: one parse besides its typed envelope");
    // A malformed v2 line (an unknown member) is still told apart from a
    // legacy line by the shared parse.
    let malformed = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "line-value-2",
        "operation": "session.ping", "params": {"machine": "current", "session": "current"}, "stray": true,
    });
    let (reply, parses) = send(&mux, client, &malformed.to_string());
    assert_eq!(reply["id"], json!("line-value-2"), "{reply}");
    assert_eq!(parses, 1);
}

#[test]
fn the_shared_parse_answers_as_each_hook_parsed_on_its_own() {
    let lines = [
        r#"{"id":1,"cmd":"ping"}"#,
        r#"{"protocol":"cmux.protocol/2","type":"request","id":"a","operation":"session.ping","params":{"machine":"current","session":"current"}}"#,
        r#"{"protocol":"cmux.protocol/2","stray":1}"#,
        r#"{"protocol":null}"#,
        r#"["protocol"]"#,
        r#"{"cmd":"cloud.repo.list","id":3}"#,
        r#"{"cmd":"cloud.repo.list","protocol":"cmux.protocol/2"}"#,
        r#"{"cmd":"\u0063loud.repo.sync"}"#,
        r#"{"cmd":7}"#,
        "not json",
        r#"{"cmd":"ping"} trailing"#,
    ];
    for text in lines {
        let line = LineValue::new(text);
        let shared = crate::resource_router::parse_resource_line_given(text, || line.value());
        let own = crate::resource_router::parse_resource_line(text);
        assert_eq!(
            shared.as_ref().map(|parsed| parsed
                .as_ref()
                .map(|envelope| envelope.id.clone())
                .map_err(Clone::clone)),
            own.as_ref().map(|parsed| parsed
                .as_ref()
                .map(|envelope| envelope.id.clone())
                .map_err(Clone::clone)),
            "resource probe of {text}"
        );
        assert_eq!(
            line.value().and_then(crate::cloud_repos::frame_command_of),
            crate::cloud_repos::frame_command(text),
            "cloud repo frame of {text}"
        );
        let own_cmd = serde_json::from_str::<Value>(text)
            .ok()
            .and_then(|value| value.get("cmd").and_then(Value::as_str).map(str::to_owned));
        assert_eq!(line.cmd().map(str::to_owned), own_cmd, "cmd of {text}");
    }
}
