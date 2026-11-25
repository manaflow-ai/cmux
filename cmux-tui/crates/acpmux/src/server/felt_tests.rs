use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::time_ack;

fn acked_count() -> u64 {
    cmux_felt::snapshot()["metrics"]["prompt_send_to_ack"]["since_start"]["count"]
        .as_u64()
        .unwrap_or(0)
}

#[test]
fn an_accepted_prompt_records_its_ack_and_still_calls_the_next() {
    let seen = Arc::new(Mutex::new(None));
    let sink = Arc::clone(&seen);
    let next: super::OnAccepted =
        Some(Box::new(move |v: Value| *sink.lock().unwrap_or_else(|e| e.into_inner()) = Some(v)));
    let before = acked_count();
    let started = Instant::now() - Duration::from_millis(5);
    let call = time_ack(started, next);
    if let Some(call) = call {
        call(json!({"promptId": "p"}));
    }
    assert!(acked_count() > before, "the ack was not recorded");
    assert_eq!(seen.lock().unwrap_or_else(|e| e.into_inner()).as_ref().unwrap()["promptId"], "p");
}
