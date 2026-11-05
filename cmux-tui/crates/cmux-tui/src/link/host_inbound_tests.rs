//! A Cloud host serves a link stream only with a token its verifier
//! accepts, for its epoch, from the install's own overlay address.

use std::net::{IpAddr, SocketAddr};

use cmux_link::overlay_addr::overlay_address;
use cmux_link::stamp::LinkPeer;
use cmux_link::token::{DenyAllTokens, Expected, TokenRefused, TokenVerifier, VerifiedToken};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use super::*;

/// Accepts the token "good" for host_vm1 at epoch 4 and names inst_mac.
struct GoodToken;

impl TokenVerifier for GoodToken {
    fn begin_handshake(
        &self,
        _host: &str,
        _epoch: u64,
        _peer_key: &[u8; 32],
    ) -> Result<StreamLease, TokenRefused> {
        Ok(StreamLease::fixed_until(std::time::Instant::now() + std::time::Duration::from_secs(30)))
    }

    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<VerifiedToken, TokenRefused> {
        if token != "good" || expected.host != "host_vm1" || expected.epoch != 4 {
            return Err(TokenRefused::Invalid);
        }
        Ok(VerifiedToken {
            vm_kind: Some(cmux_link::token::VmKind::Team),
            peer: LinkPeer { install: "inst_mac".into(), user: "42".into(), team: "team_a".into() },
            issued_at_ms: 1_700_000_000_000,
            lease: Some(StreamLease::fixed_until(
                std::time::Instant::now() + std::time::Duration::from_secs(30),
            )),
        })
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
        desktop: Path::new("/nonexistent/cmux-rd/desktop.sock"),
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
        desktop: Path::new("/nonexistent/cmux-rd/desktop.sock"),
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
async fn a_valid_desktop_hello_reaches_the_desktop_socket_and_splices_bytes() {
    let host = host().await;
    let socket = host._directory.path().join("desktop.sock");
    let desktop = tokio::net::UnixListener::bind(&socket).unwrap();
    let hello = "{\"service\":\"desktop\",\"link_token\":\"good\",\"epoch\":4}\nrd-hello\n";
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
        desktop: &socket,
    };
    let task =
        async { serve_host_inbound(link_side, [5; 32], from("inst_mac"), &GoodToken, &me).await };
    let check = async {
        let (desktop_side, _) = desktop.accept().await.unwrap();
        let mut lines = BufReader::new(desktop_side);
        let mut first = String::new();
        lines.read_line(&mut first).await.unwrap();
        assert_eq!(first, "rd-hello\n", "the hello line is the link's; the rest is the viewer's");
        lines.get_mut().write_all(b"rd-welcome\n").await.unwrap();
        let mut back = [0u8; 11];
        peer.read_exact(&mut back).await.unwrap();
        assert_eq!(&back, b"rd-welcome\n");
        drop(peer);
    };
    let (result, ()) = tokio::join!(task, check);
    assert_eq!(result, Ok(()));
    let accepted =
        tokio::time::timeout(std::time::Duration::from_millis(100), host.sshd.accept()).await;
    assert!(accepted.is_err(), "a desktop stream never reaches sshd");
}

#[tokio::test]
async fn a_desktop_hello_on_a_machine_without_the_socket_is_refused_as_desktop_unavailable() {
    let host = host().await;
    let hello = "{\"service\":\"desktop\",\"link_token\":\"good\",\"epoch\":4}\n";
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
        desktop: Path::new("/nonexistent/cmux-rd/desktop.sock"),
    };
    let mut trace = StreamTrace::default();
    let result = serve_host_inbound_traced(
        link_side,
        [5; 32],
        from("inst_mac"),
        &GoodToken,
        &me,
        &mut trace,
    )
    .await;
    assert_eq!(result, Err(HostRefused::DesktopUnavailable));
    assert_eq!(trace.service, Some(Service::Desktop));
    let mut line = String::new();
    BufReader::new(&mut peer).read_line(&mut line).await.unwrap();
    let refusal = super::super::refusal_watch::parse_refusal(line.trim_end().as_bytes()).unwrap();
    assert_eq!(refusal.reason, "DesktopUnavailable");
    assert_eq!(refusal.check.as_deref(), Some("desktop_unavailable"));
}

#[tokio::test]
async fn token_issue_time_valid_daemon_hello_reaches_the_entry_as_the_token_install() {
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
        desktop: Path::new("/nonexistent/cmux-rd/desktop.sock"),
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
            "{\"link_peer\":{\"install\":\"inst_mac\",\"user\":\"42\",\"team\":\"team_a\"},\"check\":\"native_link_token\",\"check_issued_at_ms\":1700000000000,\"native_vm_kind\":\"team\"}\n",
            "the accepted token is stamped as the stream's control-plane check"
        );
        drop(peer);
    };
    let (result, ()) = tokio::join!(task, check);
    assert_eq!(result, Ok(()));
}

