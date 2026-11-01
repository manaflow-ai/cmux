//! A WireGuard route on an SSH peer must use the same resolved credentials.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, Stdio};
use std::time::Duration;

struct Daemon(Child);
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(home: &Path, config: Value, ssh_dir: Option<&Path>) -> Daemon {
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    let mut command = daemon_env::acpmux(home);
    command
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--listen", "127.0.0.1:0"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if let Some(dir) = ssh_dir {
        command.env("PATH", format!("{}:{}", dir.display(), daemon_env::bare_path(&[])));
    }
    let mut child = Daemon(command.spawn().unwrap());
    let stdout = child.0.stdout.take().unwrap();
    let (ready, received) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.starts_with('{') {
                let _ = ready.send(line);
            }
        }
    });
    let ready: Value =
        serde_json::from_str(&received.recv_timeout(Duration::from_secs(30)).unwrap()).unwrap();
    assert_eq!(ready["ready"], true);
    child
}

fn request(home: &Path, method: &str, params: Value) -> Value {
    let mut stream = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(40))).unwrap();
    writeln!(stream, "{}", json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}))
        .unwrap();
    for line in BufReader::new(stream).lines().map_while(Result::ok) {
        let value: Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 1 {
            return value;
        }
    }
    panic!("daemon closed before reply");
}

#[test]
fn wireguard_ssh_peer_resolves_missing_peer_token_before_connecting() {
    let local = tempfile::tempdir().unwrap();
    let remote = tempfile::tempdir().unwrap();
    let scripts = tempfile::tempdir().unwrap();
    let local_key = acpmux::cli::mesh_node_key::load_or_create_at(local.path()).unwrap();
    let remote_key = acpmux::cli::mesh_node_key::load_or_create_at(remote.path()).unwrap();
    let local_udp = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let remote_udp = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let local_endpoint = local_udp.local_addr().unwrap();
    let remote_endpoint = remote_udp.local_addr().unwrap();
    let remote_config = json!({
        "transport":{"wireguard":true,"wireguardStatic":{"listen":remote_endpoint,"address":"10.79.0.2:4100"}},
        "peers":{"local":{"url":"ws://127.0.0.1:1","wireguard":{
            "publicKey":local_key.public_key_b64(),"endpoint":local_endpoint.to_string(),"address":"10.79.0.1:4100"}}}
    });
    drop(remote_udp);
    let _remote = start(remote.path(), remote_config, None);
    let remote_config: Value =
        serde_json::from_slice(&std::fs::read(remote.path().join("config.json")).unwrap()).unwrap();
    let token = remote_config["websocket"]["token"].as_str().unwrap();
    let script = format!(
        r#"#!/usr/bin/env python3
import os, sys
if "-W" in sys.argv:
    raise SystemExit("this test requires the WireGuard data path")
home = {home}
os.write(1, open(os.path.join(home, "config.json"), "rb").read() + b"\0" + open(os.path.join(home, "run", "peer.token"), "rb").read())
"#,
        home = serde_json::to_string(&remote.path().to_string_lossy()).unwrap()
    );
    let ssh = scripts.path().join("ssh");
    std::fs::write(&ssh, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let url = "ssh://fixture.invalid:1";
    let local_config = json!({
        "transport":{"wireguard":true,"wireguardStatic":{"listen":local_endpoint,"address":"10.79.0.1:4100"}},
        "peers":{"remote":{"url":url,"token":token,"wireguard":{
            "publicKey":remote_key.public_key_b64(),"endpoint":remote_endpoint.to_string(),"address":"10.79.0.2:4100"}}}
    });
    drop(local_udp);
    let _local = start(local.path(), local_config, Some(scripts.path()));
    // Re-add with wait uses the existing WG route and waits on its settlement event.
    // No polling: without the fix it settles disconnected after the stale-token reconnect.
    let reply = request(
        local.path(),
        "_acpmux/peer_add",
        json!({"name":"remote","url":url,"token":token,"wait":true}),
    );
    assert!(reply["error"].is_null(), "{reply}");
    let peer = &reply["result"]["peers"][0];
    assert_eq!(peer["state"], "connected", "{reply}");
    assert_eq!(peer["servedAs"], "peer", "{reply}");
}

#[tokio::test]
async fn daemon_restart_sends_close_1012_before_wireguard_shutdown() {
    use futures_util::StreamExt;
    use tokio_tungstenite::tungstenite::{Message, protocol::frame::coding::CloseCode};

    let local = tempfile::tempdir().unwrap();
    let remote = tempfile::tempdir().unwrap();
    let local_key = acpmux::cli::mesh_node_key::load_or_create_at(local.path()).unwrap();
    let remote_key = acpmux::cli::mesh_node_key::load_or_create_at(remote.path()).unwrap();
    let remote_udp = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let local_endpoint: std::net::SocketAddr = "127.0.0.1:9".parse().unwrap();
    let remote_endpoint = remote_udp.local_addr().unwrap();
    drop(remote_udp);
    let remote_daemon = start(
        remote.path(),
        json!({
            "transport":{"wireguard":true,"wireguardStatic":{"listen":remote_endpoint,"address":"10.80.0.2:4100"}},
            "peers":{"local":{"url":"ws://127.0.0.1:1","wireguard":{
                "publicKey":local_key.public_key_b64(),"endpoint":local_endpoint.to_string(),"address":"10.80.0.1:4100"}}}
        }),
        None,
    );
    let config: Value =
        serde_json::from_slice(&std::fs::read(remote.path().join("config.json")).unwrap()).unwrap();
    let token = config["websocket"]["token"].as_str().unwrap();
    let local_config = serde_json::from_value(json!({
        "transport":{"wireguard":true,"wireguardStatic":{"listen":"127.0.0.1:0","address":"10.80.0.1:4100"}},
        "peers":{"remote":{"url":"ws://127.0.0.1:1","wireguard":{
            "publicKey":remote_key.public_key_b64(),"endpoint":remote_endpoint.to_string(),"address":"10.80.0.2:4100"}}}
    })).unwrap();
    let transport = acpmux::wireguard::Transport::start(
        &local_config,
        local.path(),
        "127.0.0.1:1".parse().unwrap(),
    )
    .await
    .unwrap()
    .unwrap();
    let stream = transport.connect("10.80.0.2:4100".parse().unwrap()).await.unwrap();
    let (mut websocket, _) =
        tokio_tungstenite::client_async(format!("ws://localhost:4100/?token={token}"), stream)
            .await
            .unwrap();
    // Signal only the child this fixture owns. This follows the daemon update path.
    assert_eq!(unsafe { libc::kill(remote_daemon.0.id() as libc::pid_t, libc::SIGTERM) }, 0);
    let close = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(message) = websocket.next().await {
            if let Message::Close(frame) = message.expect("WG must carry the restart close") {
                return frame;
            }
        }
        panic!("WireGuard closed before the daemon's restart notice");
    })
    .await
    .expect("WireGuard must drain the restart notice")
    .unwrap();
    assert_eq!(close.code, CloseCode::Restart);
    let _ = websocket.close(None).await;
    transport.shutdown(tokio::time::Instant::now()).await;
}
