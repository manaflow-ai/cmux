//! The Cloud link's acpmux peer bridge, off by default
//! (`CMUX_ACPMUX_CLOUD_PEER=1` turns it on). Inside the link's
//! `remote connect --headless --json` process, it makes the Cloud VM's
//! acpmux a peer of this Mac's acpmux over the remote tunnel the link
//! already holds, so the VM's agent sessions list as `cloud-<machine>/<name>`.
//!
//! After the link connects, and again whenever the lease is lost:
//!
//! 1. The machine daemon's `identify` names its binary,
//!    `<home>/.cmux/bin/cmux-tui`, which gives the VM user's home; any other
//!    place is refused.
//! 2. The VM must be a personal Cloud VM: `/etc/cmux/vm-kind` reads `owner`
//!    and there is no team files root `/srv/team`. Anything else (a team VM,
//!    no record, a folder that cannot be read) is refused, as the local
//!    agent-start gate does (`agent_start_host.rs`).
//! 3. It reads the VM acpmux's `~/.acpmux/config.json` (dashboard token and
//!    listen port, `acpmux::peer::remote_daemon_config`) and
//!    `run/peer.token` over the workspace RPC.
//! 4. A loopback-only route to `127.0.0.1:<port>` on the VM, and a local
//!    forward on `127.0.0.1:0` here (`LocalPortForward`).
//! 5. Through the forward, the VM acpmux's `_acpmux/status` must report
//!    `personKey: true`: a VM daemon started without the person key is
//!    skipped for the rest of this link (the next link checks again).
//! 6. `_acpmux/peer_lease` on this Mac's acpmux, over a unix socket
//!    connection this bridge keeps open: the peer lasts as long as that
//!    connection (acpmux `hub/peer_lease.rs`), so it is never saved and a
//!    later process on the forward's port never receives the VM's tokens.
//!
//! Every `RENEW_EVERY` it checks the lease. The VM daemon's peer token
//! changes at each start, so a peer that its VM serves as `remote` (Web)
//! instead of `peer`, or that keeps failing to connect, gets its tokens read
//! again and the lease renewed when they changed.
//!
//! The peer is named `cloud-<machine name>`; two links to VMs of the same
//! name would take the name from each other.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::bridge::LocalPortForward;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::service::ServiceMultiplexer;
use cmux_remote_protocol::{
    RouteId, RoutePolicy, WorkspaceId, WorkspaceRequest, WorkspaceResponse,
};
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};

/// The switch; only `1` turns the bridge on.
pub(super) const GATE: &str = "CMUX_ACPMUX_CLOUD_PEER";
/// How often the lease is checked, and a lost one tried again.
const RENEW_EVERY: Duration = Duration::from_secs(15);
/// A peer this many failed connects in a row gets its tokens read again.
const RENEW_AFTER_ATTEMPTS: u64 = 3;
/// The budget of the status probe through the forward.
const PROBE_BUDGET: Duration = Duration::from_secs(15);
/// The budget of one request to this Mac's acpmux while checking the lease.
const CALL_BUDGET: Duration = Duration::from_secs(15);
/// The budget of a `_acpmux/peer_lease` that waits for the first connect.
const LEASE_BUDGET: Duration = Duration::from_secs(45);
/// Most bytes read of one VM file.
const MAX_FILE_BYTES: u32 = 1 << 20;
const AREA: &str = "acpmux-peer";
const VM_ETC: &str = "/etc/cmux";
const VM_KIND_FILE: &str = "vm-kind";
const TEAM_FILES_ROOT: &str = "/srv/team";
const DAEMON_BINARY_SUFFIX: &str = "/.cmux/bin/cmux-tui";

/// Whether `CMUX_ACPMUX_CLOUD_PEER=1`.
pub(super) fn enabled() -> bool {
    gate_on(std::env::var(GATE).ok().as_deref())
}

/// The gate's rule: exactly `1`.
fn gate_on(value: Option<&str>) -> bool {
    value == Some("1")
}

/// The running bridge; dropping it ends the lease and the forward.
pub(super) struct AcpmuxPeerBridge {
    task: tokio::task::JoinHandle<()>,
}

