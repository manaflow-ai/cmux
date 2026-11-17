//! `acpmux share-host status [--json] | on | off`, and the hidden `share-host session` the daemon
//! starts per share.

use anyhow::Result;
use serde_json::Value;

/// What `share-host` does.
#[derive(clap::Subcommand, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShareHostCmd {
    /// Whether this Mac's share host runs (or why not), its hub link, device, sharing switch,
    /// live shares, helper and whether the app is attached; read from the running daemon.
    Status,
    /// Turn sharing this Mac's screen on (`PUT /v1/devices/:id/mac-screen`): the person's switch.
    On,
    /// Turn sharing this Mac's screen off.
    Off,
    /// One share, started by the daemon with its ticket on stdin.
    #[command(hide = true)]
    Session,
}

pub(crate) async fn run(cmd: ShareHostCmd, json_out: bool) -> Result<()> {
    match cmd {
        ShareHostCmd::Status => {
            let status = status().await;
            if json_out {
                crate::cli::output::print_json(&status);
            } else {
                print_status(&status);
            }
            Ok(())
        }
        ShareHostCmd::On | ShareHostCmd::Off => {
            let shared = cmd == ShareHostCmd::On;
            set_shared(shared).await?;
            if json_out {
                crate::cli::output::print_json(&serde_json::json!({"sharing": shared}));
            } else {
                println!("Sharing this Mac's screen is {}.", if shared { "on" } else { "off" });
            }
            Ok(())
        }
        ShareHostCmd::Session => session().await,
    }
}

/// The running daemon's status (`_acpmux/share_host_status`); with no daemon, or one too old to
/// answer, that it does not run.
async fn status() -> Value {
    if let Ok(client) = crate::daemon::connect(false).await
        && let Ok(status) =
            client.request(crate::rpc::method::MUX_SHARE_HOST_STATUS, serde_json::json!({})).await
    {
        return status;
    }
    serde_json::json!({
        "schema": "acpmux.share-host.status/1",
        "running": false,
        "state": "daemon_not_running",
        "detail": "no acpmux daemon answered (or it predates the share host)",
    })
}

fn print_status(status: &Value) {
    let text = |key: &str| status.get(key).and_then(Value::as_str).unwrap_or("-");
    let running = status.get("running").and_then(Value::as_bool) == Some(true);
    println!("share host: {}", if running { text("state") } else { "not running" });
    if !running || status.get("detail").is_some_and(|d| !d.is_null()) {
        println!("  {}: {}", text("state"), text("detail"));
    }
    if !running {
        return;
    }
    println!("  device:  {} ({})", text("deviceName"), text("deviceId"));
    println!("  hub:     {}", text("hub"));
    let flag = |key: &str| match status.get(key).and_then(Value::as_bool) {
        Some(true) => "yes",
        Some(false) => "no",
        None => "unknown",
    };
    println!("  sharing: {}  app attached: {}", flag("sharing"), flag("appAttached"));
    let sessions = status.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    println!("  shares:  {}", sessions.len());
    for share in sessions {
        let field = |k: &str| share.get(k).and_then(Value::as_str).unwrap_or("-").to_owned();
        println!("    {} {} for {}", field("sessionId"), field("scope"), field("viewerName"));
    }
    let helper = status.pointer("/helper/lastResolved/path").and_then(Value::as_str);
    println!("  helper:  {}", helper.unwrap_or("none resolved yet"));
}

#[cfg(unix)]
async fn set_shared(shared: bool) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        let hub = super::machine_hub(&crate::config::home(), false)?;
        hub.set_shared(shared).map_err(|e| anyhow::anyhow!("{e}"))?;
        Ok(())
    })
    .await?
}

#[cfg(not(unix))]
async fn set_shared(_shared: bool) -> Result<()> {
    anyhow::bail!("the share host runs on macOS")
}

#[cfg(unix)]
async fn session() -> Result<()> {
    tokio::task::spawn_blocking(super::session::run).await?
}

#[cfg(not(unix))]
async fn session() -> Result<()> {
    anyhow::bail!("the share host runs on macOS")
}
