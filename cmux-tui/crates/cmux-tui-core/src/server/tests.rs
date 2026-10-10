//! Unit tests for the control protocol server (server.rs and its child
//! modules): shared imports and fixtures here, tests by family in
//! `tests/<family>.rs`.

use super::*;
use crate::JournalSensitivity;
use crate::{BrowserFrame, BrowserStatus, SurfaceOptions};
use std::time::Duration;

/// A test socket directory: a short directory under the canonical
/// `/tmp` from the shared helper, so socket paths fit sun_path whatever
/// `$TMPDIR` is (cmux_unix_socket::short_test_dir).
struct TestSocketDir(cmux_unix_socket::TestDir);

impl TestSocketDir {
    fn create(name: &str) -> Self {
        Self(cmux_unix_socket::short_test_dir(&format!("cts-{name}")))
    }

    fn path(&self) -> &Path {
        self.0.path()
    }
}

pub(super) fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("test", SurfaceOptions::default())
}

fn test_writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

pub(super) fn captured_writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

fn pop_json(outbound: &BoundedOutbound) -> Value {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(message) = outbound.try_pop() {
            return serde_json::from_str(&message).expect("outbound JSON");
        }
        assert!(Instant::now() < deadline, "timed out waiting for outbound JSON");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn resource_request(
    id: &str,
    operation: &str,
    params: Value,
    idempotency_key: Option<&str>,
) -> String {
    let mut request = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    });
    if let Some(idempotency_key) = idempotency_key {
        request["idempotency_key"] = json!(idempotency_key);
    }
    serde_json::to_string(&request).unwrap()
}

fn run_json_command(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &test_writer())
}

mod detach_and_browser;
mod event_shape_tests;
mod identify_and_protocol;
mod outbound_and_scheduler;
mod resource_attach;
mod session_streams;
mod socket_and_render;
mod wire_commands;

fn journal_subscription_filter(max_sensitivity: JournalSensitivity, mut filter: Value) -> Value {
    filter
        .as_object_mut()
        .expect("journal subscription filter fixture is an object")
        .insert("max_sensitivity".into(), json!(max_sensitivity));
    filter
}
