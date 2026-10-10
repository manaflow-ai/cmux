//! Backend ops a first-party app server serves (`serves.ops` in its
//! manifest; cloud-client-contract.md 2.1, D-ROUTE). `consumes.ops` is a
//! different list (the ops an app calls) and is never routed here. The backend catalog
//! (`backend/catalog/cloud-operations.json`, generated from the protocol
//! package) is the one owner of their policy: an app never declares a
//! weaker one. The supervisor routes a consumed op to the app's server only
//! when the catalog knows it, and decides its origin and scope from the
//! catalog row:
//!
//! - an op the catalog does not know is refused (fail closed);
//! - `cloud.machine.link_token` is never routable (only `cmux link` mints
//!   dial tokens, contract 1.7);
//! - a `money` or `destructive` op, or one the catalog keeps off MCP
//!   (`mcp.expose: never`), needs origin user (the person's confirmed
//!   gesture in the app);
//! - every other op needs the scope its risk names (`servers::op_scope`).

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde_json::Value;

/// The generated backend catalog (embedded: the tree key lists it,
/// scripts/cmux-next/cmux-tui-tree-inputs.txt).
const CATALOG: &str = include_str!("../../../../../backend/catalog/cloud-operations.json");

/// Ops no app server may run, whatever its manifest says.
const NEVER_ROUTED: &[&str] = &["cloud.machine.link_token"];

/// How the supervisor admits one served op.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Policy {
    /// The catalog row, for `servers::op_scope` (`risk`, `class`).
    pub(super) entry: Value,
    /// Only the person may run it (origin user).
    pub(super) person_only: bool,
}

fn rows() -> &'static BTreeMap<String, Value> {
    static ROWS: OnceLock<BTreeMap<String, Value>> = OnceLock::new();
    ROWS.get_or_init(|| {
        let catalog: Value = serde_json::from_str(CATALOG).unwrap_or(Value::Null);
        catalog
            .get("operations")
            .and_then(Value::as_object)
            .map(|ops| ops.iter().map(|(name, row)| (name.clone(), row.clone())).collect())
            .unwrap_or_default()
    })
}

/// The policy of served op `op`, or `None` when no server may run it.
pub(super) fn policy(op: &str) -> Option<Policy> {
    if NEVER_ROUTED.contains(&op) {
        return None;
    }
    let row = rows().get(op)?;
    let risk = row.get("risk").and_then(Value::as_str);
    let never_exposed = row.pointer("/mcp/expose").and_then(Value::as_str) == Some("never");
    Some(Policy {
        entry: row.clone(),
        person_only: matches!(risk, Some("money" | "destructive")) || never_exposed,
    })
}
