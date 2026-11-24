//! `acpmux share-host status [--json] | on | off | link`, the screen shares' verbs (`screens`, `start`,
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
            } else {
                print_verb(verb, &answer);
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
            ShareHostCmd::Status
            | ShareHostCmd::On
            | ShareHostCmd::Off
            | ShareHostCmd::Link { .. }
            | ShareHostCmd::Session => {
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

/// A verb's answer for a person: the list for `screens`, one record otherwise.
#[cfg(unix)]
fn print_verb(verb: &str, answer: &Value) {
    if verb == "screens" {
        super::verbs::print_list(answer);
    } else {
        super::verbs::print_record(verb, answer);
    }
}

/// No share verb answers off unix (`verb` refuses first), so there is nothing to print.
#[cfg(not(unix))]
fn print_verb(_verb: &str, _answer: &Value) {}

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
