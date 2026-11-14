use super::*;
use cmux_json::JsonSet as _;

/// A steer answered before it was written (held, or refused) moves nothing; one written moves
/// work only from then on, while its answer is still to come.
#[tokio::test]
async fn work_moves_only_once_the_steer_is_written() {
    let moved = std::sync::atomic::AtomicBool::new(false);
    let mover = || async { moved.store(true, Ordering::SeqCst) };
    let written = tokio::sync::Notify::new();
    let held = async {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        "held"
    };
    assert_eq!(answer_once_written(&written, held, mover()).await, "held");
    assert!(!moved.load(Ordering::SeqCst), "a steer never written moved work");

    let (tx, rx) = tokio::sync::oneshot::channel::<&str>();
    let answer = async {
        written.notify_one();
        tokio::task::yield_now().await;
        assert!(moved.load(Ordering::SeqCst), "the written steer moved nothing");
        rx.await.unwrap()
    };
    tx.send("read").unwrap();
    assert_eq!(answer_once_written(&written, answer, mover()).await, "read");
}

#[test]
fn the_wait_comes_from_the_env_and_zero_turns_it_off() {
    assert_eq!(after_of(None), Some(AUTO_BACKGROUND_AFTER));
    assert_eq!(after_of(Some("")), Some(AUTO_BACKGROUND_AFTER));
    assert_eq!(after_of(Some("90")), Some(std::time::Duration::from_secs(90)));
    assert_eq!(after_of(Some("0")), None);
    assert_eq!(after_of(Some("soon")), Some(AUTO_BACKGROUND_AFTER));
}

#[test]
fn a_declared_timeout_is_read_in_milliseconds() {
    let call = |input: Value| json!({"rawInput": input});
    assert_eq!(declared_timeout(&call(json!({"command": "x"}))), None);
    assert_eq!(
        declared_timeout(&call(json!({"command": "x", "timeout": 600000}))),
        Some(std::time::Duration::from_secs(600))
    );
    assert_eq!(
        declared_timeout(&call(json!({"command": "x", "timeout": 1500.0}))),
        Some(std::time::Duration::from_millis(1500))
    );
    assert_eq!(declared_timeout(&call(json!({"command": "x", "timeout": "soon"}))), None);
}

#[test]
fn only_a_new_foreground_shell_arms_it() {
    let call = |input: Value| {
        json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "kind": "execute",
                "status": "in_progress", "rawInput": input})
    };
    assert_eq!(foreground_shell(&call(json!({"command": "make"}))), Some("t1"));
    assert_eq!(
        foreground_shell(&call(json!({"command": "make", "run_in_background": false}))),
        Some("t1")
    );
    assert_eq!(
        foreground_shell(&call(json!({"command": "npm run dev", "run_in_background": true}))),
        None
    );
    // Announced before its input streamed: no command yet, nothing to time.
    assert_eq!(foreground_shell(&call(json!({}))), None);
    let mut read = call(json!({"command": "x"}));
    read.set("kind", json!("read"));
    assert_eq!(foreground_shell(&read), None);
    // A call named early gets its command in the update that follows.
    let mut update = call(json!({"command": "make"}));
    update.set("sessionUpdate", json!("tool_call_update"));
    assert_eq!(foreground_shell(&update), Some("t1"));
    update.set("status", json!("completed"));
    assert_eq!(foreground_shell(&update), None);
}
