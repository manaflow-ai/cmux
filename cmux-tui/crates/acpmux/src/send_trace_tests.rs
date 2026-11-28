use super::*;

fn pending(received_ms: u64, handed: Option<(u64, bool)>) -> Pending {
    Pending {
        trace_id: "0123456789abcdef0123456789abcdef".into(),
        received_ms,
        handed,
        step: tracing::Span::none(),
        heard: Heard::default(),
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
                {"hop": "first_token", "start_ms": 1_250, "end_ms": 1_900, "source": "machine",
                 "attrs": {"agent_msgs": 0, "stderr_lines": 0, "retries": 0}},
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
fn minted_ids_are_w3c_trace_ids() {
    let a = mint_trace_id();
    assert_eq!(a.len(), 32);
    assert!(a.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    assert_ne!(a, "0".repeat(32));
    assert_ne!(a, mint_trace_id());
    // The platform takes it (StartTraceRoute.ts shape) as a client's would be.
    assert_eq!(trace_id_of(&json!({"_meta": {"traceId": a}})), Some(a.as_str()));
}

#[test]
fn only_an_explicit_off_turns_send_traces_off() {
    for v in ["off", "OFF", " off ", "0", "false", "no"] {
        assert!(switch_off(Some(v)), "{v}");
    }
    for v in ["", "on", "1", "true", "yes"] {
        assert!(!switch_off(Some(v)), "{v}");
    }
    assert!(!switch_off(None));
}

#[test]
fn untraced_calls_touch_nothing() {
    // Off a Cloud VM (the test host) a prompt, traced or not, starts nothing.
    received("s-unminted", &json!({}));
    assert!(!waiting("s-unminted") || crate::cloud_host::is_cloud_vm());
    if crate::cloud_host::is_cloud_vm() {
        return;
    }
    received("s-untraced", &json!({"_meta": {"traceId": "0123456789abcdef0123456789abcdef"}}));
    assert!(!waiting("s-untraced"));
    handed("s-untraced", true);
    first_update("s-untraced");
}

#[test]
fn first_token_attrs_say_what_the_agent_did_before_the_model() {
    let mut p = pending(1_000, Some((1_250, false)));
    p.heard = Heard {
        first_ms: Some(1_300),
        msgs: 4,
        stderr: 2,
        harness: Some("codex"),
        retries: 3,
        retry_status: Some(401),
        retry_cause: Some("auth".into()),
    };
    let b = body(&p, 301_250, None).expect("handed");
    assert_eq!(
        b["spans"][1]["attrs"],
        json!({"agent_first_ms": 50, "agent_msgs": 4, "stderr_lines": 2, "retries": 3,
               "retry_status": 401, "retry_cause": "auth", "harness": "codex"})
    );
}

#[test]
fn first_token_attrs_keep_inside_the_span_and_the_platform_shape() {
    // A clock stepped back: the first message is never before the hand-off nor after the end.
    let h = Heard { first_ms: Some(10), ..Heard::default() };
    assert_eq!(first_token_attrs(&h, 100, 200)["agent_first_ms"], 0);
    let h = Heard { first_ms: Some(900), ..Heard::default() };
    assert_eq!(first_token_attrs(&h, 100, 200)["agent_first_ms"], 100);
    // Only fixed codes: anything with a space, a slash or too long is no cause.
    assert_eq!(code_of("network_unreachable").as_deref(), Some("network_unreachable"));
    assert_eq!(code_of("api.anthropic.com"), Some("api.anthropic.com".into()));
    assert_eq!(code_of("not logged in"), None);
    assert_eq!(code_of("a/b"), None);
    assert_eq!(code_of(&"a".repeat(65)), None);
    assert_eq!(code_of(""), None);
    // Every key is one StartTrace.ts parseSpans takes (ATTR_KEY, not a refused name).
    let all = Heard {
        first_ms: Some(1),
        msgs: 1,
        stderr: 1,
        harness: Some("claude"),
        retries: 1,
        retry_status: Some(500),
        retry_cause: Some("x".into()),
    };
    let attrs = first_token_attrs(&all, 0, 2);
    let obj = attrs.as_object().expect("object");
    assert!(obj.len() <= 16);
    for k in obj.keys() {
        assert!(k.len() <= 32 && k.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'), "{k}");
        for refused in ["key", "token", "secret", "password", "prompt", "message"] {
            assert!(!k.split('_').any(|w| w == refused), "{k}");
        }
    }
}

#[test]
fn harness_comes_from_raw_line_methods() {
    assert_eq!(harness_of("claude.system.init"), Some("claude"));
    assert_eq!(harness_of("codex.turn/started"), Some("codex"));
    assert_eq!(harness_of("session/update"), None);
}
