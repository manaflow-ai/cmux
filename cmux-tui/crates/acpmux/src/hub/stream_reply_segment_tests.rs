use super::StreamState;

/// Text between turns never takes an id an earlier run of such text had, however many turns
/// come between them (cmux#48659: `-.<boot>.1` named two replies an hour apart).
#[test]
fn replies_with_no_turn_never_reuse_a_segment() {
    let mut st = StreamState::default();
    let first = st.reply_segment_for(None, Some("msg_a"), "b");
    assert_eq!(first, "-.b.1");
    assert_eq!(st.reply_segment_for(None, Some("msg_a"), "b"), first, "one message, one segment");
    assert_eq!(st.reply_segment_for(Some("t1"), Some("msg_b"), "b"), "t1.b.1");
    assert_eq!(st.reply_segment_for(Some("t1"), Some("msg_c"), "b"), "t1.b.2");
    let later = st.reply_segment_for(None, Some("msg_d"), "b");
    assert_eq!(later, "-.b.2");
    assert_ne!(later, first);
    assert_eq!(
        st.reply_segment_for(Some("t2"), Some("msg_e"), "b"),
        "t2.b.1",
        "a turn counts from 1"
    );
    assert_eq!(st.reply_segment_for(None, Some("msg_f"), "b"), "-.b.3");
}

/// A cut (`reply_segment` cleared) starts a new segment of the same message.
#[test]
fn a_cut_starts_a_new_segment_of_the_same_message() {
    let mut st = StreamState::default();
    assert_eq!(st.reply_segment_for(None, Some("msg_a"), "b"), "-.b.1");
    st.reply_segment = None;
    assert_eq!(st.reply_segment_for(None, Some("msg_a"), "b"), "-.b.2");
}
