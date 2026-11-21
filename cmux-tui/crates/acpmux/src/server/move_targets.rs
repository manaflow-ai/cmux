//! The local app's Move to… list, from one peer snapshot; no SSH probes or session mutations.

use crate::hub::Hub;
use serde_json::Value;

/// `{"source": PEER?, "sourceKind": KIND?}` → `{"targets": [...], "pick": NAME|null}`. A peer is named exactly as
/// `_acpmux/peers` names it. This Mac and Cloud rows keep their existing app-owned move paths.
pub(super) fn targets(hub: &Hub, params: &Value) -> Value {
    let registry = crate::placement::load_registry();
    let source = params.get("source").and_then(Value::as_str);
    let source_kind = params.get("sourceKind").and_then(Value::as_str);
    crate::placement::move_targets::targets(&hub.peers(), source, source_kind, registry.as_ref())
}
