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
/// An inherited ACPMUX_HOME or ACPMUX_SOCKET (an app terminal exports both)
/// would point the hand at the person's own daemon: the hand does not start.
pub fn use_hand_home() -> anyhow::Result<()> {
    for var in ["ACPMUX_HOME", "ACPMUX_SOCKET"] {
        if std::env::var_os(var).is_some() {
            anyhow::bail!(
                "{var} is set: it would point the hand at another acpmux daemon; start the hand without it (env -u {var})"
            );
        }
    }
    let home = super::config::home().join("acpmux");
    crate::config::set_home_override(home.clone());
    if crate::config::home() != home {
        anyhow::bail!(
            "the hand's acpmux home did not take effect ({})",
            crate::config::home().display()
        );
    }
    Ok(())
}

/// Whether this hand run already restarted a daemon that refused its key: it does so once, then
/// keeps the connection (prompts are then refused), so agents are not cut off at every start.
static RESTARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// One connect at a time: two starts at once would both start a daemon.
static CONNECT: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// `<acpmux> [prefix…] daemon start --person-key-fd 0`: the key arrives on
/// stdin. Inside cmux-tui the prefix is `acp`.
fn keyed_start_command(this: &crate::self_command::SelfCommand) -> tokio::process::Command {
    this.tokio_command(&["daemon", "start", "--person-key-fd", "0"])
}

async fn start_keyed() -> Result<(), HandError> {
    use tokio::io::AsyncWriteExt;
    let this = crate::self_command::SelfCommand::current()
        .map_err(|e| HandError::new("agent.daemon", e.to_string()))?;
    let mut child = keyed_start_command(&this)
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
    let _one = CONNECT.lock().await;
    let path = crate::config::socket_path();
    if let Ok(client) = Client::connect(&path).await {
        if client.prove_person(key()).await {
            return Ok((client, true));
        }
        if RESTARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return Ok((client, false));
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

#[cfg(test)]
mod self_command_tests {
    #[test]
    fn the_keyed_start_runs_under_the_daemon_prefix() {
        let [standalone, tui] = crate::self_command::test_commands();
        let args = |c: &tokio::process::Command| -> Vec<String> {
            c.as_std().get_args().map(|a| a.to_string_lossy().into_owned()).collect()
        };
        let start = ["daemon", "start", "--person-key-fd", "0"];
        assert_eq!(args(&super::keyed_start_command(&standalone)), start);
        let command = super::keyed_start_command(&tui);
        assert_eq!(command.as_std().get_program(), tui.exe.as_os_str());
        assert_eq!(args(&command)[0], "acp");
        assert_eq!(args(&command)[1..], start);
    }
}
