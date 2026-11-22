//! `acpmux share-host status [--json] | on | off | link`, and the hidden `share-host session` the daemon
//! starts per share.

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
    /// The link that opens this Mac's screen, view-only, in cmux on a Mac or iPhone; with
    /// `--display`, that display (a run's virtual display, by its CGDirectDisplayID).
    Link {
        /// The display's CGDirectDisplayID (what vdisplay prints as `ready <id>`).
        #[arg(long)]
        display: Option<u32>,
        /// A label for the viewer to show (the run's name); never used to route.
        #[arg(long)]
        name: Option<String>,
        /// Ask for full control instead of view-only.
        #[arg(long)]
        control: bool,
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
        ShareHostCmd::Link { display, name, control } => {
            let status = status().await;
            let device = status
                .get("deviceId")
                .and_then(Value::as_str)
                .filter(|d| !d.is_empty())
                .ok_or_else(|| {
                anyhow::anyhow!(
                    "this Mac has no hub device yet (acpmux share-host status says why); \
                         join it to cmux first"
                )
            })?;
            let link = ScreenLink { device, display, name: name.as_deref(), control };
            let sharing = status.get("sharing").and_then(Value::as_bool);
            if json_out {
                crate::cli::output::print_json(&serde_json::json!({
                    "schema": "acpmux.share-host.link/1",
                    "device": device,
                    "display": display,
                    "native": link.native(),
                    "web": link.web(),
                    "sharing": sharing,
                }));
            } else {
                println!("{}", link.web());
                println!("{}", link.native());
                if sharing == Some(false) {
                    eprintln!("sharing this Mac's screen is off: acpmux share-host on");
                }
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

/// A screen link: `cmux://mac-screen?device=..&display=..` for cmux itself and
/// `https://cmux.com/deeplink/screen?..` for a tap anywhere (the universal link). No `control`
/// means view-only.
pub(crate) struct ScreenLink<'a> {
    pub device: &'a str,
    pub display: Option<u32>,
    pub name: Option<&'a str>,
    pub control: bool,
}

impl ScreenLink<'_> {
    fn query(&self) -> String {
        let mut query = format!("device={}", percent(&self.device.to_ascii_lowercase()));
        if let Some(display) = self.display {
            query.push_str(&format!("&display={display}"));
        }
        if self.control {
            query.push_str("&control=1");
        }
        if let Some(name) = self.name.filter(|n| !n.is_empty()) {
            query.push_str(&format!("&name={}", percent(name)));
        }
        query
    }

    pub fn native(&self) -> String {
        format!("cmux://mac-screen?{}", self.query())
    }

    pub fn web(&self) -> String {
        format!("https://cmux.com/deeplink/screen?{}", self.query())
    }
}

/// `value` percent-encoded for a query string (RFC 3986 unreserved bytes kept).
fn percent(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
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

#[cfg(test)]
mod link_tests {
    use super::ScreenLink;

    #[test]
    fn links_are_view_only_unless_asked_and_encode_the_name() {
        let link = ScreenLink {
            device: "D47F285E-d0ba-48b9-a593-508b0b9d1ab4",
            display: Some(17),
            name: Some("gui run #3"),
            control: false,
        };
        assert_eq!(
            link.native(),
            "cmux://mac-screen?device=d47f285e-d0ba-48b9-a593-508b0b9d1ab4&display=17&name=gui%20run%20%233"
        );
        assert!(link.web().starts_with("https://cmux.com/deeplink/screen?device=d47f285e-"));
        let control = ScreenLink { device: "x", display: None, name: None, control: true };
        assert_eq!(control.native(), "cmux://mac-screen?device=x&control=1");
    }
}
