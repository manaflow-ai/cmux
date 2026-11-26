use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::*;

#[derive(Clone, Copy)]
struct Server {
    /// Answer `Range` with 206 (else 200 and the whole body).
    ranges: bool,
    /// `/asset` answers 302 to `/blob`, as a GitHub release asset does.
    redirect: bool,
    /// The first slice request (a range longer than one byte) is cut off after half its body.
    cut_once: bool,
    /// Every slice answers one byte too few.
    short: bool,
    /// An open-ended range from byte 0 (the head stream) trickles at about 100 KB/s.
    slow_head: bool,
    /// The head stream sends its headers and then nothing.
    silent_head: bool,
    /// Every slice's `Content-Range` names the wrong first byte (the length is right).
    wrong_offset: bool,
    /// With `redirect`: each redirect hands out a new `/blob?sig=N`, and a slice on the first one
    /// is refused with 403, as an expired signed URL is.
    expire_first_sig: bool,
}

struct Running {
    base: String,
    /// Requests with a range longer than one byte.
    slices: Arc<AtomicUsize>,
    /// Requests of any kind.
    hits: Arc<AtomicUsize>,
}

fn body(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i.wrapping_mul(31).wrapping_add(i >> 8)) as u8).collect()
}

async fn serve(data: Vec<u8>, cfg: Server) -> Running {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let slices = Arc::new(AtomicUsize::new(0));
    let hits = Arc::new(AtomicUsize::new(0));
    let cut = Arc::new(AtomicUsize::new(0));
    let sigs = Arc::new(AtomicUsize::new(0));
    let data = Arc::new(data);
    let (s2, h2) = (slices.clone(), hits.clone());
    tokio::spawn(async move {
        loop {
            let (sock, _) = listener.accept().await.unwrap();
            let counters = (s2.clone(), h2.clone(), cut.clone(), sigs.clone());
            tokio::spawn(handle(sock, data.clone(), cfg, counters));
        }
    });
    Running { base, slices, hits }
}

async fn handle(
    mut sock: TcpStream,
    data: Arc<Vec<u8>>,
    cfg: Server,
    (slices, hits, cut, sigs): (
        Arc<AtomicUsize>,
        Arc<AtomicUsize>,
        Arc<AtomicUsize>,
        Arc<AtomicUsize>,
    ),
) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = sock.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    hits.fetch_add(1, Ordering::SeqCst);
    let head = String::from_utf8_lossy(&buf).to_string();
    let path = head.split_whitespace().nth(1).unwrap_or("/").to_owned();
    if cfg.redirect && path == "/asset" {
        let sig = sigs.fetch_add(1, Ordering::SeqCst) + 1;
        let out = format!(
            "HTTP/1.1 302 Found\r\nLocation: /blob?sig={sig}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        let _ = sock.write_all(out.as_bytes()).await;
        return;
    }
    let range = head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case("range").then(|| v.trim().to_owned())
    });
    let total = data.len();
    if total == 0 {
        let out = if range.is_some() && cfg.ranges {
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        };
        let _ = sock.write_all(out.as_bytes()).await;
        return;
    }
    let (status, from, to) = match range.as_deref().and_then(|r| r.strip_prefix("bytes=")) {
        Some(r) if cfg.ranges => {
            let (a, b) = r.split_once('-').unwrap();
            let b = if b.is_empty() { total - 1 } else { b.parse::<usize>().unwrap() };
            ("206 Partial Content", a.parse::<usize>().unwrap(), b)
        }
        _ => ("200 OK", 0, total - 1),
    };
    let mut to = to.min(total - 1);
    let is_slice = status.starts_with("206") && to > from;
    if is_slice && cfg.expire_first_sig && path.ends_with("sig=1") {
        let _ = sock
            .write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await;
        return;
    }
    if is_slice {
        slices.fetch_add(1, Ordering::SeqCst);
        if cfg.short {
            to -= 1;
        }
    }
    let payload = &data[from..=to];
    let mut out =
        format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n", payload.len());
    if status.starts_with("206") {
        let shift = usize::from(is_slice && cfg.wrong_offset);
        out.push_str(&format!("Content-Range: bytes {}-{}/{total}\r\n", from + shift, to + shift));
    }
    out.push_str("\r\n");
    let _ = sock.write_all(out.as_bytes()).await;
    let head_stream = is_slice && from == 0 && range.as_deref().is_some_and(|r| r.ends_with('-'));
    if cfg.silent_head && head_stream {
        tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        return;
    }
    if is_slice && cfg.cut_once && cut.fetch_add(1, Ordering::SeqCst) == 0 {
        let _ = sock.write_all(&payload[..payload.len() / 2]).await;
        return;
    }
    if cfg.slow_head && is_slice && from == 0 && range.as_deref().is_some_and(|r| r.ends_with('-'))
    {
        for piece in payload.chunks(1000) {
            if sock.write_all(piece).await.is_err() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        return;
    }
    let _ = sock.write_all(payload).await;
}