impl AcpmuxPeerBridge {
    /// Start the bridge on the current runtime when the gate is on and this
    /// Mac's acpmux socket is known; None otherwise.
    pub(super) fn spawn(runtime: &crate::remote_runtime::ClientRuntimeHandle) -> Option<Self> {
        if !enabled() {
            return None;
        }
        let acpmux_socket = crate::acp::daemon_socket_path()?;
        let multiplexer = runtime.multiplexer().clone();
        let machine_socket = runtime.info().local_socket.clone();
        let task = tokio::spawn(run(multiplexer, machine_socket, acpmux_socket));
        Some(Self { task })
    }
}

impl Drop for AcpmuxPeerBridge {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Why the bridge could not lease: `Stop` for good (this VM must not be a
/// peer), `Retry` at the next check.
#[derive(Debug, PartialEq, Eq)]
enum Failure {
    Stop(String),
    Retry(String),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Stop(why) | Self::Retry(why) => formatter.write_str(why),
        }
    }
}

async fn run(
    multiplexer: Arc<ServiceMultiplexer>,
    machine_socket: PathBuf,
    acpmux_socket: PathBuf,
) {
    let mut tick = tokio::time::interval(RENEW_EVERY);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut live: Option<Live> = None;
    let mut last_retry = None;
    loop {
        tick.tick().await;
        if let Some(current) = live.as_mut() {
            match current.check().await {
                Ok(()) => continue,
                Err(why) => {
                    crate::client_log::warn(AREA, &format!("lease lost: {why}"));
                    if let Some(old) = live.take() {
                        old.close().await;
                    }
                }
            }
        }
        match Live::establish(&multiplexer, &machine_socket, &acpmux_socket).await {
            Ok(established) => {
                crate::client_log::info(AREA, &format!("leased peer {}", established.name));
                live = Some(established);
                last_retry = None;
            }
            Err(Failure::Stop(why)) => {
                crate::client_log::info(AREA, &format!("not leasing this machine: {why}"));
                return;
            }
            Err(Failure::Retry(why)) => {
                // One line per distinct reason, not one per check.
                if last_retry.as_ref() != Some(&why) {
                    crate::client_log::info(AREA, &format!("cannot lease yet: {why}"));
                    last_retry = Some(why);
                }
            }
        }
    }
}

/// The VM acpmux's dashboard token and peer token, as read from its home.
#[derive(Clone, PartialEq, Eq)]
struct Tokens {
    token: String,
    peer_token: Option<String>,
    port: u16,
}

impl std::fmt::Debug for Tokens {
    /// Never the tokens themselves.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Tokens")
            .field("port", &self.port)
            .field("peer_token", &self.peer_token.is_some())
            .finish_non_exhaustive()
    }
}

/// A lease in force.
struct Live {
    name: String,
    acpmux: Arc<acpmux::client::Client>,
    workspace_client: Arc<WorkspaceClient>,
    acpmux_home: WorkspaceId,
    route: RouteId,
    forward: LocalPortForward,
    tokens: Tokens,
}

