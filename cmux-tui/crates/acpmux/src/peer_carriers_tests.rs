use super::*;
use std::future::pending;

type Dial = std::pin::Pin<Box<dyn Future<Output = Result<&'static str, String>> + Send>>;

fn after(ms: u64, result: Result<&'static str, String>) -> Dial {
    Box::pin(async move {
        tokio::time::sleep(Duration::from_millis(ms)).await;
        result
    })
}

fn dead() -> Dial {
    Box::pin(pending())
}

#[tokio::test(start_paused = true)]
async fn a_dead_direct_path_delays_ssh_by_the_stagger_only() {
    // The direct path never answers (a dead WireGuard route waits out its whole connect
    // deadline); ssh opens 300 ms after it starts.
    let started = tokio::time::Instant::now();
    let won = race(vec![(Via::Link, dead()), (Via::Ssh, after(300, Ok("ssh")))], STAGGER).await;
    let (via, value, failed) = won.expect("ssh opens");
    assert_eq!((via, value), (Via::Ssh, "ssh"));
    assert!(failed.is_empty());
    assert_eq!(started.elapsed(), STAGGER + Duration::from_millis(300));
}

#[tokio::test(start_paused = true)]
async fn a_path_that_fails_at_once_starts_the_next_at_once() {
    let started = tokio::time::Instant::now();
    let won = race(
        vec![
            (Via::Link, after(10, Err("cmux link is not running".into()))),
            (Via::Ssh, after(300, Ok("ssh"))),
        ],
        STAGGER,
    )
    .await;
    let (via, _, failed) = won.unwrap();
    assert_eq!(via, Via::Ssh);
    assert_eq!(failed, vec![(Via::Link, "cmux link is not running".to_owned())]);
    assert_eq!(started.elapsed(), Duration::from_millis(310));
}

#[tokio::test(start_paused = true)]
async fn the_first_path_wins_when_it_opens_within_the_stagger_and_ssh_never_starts() {
    let ssh_started = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = ssh_started.clone();
    let ssh: Dial = Box::pin(async move {
        flag.store(true, Ordering::SeqCst);
        Ok("ssh")
    });
    let (via, _, _) =
        race(vec![(Via::Link, after(5, Ok("link"))), (Via::Ssh, ssh)], STAGGER).await.unwrap();
    assert_eq!(via, Via::Link);
    assert!(!ssh_started.load(Ordering::SeqCst), "no ssh process for a path that opened in 5 ms");
}

#[tokio::test(start_paused = true)]
async fn a_slow_first_path_still_wins_when_it_opens_before_the_next() {
    // Both run after the stagger; the earlier answer wins and the other is dropped.
    let won =
        race(vec![(Via::Link, after(400, Ok("link"))), (Via::Ssh, after(600, Ok("ssh")))], STAGGER)
            .await
            .unwrap();
    assert_eq!(won.0, Via::Link);
}

#[tokio::test(start_paused = true)]
async fn every_failure_is_returned_when_no_path_opens() {
    let failed = race(
        vec![
            (Via::Link, after(10, Err("refused".into()))),
            (Via::Ssh, after(20, Err("Permission denied".into()))),
        ],
        STAGGER,
    )
    .await
    .unwrap_err();
    assert_eq!(failed.len(), 2);
    assert_eq!(failures_line(&failed), "link: refused; ssh: Permission denied");
    assert_eq!(failures_line(&failed[1..]), "Permission denied", "one path: its own error");
}

#[test]
fn acpmux_wireguard_is_the_direct_path_only_while_it_holds_the_key_lock() {
    // The transport runs only when it took the key lock (`wireguard::Transport::start`).
    assert_eq!(direct_via(true, true), Some(Via::Wireguard));
    assert_eq!(direct_via(true, false), Some(Via::Wireguard));
    // The link holds the key: a paired peer is reached through the link.
    assert_eq!(direct_via(false, true), Some(Via::Link));
    assert_eq!(direct_via(false, false), None);
}

#[test]
fn a_ping_stamp_measures_its_pong() {
    let stamp = ping_stamp();
    std::thread::sleep(Duration::from_millis(2));
    let rtt = pong_rtt(&stamp).unwrap();
    assert!(rtt >= Duration::from_millis(2), "{rtt:?}");
    assert_eq!(pong_rtt(b""), None, "a ping from elsewhere (the wake probe) measures nothing");
    assert_eq!(pong_rtt(&u64::MAX.to_le_bytes()), None);
}

/// A link socket that answers one `link.dial` with `reply`, then echoes a line.
#[cfg(target_os = "linux")]
async fn fake_link(reply: &'static str) -> (tempfile::TempDir, PathBuf) {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let request = lines.next_line().await.unwrap().unwrap();
        assert_eq!(request, r#"{"op":"link.dial","host":"inst_b","service":"acpmux"}"#);
        write.write_all(reply.as_bytes()).await.unwrap();
        write.write_all(b"GET / HTTP/1.1\n").await.unwrap();
        if let Ok(Some(echoed)) = lines.next_line().await {
            write.write_all(format!("{echoed}\n").as_bytes()).await.unwrap();
        }
    });
    (dir, path)
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_link_dial_asks_for_the_acpmux_service_and_keeps_the_first_stream_bytes() {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let (_dir, path) =
        fake_link("{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n").await;
    let stream = dial_link(&path, "inst_b").await.unwrap();
    let mut lines = BufReader::new(stream);
    let mut first = String::new();
    lines.read_line(&mut first).await.unwrap();
    assert_eq!(first, "GET / HTTP/1.1\n");
    lines.get_mut().write_all(b"ping\n").await.unwrap();
    let mut echoed = String::new();
    lines.read_line(&mut echoed).await.unwrap();
    assert_eq!(echoed, "ping\n");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_refused_link_dial_says_why_and_a_missing_link_is_not_running() {
    let (dir, path) = fake_link(
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n",
    )
    .await;
    let error = dial_link(&path, "inst_b").await.unwrap_err();
    assert!(error.contains("Unreachable"), "{error}");
    let error = dial_link(&dir.path().join("none.sock"), "inst_b").await.unwrap_err();
    assert!(error.starts_with("cmux link is not running"), "{error}");
}
