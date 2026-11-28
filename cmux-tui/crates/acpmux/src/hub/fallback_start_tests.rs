use super::*;

#[test]
fn the_turn_error_names_the_fallback_that_could_not_start() {
    let e = RpcError::new(-32603, "agent process closed");
    let mut out = fallback_not_started(&e, "claude", "cmux", "the local CodeRouter is not running");
    // The message stays the agent's own until the turn ends, so it still reads as a dead
    // process (`recovery::dead_process`), whose stderr line `finish_turn` adds.
    assert_eq!(out.message, "agent process closed");
    assert!(crate::recovery::dead_process(&out));
    assert_eq!(out.data.as_ref().unwrap()[NOTE_KEY]["profile"], "cmux");
    say_fallback(&mut out);
    assert!(out.message.starts_with("agent process closed"), "{}", out.message);
    assert!(out.message.contains("cmux cannot start"), "{}", out.message);
    assert!(out.message.contains("CodeRouter is not running"), "{}", out.message);
    assert!(out.message.contains("stays on claude"), "{}", out.message);
    // Data the error had stays.
    let e = e.with_data(json!({"reason": "limit"}));
    let out = fallback_not_started(&e, "claude", "cmux", "down");
    let data = out.data.unwrap();
    assert_eq!(data["reason"], "limit");
    assert_eq!(data[NOTE_KEY]["error"], "down");
    // An error no fallback marked keeps its message.
    let mut plain = RpcError::new(-32603, "agent process closed");
    say_fallback(&mut plain);
    assert_eq!(plain.message, "agent process closed");
}