impl Live {
    async fn establish(
        multiplexer: &Arc<ServiceMultiplexer>,
        machine_socket: &Path,
        acpmux_socket: &Path,
    ) -> Result<Self, Failure> {
        let socket = machine_socket.to_path_buf();
        let identity =
            tokio::task::spawn_blocking(move || crate::link::machine_gate::identify(&socket))
                .await
                .ok()
                .flatten()
                .ok_or_else(|| {
                    Failure::Retry("the machine daemon did not answer identify".into())
                })?;
        let home = identity
            .get("cli_path")
            .and_then(Value::as_str)
            .and_then(home_from_cli_path)
            .ok_or_else(|| Failure::Stop("the machine daemon runs from an unknown place".into()))?
            .to_owned();
        let name =
            peer_name(identity.get("machine_name").and_then(Value::as_str).unwrap_or_default());
        let workspace_client = WorkspaceClient::connect(multiplexer.clone())
            .await
            .map_err(|e| Failure::Retry(format!("workspace rpc: {}", e.message)))?;
        let kind = read_vm_kind(&workspace_client).await;
        let team_files = team_files_present(&workspace_client).await;
        vm_admits(kind.as_deref(), team_files).map_err(|why| Failure::Stop(why.into()))?;

        let acpmux_home = open_workspace(&workspace_client, &format!("{home}/.acpmux"))
            .await
            .map_err(|e| Failure::Retry(format!("the machine has no acpmux home: {e}")))?;
        let tokens = read_tokens(&workspace_client, &acpmux_home).await?;
        let route = match workspace_client
            .request(WorkspaceRequest::CreateRoute {
                workspace: acpmux_home.clone(),
                host: "127.0.0.1".into(),
                port: tokens.port,
                policy: RoutePolicy::LoopbackOnly,
            })
            .await
        {
            Ok(WorkspaceResponse::RouteCreated { route, .. }) => route,
            Ok(_) => return Err(Failure::Retry("unexpected create-route response".into())),
            Err(e) => return Err(Failure::Retry(format!("create route: {}", e.message))),
        };
        let listen = SocketAddr::from(([127, 0, 0, 1], 0));
        let forward = match LocalPortForward::bind(multiplexer.clone(), route, listen).await {
            Ok(forward) => forward,
            Err(e) => {
                close_route(&workspace_client, route).await;
                return Err(Failure::Retry(format!("local forward: {e}")));
            }
        };
        let url = format!("ws://{}", forward.local_addr());
        let refused = match probe_status(&url, &tokens).await {
            Ok(status) if status.get("personKey").and_then(Value::as_bool) == Some(true) => None,
            Ok(_) => Some(Failure::Stop("its acpmux runs without the person key".into())),
            Err(why) => Some(Failure::Retry(format!("its acpmux did not answer: {why}"))),
        };
        let acpmux = match refused {
            Some(refused) => Err(refused),
            None => connect_acpmux(acpmux_socket).await,
        };
        let acpmux = match acpmux {
            Ok(acpmux) => acpmux,
            Err(refused) => {
                forward.shutdown().await;
                close_route(&workspace_client, route).await;
                return Err(refused);
            }
        };
        let mut live = Self { name, acpmux, workspace_client, acpmux_home, route, forward, tokens };
        if let Err(why) = live.lease().await {
            live.close().await;
            return Err(Failure::Retry(why));
        }
        Ok(live)
    }

    fn url(&self) -> String {
        format!("ws://{}", self.forward.local_addr())
    }

    async fn lease(&mut self) -> Result<(), String> {
        let params = json!({
            "name": self.name,
            "url": self.url(),
            "token": self.tokens.token,
            "peerToken": self.tokens.peer_token,
            "wait": true,
        });
        // The daemon answers within its 30 s settle budget (`wait`).
        tokio::time::timeout(LEASE_BUDGET, self.acpmux.request("_acpmux/peer_lease", params))
            .await
            .map_err(|_| format!("peer_lease: no answer in {}s", LEASE_BUDGET.as_secs()))?
            .map(drop)
            .map_err(|e| format!("peer_lease: {e:#}"))
    }

    /// The lease still holds, renewed with fresh tokens when its VM restarted.
    async fn check(&mut self) -> Result<(), String> {
        if self.acpmux.is_closed() {
            return Err("this Mac's acpmux closed the connection".into());
        }
        let peers =
            tokio::time::timeout(CALL_BUDGET, self.acpmux.request("_acpmux/peers", json!({})))
                .await
                .map_err(|_| format!("_acpmux/peers: no answer in {}s", CALL_BUDGET.as_secs()))?
                .map_err(|e| format!("_acpmux/peers: {e:#}"))?;
        let ours = peers.get("peers").and_then(Value::as_array).and_then(|all| {
            all.iter().find(|p| p.get("name").and_then(Value::as_str) == Some(self.name.as_str()))
        });
        let Some(ours) = ours else {
            return Err("the peer is gone".into());
        };
        if !needs_renewal(ours) {
            return Ok(());
        }
        let fresh = read_tokens(&self.workspace_client, &self.acpmux_home)
            .await
            .map_err(|failure| failure.to_string())?;
        if fresh.port != self.tokens.port {
            return Err("the machine's acpmux moved to another port".into());
        }
        if fresh == self.tokens {
            return Ok(());
        }
        self.tokens = fresh;
        self.lease().await
    }

    async fn close(self) {
        // Closing the unix connection ends the lease on this Mac's acpmux.
        drop(self.acpmux);
        self.forward.shutdown().await;
        // The opened workspaces stay: the daemon keeps them per connection,
        // shared with anything else on this link, and the next open of the
        // same folder gets the same one back.
        close_route(&self.workspace_client, self.route).await;
    }
}

async fn connect_acpmux(socket: &Path) -> Result<Arc<acpmux::client::Client>, Failure> {
    acpmux::client::Client::connect(socket)
        .await
        .map_err(|e| Failure::Retry(format!("this Mac's acpmux is not running: {e:#}")))
}

