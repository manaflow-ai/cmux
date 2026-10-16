//! The hand's own agent daemon: an acpmux daemon under the hand's home (never
//! the person's app daemon), started with a person key that only this hand
//! process holds, so the hand can answer an agent's permission prompt after
//! the owner allowed it in the Cloud (approvals) — the acpmux person rule
//! (`hub/person.rs`) lets only the person allow.
//!
//! The key is 32 random bytes made at each hand start and kept in memory; it
//! reaches the daemon once, on the keyed start's stdin (`daemon start
//! --person-key-fd 0`). A daemon that runs with another key (a previous hand
//! run) is shut down with its agents kept, then started again with this key.
//! A signed (Team) daemon ignores the key: then allows cannot be applied and
//! the hand refuses those prompts (`proven` stays false).

use super::HandError;
use crate::client::Client;
use crate::rpc::method;
use serde_json::json;
use std::sync::{Arc, OnceLock};

fn key() -> &'static str {
    static KEY: OnceLock<String> = OnceLock::new();
    KEY.get_or_init(|| {
        let mut raw = [0u8; 32];
        if getrandom::fill(&mut raw).is_err() {
            return String::new();
        }
        raw.iter().map(|b| format!("{b:02x}")).collect()
    })
}

/// The hand's acpmux home: `<hand home>/acpmux` (set once at hand start).
pub fn use_hand_home() {
    crate::config::set_home_override(super::config::home().join("acpmux"));
}

async fn start_keyed() -> Result<(), HandError> {
    use tokio::io::AsyncWriteExt;
    let exe = std::env::current_exe().map_err(|e| HandError::new("agent.daemon", e.to_string()))?;
    let mut child = tokio::process::Command::new(exe)
        .args(["daemon", "start", "--person-key-fd", "0"])
        .env("ACPMUX_HOME", crate::config::home())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| HandError::new("agent.daemon", format!("start the agent daemon: {e}")))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(format!("{}\n", key()).as_bytes()).await;
    }
    let out = child
        .wait_with_output()
        .await
        .map_err(|e| HandError::new("agent.daemon", e.to_string()))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(HandError::new(
            "agent.daemon",
            format!(
                "the agent daemon did not start: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        ))
    }
}

/// A connection to the hand's daemon, proven as the person when the daemon
/// took this hand's key. Starts (or restarts, agents kept) the daemon as needed.
pub async fn connect() -> Result<(Arc<Client>, bool), HandError> {
    let path = crate::config::socket_path();
    if let Ok(client) = Client::connect(&path).await {
        if client.prove_person(key()).await {
            return Ok((client, true));
        }
        // Another key (an earlier hand run): restart it keyed, its agents kept.
        let _ = client.request(method::MUX_SHUTDOWN, json!({})).await;
        crate::daemon::wait_for_exit().await;
    }
    start_keyed().await?;
    let client = Client::connect(&path)
        .await
        .map_err(|e| HandError::new("agent.daemon", format!("{e:#}")))?;
    let proven = client.prove_person(key()).await;
    if !proven {
        tracing::warn!(
            "the agent daemon refused this hand's person key: agent permission prompts cannot be allowed"
        );
    }
    Ok((client, proven))
}
