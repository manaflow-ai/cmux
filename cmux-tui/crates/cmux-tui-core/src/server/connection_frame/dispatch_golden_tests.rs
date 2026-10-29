//! Byte-identical replies: every line in
//! spec/fixtures/line-dispatch/replies.json gets, through the whole frame
//! path, exactly the reply text recorded there. The fixture was recorded on
//! the dispatch before single-parse routing (the ordered sniffer chain, the
//! page router tried after a catalog refusal), so a routing change that
//! answers any line differently fails here.
//!
//! `CMUX_LINE_DISPATCH_RECORD=<path>` writes the replies of the fixture's
//! lines to `<path>` instead of comparing them.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::handle_connection_frame;
use crate::server::tests::{captured_writer, test_mux};
use crate::server::*;

const FIXTURE: &str = include_str!("../../../../../spec/fixtures/line-dispatch/replies.json");

#[derive(Deserialize, Serialize)]
struct Fixture {
    recorded_on: String,
    cases: Vec<Case>,
}

#[derive(Deserialize, Serialize)]
struct Case {
    line: String,
    replies: Vec<String>,
}

/// The reply texts of `line` on a fresh trusted local connection of `mux`.
fn replies(mux: &Arc<Mux>, line: &str) -> Vec<String> {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    handle_connection_frame(mux, client, ClientTransport::Unix, line, &writer, &scheduler);
    scheduler.finish_and_wait();
    std::iter::from_fn(|| outbound.try_pop()).collect()
}

#[test]
fn connection_frame_replies_match_the_recorded_dispatch() {
    let fixture: Fixture = serde_json::from_str(FIXTURE).expect("replies.json");
    let mux = test_mux();
    let observed: Vec<Case> = fixture
        .cases
        .iter()
        .map(|case| Case { line: case.line.clone(), replies: replies(&mux, &case.line) })
        .collect();
    if let Ok(path) = std::env::var("CMUX_LINE_DISPATCH_RECORD") {
        let recorded = Fixture { recorded_on: fixture.recorded_on, cases: observed };
        let text = serde_json::to_string_pretty(&recorded).expect("fixture JSON");
        std::fs::write(&path, text + "\n").expect("write the recorded fixture");
        return;
    }
    for (case, seen) in fixture.cases.iter().zip(&observed) {
        assert_eq!(seen.replies, case.replies, "replies to {}", case.line);
    }
}
