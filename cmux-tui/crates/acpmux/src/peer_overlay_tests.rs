//! The cmux link as a plain ssh machine's backup path (`peer_overlay.rs`).

use super::*;
use crate::peer_last_good::{Endpoints, LastGood};
use crate::peer_paths::{Carrier, Paths};
use serde_json::json;
use std::time::Duration;
use tokio::sync::mpsc;

/// Nothing answers ssh on port 1: the machine's ssh is down.
const SSH_DOWN: &str = "ssh://nobody@127.0.0.1:1";
const KEY_B: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
const KEY_OTHER: &str = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=";

/// A link state directory paired with `inst_b` (key [`KEY_B`]).
fn paired_link_dir() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let pairings = json!({"peers": [{
        "install": "inst_b", "user": "usr_a", "team": "team_a", "public_key": KEY_B,
    }]});
    std::fs::write(dir.path().join("peers.json"), pairings.to_string()).unwrap();
    dir
}

fn ssh_peer(name: &str, token: Option<&str>, peer_token: Option<&str>) -> Arc<Peer> {
    let (tx, _rx) = mpsc::channel(8);
    Peer::new(name, SSH_DOWN, token.map(str::to_owned), peer_token.map(str::to_owned), tx)
}

#[test]
fn a_health_reply_names_a_paired_install_by_its_link_install_or_its_node_key() {
    let dir = paired_link_dir();
    let by_install = json!({"link": {"install": "inst_b"}});
    assert_eq!(overlay_install_in(dir.path(), &by_install).as_deref(), Some("inst_b"));
    let by_key = json!({"node": {"wgPublicKey": KEY_B}});
    assert_eq!(overlay_install_in(dir.path(), &by_key).as_deref(), Some("inst_b"));
    let unpaired = json!({"link": {"install": "inst_other"}, "node": {"wgPublicKey": KEY_OTHER}});
    assert_eq!(overlay_install_in(dir.path(), &unpaired), None, "only this link's pairings");
    assert_eq!(overlay_install_in(dir.path(), &json!({"os": "linux"})), None);
    let no_link = tempfile::tempdir().unwrap();
    assert_eq!(overlay_install_in(no_link.path(), &by_install), None, "no pairings, no path");
}

#[test]
fn a_remembered_install_comes_back_only_for_the_same_url_while_still_paired() {
    let dir = paired_link_dir();
    let entry = Entry {
        via: Some(Via::Ssh),
        endpoints: Endpoints {
            url: Some(SSH_DOWN.into()),
            link: Some("inst_b".into()),
            wireguard: None,
        },
        ..Entry::default()
    };
    assert_eq!(
        remembered_install_in(dir.path(), Some(&entry), SSH_DOWN).as_deref(),
        Some("inst_b")
    );
    assert_eq!(remembered_install_in(dir.path(), Some(&entry), "ssh://other@box"), None);
    assert_eq!(remembered_install_in(dir.path(), None, SSH_DOWN), None);
    let unpaired = tempfile::tempdir().unwrap();
    assert_eq!(remembered_install_in(unpaired.path(), Some(&entry), SSH_DOWN), None);
}

