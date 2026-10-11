//! A Cloud host serves a link stream only with a token its verifier
//! accepts, for its epoch, from the install's own overlay address.

use std::net::{IpAddr, SocketAddr};

use cmux_link::overlay_addr::overlay_address;
use cmux_link::stamp::LinkPeer;
use cmux_link::token::{DenyAllTokens, Expected, TokenRefused, TokenVerifier};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use super::*;

/// Accepts the token "good" for host_vm1 at epoch 4 and names inst_mac.
struct GoodToken;

impl TokenVerifier for GoodToken {
    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<LinkPeer, TokenRefused> {
        if token != "good" || expected.host != "host_vm1" || expected.epoch != 4 {
            return Err(TokenRefused::Invalid);
        }
        Ok(LinkPeer { install: "inst_mac".into(), user: "42".into(), team: "team_a".into() })
    }
}

fn from(install: &str) -> SocketAddr {
    SocketAddr::new(IpAddr::V6(overlay_address(install)), 40000)
}

struct Host {
    _directory: cmux_unix_socket::TestDir,
    session: std::path::PathBuf,
    sshd: tokio::net::TcpListener,
}

async fn host() -> Host {
    let directory = cmux_unix_socket::short_test_dir("linkhost");
    let session = directory.path().join("s.sock");
    let sshd = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    Host { _directory: directory, session, sshd }
}

async fn serve(
    host: &Host,
    hello: &str,
    verifier: &dyn TokenVerifier,
    source: SocketAddr,
) -> (Result<(), HostRefused>, tokio::io::DuplexStream) {
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
    };
    // A refused stream ends at once; one still open after 5 s was served.
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        serve_host_inbound(link_side, [5; 32], source, verifier, &me),
    )
    .await
    .unwrap_or(Ok(()));
    (result, peer)
}

/// RED (security): with no token format configured, a host serves nothing.
#[tokio::test]
async fn the_default_verifier_serves_nothing() {
    let host = host().await;
    let hello = "{\"service\":\"ssh\",\"link_token\":\"good\",\"epoch\":4}\n";
    let (result, _) = serve(&host, hello, &DenyAllTokens, from("inst_mac")).await;
    assert_eq!(result, Err(HostRefused::Token));
    let accepted =
        tokio::time::timeout(std::time::Duration::from_millis(200), host.sshd.accept()).await;
    assert!(accepted.is_err(), "sshd must not see a stream the host refused");
}

#[tokio::test]
async fn a_hello_without_a_token_with_an_old_epoch_or_from_another_install_is_refused() {
    let host = host().await;
    let cases = [
        ("{\"service\":\"daemon\"}\n", from("inst_mac"), HostRefused::Token),
        (
            "{\"service\":\"daemon\",\"link_token\":\"good\",\"epoch\":3}\n",
            from("inst_mac"),
            HostRefused::StaleEpoch,
        ),
        (
            "{\"service\":\"daemon\",\"link_token\":\"good\",\"epoch\":5}\n",
            from("inst_mac"),
            HostRefused::StaleEpoch,
        ),
        (
            "{\"service\":\"daemon\",\"link_token\":\"bad\",\"epoch\":4}\n",
            from("inst_mac"),
            HostRefused::Token,
        ),
        (
            "{\"service\":\"daemon\",\"link_token\":\"good\",\"epoch\":4}\n",
            from("inst_other"),
            HostRefused::AddressMismatch,
        ),
    ];
    for (hello, source, refused) in cases {
        let (result, _) = serve(&host, hello, &GoodToken, source).await;
        assert_eq!(result, Err(refused), "{hello}");
    }
}

#[tokio::test]
async fn a_valid_ssh_hello_reaches_the_loopback_sshd() {
    let host = host().await;
    let hello = "{\"service\":\"ssh\",\"link_token\":\"good\",\"epoch\":4}\nSSH-2.0-client\n";
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
    };
    let task =
        async { serve_host_inbound(link_side, [5; 32], from("inst_mac"), &GoodToken, &me).await };
    let check = async {
        let (sshd_side, _) = host.sshd.accept().await.unwrap();
        let mut lines = BufReader::new(sshd_side);
        let mut banner = String::new();
        lines.read_line(&mut banner).await.unwrap();
        assert_eq!(banner, "SSH-2.0-client\n");
        lines.get_mut().write_all(b"SSH-2.0-server\n").await.unwrap();
        let mut back = [0u8; 15];
        peer.read_exact(&mut back).await.unwrap();
        assert_eq!(&back, b"SSH-2.0-server\n");
        drop(peer);
    };
    let (result, ()) = tokio::join!(task, check);
    assert_eq!(result, Ok(()));
}

#[tokio::test]
async fn a_valid_daemon_hello_reaches_the_remote_entry_stamped_as_the_token_install() {
    let host = host().await;
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&host.session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(&entry_path).unwrap();
    let hello = "{\"service\":\"daemon\",\"link_token\":\"good\",\"epoch\":4}\n";
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
    };
    let task =
        async { serve_host_inbound(link_side, [5; 32], from("inst_mac"), &GoodToken, &me).await };
    let check = async {
        let (mut daemon_side, _) = entry.accept().await.unwrap();
        daemon_side.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
        let mut lines = BufReader::new(daemon_side);
        let mut stamp = String::new();
        lines.read_line(&mut stamp).await.unwrap();
        assert_eq!(
            stamp,
            "{\"link_peer\":{\"install\":\"inst_mac\",\"user\":\"42\",\"team\":\"team_a\"},\"check\":\"link_token\"}\n",
            "the accepted token is stamped as the stream's control-plane check"
        );
        drop(peer);
    };
    let (result, ()) = tokio::join!(task, check);
    assert_eq!(result, Ok(()));
}
