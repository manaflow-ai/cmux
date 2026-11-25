use super::{PREVIEW_BYTES, end_state, reply_text};

#[test]
fn a_reply_is_the_turns_text_without_a_cut_head() {
    assert_eq!(reply_text("  done.  "), Some("done.".to_owned()));
    assert_eq!(reply_text(" "), None);
    // A cut preview (1997 to 2000 bytes) loses its first, maybe cut, word.
    let cut = format!("tail-of-a-cut-word {}", "x".repeat(PREVIEW_BYTES - 22));
    assert_eq!(cut.len(), PREVIEW_BYTES - 3);
    let reply = reply_text(&cut).unwrap();
    assert!(reply.starts_with("…x") && !reply.contains("tail-of"), "{reply}");
    // One cut word: only that something was said.
    assert_eq!(reply_text(&"é".repeat(PREVIEW_BYTES / 2)).as_deref(), Some("…"));
    // Below the cut: whole.
    let short = format!("a {}", "é".repeat(900));
    assert_eq!(reply_text(&short).as_deref(), Some(short.as_str()));
}

#[test]
fn a_turn_end_is_done_failed_or_cancelled() {
    assert_eq!(end_state(Some("completed")), "done");
    assert_eq!(end_state(Some("cancelled")), "cancelled");
    assert_eq!(end_state(Some("failed")), "failed");
    assert_eq!(end_state(None), "failed");
}
