use super::*;

fn sha(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

#[test]
fn a_timing_record_has_a_key_of_its_own() {
    let key = format!("bun-{}", "a".repeat(64));
    let meta = meta_key(&key).unwrap();
    assert!(meta.starts_with("bun-"));
    assert_eq!(meta.len(), key.len());
    assert_ne!(meta, key);
    assert!(meta[4..].bytes().all(|b| b.is_ascii_hexdigit()));
    assert_eq!(meta_key(&key), Some(meta));
    assert_eq!(meta_key("nodash"), None);
}

#[test]
fn tree_digest_is_the_hash_of_part_hashes_however_it_is_fed() {
    let data: Vec<u8> = (0..2500u32).map(|i| (i % 251) as u8).collect();
    let mut expected = Sha256::new();
    for part in data.chunks(1000) {
        expected.update(sha(part));
    }
    let expected = hex(&expected.finalize());
    for step in [1, 7, 1000, 2500] {
        let mut h = TreeHasher::new(1000);
        for piece in data.chunks(step) {
            h.update(piece);
        }
        assert_eq!(h.finish(), (expected.clone(), 3), "step {step}");
    }
    // Exactly one full part: no empty trailing part.
    let mut h = TreeHasher::new(1000);
    h.update(&data[..1000]);
    let mut one = Sha256::new();
    one.update(sha(&data[..1000]));
    assert_eq!(h.finish(), (hex(&one.finalize()), 1));
}

/// A hub on 127.0.0.1 that answers one GET with `size`'s headers, then sends
/// `chunks` (each after its delay) and holds the connection open, silent.
/// With `answer` false it reads the request and never answers.
async fn hub(answer: bool, size: u64, digest: String, chunks: Vec<(u64, Vec<u8>)>) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut buf = [0u8; 4096];
        let _ = socket.read(&mut buf).await;
        if answer {
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-length: {size}\r\nx-dep-cache-sha256: {digest}\r\n\
                 x-dep-cache-size: {size}\r\nx-dep-cache-part-bytes: 1000\r\n\r\n"
            );
            socket.write_all(head.as_bytes()).await.unwrap();
            for (delay_ms, bytes) in chunks {
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                socket.write_all(&bytes).await.unwrap();
                socket.flush().await.unwrap();
            }
        }
        // Silent from here: the stalled cache.
        tokio::time::sleep(Duration::from_secs(3600)).await;
        drop(socket);
    });
    origin
}

fn remote(origin: String, stall_ms: u64) -> Remote {
    let mut remote = Remote::new(origin, "cmm_test".into()).unwrap();
    remote.stall = Duration::from_millis(stall_ms);
    remote
}

fn digest_of(data: &[u8]) -> String {
    let mut h = TreeHasher::new(1000);
    h.update(data);
    h.finish().0
}

const KEY: &str = "npm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[tokio::test]
async fn a_stream_that_stops_mid_archive_is_dropped_within_the_bound() {
    let data = vec![7u8; 4000];
    let origin = hub(true, 4000, digest_of(&data), vec![(0, data[..1000].to_vec())]).await;
    let out = tempfile::tempdir().unwrap();
    let started = std::time::Instant::now();
    let fetched =
        remote(origin, 300).fetch(KEY, &out.path().join("a"), |_, _, _| false).await.unwrap();
    let took = started.elapsed();
    assert_eq!(fetched, Fetched::Stalled { got: 1000 });
    // The whole request ends at the bound, not at the 600 s client timeout:
    // `warm` then runs the install from the registry.
    assert!(took >= Duration::from_millis(300), "{took:?}");
    assert!(took < Duration::from_millis(2_000), "{took:?}");
}

#[tokio::test]
async fn a_hub_that_never_answers_is_dropped_within_the_bound() {
    let origin = hub(false, 0, String::new(), vec![]).await;
    let out = tempfile::tempdir().unwrap();
    let started = std::time::Instant::now();
    let fetched =
        remote(origin, 300).fetch(KEY, &out.path().join("a"), |_, _, _| false).await.unwrap();
    assert_eq!(fetched, Fetched::Stalled { got: 0 });
    assert!(started.elapsed() < Duration::from_millis(2_000), "{:?}", started.elapsed());
}

#[tokio::test]
async fn a_slow_stream_that_keeps_moving_is_not_a_stall() {
    // Every gap is under the bound, the whole download is well over it.
    let data: Vec<u8> = (0..4000u32).map(|i| (i % 251) as u8).collect();
    let chunks = data.chunks(500).map(|c| (150, c.to_vec())).collect();
    let origin = hub(true, 4000, digest_of(&data), chunks).await;
    let out = tempfile::tempdir().unwrap();
    let path = out.path().join("a");
    let fetched = remote(origin, 400).fetch(KEY, &path, |_, _, _| false).await.unwrap();
    assert_eq!(fetched, Fetched::Hit(4000));
    assert_eq!(std::fs::read(&path).unwrap(), data);
}
