//! A daemon loop of an agent's host link that panics (`ACPMUX_TEST_PANIC_AT`, debug builds) ends
//! that link as a lost one, and the hub reaches the host again (#54378).
//!
//! Before, the reader of the host's entries or the writer of its frames died alone on a panic:
//! the prompt it carried was never answered, and every later prompt of the session waited too,
//! until the daemon restarted.

use super::*;

/// The answer to request `id` on `rpc`, read off the stream (its notifications are skipped).
async fn answer(rpc: &mut Rpc, id: i64, within: Duration) -> Option<Value> {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        let line = tokio::time::timeout(left, rpc.lines.next_line()).await.ok()?.ok()??;
        let v: Value = serde_json::from_str(&line).ok()?;
        if v.get("id") == Some(&json!(id)) {
            return Some(v);
        }
    }
}

/// A prompt whose text holds `marker` panics the daemon loop `point` names once; that prompt is
/// answered (or failed) and the session's next prompt ends its turn.
async fn a_panic_at(tag: &str, point: &str) {
    let marker = format!("loop-panic-{tag}");
    let seam = format!("{point}:{marker}");
    let daemon = Daemon::with_env(tag, "approve-all", &[("ACPMUX_TEST_PANIC_AT", &seam)]);
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let warm = client
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]}),
        )
        .await;
    assert_eq!(warm["stopReason"], "end_turn", "{warm}");

    let started = Instant::now();
    let id = client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": marker}]}),
        )
        .await;
    let reply = answer(&mut client, id, Duration::from_secs(30)).await;
    let answered_ms = started.elapsed().as_millis();
    let next = started.elapsed();
    let id = client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello again"}]}),
        )
        .await;
    let again = answer(&mut client, id, Duration::from_secs(30)).await;
    let next_ms = (started.elapsed() - next).as_millis();
    println!(
        "LOOP-PANIC point={point:?} answered={} answered_ms={answered_ms} next_turn={} next_ms={next_ms}",
        reply.is_some(),
        again.as_ref().map_or(Value::Null, |v| v["result"]["stopReason"].clone()),
    );
    assert!(reply.is_some(), "the prompt the {point} panicked on was never answered");
    let again = again.expect("the next prompt was never answered");
    assert_eq!(again["result"]["stopReason"], "end_turn", "{again}");
}

#[tokio::test]
async fn a_host_reader_that_panics_reaches_its_host_again() {
    a_panic_at("rdpanic", "agent reader").await;
}

#[tokio::test]
async fn a_host_link_writer_that_panics_reaches_its_host_again() {
    a_panic_at("wrpanic", "link writer").await;
}
