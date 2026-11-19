//! `acpmux share-host status [--json] | on | off`, the screen shares' verbs (`screens`, `start`,
//! `stop`, `move`; [`super::verbs`]), and the hidden `share-host session` the daemon starts per share.

use anyhow::Result;
use serde_json::Value;

/// What `share-host` does.
#[derive(clap::Subcommand, Debug, Clone, PartialEq, Eq)]
pub enum ShareHostCmd {
    /// Whether this Mac's share host runs (or why not), its hub link, device, sharing switch,
    /// live shares, helper and whether the app is attached; read from the running daemon.
    Status,
    /// Turn sharing this Mac's screen on (`PUT /v1/devices/:id/mac-screen`): the person's switch.
    On,
    /// Turn sharing this Mac's screen off.
    Off,
    /// The live screen shares this machine hosts or views, as the device hub keeps them.
    Screens,
    /// Share this machine's screen to another of your devices; its app opens it with no click.
    Start {
        /// The viewer: a device id, an id prefix or a name.
        #[arg(long)]
        to: String,
        /// View only: the viewer cannot type or click.
        #[arg(long)]
        view_only: bool,
    },
    /// End a share this machine hosts.
    Stop {
        /// The share's session id, or a prefix of one (`share-host screens`).
        session: String,
    },
    /// Hand a live share to another device: `--to` the viewer side, `--host` the host side.
    Move {
        /// The share's session id, or a prefix of one (`share-host screens`).
        session: String,
        /// The new viewer: a device id, an id prefix or a name.
        #[arg(long, conflicts_with = "host", required_unless_present = "host")]
        to: Option<String>,
        /// The new host, whose screen the viewer now sees.
        #[arg(long)]
        host: Option<String>,
    },
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
            let shared = matches!(cmd, ShareHostCmd::On);
            set_shared(shared).await?;
            if json_out {
                crate::cli::output::print_json(&serde_json::json!({"sharing": shared}));
            } else {
                println!("Sharing this Mac's screen is {}.", if shared { "on" } else { "off" });
            }
            Ok(())
        }
        ShareHostCmd::Screens
        | ShareHostCmd::Start { .. }
        | ShareHostCmd::Stop { .. }
        | ShareHostCmd::Move { .. } => {
            let (verb, answer) = verb(cmd).await?;
            if json_out {
                crate::cli::output::print_json(&answer);
            } else if verb == "screens" {
                super::verbs::print_list(&answer);
            } else {
                super::verbs::print_record(verb, &answer);
            }
            Ok(())
        }
        ShareHostCmd::Session => session().await,
    }
}

/// Runs a share verb with this machine's device and machine credential: its name and the answer.
#[cfg(unix)]
async fn verb(cmd: ShareHostCmd) -> Result<(&'static str, Value)> {
    use super::verbs::{self, Side};
    tokio::task::spawn_blocking(move || {
        if cfg!(target_os = "linux") {
            // cmux-rd holds a Linux machine's device (`share_host/linux.rs`), not this daemon.
            anyhow::bail!("on Linux the shares are cmux-rd's: cmux-rd linux-host status");
        }
        let hub = super::machine_hub(&crate::config::home(), false)?;
        let own = hub.device.id.clone();
        let call = |method: &str, path: &str, body: Option<&Value>| hub.call(method, path, body);
        let (name, answer) = match cmd {
            ShareHostCmd::Screens => ("screens", verbs::list(&call)),
            ShareHostCmd::Start { to, view_only } => {
                ("start", verbs::start(&call, &own, &to, view_only))
            }
            ShareHostCmd::Stop { session } => ("stop", verbs::stop(&call, &session)),
            ShareHostCmd::Move { session, to, host } => {
                let (side, target) = match (to, host) {
                    (Some(to), _) => (Side::Viewer, to),
                    (None, Some(host)) => (Side::Host, host),
                    (None, None) => anyhow::bail!("move takes --to DEVICE or --host DEVICE"),
                };
                ("move", verbs::move_share(&call, &own, &session, side, &target))
            }
            ShareHostCmd::Status | ShareHostCmd::On | ShareHostCmd::Off | ShareHostCmd::Session => {
                anyhow::bail!("not a share verb")
            }
        };
        Ok((name, answer.map_err(|e| anyhow::anyhow!("{e}"))?))
    })
    .await?
}

#[cfg(not(unix))]
async fn verb(_cmd: ShareHostCmd) -> Result<(&'static str, Value)> {
    anyhow::bail!("the share host runs on macOS")
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

#[cfg(unix)]
async fn session() -> Result<()> {
    tokio::task::spawn_blocking(super::session::run).await?
}

#[cfg(not(unix))]
async fn session() -> Result<()> {
    anyhow::bail!("the share host runs on macOS")
}
