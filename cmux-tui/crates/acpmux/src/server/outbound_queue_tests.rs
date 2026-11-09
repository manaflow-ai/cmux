use super::{Message, enqueue_after_controls, enqueue_outbound};
use serde_json::json;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

#[tokio::test]
async fn a_slow_reader_gets_a_gap_signal_without_losing_a_response() {
    let (out, mut queued) = mpsc::channel(3);
    out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
    let dropped = Arc::new(AtomicU64::new(0));
    let gap_pending = Arc::new(AtomicBool::new(false));
    let pending_controls = Arc::new(AtomicUsize::new(0));
    let lock = Arc::new(Mutex::new(()));

    enqueue_outbound(
        &out,
        Message::notification("session/update", json!({"kind": "progress"})).to_line(),
        false,
        &dropped,
        &gap_pending,
        &lock,
        &pending_controls,
    );
    enqueue_outbound(
        &out,
        Message::ok(json!(7), json!({"status": "complete"})).to_line(),
        true,
        &dropped,
        &gap_pending,
        &lock,
        &pending_controls,
    );

    assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
    let gap = Message::parse(&queued.recv().await.unwrap()).unwrap();
    let Message::Notification { method, params } = gap else { panic!("{gap:?}") };
    assert_eq!(method, "_acpmux/lagged");
    let params = params.unwrap();
    assert_eq!(params["reason"], "output_queue_full");
    assert_eq!(params["dropped"], 1);
    let response = Message::parse(&queued.recv().await.unwrap()).unwrap();
    assert!(matches!(response, Message::Response { id, .. } if id == json!(7)));
}

#[tokio::test]
async fn a_full_queue_delivers_its_gap_after_the_reader_catches_up() {
    let (out, mut queued) = mpsc::channel(1);
    out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
    let dropped = Arc::new(AtomicU64::new(0));
    let gap_pending = Arc::new(AtomicBool::new(false));
    let pending_controls = Arc::new(AtomicUsize::new(0));
    let lock = Arc::new(Mutex::new(()));

    enqueue_outbound(
        &out,
        Message::notification("session/update", json!({"kind": "progress"})).to_line(),
        false,
        &dropped,
        &gap_pending,
        &lock,
        &pending_controls,
    );
    assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
    let gap = Message::parse(&queued.recv().await.unwrap()).unwrap();
    assert!(matches!(gap, Message::Notification { method, .. } if method == "_acpmux/lagged"));
}

/// Review of #26784 at 0a57249: a watch answer that waited for room in a full queue (in a
/// task of its own) could be passed by the GitHub request sent after it, which the Mac then
/// refused. That request now waits for no such answer: it is refused until none is left.
#[tokio::test]
async fn a_request_in_order_never_passes_an_answer_waiting_for_room() {
    let (out, mut queued) = mpsc::channel(1);
    out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
    let dropped = Arc::new(AtomicU64::new(0));
    let gap_pending = Arc::new(AtomicBool::new(false));
    let pending_controls = Arc::new(AtomicUsize::new(0));
    let lock = Arc::new(Mutex::new(()));
    let answer = Message::ok(json!(7), json!({"sessions": []})).to_line();
    enqueue_outbound(&out, answer, true, &dropped, &gap_pending, &lock, &pending_controls);
    let request =
        || Message::request(json!("acpmux-0"), "_acpmux/github_action", json!({})).to_line();

    // The reader takes a line; the answer still waits for room in its task. The request is
    // refused, and queues nothing.
    assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
    let sent =
        enqueue_after_controls(&out, request(), &dropped, &gap_pending, &lock, &pending_controls);
    assert!(!sent, "nothing goes ahead of an answer that waits for room");
    let first = Message::parse(&queued.recv().await.unwrap()).unwrap();
    assert!(matches!(first, Message::Response { id, .. } if id == json!(7)));
    // The answer is in the queue, so the request is sent after it.
    while pending_controls.load(std::sync::atomic::Ordering::Acquire) != 0 {
        tokio::task::yield_now().await;
    }
    assert!(enqueue_after_controls(
        &out,
        request(),
        &dropped,
        &gap_pending,
        &lock,
        &pending_controls
    ));
    let next = Message::parse(&queued.recv().await.unwrap()).unwrap();
    assert!(matches!(next, Message::Request { .. }));
}

/// Review of #26784 at d0b90b0: a request to a client whose reader was gone counted as sent,
/// and its action waited out the whole wait before failing.
#[test]
fn a_request_in_order_to_a_reader_that_is_gone_is_not_sent() {
    let (out, queued) = mpsc::channel(4);
    drop(queued);
    let (dropped, gap_pending) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicBool::new(false)));
    let (pending, lock) = (Arc::new(AtomicUsize::new(0)), Arc::new(Mutex::new(())));
    let request = Message::request(json!("acpmux-0"), "_acpmux/github_action", json!({}));
    let sent =
        enqueue_after_controls(&out, request.to_line(), &dropped, &gap_pending, &lock, &pending);
    assert!(!sent);
}