fn hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

fn plain() -> Server {
    Server {
        ranges: true,
        redirect: false,
        cut_once: false,
        short: false,
        slow_head: false,
        silent_head: false,
        wrong_offset: false,
        expire_first_sig: false,
    }
}

fn small(ranges: usize) -> Options {
    Options { ranges, threshold: 1000, sha256: None, adaptive: None }
}

#[test]
fn a_file_is_split_into_slices_that_cover_it_exactly_once() {
    for (total, n) in [(1u64, 16usize), (15, 16), (16, 16), (17, 16), (1000, 3), (100_000_007, 16)]
    {
        let parts = split(total, n);
        assert!(parts.len() <= n);
        assert_eq!(parts[0].0, 0);
        assert_eq!(parts.last().unwrap().1, total - 1);
        for pair in parts.windows(2) {
            assert_eq!(pair[0].1 + 1, pair[1].0, "no gap or overlap for {total}/{n}");
        }
    }
}

#[test]
fn a_content_range_total_is_read() {
    assert_eq!(content_range_total("bytes 0-0/12345"), Some(12345));
    assert_eq!(content_range_total("bytes 0-0/*"), None);
}

#[test]
fn a_content_range_span_is_read() {
    assert_eq!(content_range_span("bytes 10-19/100"), Some((10, 19)));
    assert_eq!(content_range_span("bytes */100"), None);
    assert_eq!(content_range_span("items 0-1/2"), None);
}

#[tokio::test]
async fn an_empty_file_is_an_empty_file_not_an_error() {
    let srv = serve(Vec::new(), plain()).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let report = fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &small(16))
        .await
        .unwrap();
    assert_eq!((report.bytes, report.ranges), (0, 1));
    assert_eq!(std::fs::read(&dest).unwrap(), Vec::<u8>::new());
}

