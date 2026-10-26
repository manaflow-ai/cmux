//! The request head: one parse that borrows `cmd` and `operation`, skips
//! every other member, and never refuses a member's type.

use std::borrow::Cow;

use super::super::Command;
use super::super::command_names::MethodClass;
use super::super::request_spans::RequestMethod;
use super::RequestHead;

#[test]
fn request_head_borrows_cmd_from_the_line() {
    let line = r#"{"id":7,"cmd":"agent-inventory","params":{"cmd":"ping"}}"#;
    let head = RequestHead::parse(line);
    assert!(matches!(head.cmd, Some(Cow::Borrowed("agent-inventory"))), "{head:?}");
    assert_eq!(head.id, Some(serde_json::json!(7)));
    assert!(!head.is_command(), "a nested `cmd` names nothing");
    assert!(!head.is_resource());
}

#[test]
fn request_head_decodes_an_escaped_cmd() {
    let head = RequestHead::parse(r#"{"cmd":"ping"}"#);
    assert_eq!(head.cmd(), Some("ping"));
    assert!(head.is_command());
    let (id, class) = Command::method_of_wire("ping").expect("ping is a command");
    assert_eq!(head.method(), RequestMethod { id, class });
}

#[test]
fn request_head_takes_any_member_type() {
    let head = RequestHead::parse(r#"{"id":[1,{"a":2}],"cmd":42,"operation":{"x":1}}"#);
    assert_eq!(head.cmd(), None);
    assert_eq!(head.operation(), None);
    assert!(!head.is_command(), "a parsed line whose cmd is no string is not a command");
    assert_eq!(head.method(), RequestMethod::routed(None));
}

#[test]
fn request_head_of_a_line_that_is_no_object_leaves_it_to_the_command_parse() {
    for line in ["", "not json", "[1,2]", "\"ping\"", r#"{"cmd":"ping"} trailing"#] {
        let head = RequestHead::parse(line);
        assert!(head.is_command(), "{line:?}");
        assert!(!head.is_resource(), "{line:?}");
        assert_eq!(head.cmd(), None, "{line:?}");
        assert_eq!(head.method().class, MethodClass::Other, "{line:?}");
    }
}

#[test]
fn request_head_marks_a_protocol_line_whatever_its_value() {
    for protocol in [r#""cmux.protocol/2""#, "null", "2", "{}"] {
        let line =
            format!(r#"{{"protocol":{protocol},"type":"request","operation":"session.ping"}}"#);
        let head = RequestHead::parse(&line);
        assert!(head.is_resource(), "{line}");
        assert_eq!(head.operation(), Some("session.ping"));
    }
}

#[test]
fn request_head_keeps_the_last_of_a_repeated_member() {
    let head = RequestHead::parse(r#"{"cmd":"ping","cmd":"apps-list"}"#);
    assert_eq!(head.cmd(), Some("apps-list"), "as the Value parse of the routes does");
}
