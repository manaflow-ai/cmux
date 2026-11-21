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
    // A Linux machine's host is cmux-rd's own: its device and shares are `cmux-rd linux-host status`'s.
    if text("host") == "cmux-rd" {
        println!("  host:    {} ({})", text("unit"), text("cmuxRd"));
        println!("  hub:     {}", text("hub"));
        println!("  more:    cmux-rd linux-host status");
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
    if cfg!(target_os = "linux") {
        // cmux-rd holds a Linux machine's device (`share_host/linux.rs`), not this daemon.
        anyhow::bail!(
            "on Linux the switch is cmux-rd's: cmux-rd linux-host share {}",
            if shared { "on" } else { "off" }
        );
    }
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

/// What turning this machine's sharing off through the share host's own device found.
#[derive(Debug, Clone, PartialEq)]
pub enum OffHere {
    /// No share-host device here (not joined, a copied or revoked join, no device made yet): the
    /// caller keeps its own path (cmux Remote's worker or the app).
    NoHost,
    /// The hub turned this device's sharing off; its answer.
    Off(Value),
    /// This machine is joined but its switch could not be turned off: one line saying why and
    /// what to do.
    Failed(String),
}

/// `cmux remote-host share off` on a joined machine (cmuxterm-hq
/// docs/design/remote-screen-share-zero-touch.md, Z4: the join turns sharing on, and the switch
/// stays the off switch on that Mac and in `cmux remote-host share off`). The daemon's share host
/// serves the shares with the app closed, so the off switch must reach the same device: `PUT
/// /v1/devices/:id/mac-screen {"shared": false}` with the machine credential, no app needed. A
/// machine with no share host here answers [`OffHere::NoHost`]. Blocking.
pub fn share_off_here() -> OffHere {
    #[cfg(unix)]
    {
        let home = crate::config::home();
        off_outcome(
            cfg!(target_os = "linux"),
            super::joined().map(|_| ()),
            || super::machine_hub(&home, false),
            |hub| hub.set_shared(false).map_err(|e| e.to_string()),
        )
    }
    #[cfg(not(unix))]
    {
        OffHere::NoHost
    }
}

/// [`share_off_here`]'s decision, with the join, the hub and the hub call passed in.
#[cfg(unix)]
pub(crate) fn off_outcome<H>(
    linux: bool,
    joined: Result<(), super::NotRunning>,
    hub: impl FnOnce() -> Result<H, super::NotRunning>,
    turn_off: impl FnOnce(&H) -> Result<Value, String>,
) -> OffHere {
    if joined.is_err() {
        return OffHere::NoHost;
    }
    if linux {
        // cmux-rd holds a joined Linux machine's device (`share_host/linux.rs`), not this daemon.
        return OffHere::Failed(
            "this Linux machine's switch is cmux-rd's; run here: cmux-rd linux-host share off"
                .into(),
        );
    }
    let hub = match hub() {
        Ok(hub) => hub,
        // The daemon has not registered this Mac's device yet: nothing it serves to turn off.
        Err(why) if why.code == "not_registered" => return OffHere::NoHost,
        Err(why) => {
            return OffHere::Failed(format!(
                "could not read this Mac's share-host device ({why}); turn Allow Mac Screen off in cmux on this Mac"
            ));
        }
    };
    match turn_off(&hub) {
        Ok(answer) => OffHere::Off(answer),
        Err(e) => OffHere::Failed(format!(
            "the device hub did not turn sharing off ({e}); check this Mac's network and run it again, or turn Allow Mac Screen off in cmux on this Mac"
        )),
    }
}

#[cfg(unix)]
async fn session() -> Result<()> {
    tokio::task::spawn_blocking(super::session::run).await?
}

#[cfg(not(unix))]
async fn session() -> Result<()> {
    anyhow::bail!("the share host runs on macOS")
}
