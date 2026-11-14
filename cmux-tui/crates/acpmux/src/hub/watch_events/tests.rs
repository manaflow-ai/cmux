use super::*;

fn chunk(text: &str, ids: usize) -> Value {
    let mut msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}});
    // Short id fields that, read first, would fill the stub before its text.
    for n in 0..ids {
        msg[format!("field{n:03}Id")] = json!("i".repeat(200));
    }
    msg
}

/// A `match` at the longest a watch takes, split across two long reply chunks that both come
/// as stubs, is still found: each stub keeps at least the pattern's length of its text's ends,
/// before any field (review of #40800: a 5000-char pattern across an 80 KB chunk was lost).
#[test]
fn a_longest_match_across_two_stubbed_chunks_is_found() {
    let pattern = format!("{}{}", "a".repeat(1500), "b".repeat(crate::hub::MAX_MATCH_BYTES - 1500));
    let first = format!("{}{}", "x".repeat(80 * 1024), "a".repeat(1500));
    let second =
        format!("{}{}", "b".repeat(crate::hub::MAX_MATCH_BYTES - 1500), "y".repeat(80 * 1024));
    let mut c = Cursor::default();
    for text in [&first, &second] {
        let stub = super::super::paging::stub_msg(&chunk(text, 60), 90 * 1024, Some(&pattern));
        let omitted = &stub["_meta"]["acpmux"]["omitted"];
        assert_eq!(omitted["matched"], false, "neither chunk holds it alone");
        c.stub_text(omitted, Some(&pattern));
    }
    assert!(c.matched, "the match across the two chunks was lost");
}
