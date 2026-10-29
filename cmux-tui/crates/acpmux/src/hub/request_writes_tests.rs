//! What a request wrote is noted on its own task only (`cargo test -p acpmux request_writes`).

use super::*;

#[tokio::test]
async fn request_writes_notes_the_last_record_of_each_log_on_its_task() {
    let ((), writes) = scope(Box::pin(async {
        note_log("a", 3);
        note_log("a", 7);
        note_log("b", 1);
        note_config();
        // Another task's writes are not this request's.
        tokio::spawn(async { note_log("c", 9) }).await.unwrap();
    }))
    .await;
    assert_eq!(writes.logs.get("a"), Some(&7));
    assert_eq!(writes.logs.get("b"), Some(&1));
    assert_eq!(writes.logs.get("c"), None);
    assert!(writes.config);
}

#[test]
fn request_writes_outside_a_request_notes_nothing() {
    note_log("a", 1);
    note_config();
}
