use super::*;

#[test]
fn a_row_notice_quoting_a_tag_is_not_a_second_delivery() {
    let tag = crate::agent::tag(3, 7, 0, 1_000);
    let event = json!({"jsonrpc": "2.0", "method": "_acpmux/event", "params": {"record": {"msg":
        {"method": "session/update", "params": {"update": {"sessionUpdate": "tool_call", "title": tag}}}}}});
    let row = json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": {"row":
        {"preview": tag, "toolTitle": tag, "planStep": tag}}});
    let n: usize = [event.to_string(), row.to_string()].iter().map(|l| stream_tags(l).len()).sum();
    assert_eq!(n, 1);
}
