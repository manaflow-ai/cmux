//! Routing parity through the production dispatcher: new chats, Chief chats, peer copies,
//! malformed replies, and disk fallback keys. Native socket and directory probes remain Swift.

use cmux_agent_pane_policy::ffi::{ERR_INVALID, call};
use serde_json::{Value, json};

fn routing(request: Value) -> Value {
    call("session_routing", &request).unwrap()
}

#[test]
fn session_routing_host_and_restart_have_the_same_owner() {
    for session in [Value::Null, json!(""), json!("chief-chat"), json!("local-chat")] {
        for chief_owns in [false, true] {
            let chief = !session.is_null() && chief_owns;
            assert_eq!(
                routing(json!({"kind": "route", "session": session, "chief_owns": chief_owns})),
                json!({"host": if chief { "chief" } else { "local" }, "restart": !chief}),
                "session={session}, chief_owns={chief_owns}"
            );
        }
    }
}

#[test]
fn session_routing_exact_resolve_ignores_tags_and_excludes_only_named_peers() {
    assert_eq!(routing(json!({"kind": "resolved", "summary": null})), json!({"owned": false}));
    for tags in [json!({}), json!({"mux.parent": "optchat-chief:named"})] {
        for peer in [Value::Null, json!(""), json!(7), json!(false), json!([]), json!({})] {
            assert_eq!(
                routing(json!({"kind": "resolved", "summary": {"peer": peer, "tags": tags}})),
                json!({"owned": true}),
                "peer={peer}, tags={tags}"
            );
        }
        assert_eq!(
            routing(json!({"kind": "resolved", "summary": {"tags": tags}})),
            json!({"owned": true})
        );
        for peer in ["gcp", " ", "chief:home"] {
            assert_eq!(
                routing(json!({"kind": "resolved", "summary": {"peer": peer, "tags": tags}})),
                json!({"owned": false})
            );
        }
    }
}

#[test]
fn session_routing_disk_fallback_preserves_the_native_component_rule() {
    for session in ["", ".", "..", "/", "../chat", "chat/child", "/chat"] {
        assert_eq!(
            routing(json!({"kind": "disk_key", "session": session})),
            json!({"allowed": false})
        );
    }
    // These names pass the existing shape rule; actual existence and directory status stay native.
    for session in ["chat", "...", " chat ", "a\\b", "é", "e\u{301}", "a\0b"] {
        assert_eq!(
            routing(json!({"kind": "disk_key", "session": session})),
            json!({"allowed": true})
        );
    }
}

#[test]
fn session_routing_invalid_facts_never_become_a_local_route() {
    for request in [
        json!({}),
        json!({"kind": "unknown"}),
        json!({"kind": "route"}),
        json!({"kind": "route", "session": null}),
        json!({"kind": "route", "session": 1, "chief_owns": false}),
        json!({"kind": "route", "session": "chat", "chief_owns": "true"}),
        json!({"kind": "resolved"}),
        json!({"kind": "resolved", "summary": []}),
        json!({"kind": "disk_key"}),
        json!({"kind": "disk_key", "session": null}),
    ] {
        assert_eq!(call("session_routing", &request), Err(ERR_INVALID), "{request}");
    }
}