async fn close_route(client: &WorkspaceClient, route: RouteId) {
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        client.request(WorkspaceRequest::CloseRoute { route }),
    )
    .await;
}

async fn open_workspace(client: &WorkspaceClient, root: &str) -> Result<WorkspaceId, String> {
    match client.request(WorkspaceRequest::OpenWorkspace { root: root.to_owned() }).await {
        Ok(WorkspaceResponse::Workspace { id, .. }) => Ok(id),
        Ok(_) => Err("unexpected open-workspace response".into()),
        Err(e) => Err(e.code),
    }
}

async fn read_file(
    client: &WorkspaceClient,
    workspace: &WorkspaceId,
    path: &str,
) -> Option<Vec<u8>> {
    let request = WorkspaceRequest::ReadFile {
        workspace: workspace.clone(),
        path: path.to_owned(),
        offset: 0,
        limit: MAX_FILE_BYTES,
    };
    match client.request(request).await {
        Ok(WorkspaceResponse::File { data, .. }) => data.decode().ok(),
        _ => None,
    }
}

/// `/etc/cmux/vm-kind`, trimmed; None when it cannot be read.
async fn read_vm_kind(client: &WorkspaceClient) -> Option<String> {
    let etc = open_workspace(client, VM_ETC).await.ok()?;
    let text = String::from_utf8(read_file(client, &etc, VM_KIND_FILE).await?).ok()?;
    Some(text.trim().to_owned())
}

/// Whether `/srv/team` may be there: it opens, or fails for any reason but
/// "not found" (fail closed).
async fn team_files_present(client: &WorkspaceClient) -> bool {
    match open_workspace(client, TEAM_FILES_ROOT).await {
        Ok(_) => true,
        Err(code) => code != "not-found",
    }
}

async fn read_tokens(client: &WorkspaceClient, home: &WorkspaceId) -> Result<Tokens, Failure> {
    let config = read_file(client, home, "config.json")
        .await
        .ok_or_else(|| Failure::Retry("the machine's acpmux has no config.json yet".into()))?;
    let peer_token = read_file(client, home, "run/peer.token")
        .await
        .and_then(|bytes| acpmux::peer::peer_token_text(&bytes));
    tokens_from(&config, peer_token).map_err(Failure::Retry)
}

/// The tokens and port from a VM acpmux's config bytes and peer token.
fn tokens_from(config: &[u8], peer_token: Option<String>) -> Result<Tokens, String> {
    let parsed = acpmux::peer::remote_daemon_config(config).map_err(|why| match why {
        acpmux::peer::RemoteConfigError::Unreadable => "its acpmux config is not readable",
        acpmux::peer::RemoteConfigError::NoToken => "its acpmux config has no websocket token",
    })?;
    let port = parsed
        .listen
        .as_deref()
        .and_then(listen_port)
        .ok_or("its acpmux does not listen on a loopback WebSocket port")?;
    Ok(Tokens { token: parsed.token, peer_token, port })
}

/// The port of a listen address the VM's loopback reaches at `127.0.0.1`:
/// `127.0.0.1:P`, `localhost:P` or `0.0.0.0:P`. None for any other host
/// (an IPv6 or a public address the route would not reach) or port 0.
fn listen_port(listen: &str) -> Option<u16> {
    let (host, port) = listen.trim().rsplit_once(':')?;
    if !matches!(host, "127.0.0.1" | "localhost" | "0.0.0.0") {
        return None;
    }
    port.parse::<u16>().ok().filter(|port| *port != 0)
}

/// The VM user's home from the machine daemon's `cli_path`
/// (`<home>/.cmux/bin/cmux-tui`, as `link/machine_update.rs` requires).
fn home_from_cli_path(cli_path: &str) -> Option<&str> {
    let home = cli_path.strip_suffix(DAEMON_BINARY_SUFFIX)?;
    let plain = home.starts_with('/')
        && home.len() > 1
        && home.split('/').skip(1).all(|part| !part.is_empty() && part != "." && part != "..");
    plain.then_some(home)
}

/// Whether a VM with this `vm-kind` and team marker may be a peer: only a
/// personal VM (`owner`) without the team files root.
fn vm_admits(kind: Option<&str>, team_files: bool) -> Result<(), &'static str> {
    if team_files || kind == Some("team") {
        return Err("it is a team VM");
    }
    match kind {
        Some("owner") => Ok(()),
        _ => Err("it is not a personal Cloud VM (no owner vm-kind)"),
    }
}

