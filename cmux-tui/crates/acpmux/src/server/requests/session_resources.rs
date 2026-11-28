//! `_acpmux/session_resources`: CPU time and memory of one chat's agent, read from the operating
//! system when the request arrives: its agent host and everything under it (the harness, its MCP
//! servers, the tools it runs), or the agent this daemon runs as its own child. The app's tab and
//! workspace hover cards show it as the chat's Memory (Leo 2026-11-27: "the memory line... it
//! should be the ram usage. why dont we have ram usage?"): the chat's page alone said "–", since
//! its agent runs in this daemon, not under the app.
//!
//! Nothing runs in the background: no sampler, cache or timer, as for `terminal-resources`
//! (`cmux_tui_platform::process_resources`). A peer's chat is forwarded there like any request
//! that names a session (`peer_forward.rs`), so a remote chat's numbers are its own machine's.

use std::sync::Arc;
use std::time::Duration;

use cmux_tui_platform::process_resources::{Sampler, monotonic_now_ns};
use serde_json::{Value, json};

use crate::hub::Hub;
use crate::rpc::RpcError;
use crate::server::session_key;

/// How long the request waits for a start or stop that holds the chat's agent slot. Past it the
/// reply says `running: null` (unknown) rather than hold a hover card.
const SLOT_WAIT: Duration = Duration::from_millis(250);

pub(super) async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let root = s.agent_root_pid(SLOT_WAIT).await;
    let id = s.id.to_string();
    let mut reply = tokio::task::spawn_blocking(move || describe(root))
        .await
        .map_err(|e| RpcError::internal(format!("_acpmux/session_resources: {e}")))?;
    reply["sessionId"] = Value::String(id);
    Ok(reply)
}

/// The reply for an agent whose process tree starts at `root`: `Some(None)` no agent runs (a new
/// or hibernated chat), `None` its slot was held past [`SLOT_WAIT`].
pub(crate) fn describe(root: Option<Option<u32>>) -> Value {
    let sampled_at_ns = monotonic_now_ns();
    let Some(root) = root else {
        return json!({"running": null, "sampledAtNs": sampled_at_ns, "pid": null, "processes": [],
                      "memoryBytes": 0, "cpuNs": 0, "truncated": false});
    };
    let Some(pid) = root else {
        return json!({"running": false, "sampledAtNs": sampled_at_ns, "pid": null, "processes": [],
                      "memoryBytes": 0, "cpuNs": 0, "truncated": false});
    };
    let sampler = Sampler::new();
    let tree = sampler.tree(pid);
    let parent = sampler.parent(pid);
    let (mut memory, mut cpu) = (0u64, 0u64);
    let processes = tree
        .nodes
        .iter()
        .filter_map(|node| {
            // A process that exited during the walk is left out.
            let sample = sampler.sample(node.pid)?;
            memory = memory.saturating_add(sample.memory_bytes);
            cpu = cpu.saturating_add(sample.cpu_ns);
            Some(json!({
                "pid": node.pid,
                "ppid": node.parent.or(parent).unwrap_or(0),
                "name": sample.name,
                "cpuNs": sample.cpu_ns,
                "memoryBytes": sample.memory_bytes,
            }))
        })
        .collect::<Vec<_>>();
    json!({
        "running": !processes.is_empty(),
        "sampledAtNs": sampled_at_ns,
        "pid": pid,
        "processes": processes,
        "memoryBytes": memory,
        "cpuNs": cpu,
        "truncated": tree.truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_live_tree_reports_each_process_and_the_sum() {
        let mut child = std::process::Command::new("sleep").arg("30").spawn().expect("sleep");
        let own = std::process::id();
        let reply = describe(Some(Some(own)));
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(reply["running"], true);
        assert_eq!(reply["pid"], own);
        let processes = reply["processes"].as_array().expect("processes");
        assert!(processes.iter().any(|p| p["pid"] == own), "the root itself is counted");
        assert!(
            processes.iter().any(|p| p["pid"] == child.id() && p["ppid"] == own),
            "and its child"
        );
        let sum: u64 = processes.iter().map(|p| p["memoryBytes"].as_u64().unwrap()).sum();
        assert_eq!(reply["memoryBytes"].as_u64(), Some(sum));
        assert!(sum > 0, "a live process has memory");
    }

    #[test]
    fn no_agent_or_a_held_slot_reports_nothing_measured() {
        let idle = describe(Some(None));
        assert_eq!(idle["running"], false);
        assert_eq!(idle["processes"], json!([]));
        let held = describe(None);
        assert_eq!(held["running"], Value::Null);
        assert_eq!(held["memoryBytes"], 0);
    }
}
