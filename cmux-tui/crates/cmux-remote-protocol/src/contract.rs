//! The remote contract: every `WorkspaceRequest` method, the capability that
//! gates it, the responses it can answer with, and every event, each with a
//! JSON Schema (`contract/remote-v1.json`, format [`REMOTE_CONTRACT_FORMAT`]).
//!
//! Peers check a method's capability instead of comparing protocol numbers, so
//! old and new builds keep talking as the wire grows. The golden file is
//! generated from the Rust types by this crate's tests (`UPDATE_CONTRACT=1
//! cargo test -p cmux-remote-protocol contract`); a wire change that is not
//! written to it fails the build.

/// The `format` field of the contract document.
pub const REMOTE_CONTRACT_FORMAT: &str = "cmux.remote.contract/1";

/// The golden contract document, as served by `describe`.
pub const REMOTE_CONTRACT_JSON: &str = include_str!("../contract/remote-v1.json");

/// One `WorkspaceRequest` method: its wire `type`, the capability a client
/// checks before calling it (`None`: every daemon serves it), and the
/// `WorkspaceResponse` types it answers with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContractMethod {
    pub name: &'static str,
    pub capability: Option<&'static str>,
    pub responses: &'static [&'static str],
}

const fn method(
    name: &'static str,
    capability: Option<&'static str>,
    responses: &'static [&'static str],
) -> ContractMethod {
    ContractMethod { name, capability, responses }
}

/// Every method, in `WorkspaceRequest` order. A test keeps this equal to the
/// enum's wire tags.
pub const CONTRACT_METHODS: &[ContractMethod] = &[
    method("capabilities", None, &["capabilities"]),
    method("describe", Some("describe-v1"), &["contract"]),
    method("open-workspace", None, &["workspace"]),
    method("list-workspaces", None, &["workspaces"]),
    method("stat", Some("workspace-files-v1"), &["stat"]),
    method("read-file", Some("workspace-files-v1"), &["file"]),
    method("write-file", Some("workspace-files-v1"), &["written"]),
    method("list-directory", Some("workspace-files-v1"), &["directory"]),
    method("search", Some("workspace-search-v1"), &["search"]),
    method("apply-patch", Some("workspace-patch-v1"), &["patch"]),
    method("git-status", Some("workspace-diff-v1"), &["git-status"]),
    method("diff", Some("workspace-diff-v1"), &["diff", "structured-diff"]),
    method("spawn-process", Some("process-pipes-v1"), &["process-started"]),
    method("spawn-process-with-handle", Some("process-handles-v2"), &["process-started"]),
    method("write-process", Some("process-pipes-v1"), &["process-write-accepted"]),
    method("resize-process", Some("process-pty-v1"), &["process-resized"]),
    method("signal-process", Some("process-pipes-v1"), &["process-signaled"]),
    method("wait-process", Some("process-pipes-v1"), &["process-exit"]),
    method(
        "read-process-events",
        Some("process-replay-v1"),
        &["process-events", "process-replay-gap"],
    ),
    method("list-processes", Some("process-catalog-v1"), &["processes"]),
    method(
        "snapshot-process-terminal",
        Some("process-terminal-snapshot-v1"),
        &["process-terminal-snapshot"],
    ),
    method("finish-operation", None, &["operation-finished"]),
    method("close-workspace", None, &["workspace-closed"]),
    method("cancel-request", Some("request-control-v1"), &["request-canceled"]),
    method("create-route", Some("tcp-routes-v1"), &["route-created"]),
    method("close-route", Some("tcp-routes-v1"), &["closed"]),
    method(
        "computer-use-capabilities",
        Some("computer-use-negotiation-v1"),
        &["computer-use-capabilities"],
    ),
    method(
        "computer-use-capabilities-v1",
        Some("computer-use-v1"),
        &["computer-use-capabilities-v1"],
    ),
    method(
        "invoke-computer-use",
        Some("computer-use-v1"),
        &["computer-use-accepted", "computer-use-result"],
    ),
    method("cancel-computer-use", Some("computer-use-v1"), &["computer-use-canceled"]),
    method("replace-machine-secrets", Some("secrets-v1"), &["machine-secrets-replaced"]),
    method("replace-git-host-token", Some("git-host-tokens-v1"), &["git-host-token-replaced"]),
];

/// The contract document `describe` serves. `Null` only if the embedded file
/// is not JSON, which this crate's tests rule out.
pub fn remote_contract() -> serde_json::Value {
    serde_json::from_str(REMOTE_CONTRACT_JSON).unwrap_or(serde_json::Value::Null)
}

#[cfg(test)]
#[path = "contract_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "contract_skew_tests.rs"]
mod skew_tests;
