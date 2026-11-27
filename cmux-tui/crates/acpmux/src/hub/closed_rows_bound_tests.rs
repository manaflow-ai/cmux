use super::*;

fn row(i: usize) -> Value {
    json!({"sessionId": format!("s{i}"), "timeBreakdown": {"spans": "x".repeat(900)}})
}

/// However many closed chats are read, the bytes kept stay under the bound, the
/// one just stored and the ones read since stay, and a form let go reads as not current.
#[test]
fn closed_rows_keep_at_most_their_bound() {
    const CAP: usize = 64 << 10;
    let mut rows = ClosedRows::with_cap(CAP);
    let stamp = (SummaryStamp::default(), 0);
    for i in 0..5_000 {
        rows.store(format!("s{i}"), i % 2 == 0, stamp, &row(i));
        if i >= 1 {
            // A chat read now and then stays kept however many go by.
            assert!(rows.current("s1", false, stamp.0, 0).is_some(), "s1 at {i}");
        }
        let (forms, bytes) = rows.kept();
        assert!(bytes <= CAP, "{bytes} kept at {i}");
        assert!(forms <= CAP / 900, "{forms} forms at {i}");
        assert!(rows.current(&format!("s{i}"), i % 2 == 0, stamp.0, 0).is_some());
    }
    assert!(rows.current("s3", false, stamp.0, 0).is_none(), "an old form is let go");
    assert!(rows.entries.len() < 5_000 / 10, "{} entries", rows.entries.len());
    for i in 0..5_000 {
        rows.remove(&format!("s{i}"));
    }
    assert_eq!(rows.kept(), (0, 0));
    assert!(rows.entries.is_empty());
}