async fn serve_traced(
    host: &Host,
    hello: &str,
    verifier: &dyn TokenVerifier,
) -> (Result<(), HostRefused>, StreamTrace, String) {
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(hello.as_bytes()).await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
        desktop: Path::new("/nonexistent/cmux-rd/desktop.sock"),
    };
    let mut trace = StreamTrace::default();
    let source = from("inst_mac");
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        serve_host_inbound_traced(link_side, [5; 32], source, verifier, &me, &mut trace),
    )
    .await
    .expect("a refused stream ends at once");
    let line = super::super::native_receiver::stream_ended_line(
        7,
        &source,
        std::time::Duration::from_millis(12),
        &trace,
        Some(&result),
    );
    (result, trace, line)
}

/// RED before the receiver's journal line: a refused stream closed with no word on either side
/// (the Mac saw its daemon stream end with no byte), so nobody could tell which check dropped it.
#[tokio::test]
async fn a_refused_stream_says_which_check_refused_it() {
    let host = host().await;
    let (result, trace, line) = serve_traced(
        &host,
        "{\"service\":\"daemon\",\"link_token\":\"bad\",\"epoch\":4}\n",
        &GoodToken,
    )
    .await;
    assert_eq!(result, Err(HostRefused::Token));
    assert_eq!(trace.token, Some(TokenRefused::Invalid));
    assert!(line.contains("receiver stream 7 (daemon)"), "{line}");
    assert!(line.ends_with("ended after 12 ms: refused: token Invalid"), "{line}");
    assert!(!line.contains("bad"), "the line never carries the token: {line}");

    let (_, trace, line) = serve_traced(&host, "{\"service\":\"daemon\"}\n", &GoodToken).await;
    assert_eq!(trace.token, Some(TokenRefused::Missing));
    assert!(line.ends_with("refused: token Missing"), "{line}");

    let (_, _, line) = serve_traced(
        &host,
        "{\"service\":\"daemon\",\"link_token\":\"good\",\"epoch\":3}\n",
        &GoodToken,
    )
    .await;
    assert!(line.ends_with("refused: StaleEpoch"), "{line}");

    // The token passed but no session daemon listens at the entry.
    let (result, trace, line) = serve_traced(
        &host,
        "{\"service\":\"daemon\",\"link_token\":\"good\",\"epoch\":4}\n",
        &GoodToken,
    )
    .await;
    assert_eq!(result, Err(HostRefused::Inbound(InboundRefused::EntryUnavailable)));
    assert_eq!(trace.spliced, None);
    assert!(line.ends_with("refused: Inbound(EntryUnavailable)"), "{line}");
}

/// A served stream's line has the bytes each way, so a stream the far side closed with nothing
/// written reads as `0 bytes back`.
#[tokio::test]
async fn a_spliced_stream_reports_its_bytes_each_way() {
    let host = host().await;
    let (mut peer, link_side) = tokio::io::duplex(64 * 1024);
    peer.write_all(b"{\"service\":\"ssh\",\"link_token\":\"good\",\"epoch\":4}\nabc")
        .await
        .unwrap();
    peer.shutdown().await.unwrap();
    let me = HostIdentity {
        host: "host_vm1",
        epoch: 4,
        session_socket: &host.session,
        sshd: host.sshd.local_addr().unwrap(),
        desktop: Path::new("/nonexistent/cmux-rd/desktop.sock"),
    };
    let mut trace = StreamTrace::default();
    let sshd = async {
        let (mut conn, _) = host.sshd.accept().await.unwrap();
        let mut got = Vec::new();
        conn.read_to_end(&mut got).await.unwrap();
        conn.write_all(b"xy").await.unwrap();
        got
    };
    let (result, got) = tokio::join!(
        serve_host_inbound_traced(
            link_side,
            [5; 32],
            from("inst_mac"),
            &GoodToken,
            &me,
            &mut trace
        ),
        sshd
    );
    assert_eq!(result, Ok(()));
    assert_eq!(got, b"abc");
    let line = super::super::native_receiver::stream_ended_line(
        8,
        &from("inst_mac"),
        std::time::Duration::from_millis(3),
        &trace,
        Some(&result),
    );
    assert!(line.contains("receiver stream 8 (ssh)"), "{line}");
    assert!(line.ends_with("spliced: 3 bytes in, 2 bytes back"), "{line}");
}

/// A stream the receiver itself closed (its peer left the policy) says so, with the service
/// its hello had named.
#[test]
fn a_stream_the_receiver_closed_says_so() {
    let trace = StreamTrace { service: Some(Service::Daemon), ..StreamTrace::default() };
    let line = super::super::native_receiver::stream_ended_line(
        9,
        &from("inst_mac"),
        std::time::Duration::from_millis(4100),
        &trace,
        None,
    );
    assert!(line.contains("receiver stream 9 (daemon)"), "{line}");
    assert!(line.contains("ended after 4100 ms: closed by the receiver"), "{line}");
    let line = super::super::native_receiver::stream_ended_line(
        10,
        &from("inst_mac"),
        std::time::Duration::ZERO,
        &StreamTrace::default(),
        None,
    );
    assert!(line.contains("(no hello)"), "{line}");
}
