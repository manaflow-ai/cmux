use super::*;

#[test]
fn replies_and_notes_are_told_apart() {
    assert!(is_reply(r#"{"id":3,"jsonrpc":"2.0","result":{"events":[{"msg":{"method":"x"}}]}}"#));
    assert!(is_reply(r#"{"jsonrpc":"2.0","id":3,"error":{"code":1}}"#));
    assert!(!is_reply(r#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"result":1}}"#));
    assert!(!is_reply(r#"{"method":"session/update","params":{"update":{"error":"x"}}}"#));
}
