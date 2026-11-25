use super::*;

#[test]
fn a_link_failure_is_read_from_the_links_own_words() {
    let timed_out = |m| matches!(link_failure("hb", m), Some(LinkFailure::TimedOut));
    let lost = |m| matches!(link_failure("hb", m), Some(LinkFailure::Lost));
    assert!(timed_out("peer hb timed out after 30s"));
    assert!(timed_out("peer hb timed out"));
    assert!(lost("peer hb connection closed"));
    assert!(lost("peer hb dropped the request"));
    // The peer's own answer, or another peer's words, is not the link's.
    assert!(link_failure("hb", "session not found: abc").is_none());
    assert!(link_failure("hb", "peer hbx timed out after 3s").is_none());
    assert!(link_failure("hbx", "peer hb timed out after 3s").is_none());
}