#[test]
fn this_machine_names_its_own_link_install() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(own_install_in(dir.path()), None);
    std::fs::write(dir.path().join("config.json"), r#"{"install":"inst_a","port":4101}"#).unwrap();
    assert_eq!(own_install_in(dir.path()).as_deref(), Some("inst_a"));
    std::fs::write(dir.path().join("config.json"), r#"{"install":"bad id"}"#).unwrap();
    assert_eq!(own_install_in(dir.path()), None);
}

#[test]
fn a_path_added_later_is_dialed_and_added_once() {
    let mut paths = Paths::new(&[Via::Ssh]);
    assert!(paths.add(Via::Link));
    assert!(!paths.add(Via::Link), "once");
    assert!(!paths.add(Via::Ssh));
    assert_eq!(paths.dial_order(0), [Via::Link, Via::Ssh]);
}

/// SSH up, no overlay: ssh is the machine's only path, as before.
#[tokio::test]
async fn a_machine_with_no_pairing_keeps_ssh_as_its_only_path() {
    let dir = paired_link_dir();
    let peer = ssh_peer("ssh-only", None, None);
    let unpaired = json!({"node": {"wgPublicKey": KEY_OTHER}});
    assert!(!peer.learn_overlay_in(dir.path(), &unpaired));
    assert_eq!(peer.dial_order(), [Via::Ssh]);
    peer.stop();
}

/// SSH down, no overlay: the connect fails with ssh's own error, nothing else is tried.
#[tokio::test]
async fn ssh_down_with_no_overlay_fails_with_the_ssh_error() {
    let peer = ssh_peer("ssh-down-no-overlay", None, None);
    let error = tokio::time::timeout(Duration::from_secs(30), peer.open_first())
        .await
        .expect("the ssh failure is bounded")
        .err()
        .expect("nothing reaches the machine");
    assert!(error.to_ascii_lowercase().contains("ssh"), "the ssh path's failure: {error}");
    assert!(!error.contains("link:"), "no other path was tried: {error}");
    peer.stop();
}

/// A peer whose config names its own route is left alone.
#[tokio::test]
async fn a_configured_link_host_is_never_replaced() {
    let dir = paired_link_dir();
    let peer = ssh_peer("configured", None, None);
    peer.set_link_host("inst_configured".into());
    assert!(!peer.learn_overlay_in(dir.path(), &json!({"link": {"install": "inst_b"}})));
    assert_eq!(peer.link_host.get().map(String::as_str), Some("inst_configured"));
    peer.stop();
}

/// A restarted daemon takes the remembered install back before its first dial.
#[tokio::test]
async fn a_remembered_overlay_is_a_path_from_the_first_dial() {
    let dir = paired_link_dir();
    let book = Arc::new(LastGood::open(None));
    book.record(
        "remembered",
        Entry {
            via: Some(Via::Ssh),
            endpoints: Endpoints {
                url: Some(SSH_DOWN.into()),
                link: Some("inst_b".into()),
                wireguard: None,
            },
            ..Entry::default()
        },
    );
    let peer = ssh_peer("remembered", None, None);
    peer.set_last_good(book);
    peer.recall_overlay_in(dir.path());
    assert_eq!(peer.link_host.get().map(String::as_str), Some("inst_b"));
    assert!(peer.dial_order().contains(&Via::Link));
    peer.stop();
}

/// A link socket that answers one `link.dial` of `inst_b`'s acpmux, then serves a WebSocket.
#[cfg(target_os = "linux")]
async fn fake_link_to_a_listener() -> (tempfile::TempDir, std::path::PathBuf) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut request = String::new();
        stream.read_line(&mut request).await.unwrap();
        assert_eq!(request.trim_end(), r#"{"op":"link.dial","host":"inst_b","service":"acpmux"}"#);
        let reply = "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n";
        stream.get_mut().write_all(reply.as_bytes()).await.unwrap();
        let ws = tokio_tungstenite::accept_async(stream.into_inner()).await.unwrap();
        std::future::pending::<()>().await;
        drop(ws);
    });
    (dir, path)
}

/// SSH down, overlay found: the connect goes over the cmux link, which the app shows as a
/// direct link.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn ssh_down_with_a_found_overlay_connects_over_the_cmux_link() {
    let (_socket_dir, socket) = fake_link_to_a_listener().await;
    let dir = paired_link_dir();
    // The tokens the earlier ssh read kept (configured here: ssh is down).
    let peer = ssh_peer("ssh-down-overlay", Some("token"), Some("peer-token"));
    // The machine was reached over ssh before: its paths exist, with ssh alone.
    assert_eq!(peer.dial_order(), [Via::Ssh]);
    assert!(peer.learn_overlay_in(dir.path(), &json!({"link": {"install": "inst_b"}})));
    assert!(!peer.learn_overlay_in(dir.path(), &json!({"link": {"install": "inst_b"}})), "once");
    peer.set_link_socket(socket);
    assert_eq!(peer.dial_order(), [Via::Link, Via::Ssh]);
    let (via, _opened) = tokio::time::timeout(Duration::from_secs(5), peer.open_first())
        .await
        .expect("the link path waited on ssh")
        .unwrap();
    assert_eq!(via, Via::Link);
    assert_eq!(via.carrier(), Carrier::Direct);
    peer.stop();
}

#[test]
fn the_backup_line_says_which_path_carries_the_link_and_why_ssh_does_not() {
    use crate::peer::carriers::backup_line;
    let refused = [(Via::Ssh, "SSH connection refused".to_owned())];
    assert_eq!(
        backup_line(Via::Link, true, &refused).as_deref(),
        Some("ssh did not connect (SSH connection refused); the link runs on the link path")
    );
    assert_eq!(
        backup_line(Via::Link, true, &[]).as_deref(),
        Some("ssh had not connected first; the link runs on the link path")
    );
    assert_eq!(backup_line(Via::Ssh, true, &[]), None, "ssh carries it: nothing to say");
    assert_eq!(backup_line(Via::Link, false, &[]), None, "a peer with no ssh path");
}
