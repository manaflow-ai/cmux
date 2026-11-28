use std::io::{Read as _, Write as _};
use std::path::Path;

use cmux_cas::fetch::Source as _;

use super::super::{AppCommand, parse};
use super::{Command, DEFAULT_BASE, Http};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

const ID: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

#[test]
fn web_cas_parses_its_options() {
    let parsed = parse(&args(&[
        "app",
        "web-cas",
        "fetch",
        "--manifest",
        ID,
        "--pack",
        ID,
        "--store",
        "/s",
        "--out",
        "/o",
        "--have",
        "/a",
        "--have",
        "/b",
    ]))
    .unwrap();
    let Some(AppCommand::WebCas(Command::Fetch(fetch))) = parsed else { panic!("{parsed:?}") };
    assert_eq!(fetch.base, DEFAULT_BASE);
    assert_eq!(fetch.manifest.hex(), ID);
    assert_eq!(fetch.have, vec![Path::new("/a"), Path::new("/b")]);
    for bad in [
        &["app", "web-cas"][..],
        &["app", "web-cas", "fetch", "--pack", ID, "--store", "/s", "--out", "/o"],
        &[
            "app",
            "web-cas",
            "fetch",
            "--manifest",
            "x",
            "--pack",
            ID,
            "--store",
            "/s",
            "--out",
            "/o",
        ],
        &["app", "web-cas", "fetch", "--manifest", ID, "--pack", ID, "--out", "/o"],
        &[
            "app",
            "web-cas",
            "fetch",
            "--manifest",
            ID,
            "--pack",
            ID,
            "--store",
            "/s",
            "--out",
            "/o",
            "--base",
            "http://example.com/",
        ],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?}");
    }
}

/// Serves the files under `root` on 127.0.0.1, with Range, one connection per request, until
/// `requests` have been answered; gives back each request's `Range` header (empty for none).
fn serve(
    root: &Path,
    requests: usize,
    honest: bool,
) -> (String, std::thread::JoinHandle<Vec<String>>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}/cas/", listener.local_addr().unwrap().port());
    let root = root.to_owned();
    let server = std::thread::spawn(move || {
        (0..requests)
            .map(|_| {
                let (mut stream, _) = listener.accept().unwrap();
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") && stream.read(&mut byte).unwrap() == 1 {
                    head.push(byte[0]);
                }
                let head = String::from_utf8_lossy(&head).into_owned();
                let path = head.split(' ').nth(1).unwrap().trim_start_matches("/cas/");
                let range = head
                    .lines()
                    .find_map(|l| l.to_ascii_lowercase().strip_prefix("range: bytes=").map(str::to_owned))
                    .unwrap_or_default();
                let answer = match std::fs::read(root.join(path)) {
                    Err(_) => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
                    Ok(body) if range.is_empty() => [
                        format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes(),
                        body,
                    ]
                    .concat(),
                    Ok(body) => {
                        let (a, b) = range.split_once('-').unwrap();
                        let (a, b): (usize, usize) = (a.parse().unwrap(), b.parse().unwrap());
                        // A dishonest server answers a range with the whole object.
                        let (status, part) = if honest { ("206 Partial Content", &body[a..=b]) } else { ("200 OK", &body[..]) };
                        [
                            format!(
                                "HTTP/1.1 {status}\r\nContent-Range: bytes {a}-{b}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                body.len(),
                                part.len()
                            )
                            .into_bytes(),
                            part.to_vec(),
                        ]
                        .concat()
                    }
                };
                let _ = stream.write_all(&answer);
                range
            })
            .collect()
    });
    (base, server)
}

fn tree(root: &Path, seed: u8) {
    std::fs::create_dir_all(root.join("app")).unwrap();
    let mut x = 0x9e37_79b9_u32 ^ u32::from(seed);
    let big: Vec<u8> = (0..600_000)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x as u8
        })
        .collect();
    std::fs::write(root.join("app/main.js"), &big).unwrap();
    std::fs::write(root.join("app/index.html"), format!("<p>{seed}</p>")).unwrap();
}

#[test]
fn a_fetch_over_http_moves_the_chunks_and_is_bit_exact() {
    let dir = tempfile::tempdir().unwrap();
    let (v1, objects) = (dir.path().join("v1"), dir.path().join("objects"));
    tree(&v1, 1);
    let published = cmux_cas::publish::publish(&v1, &objects).unwrap();
    // Manifest, index, then the ranges of the pack.
    let (base, server) = serve(&objects, 3, true);
    let mut http = Http::new(&super::super::web_pieces::base_url(&base).unwrap()).unwrap();
    let out = dir.path().join("out");
    let store = cmux_cas::Store::new(dir.path().join("store"));
    let report =
        cmux_cas::fetch::fetch(&mut http, &store, &published.manifest, &published.pack, &[], &out)
            .unwrap();
    assert_eq!(report.ranges, 1);
    assert_eq!(report.range_bytes, published.pack_bytes);
    assert_eq!(
        std::fs::read(out.join("app/main.js")).unwrap(),
        std::fs::read(v1.join("app/main.js")).unwrap()
    );
    let ranges = server.join().unwrap();
    assert_eq!(ranges[..2], [String::new(), String::new()]);
    assert_eq!(ranges[2], format!("0-{}", published.pack_bytes - 1));
}

#[test]
fn a_range_answered_with_the_whole_object_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("blob"), vec![7u8; 1000]).unwrap();
    let (base, server) = serve(dir.path(), 2, false);
    let mut http = Http::new(&base).unwrap();
    let why = http.range("blob", 10, 20).unwrap_err().to_string();
    assert!(why.contains("HTTP 200"), "{why}");
    let why = http.get("missing", 10).unwrap_err().to_string();
    assert!(why.contains("HTTP 404"), "{why}");
    server.join().unwrap();
}

#[test]
fn a_fetch_whose_app_went_away_ends_and_removes_what_it_made() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    let dir = tempfile::tempdir().unwrap();
    let (out, store, kept) =
        (dir.path().join("out"), dir.path().join("store"), dir.path().join("kept"));
    std::fs::create_dir(&kept).unwrap();
    let made = super::made_by_fetch(&out, &store);
    assert_eq!(made, vec![out.clone(), store.clone()]);
    assert_eq!(
        super::made_by_fetch(&kept, &store),
        vec![store.clone()],
        "a folder there before is never the fetch's"
    );

    // A server that takes the request and never answers: without the parent check this read
    // would wait out REQUEST_TIMEOUT (120 s).
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}/cas/", listener.local_addr().unwrap().port());
    let _held = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        std::thread::sleep(Duration::from_secs(30));
        drop(stream);
    });
    let gone = Arc::new(AtomicBool::new(false));
    let watched = Arc::clone(&gone);
    let mut http = Http::new(&base)
        .unwrap()
        .ending_when(move || watched.load(Ordering::SeqCst), Duration::from_millis(5));
    let flip = Arc::clone(&gone);
    let started = Instant::now();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        flip.store(true, Ordering::SeqCst);
    });
    let error = http.get("manifest", 1024).expect_err("a read outlived its app");
    let took = started.elapsed();
    assert!(error.to_string().contains("went away"), "{error}");
    assert!(took >= Duration::from_millis(100), "ended while its app was alive ({took:?})");
    assert!(took < Duration::from_secs(5), "took {took:?} to notice");

    std::fs::create_dir_all(out.join("a")).unwrap();
    std::fs::create_dir_all(&store).unwrap();
    super::remove_made(&made);
    assert!(!out.exists() && !store.exists());
    assert!(kept.exists());
}
