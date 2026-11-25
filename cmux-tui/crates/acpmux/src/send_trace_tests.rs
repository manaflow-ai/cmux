use super::*;

fn pending(received_ms: u64, handed: Option<(u64, bool)>) -> Pending {
    Pending {
        trace_id: "0123456789abcdef0123456789abcdef".into(),
        received_ms,
        handed,
        step: tracing::Span::none(),
    }
}

#[test]
fn trace_id_takes_only_the_platform_shape() {
    let id = "0123456789abcdef0123456789abcdef";
    assert_eq!(trace_id_of(&json!({"_meta": {"traceId": id}})), Some(id));
    assert_eq!(trace_id_of(&json!({"_meta": {}})), None);
    assert_eq!(trace_id_of(&json!({})), None);
    assert_eq!(trace_id_of(&json!({"_meta": {"traceId": 5}})), None);
    assert_eq!(trace_id_of(&json!({"_meta": {"traceId": "short"}})), None);
    assert_eq!(trace_id_of(&json!({"_meta": {"traceId": "has/slash/in/it"}})), None);
    assert_eq!(trace_id_of(&json!({"_meta": {"traceId": "a".repeat(81)}})), None);
}

#[test]
fn machine_id_takes_only_the_platform_shape() {
    assert!(is_machine_id("vm_abcdefghij0123456789"));
    assert!(!is_machine_id("vm_ABCDEFGHIJ0123456789"));
    assert!(!is_machine_id("vm_short"));
    assert!(!is_machine_id("abcdefghij0123456789"));
}

#[test]
fn body_has_both_hops_as_machine_spans() {
    let b =
        body(&pending(1_000, Some((1_250, true))), 1_900, Some("vm_abcdefghij0123456789".into()))
            .expect("handed");
    assert_eq!(
        b,
        json!({
            "spans": [
                {"hop": "agent_start", "start_ms": 1_000, "end_ms": 1_250, "source": "machine",
                 "attrs": {"cold": 1}},
                {"hop": "first_token", "start_ms": 1_250, "end_ms": 1_900, "source": "machine"},
            ],
            "machine": "vm_abcdefghij0123456789",
        })
    );
}

#[test]
fn body_warm_start_has_cold_zero_and_no_machine_without_one() {
    let b = body(&pending(10, Some((11, false))), 12, None).expect("handed");
    assert_eq!(b["spans"][0]["attrs"]["cold"], 0);
    assert!(b.get("machine").is_none());
}

#[test]
fn body_never_ends_before_it_starts() {
    // A wall clock stepped back between the marks.
    let b = body(&pending(5_000, Some((4_000, false))), 3_000, None).expect("handed");
    for s in b["spans"].as_array().expect("spans") {
        assert!(s["end_ms"].as_u64() >= s["start_ms"].as_u64(), "{s}");
    }
}

#[test]
fn body_waits_for_the_hand_off() {
    assert!(body(&pending(1, None), 2, None).is_none());
}

#[test]
fn url_is_the_edge_spans_route() {
    assert_eq!(
        spans_url("0123456789abcdef0123456789abcdef"),
        "https://platform.cmux.internal/v1/cloud/start-traces/0123456789abcdef0123456789abcdef/spans"
    );
}

#[test]
fn untraced_calls_touch_nothing() {
    // Off a Cloud VM (the test host) a traced prompt starts nothing.
    if crate::cloud_host::is_cloud_vm() {
        return;
    }
    received("s-untraced", &json!({"_meta": {"traceId": "0123456789abcdef0123456789abcdef"}}));
    assert!(!waiting("s-untraced"));
    handed("s-untraced", true);
    first_update("s-untraced");
}
