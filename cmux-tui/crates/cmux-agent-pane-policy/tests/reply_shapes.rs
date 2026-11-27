//! The reply shapes in policy.json (src/data.rs, src/reply.rs): a shape
//! that does not parse is kept as an empty filter, never dropped, so its
//! method's replies never reach the page unfiltered. The cases of the filter
//! itself are tests/cases/replies.json (parity.rs `replies`).

use cmux_agent_pane_policy::{ReplyShape, data::POLICY_JSON, policy};
use serde_json::Value;
use std::collections::BTreeSet;

/// Every reply shape in policy.json parses.
#[test]
fn every_reply_shape_parses() {
    let raw: Value = serde_json::from_str(POLICY_JSON).unwrap();
    let methods: BTreeSet<&String> = raw["reply_shapes"].as_object().unwrap().keys().collect();
    let parsed: BTreeSet<&String> = policy().reply_shapes.keys().collect();
    assert_eq!(parsed, methods, "reply shapes that parse vs policy.json reply_shapes");
    for (method, shape) in &policy().reply_shapes {
        assert_ne!(
            *shape,
            ReplyShape::Object(Default::default()),
            "{method}: its shape did not parse"
        );
    }
}

/// A peer's AutoCloud state (RFD 0172) reaches the page's picker badges:
/// enrolled, accepting, owner idle and its capability words, never its
/// owner's policy. The macOS host's own filter kept these (AcpmuxPaneMethods
/// +ReplyShapes.swift) before it read this one.
#[test]
fn status_keeps_a_peers_autocloud_badges_only() {
    let reply = r#"{"jsonrpc":"2.0","id":4,"result":{"peers":[{"name":"mini","url":"ssh://me@mini","health":{"autoCloud":{"enrolled":true,"accepting":false,"ownerIdle":true,"caps":["macos","xcode",3],"team":"t","hours":"9-5"}}}]}}"#;
    let text =
        cmux_agent_pane_policy::ffi::filter_reply("_acpmux/status", reply, "\"p1\"").unwrap();
    let got: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        got["result"]["peers"][0]["health"]["autoCloud"],
        serde_json::json!({"enrolled": true, "accepting": false, "ownerIdle": true, "caps": ["macos", "xcode"]})
    );
    assert_eq!(got["id"], "p1");
}