#[tokio::test]
async fn a_slice_at_the_wrong_offset_is_refused() {
    let data = body(100_000);
    let srv = serve(data, Server { wrong_offset: true, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let err = fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &small(4))
        .await
        .unwrap_err();
    assert!(format!("{err:#}").contains("answered with bytes"), "{err:#}");
    assert!(!dest.exists() && !part_path(&dest).exists());
}

#[tokio::test]
async fn an_expired_signed_url_is_fetched_again_from_the_original_url() {
    let data = body(400_000);
    let cfg = Server { redirect: true, expire_first_sig: true, ..plain() };
    let srv = serve(data.clone(), cfg).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { sha256: Some(hex(&data)), ..small(4) };
    fetch_to_file(&client().unwrap(), &format!("{}/asset", srv.base), &dest, &opts).await.unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
}

#[tokio::test]
async fn a_large_file_arrives_in_parallel_ranges_with_its_bytes_intact() {
    let data = body(1_000_003);
    let srv = serve(data.clone(), plain()).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("asset.bin");
    let opts = Options { sha256: Some(hex(&data)), ..small(16) };
    let report = fetch_to_file(&client().unwrap(), &format!("{}/asset", srv.base), &dest, &opts)
        .await
        .unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!((report.bytes, report.ranges), (1_000_003, 16));
    assert_eq!(srv.slices.load(Ordering::SeqCst), 16);
    assert!(!part_path(&dest).exists());
}

#[tokio::test]
async fn a_redirect_is_followed_once_and_the_ranges_go_to_its_target() {
    let data = body(500_000);
    let srv = serve(data.clone(), Server { redirect: true, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    fetch_to_file(&client().unwrap(), &format!("{}/asset", srv.base), &dest, &small(4))
        .await
        .unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    // The probe's request and its redirect, then four slices straight at /blob.
    assert_eq!(srv.hits.load(Ordering::SeqCst), 2 + 4);
}

#[tokio::test]
async fn a_server_that_ignores_range_is_read_as_one_stream() {
    let data = body(300_000);
    let srv = serve(data.clone(), Server { ranges: false, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let report = fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &small(16))
        .await
        .unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!(report.ranges, 1);
    assert_eq!(srv.hits.load(Ordering::SeqCst), 1, "the probe's own body is the download");
}

#[tokio::test]
async fn a_file_under_the_threshold_is_one_stream() {
    let data = body(5000);
    let srv = serve(data.clone(), plain()).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { ranges: 16, threshold: 10_000, sha256: None, adaptive: None };
    let report =
        fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &opts).await.unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!((report.ranges, srv.slices.load(Ordering::SeqCst)), (1, 0));
}

#[tokio::test]
async fn one_range_means_one_stream_whatever_the_size() {
    let data = body(200_000);
    let srv = serve(data.clone(), plain()).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let report = fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &small(1))
        .await
        .unwrap();
    assert_eq!((report.ranges, std::fs::read(&dest).unwrap()), (1, data));
}

#[tokio::test]
async fn a_slice_cut_off_midway_resumes_where_it_stopped() {
    let data = body(400_000);
    let srv = serve(data.clone(), Server { cut_once: true, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { sha256: Some(hex(&data)), ..small(4) };
    fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &opts).await.unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!(srv.slices.load(Ordering::SeqCst), 5, "four slices and one resumed");
}

#[tokio::test]
async fn a_wrong_sha256_leaves_nothing_behind() {
    let data = body(100_000);
    let srv = serve(data, plain()).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { sha256: Some("0".repeat(64)), ..small(4) };
    let err = fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &opts)
        .await
        .unwrap_err();
    assert!(format!("{err:#}").contains("not kept"), "{err:#}");
    assert!(!dest.exists() && !part_path(&dest).exists());
}

#[tokio::test]
async fn a_slice_a_byte_short_is_an_error_not_a_file() {
    let data = body(100_000);
    let srv = serve(data, Server { short: true, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let err = fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &small(4))
        .await
        .unwrap_err();
    assert!(format!("{err:#}").contains("range "), "{err:#}");
    assert!(!dest.exists() && !part_path(&dest).exists());
}

fn adaptive() -> Options {
    let fallback = Adaptive { after: Duration::from_millis(300), min_bytes_per_sec: 1_000_000 };
    Options { adaptive: Some(fallback), ..small(4) }
}

#[tokio::test]
async fn a_fast_stream_is_never_split() {
    let data = body(400_000);
    let srv = serve(data.clone(), plain()).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { sha256: Some(hex(&data)), ..adaptive() };
    let report =
        fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &opts).await.unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!(report.ranges, 1);
    // The probe, then the one stream: no slice but the stream's own.
    assert_eq!(srv.slices.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_head_stream_that_sends_nothing_goes_to_ranges_at_the_judging_point() {
    let data = body(600_000);
    let srv = serve(data.clone(), Server { silent_head: true, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { sha256: Some(hex(&data)), ..adaptive() };
    let started = Instant::now();
    let report =
        fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &opts).await.unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!(report.ranges, 4);
    // Judged at 300 ms, not after the 30 s stall (or the server's 20 s of silence).
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
}

#[tokio::test]
async fn a_slow_stream_is_given_up_on_and_the_rest_is_read_in_ranges() {
    let data = body(600_000);
    let srv = serve(data.clone(), Server { slow_head: true, ..plain() }).await;
    let dir = tempfile::tempdir().unwrap();
    let dest = dir.path().join("a");
    let opts = Options { sha256: Some(hex(&data)), ..adaptive() };
    let started = Instant::now();
    let report =
        fetch_to_file(&client().unwrap(), &format!("{}/x", srv.base), &dest, &opts).await.unwrap();
    assert_eq!(std::fs::read(&dest).unwrap(), data);
    assert_eq!(report.ranges, 4);
    assert_eq!(srv.slices.load(Ordering::SeqCst), 1 + 4, "the stream, then four ranges");
    // 600 KB at 100 KB/s would take 6 s.
    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());
}
