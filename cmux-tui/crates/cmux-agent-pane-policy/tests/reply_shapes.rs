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