/// `cloud-<machine>`, as a valid acpmux peer name: letters, digits, `-`,
/// `_` and `.`, at most 80 characters.
fn peer_name(machine: &str) -> String {
    let cleaned: String = machine
        .trim()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
        .collect();
    let cleaned = cleaned.trim_matches(|c| c == '-' || c == '.');
    let cleaned = if cleaned.is_empty() { "vm" } else { cleaned };
    let mut name = format!("cloud-{cleaned}");
    name.truncate(80);
    name
}

/// A leased peer's `_acpmux/peers` row says its tokens may be stale: its VM
/// serves it as `remote` (Web), not `peer`, or it keeps failing to connect.
fn needs_renewal(peer: &Value) -> bool {
    if peer["connected"] == true {
        return peer["servedAs"].as_str().is_some_and(|served| served != "peer");
    }
    peer["attempts"].as_u64().unwrap_or(0) >= RENEW_AFTER_ATTEMPTS
}

/// `_acpmux/status` of the acpmux at `url`, connected as its peer.
async fn probe_status(url: &str, tokens: &Tokens) -> Result<Value, String> {
    use tokio_tungstenite::tungstenite::Message as Frame;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
    let work = async {
        let mut request = url.into_client_request().map_err(|e| e.to_string())?;
        let bearer = format!("Bearer {}", tokens.token);
        request
            .headers_mut()
            .insert("authorization", bearer.parse().map_err(|_| "bad token".to_owned())?);
        if let Some(peer) = &tokens.peer_token {
            request.headers_mut().insert(
                acpmux::server::peer_auth::HEADER,
                peer.parse().map_err(|_| "bad peer token".to_owned())?,
            );
        }
        let (mut ws, _) =
            tokio_tungstenite::connect_async(request).await.map_err(|e| e.to_string())?;
        let hello = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": 1, "clientInfo": {"name": "cmux-cloud-peer"}}});
        let status = json!({"jsonrpc": "2.0", "id": 2, "method": "_acpmux/status", "params": {}});
        for message in [hello, status] {
            ws.send(Frame::Text(message.to_string().into())).await.map_err(|e| e.to_string())?;
        }
        while let Some(frame) = ws.next().await {
            let Frame::Text(text) = frame.map_err(|e| e.to_string())? else { continue };
            let Ok(reply) = serde_json::from_str::<Value>(&text) else { continue };
            if reply.get("id").and_then(Value::as_i64) != Some(2) {
                continue;
            }
            let _ = ws.close(None).await;
            return match reply.get("result") {
                Some(result) => Ok(result.clone()),
                None => Err(reply
                    .pointer("/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("refused")
                    .to_owned()),
            };
        }
        Err("the connection closed".to_owned())
    };
    tokio::time::timeout(PROBE_BUDGET, work)
        .await
        .map_err(|_| format!("no answer in {}s", PROBE_BUDGET.as_secs()))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_listen_address_gives_the_port_only_for_a_loopback_host() {
        assert_eq!(listen_port("127.0.0.1:47811"), Some(47811));
        assert_eq!(listen_port("localhost:4000"), Some(4000));
        assert_eq!(listen_port("0.0.0.0:4000"), Some(4000));
        for refused in ["10.0.0.4:4000", "[::1]:4000", "127.0.0.1:0", "127.0.0.1:x", "4000", ""] {
            assert_eq!(listen_port(refused), None, "{refused}");
        }
    }

    #[test]
    fn tokens_come_from_the_config_and_the_peer_token_file() {
        let cfg = br#"{"websocket": {"listen": "127.0.0.1:47811", "token": "dash"}}"#;
        let peer = acpmux::peer::peer_token_text("b".repeat(64).as_bytes());
        let tokens = tokens_from(cfg, peer.clone()).unwrap();
        assert_eq!(tokens, Tokens { token: "dash".into(), peer_token: peer, port: 47811 });
        assert!(tokens_from(b"{}", None).unwrap_err().contains("no websocket token"));
        assert!(tokens_from(b"nope", None).unwrap_err().contains("not readable"));
        let public = br#"{"websocket": {"listen": "10.1.2.3:47811", "token": "dash"}}"#;
        assert!(tokens_from(public, None).unwrap_err().contains("loopback"));
        // The errors never quote the file.
        assert!(!tokens_from(public, None).unwrap_err().contains("dash"));
    }

    #[test]
    fn only_a_personal_vm_without_team_files_is_admitted() {
        assert_eq!(vm_admits(Some("owner"), false), Ok(()));
        assert_eq!(vm_admits(Some("team"), false), Err("it is a team VM"));
        assert_eq!(vm_admits(Some("owner"), true), Err("it is a team VM"));
        assert!(vm_admits(None, false).is_err());
        assert!(vm_admits(Some(""), false).is_err());
        assert!(vm_admits(Some("other"), false).is_err());
    }

    #[test]
    fn the_home_comes_only_from_the_daemons_own_install_path() {
        assert_eq!(home_from_cli_path("/home/cmux/.cmux/bin/cmux-tui"), Some("/home/cmux"));
        assert_eq!(home_from_cli_path("/root/.cmux/bin/cmux-tui"), Some("/root"));
        for refused in [
            "/usr/local/bin/cmux-tui",
            "home/cmux/.cmux/bin/cmux-tui",
            "/.cmux/bin/cmux-tui",
            "/home/../etc/.cmux/bin/cmux-tui",
            "/home//cmux/.cmux/bin/cmux-tui",
        ] {
            assert_eq!(home_from_cli_path(refused), None, "{refused}");
        }
    }

    #[test]
    fn the_peer_name_is_a_valid_acpmux_name() {
        assert_eq!(peer_name("devbox-7"), "cloud-devbox-7");
        assert_eq!(peer_name("Leo's VM"), "cloud-Leo-s-VM");
        assert_eq!(peer_name(""), "cloud-vm");
        assert_eq!(peer_name("..."), "cloud-vm");
        assert_eq!(peer_name(&"x".repeat(200)).len(), 80);
        for machine in ["devbox-7", "Leo's VM", "", "...", "a/b c", &"x".repeat(200)] {
            acpmux::session_name::validate(&peer_name(machine)).unwrap();
        }
    }

    #[test]
    fn a_peer_served_as_web_or_failing_needs_fresh_tokens() {
        assert!(!needs_renewal(&json!({"connected": true, "servedAs": "peer"})));
        assert!(needs_renewal(&json!({"connected": true, "servedAs": "remote"})));
        assert!(!needs_renewal(&json!({"connected": false, "attempts": 1})));
        assert!(needs_renewal(&json!({"connected": false, "attempts": 3})));
    }

    #[test]
    fn the_bridge_is_off_unless_the_gate_is_exactly_one() {
        assert!(gate_on(Some("1")));
        for off in [None, Some(""), Some("0"), Some("true"), Some("yes"), Some(" 1")] {
            assert!(!gate_on(off), "{off:?}");
        }
    }

    /// A stand-in VM acpmux behind a local listener: the probe connects with
    /// the dashboard and peer tokens and reads `personKey`.
    #[tokio::test]
    async fn the_status_probe_sends_both_tokens_and_reads_the_person_key() {
        use tokio_tungstenite::tungstenite::Message as Frame;
        use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut seen = (None, None);
            #[allow(clippy::result_large_err)]
            // Required by tungstenite's handshake callback signature.
            let callback = |request: &Request, response: Response| {
                let header = |name: &str| {
                    request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned)
                };
                seen = (header("authorization"), header(acpmux::server::peer_auth::HEADER));
                Ok(response)
            };
            let mut ws = tokio_tungstenite::accept_hdr_async(stream, callback).await.unwrap();
            while let Some(Ok(frame)) = ws.next().await {
                let Frame::Text(text) = frame else { continue };
                let request: Value = serde_json::from_str(&text).unwrap();
                let result = if request["method"] == "_acpmux/status" {
                    json!({"personKey": true})
                } else {
                    json!({})
                };
                let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
                if ws.send(Frame::Text(reply.to_string().into())).await.is_err() {
                    break;
                }
            }
            seen
        });
        let tokens = Tokens { token: "dash".into(), peer_token: Some("p".repeat(64)), port };
        let status = probe_status(&format!("ws://127.0.0.1:{port}"), &tokens).await.unwrap();
        assert_eq!(status["personKey"], true);
        let (authorization, peer) = server.await.unwrap();
        assert_eq!(authorization.as_deref(), Some("Bearer dash"));
        assert_eq!(peer, Some("p".repeat(64)));
    }
}
