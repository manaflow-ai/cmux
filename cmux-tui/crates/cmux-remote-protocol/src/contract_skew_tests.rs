//! Version skew: an older peer's wire still decodes here, and this build's
//! wire still decodes in an older peer that keeps an unknown fallback.

use crate::{
    ProcessEvent, ProcessId, RemoteCapability, RequestId, RpcError, RpcEvent, RpcRequest,
    RpcResponse, WorkspaceResponse, remote_contract,
};
use serde::Deserialize;
use serde_json::{Value, json};

/// Wire a peer built from `ecf6cf6c` (2026-11-13, before `git-host-tokens-v1`,
/// `paused-reads-v1` and `describe-v1`) sends. The same lines decode with that
/// commit's types.
const OLD_PEER_WIRE: &str = include_str!("../tests/fixtures/remote-v1-peer-2026-11-13.jsonl");

fn old_peer_lines() -> Vec<(String, Value)> {
    OLD_PEER_WIRE
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let line: Value = serde_json::from_str(line).unwrap();
            (line["kind"].as_str().unwrap().to_owned(), line["wire"].clone())
        })
        .collect()
}

/// `None` fields this build writes as `null` read the same as absent ones.
fn without_nulls(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .filter(|(_, child)| !child.is_null())
                .map(|(key, child)| (key, without_nulls(child)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.into_iter().map(without_nulls).collect()),
        other => other,
    }
}

#[test]
fn old_peer_wire_decodes_and_reencodes_unchanged() {
    let lines = old_peer_lines();
    assert!(lines.len() >= 12, "keep at least a dozen old shapes");
    for (kind, wire) in lines {
        let reencoded = match kind.as_str() {
            "request" => serde_json::to_value(
                serde_json::from_value::<RpcRequest>(wire.clone())
                    .unwrap_or_else(|error| panic!("old request {wire}: {error}")),
            ),
            "response" => serde_json::to_value(
                serde_json::from_value::<RpcResponse>(wire.clone())
                    .unwrap_or_else(|error| panic!("old response {wire}: {error}")),
            ),
            "event" => serde_json::to_value(
                serde_json::from_value::<RpcEvent>(wire.clone())
                    .unwrap_or_else(|error| panic!("old event {wire}: {error}")),
            ),
            other => panic!("unknown fixture kind {other}"),
        }
        .unwrap();
        assert_eq!(without_nulls(reencoded), wire, "the old shape must survive a round trip");
    }
}

/// An older client's capability list: the names it knew plus the catch-all.
#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum OldPeerCapability {
    WorkspaceFilesV1,
    SecretsV1,
    #[serde(untagged)]
    Unknown(String),
}

/// An older client's response decoder: a few known types and a fallback, so a
/// response type it never heard of fails one request, not the channel.
#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum OldPeerResponse {
    Capabilities {
        capabilities: Vec<OldPeerCapability>,
    },
    Workspace {
        id: String,
        root: String,
    },
    MachineSecretsReplaced {
        count: u32,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Deserialize)]
struct OldPeerRpcResponse {
    id: RequestId,
    result: Result<OldPeerResponse, RpcError>,
}

#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum OldPeerEvent {
    Stdout {
        process: ProcessId,
        sequence: u64,
    },
    #[serde(other)]
    Unknown,
}

fn id() -> RequestId {
    serde_json::from_value(json!("00000000-0000-4000-8000-000000000001")).unwrap()
}

fn old_peer_reads(response: WorkspaceResponse) -> OldPeerResponse {
    let wire = serde_json::to_value(RpcResponse { id: id(), result: Ok(response) }).unwrap();
    let decoded: OldPeerRpcResponse = serde_json::from_value(wire).unwrap();
    assert_eq!(decoded.id, id(), "the request id survives so the client fails only that request");
    decoded.result.unwrap()
}

#[test]
fn current_responses_decode_in_an_old_peer_with_a_fallback() {
    assert_eq!(
        old_peer_reads(WorkspaceResponse::Capabilities {
            capabilities: vec![
                RemoteCapability::WorkspaceFilesV1,
                RemoteCapability::DescribeV1,
                RemoteCapability::PausedReadsV1,
            ],
        }),
        OldPeerResponse::Capabilities {
            capabilities: vec![
                OldPeerCapability::WorkspaceFilesV1,
                OldPeerCapability::Unknown("describe-v1".into()),
                OldPeerCapability::Unknown("paused-reads-v1".into()),
            ],
        }
    );
    assert_eq!(
        old_peer_reads(WorkspaceResponse::MachineSecretsReplaced { count: 2 }),
        OldPeerResponse::MachineSecretsReplaced { count: 2 }
    );
    assert_eq!(
        old_peer_reads(WorkspaceResponse::Contract {
            contract: remote_contract(),
            capabilities: vec![RemoteCapability::DescribeV1],
        }),
        OldPeerResponse::Unknown
    );
    assert_eq!(
        old_peer_reads(WorkspaceResponse::GitHostTokenReplaced {
            host: "github.com".into(),
            present: true,
        }),
        OldPeerResponse::Unknown
    );
}

#[test]
fn every_contract_response_decodes_or_falls_back_in_an_old_peer() {
    let contract = remote_contract();
    for response in contract["responses"].as_array().unwrap() {
        let name = response["name"].as_str().unwrap();
        if matches!(name, "capabilities" | "workspace" | "machine-secrets-replaced") {
            continue;
        }
        let decoded: OldPeerResponse =
            serde_json::from_value(json!({ "type": name, "future_field": [1, 2] }))
                .unwrap_or_else(|error| panic!("{name}: {error}"));
        assert_eq!(decoded, OldPeerResponse::Unknown, "{name}");
    }
}

#[test]
fn current_events_decode_in_an_old_peer_with_a_fallback() {
    let process: ProcessId =
        serde_json::from_value(json!("00000000-0000-4000-8000-0000000000a1")).unwrap();
    let stdout = serde_json::to_value(ProcessEvent::Stdout {
        process,
        sequence: 1,
        data: serde_json::from_value(json!("b2sK")).unwrap(),
    })
    .unwrap();
    assert_eq!(
        serde_json::from_value::<OldPeerEvent>(stdout).unwrap(),
        OldPeerEvent::Stdout { process, sequence: 1 }
    );
    let exit =
        serde_json::to_value(ProcessEvent::Exit { process, code: Some(0), signal: None }).unwrap();
    assert_eq!(serde_json::from_value::<OldPeerEvent>(exit).unwrap(), OldPeerEvent::Unknown);
}

/// An old daemon cannot decode `describe`, which is why a client sends it only
/// after `capabilities` lists `describe-v1`.
#[test]
fn describe_is_gated_because_old_daemons_reject_it() {
    #[derive(Debug, Deserialize)]
    #[serde(tag = "type", rename_all = "kebab-case")]
    #[allow(dead_code)]
    enum OldDaemonRequest {
        Capabilities,
        ListWorkspaces,
    }
    let describe = serde_json::to_value(crate::WorkspaceRequest::Describe).unwrap();
    assert!(serde_json::from_value::<OldDaemonRequest>(describe).is_err());
    let capabilities = serde_json::to_value(crate::WorkspaceRequest::Capabilities).unwrap();
    assert!(serde_json::from_value::<OldDaemonRequest>(capabilities).is_ok());
}
