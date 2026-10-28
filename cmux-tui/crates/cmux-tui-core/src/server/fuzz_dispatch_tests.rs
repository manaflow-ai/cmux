//! `dispatch` reports what the connection does: a framed command routes to
//! its `Command`, a header the table refuses closes with its reason, and a
//! line reaches the decode its head names.

use cmux_ipc::{CallAux, CallFlags, MethodTables, PriorityHint};

use super::{Command, Framed, Line, dispatch};

fn call(name: &str) -> CallAux {
    let tables = MethodTables::schema();
    let method = tables.v12_id(name).and_then(|id| tables.method(id)).expect("a framed method");
    CallAux {
        request_id: 7,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::empty(),
    }
}

fn command(name: &str) -> u16 {
    Command::method_of_wire(name).expect("a command").0
}

#[test]
fn framed_command_routes_to_its_command() {
    let dispatched = dispatch(call("ping"), br#"{"id":1,"cmd":"ping"}"#);
    assert_eq!(dispatched.frame, Ok(Framed::Command { method: command("ping") }));
    assert_eq!(dispatched.head.cmd.as_deref(), Some("ping"));
    assert_eq!(dispatched.head.command, Some(command("ping")));
    assert_eq!(dispatched.line, Some(Line::Command { method: command("ping") }));
}

#[test]
fn header_the_table_refuses_closes_with_its_reason() {
    let body = br#"{"id":1,"cmd":"ping"}"#;
    let wrong_priority = CallAux { priority: PriorityHint::Background, ..call("ping") };
    assert_eq!(dispatch(wrong_priority, body).frame, Err("priority_mismatch"));
    let unknown = CallAux { method_id: 0xFFFF, ..call("ping") };
    assert_eq!(dispatch(unknown, body).frame, Err("unknown_method"));
    let fds = CallAux { flags: CallFlags::FDS, ..call("ping") };
    assert_eq!(dispatch(fds, body).frame, Err("flags_refused"));
    let other = dispatch(call("identify"), body);
    assert_eq!(other.frame, Err("method_mismatch"));
    assert_eq!(other.line, Some(Line::Command { method: command("ping") }));
}

#[test]
fn body_that_is_not_utf8_has_no_line() {
    let dispatched = dispatch(call("ping"), b"{\"cmd\":\"\xff\"}");
    assert!(dispatched.frame.is_err());
    assert_eq!(dispatched.line, None);
}

#[test]
fn protocol_line_reaches_the_resource_envelope() {
    let line = br#"{"protocol":"cmux.protocol/2","type":"request","id":"r1","operation":"workspace.list","params":{"machine":"local","session":"s"}}"#;
    let dispatched = dispatch(call("ping"), line);
    assert_eq!(dispatched.frame, Err("method_mismatch"));
    assert!(dispatched.head.protocol);
    assert_eq!(dispatched.head.operation.as_deref(), Some("workspace.list"));
    assert!(matches!(
        dispatched.line,
        Some(Line::Resource { operation: Some("workspace.list"), .. })
    ));
}

#[test]
fn line_whose_command_parse_fails_is_refused() {
    let dispatched = dispatch(call("ping"), br#"{"id":1,"cmd":"no-such-command"}"#);
    assert_eq!(dispatched.frame, Err("method_mismatch"));
    assert_eq!(dispatched.head.command, None);
    assert_eq!(dispatched.line, Some(Line::Refused));
}

/// The array form serde also reads a struct from is no request line: the
/// header's method must not accept it (the dispatch_structured crasher
/// `regress-crash-array-body`).
#[test]
fn body_that_is_not_an_object_never_names_the_method() {
    for body in [&br#"["ping"]"#[..], br#"["ping",false]"#, b" \n[\"ping\"]"] {
        let dispatched = dispatch(call("ping"), body);
        let shown = String::from_utf8_lossy(body);
        assert_eq!(dispatched.frame, Err("method_mismatch"), "{shown}");
        assert_eq!(dispatched.head.command, None, "{shown}");
    }
}

/// A numeric `cmd` names no command in the head, so its line is refused
/// rather than run as the command at that index (the dispatch_structured
/// crasher `regress-crash-numeric-cmd`).
#[test]
fn line_whose_cmd_is_a_number_is_refused() {
    let body = format!(r#"{{"id":1,"cmd":{}}}"#, command("ping"));
    let dispatched = dispatch(call("ping"), body.as_bytes());
    assert_eq!(dispatched.frame, Err("method_mismatch"));
    assert_eq!(dispatched.head.command, None);
    assert_eq!(dispatched.line, Some(Line::Refused));
}
