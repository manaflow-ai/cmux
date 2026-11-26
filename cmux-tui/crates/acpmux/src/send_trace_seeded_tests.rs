//! Seeded secrets on the wire (cmux_egress::capture) through the start-trace poster: the trace id
//! rides only in the spans path and the spans (a machine id) only in the body.
//! tests/egress_seeded.json names this test for `acpmux::send_trace`.

use super::*;

#[test]
fn seeded_trace_rides_only_in_the_path_and_spans_only_in_the_body() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let trace_id = "5eed0000000000000000000000c0ffee";
    let machine = "vm_seededmachine00000001";
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(post(trace_id.to_owned(), json!({"machine": machine})));
    assert!(!cmux_egress::capture::requests().is_empty(), "the post reached the capture server");
    let places = cmux_egress::capture::leaks(trace_id);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": target")), "{places:?}");
    let places = cmux_egress::capture::leaks(machine);
    assert!(!places.is_empty());
    assert!(places.iter().all(|p| p.ends_with(": body")), "{places:?}");
}
