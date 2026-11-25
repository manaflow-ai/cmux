use super::*;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// A network of fixed answers by URL, recording what was asked.
struct Fake {
    answers: HashMap<String, Vec<u8>>,
    asked: Mutex<Vec<String>>,
}

impl Fake {
    fn new(answers: &[(&str, &[u8])]) -> Self {
        Self {
            answers: answers
                .iter()
                .map(|(url, bytes)| ((*url).to_owned(), bytes.to_vec()))
                .collect(),
            asked: Mutex::new(Vec::new()),
        }
    }
}

/// A source at `http://down*` is unreachable, one at `http://busy*` is at its limit, and one at
/// `http://panics*` panics.
impl Get for Arc<Fake> {
    fn get(&self, url: &str, _token: Option<&str>, _deadline: Duration) -> Answer {
        self.asked.lock().unwrap().push(url.to_owned());
        if url.starts_with("http://down") {
            return Answer::Failed;
        }
        if url.starts_with("http://busy") {
            return Answer::Busy;
        }
        assert!(!url.starts_with("http://panics"), "source panicked");
        self.answers.get(url).map_or(Answer::Absent, |bytes| Answer::Found(bytes.clone()))
    }
}

fn remote(tier: &'static str, base: &str) -> Remote {
    Remote { tier, base: base.to_owned(), token: None }
}

// `git hash-object` of "hello\n" and of "".
const HELLO: &str = "ce013625030ba8dba906f756967f9e9ca394464a";
const EMPTY: &str = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

#[test]
fn blob_ids_match_git() {
    assert_eq!(blob_id(b"hello\n", 40), HELLO);
    assert_eq!(blob_id(b"", 40), EMPTY);
    assert_eq!(
        blob_id(b"hello\n", 64),
        "2cf8d83d9ee29543b34a87727421fdecb7e3f3a183d337639025de576db9ebb4"
    );
    assert!(verify(HELLO, b"hello\n"));
    assert!(!verify(HELLO, b"hellO\n"));
    assert!(!verify("not-an-id", b"hello\n"));
}

#[test]
fn a_wrong_answer_falls_through_to_the_next_source() {
    let fake = Arc::new(Fake::new(&[
        (&format!("http://peer/objects/{HELLO}"), b"tampered\n"),
        (&format!("http://ssd/objects/{HELLO}"), b"hello\n"),
    ]));
    let chain = Chain::new(
        vec![remote("peer", "http://peer"), remote("ssd", "http://ssd")],
        Box::new(fake),
    );
    let kept = Mutex::new(Vec::new());
    let (rest, filled) = chain.fill(&[HELLO.to_owned()], &|oid, bytes| {
        kept.lock().unwrap().push((oid.to_owned(), bytes.to_vec()));
        Ok(())
    });
    assert!(rest.is_empty());
    assert_eq!(filled, Filled { peer: 0, ssd: 1, r2: 0, rejected: 1, dropped: 0 });
    assert_eq!(kept.into_inner().unwrap(), vec![(HELLO.to_owned(), b"hello\n".to_vec())]);
}

#[test]
fn sources_are_asked_in_order_and_stop_at_the_first_good_answer() {
    let fake = Arc::new(Fake::new(&[
        (&format!("http://ssd/objects/{HELLO}"), b"hello\n"),
        (&format!("http://r2/objects/{HELLO}"), b"hello\n"),
    ]));
    let chain = Chain::new(
        vec![remote("peer", "http://peer"), remote("ssd", "http://ssd"), remote("r2", "http://r2")],
        Box::new(fake.clone()),
    );
    let (rest, filled) = chain.fill(&[HELLO.to_owned()], &|_, _| Ok(()));
    assert!(rest.is_empty());
    assert_eq!(filled.ssd, 1);
    let asked = fake.asked.lock().unwrap().clone();
    assert_eq!(
        asked,
        vec![format!("http://peer/objects/{HELLO}"), format!("http://ssd/objects/{HELLO}")]
    );
}

#[test]
fn what_no_source_has_is_left_for_git() {
    let fake = Arc::new(Fake::new(&[(&format!("http://r2/objects/{EMPTY}"), b"")]));
    let chain = Chain::new(vec![remote("r2", "http://r2")], Box::new(fake));
    let (rest, filled) = chain.fill(&[HELLO.to_owned(), EMPTY.to_owned()], &|_, _| Ok(()));
    assert_eq!(rest, vec![HELLO.to_owned()]);
    assert_eq!(filled.r2, 1);
}

#[test]
fn at_most_two_peers_are_asked_per_blob() {
    let fake = Arc::new(Fake::new(&[]));
    let peers = (0..5).map(|at| remote("peer", &format!("http://p{at}"))).collect();
    let chain = Chain::new(peers, Box::new(fake.clone()));
    let _ = chain.fill(&[HELLO.to_owned()], &|_, _| Ok(()));
    assert_eq!(fake.asked.lock().unwrap().len(), PEERS_PER_BLOB);
}

#[test]
fn the_chain_is_on_unless_turned_off() {
    assert!(enabled(None));
    assert!(enabled(Some("1")));
    assert!(enabled(Some("")));
    assert!(!enabled(Some("0")));
    assert!(!enabled(Some(" off ")));
    assert!(!enabled(Some("false")));
}

/// The four steps (peer, controller SSD, R2, then git), each failing in turn: a blob comes from
/// the first step that is up, and with every source down it is left for git.
#[test]
fn each_step_down_falls_to_the_next() {
    let good = |base: &str| (format!("{base}/objects/{HELLO}"), b"hello\n".to_vec());
    let cases: [(&[&str], Option<&str>); 4] = [
        (&["http://peer", "http://ssd", "http://r2"], Some("peer")),
        (&["http://down-peer", "http://ssd", "http://r2"], Some("ssd")),
        (&["http://down-peer", "http://down-ssd", "http://r2"], Some("r2")),
        (&["http://down-peer", "http://down-ssd", "http://down-r2"], None),
    ];
    for (bases, from) in cases {
        let answers: Vec<(String, Vec<u8>)> = bases.iter().map(|base| good(base)).collect();
        let answers: Vec<(&str, &[u8])> =
            answers.iter().map(|(url, bytes)| (url.as_str(), bytes.as_slice())).collect();
        let fake = Arc::new(Fake::new(&answers));
        let chain = Chain::new(
            vec![remote("peer", bases[0]), remote("ssd", bases[1]), remote("r2", bases[2])],
            Box::new(fake),
        );
        let (rest, filled) = chain.fill(&[HELLO.to_owned()], &|_, _| Ok(()));
        let got = match (filled.peer, filled.ssd, filled.r2) {
            (1, 0, 0) => Some("peer"),
            (0, 1, 0) => Some("ssd"),
            (0, 0, 1) => Some("r2"),
            _ => None,
        };
        assert_eq!(got, from, "sources {bases:?}");
        assert_eq!(rest.is_empty(), from.is_some(), "sources {bases:?}");
    }
}

#[test]
fn a_dead_source_is_dropped_after_three_failures() {
    let fake = Arc::new(Fake::new(&[]));
    let chain = Chain::new(vec![remote("peer", "http://down-peer")], Box::new(fake.clone()));
    let oids: Vec<String> = (0..500).map(|at| format!("{at:040x}")).collect();
    let (rest, filled) = chain.fill(&oids, &|_, _| Ok(()));
    assert_eq!(rest, oids);
    assert_eq!(filled.dropped, 1);
    // Workers already past the check when the third failure lands may ask once more each.
    assert!(fake.asked.lock().unwrap().len() < DEAD_AFTER + PARALLEL);
}

/// A seed answers 503 when more checkouts ask it than it serves at once (8 requests in flight
/// against its 4 connections); that is the seed working, so it must not get the seed dropped.
#[test]
fn a_busy_source_falls_through_but_is_never_dropped() {
    let fake = Arc::new(Fake::new(&[]));
    let chain = Chain::new(vec![remote("peer", "http://busy-peer")], Box::new(fake.clone()));
    let oids: Vec<String> = (0..50).map(|at| format!("{at:040x}")).collect();
    let (rest, filled) = chain.fill(&oids, &|_, _| Ok(()));
    assert_eq!(rest, oids);
    assert_eq!(filled.dropped, 0);
    assert_eq!(fake.asked.lock().unwrap().len(), oids.len());
}

#[test]
fn a_panicking_source_leaves_the_blob_for_git() {
    let fake = Arc::new(Fake::new(&[]));
    let chain = Chain::new(vec![remote("ssd", "http://panics")], Box::new(fake));
    let (rest, filled) = chain.fill(&[HELLO.to_owned()], &|_, _| Ok(()));
    assert_eq!(rest, vec![HELLO.to_owned()]);
    assert_eq!(filled, Filled::default());
}

#[test]
fn a_blob_that_cannot_be_written_is_left_for_git() {
    let fake = Arc::new(Fake::new(&[(&format!("http://ssd/objects/{HELLO}"), b"hello\n")]));
    let chain = Chain::new(vec![remote("ssd", "http://ssd")], Box::new(fake));
    let (rest, filled) =
        chain.fill(&[HELLO.to_owned()], &|_, _| Err(anyhow::anyhow!("mirror read only")));
    assert_eq!(rest, vec![HELLO.to_owned()]);
    assert_eq!(filled.ssd, 0);
}

#[test]
fn an_unreadable_peer_index_names_no_peers() {
    let fake = Arc::new(Fake::new(&[]));
    assert!(peers_in(&fake, "http://down-index/seeds").is_empty());
    assert!(peers_in(&fake, "/nonexistent/peer-index").is_empty());
}

#[test]
fn peer_lists_skip_comments_and_non_urls() {
    let text = "# seeds\nhttp://100.1.2.3:18991\n\n  https://seed.example/x  \nnot a url\n";
    assert_eq!(peer_list(text), vec!["http://100.1.2.3:18991", "https://seed.example/x"]);
}

#[test]
fn request_lines_name_only_object_ids() {
    assert_eq!(requested_id(&format!("GET /objects/{HELLO} HTTP/1.1")), Some(HELLO));
    assert_eq!(requested_id("GET /objects/../../etc/passwd HTTP/1.1"), None);
    assert_eq!(requested_id(&format!("PUT /objects/{HELLO} HTTP/1.1")), None);
    assert_eq!(requested_id("GET / HTTP/1.1"), None);
}

#[test]
fn the_bucket_holds_its_rate() {
    let start = Instant::now();
    let mut bucket = Bucket::new(1000, start);
    // The first second's burst is free.
    assert_eq!(bucket.take(1000, start), Duration::ZERO);
    // The next 500 bytes owe half a second.
    assert_eq!(bucket.take(500, start), Duration::from_millis(500));
    // A second later the debt is repaid and 500 more is free again.
    assert_eq!(bucket.take(0, start + Duration::from_millis(1500)), Duration::ZERO);
    // 10 000 bytes over a second take at least 9 s more at 1000/s.
    let mut bucket = Bucket::new(1000, start);
    let mut owed = Duration::ZERO;
    for _ in 0..10 {
        owed = bucket.take(1000, start);
    }
    assert_eq!(owed, Duration::from_secs(9));
}

#[test]
fn verified_blobs_become_loose_objects_git_reads() {
    let dir = tempfile::tempdir().unwrap();
    let git_dir = dir.path().join("m.git");
    let init =
        std::process::Command::new("git").args(["init", "-q", "--bare"]).arg(&git_dir).status();
    if !init.is_ok_and(|status| status.success()) {
        return; // no git on this host
    }
    assert!(write_loose(&git_dir, HELLO, b"tampered").is_err());
    write_loose(&git_dir, HELLO, b"hello\n").unwrap();
    let out = std::process::Command::new("git")
        .arg("--git-dir")
        .arg(&git_dir)
        .args(["cat-file", "blob", HELLO])
        .output()
        .unwrap();
    assert_eq!(out.stdout, b"hello\n");
    let mut reader = crate::git::ObjectReader::spawn(&git_dir).unwrap();
    assert_eq!(reader.blob(HELLO), Some(b"hello\n".to_vec()));
    assert_eq!(reader.blob(EMPTY), None);
}

#[test]
fn a_seed_serves_its_blobs_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    let git_dir = dir.path().join("m.git");
    let init =
        std::process::Command::new("git").args(["init", "-q", "--bare"]).arg(&git_dir).status();
    if !init.is_ok_and(|status| status.success()) {
        return;
    }
    write_loose(&git_dir, HELLO, b"hello\n").unwrap();
    // Bound here and handed over, so the port is the seed's before the first request.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    std::thread::spawn(move || {
        serve_on(&git_dir, listener, &test_limits());
    });
    let http = Http::new().unwrap();
    let base = format!("http://{addr}");
    let wait = Duration::from_secs(2);
    assert_eq!(
        http.get(&format!("{base}/objects/{HELLO}"), None, wait),
        Answer::Found(b"hello\n".to_vec())
    );
    assert_eq!(http.get(&format!("{base}/objects/{EMPTY}"), None, wait), Answer::Absent);
    assert_eq!(http.get(&format!("{base}/etc/passwd"), None, wait), Answer::Absent);
    // A peer that refuses connections, over the real network: the seed behind it answers.
    let dead = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let chain = Chain::new(
        vec![remote("peer", &format!("http://{dead}")), remote("ssd", &base)],
        Box::new(http),
    );
    let (rest, filled) = chain.fill(&[HELLO.to_owned(), EMPTY.to_owned()], &|_, _| Ok(()));
    assert_eq!(rest, vec![EMPTY.to_owned()]);
    assert_eq!(filled.ssd, 1);
}

/// Limits a test seed never trips by itself: no load cutoff.
fn test_limits() -> SeedLimits {
    SeedLimits { load_per_core: f64::MAX, ..SeedLimits::default() }
}

/// A bare mirror holding `hello\n`, or `None` where this host has no git.
fn mirror(dir: &Path) -> Option<PathBuf> {
    let git_dir = dir.join("m.git");
    let init =
        std::process::Command::new("git").args(["init", "-q", "--bare"]).arg(&git_dir).status();
    if !init.is_ok_and(|status| status.success()) {
        return None;
    }
    write_loose(&git_dir, HELLO, b"hello\n").unwrap();
    Some(git_dir)
}

/// A seed on a fresh loopback port, serving `git_dir` until the test process ends.
fn start_seed(git_dir: PathBuf, limits: SeedLimits) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || serve_on(&git_dir, listener, &limits));
    base
}

/// A one-shot server that reads one request and writes `answer` raw, then closes.
fn raw_server(answer: Vec<u8>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0; 4096];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(&answer);
        }
    });
    base
}

#[test]
fn a_peer_streams_a_whole_batch_in_one_request() {
    let dir = tempfile::tempdir().unwrap();
    let Some(git_dir) = mirror(dir.path()) else { return };
    let base = start_seed(git_dir, test_limits());
    let mut got = Vec::new();
    let answer = batch_request(
        &base,
        &[HELLO.to_owned(), EMPTY.to_owned(), "not-an-id".to_owned()],
        Duration::from_secs(2),
        &mut |oid, bytes| {
            got.push((oid.to_owned(), bytes));
            true
        },
    );
    assert_eq!(answer, BatchAnswer::Streamed);
    assert_eq!(got, vec![(HELLO.to_owned(), b"hello\n".to_vec())]);
    // Through the chain: the peer's stream fills HELLO; EMPTY, which it lacks, goes to git.
    let chain = Chain::new(vec![remote("peer", &base)], Box::new(Http::new().unwrap()));
    let kept = Mutex::new(Vec::new());
    let (rest, filled) = chain.fill(&[HELLO.to_owned(), EMPTY.to_owned()], &|oid, _| {
        kept.lock().unwrap().push(oid.to_owned());
        Ok(())
    });
    assert_eq!(rest, vec![EMPTY.to_owned()]);
    assert_eq!(filled.peer, 1);
    assert_eq!(*kept.lock().unwrap(), vec![HELLO.to_owned()]);
}

#[test]
fn a_tampered_batch_is_refused_and_the_next_source_asked() {
    let mut tampered = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_vec();
    tampered.extend_from_slice(format!("{HELLO} 8\ntampered").as_bytes());
    let liar = raw_server(tampered);
    let fake = Arc::new(Fake::new(&[(&format!("http://r2/objects/{HELLO}"), b"hello\n")]));
    // The liar is a real socket, so the chain's batch goes over the network: wrap Fake's GETs
    // and the real batch client in one Get.
    struct Both(Arc<Fake>);
    impl Get for Both {
        fn get(&self, url: &str, token: Option<&str>, deadline: Duration) -> Answer {
            self.0.get(url, token, deadline)
        }
        fn batch(
            &self,
            base: &str,
            ids: &[String],
            first_byte: Duration,
            each: &mut dyn FnMut(&str, Vec<u8>) -> bool,
        ) -> BatchAnswer {
            batch_request(base, ids, first_byte, each)
        }
    }
    let chain =
        Chain::new(vec![remote("peer", &liar), remote("r2", "http://r2")], Box::new(Both(fake)));
    let (rest, filled) = chain.fill(&[HELLO.to_owned()], &|_, _| Ok(()));
    assert!(rest.is_empty());
    assert_eq!((filled.peer, filled.r2, filled.rejected), (0, 1, 1));
}

#[test]
fn a_seed_without_batches_is_asked_per_blob() {
    // What an older seed answers a POST.
    let old = raw_server(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec());
    let answer = batch_request(&old, &[HELLO.to_owned()], Duration::from_secs(2), &mut |_, _| true);
    assert_eq!(answer, BatchAnswer::Unsupported);
    let busy =
        raw_server(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n".to_vec());
    let answer =
        batch_request(&busy, &[HELLO.to_owned()], Duration::from_secs(2), &mut |_, _| true);
    assert_eq!(answer, BatchAnswer::Busy);
    assert_eq!(
        batch_request("https://far", &[HELLO.to_owned()], Duration::from_secs(2), &mut |_, _| true),
        BatchAnswer::Unsupported
    );
}

#[test]
fn a_peer_slow_to_answer_a_batch_costs_one_short_deadline() {
    // Accepts and never answers.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        let held: Vec<_> = listener.incoming().take(1).collect();
        std::thread::park();
        drop(held);
    });
    let start = Instant::now();
    let answer = batch_request(&base, &[HELLO.to_owned()], BATCH_FIRST_BYTE, &mut |_, _| true);
    assert_eq!(answer, BatchAnswer::Failed);
    assert!(start.elapsed() < Duration::from_secs(2), "{:?}", start.elapsed());
}

#[test]
fn peers_are_asked_nearest_first() {
    let fake = Arc::new(Fake::new(&[]));
    let peers = (0..5).map(|at| remote("peer", &format!("http://p{at}"))).collect();
    let chain = Chain::new(peers, Box::new(fake.clone()));
    let _ = chain.fill(&[HELLO.to_owned(), EMPTY.to_owned()], &|_, _| Ok(()));
    let mut asked = fake.asked.lock().unwrap().clone();
    asked.sort();
    // HELLO's id sorts before EMPTY's.
    let expected: Vec<String> = ["p0", "p1"]
        .iter()
        .flat_map(|peer| [HELLO, EMPTY].map(|oid| format!("http://{peer}/objects/{oid}")))
        .collect();
    assert_eq!(asked, expected);
}

#[test]
fn a_seed_yields_while_a_build_lock_is_held() {
    let dir = tempfile::tempdir().unwrap();
    let lock = dir.path().join("build.lock");
    assert!(!lock_held(&lock), "a missing lock is not held");
    let file = std::fs::File::create(&lock).unwrap();
    assert!(!lock_held(&lock), "an unheld lock is not held");
    let held = cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive).unwrap();
    assert!(lock_held(&lock));
    let Some(git_dir) = mirror(dir.path()) else { return };
    let base = start_seed(git_dir, SeedLimits { yield_locks: vec![lock], ..test_limits() });
    let http = Http::new().unwrap();
    let url = format!("{base}/objects/{HELLO}");
    assert_eq!(http.get(&url, None, Duration::from_secs(2)), Answer::Busy);
    drop(held);
}

#[test]
fn the_collision_detecting_id_matches_git() {
    // The check is SHA-1 with collision detection (what git ships): a plain blob hashes as git
    // does, and the detector reports no attack on it.
    assert_eq!(blob_id(b"hello\n", 40), HELLO);
    let mut hash = Sha1CD::default();
    hash.update(b"hello\n");
    assert!(hash.finalize_cd().is_ok());
}

#[test]
fn a_url_index_is_asked_once_a_minute() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("peer-index");
    let fake = Arc::new(Fake::new(&[("http://controller/v1/seeds", b"http://p0:7480\n")]));
    let first = peers_in_cached(&fake, "http://controller/v1/seeds", Some(&cache));
    let second = peers_in_cached(&fake, "http://controller/v1/seeds", Some(&cache));
    assert_eq!(first, vec![remote("peer", "http://p0:7480")]);
    assert_eq!(second, first);
    assert_eq!(fake.asked.lock().unwrap().len(), 1);
}

#[test]
fn a_heartbeat_names_the_packs_and_tips_it_holds() {
    let dir = tempfile::tempdir().unwrap();
    let Some(git_dir) = mirror(dir.path()) else { return };
    std::fs::create_dir_all(git_dir.join("objects/pack")).unwrap();
    let pack = format!("pack-{}", "a".repeat(40));
    std::fs::write(git_dir.join(format!("objects/pack/{pack}.pack")), b"").unwrap();
    std::fs::write(git_dir.join(format!("objects/pack/{pack}.idx")), b"").unwrap();
    let beat = beat_repo(&git_dir, "manaflow-ai/cmux");
    assert_eq!(beat.packs, vec![pack]);
    assert!(beat.tips.is_empty(), "no branches yet");
    let json = serde_json::to_value(Beat {
        host: "h".into(),
        seed_url: "http://10.0.0.1:7480".into(),
        zone: "us-west1-c".into(),
        repos: vec![beat],
    })
    .unwrap();
    assert_eq!(json["repos"][0]["repo"], "manaflow-ai/cmux");
}

#[test]
fn a_heartbeat_keeps_registering_with_noncanonical_pack_files() {
    let dir = tempfile::tempdir().unwrap();
    let packs_dir = dir.path().join("objects/pack");
    std::fs::create_dir_all(&packs_dir).unwrap();
    let sha1 = format!("pack-{}", "a".repeat(40));
    let sha256 = format!("pack-{}", "b".repeat(64));
    let ignored = [
        "loose-42831f7628ec33270fba5abcecbec7b4d39eae32".to_owned(),
        "tmp_pack_abc".to_owned(),
        "pack-abc".to_owned(),
        format!("pack-{}", "A".repeat(40)),
        format!("pack-{}", "g".repeat(40)),
        format!("pack-{}", "c".repeat(41)),
    ];
    for name in [&sha1, &sha256].into_iter().chain(ignored.iter()) {
        std::fs::write(packs_dir.join(format!("{name}.pack")), b"pack data").unwrap();
    }
    // Only files can be advertised as packs, even when a directory has a valid name.
    std::fs::create_dir(packs_dir.join(format!("pack-{}.pack", "d".repeat(40)))).unwrap();
    let beat = beat_repo(dir.path(), "manaflow-ai/cmux");
    assert_eq!(beat.packs, vec![sha1, sha256]);
    for name in ignored {
        assert_eq!(std::fs::read(packs_dir.join(format!("{name}.pack"))).unwrap(), b"pack data");
    }
}

/// A repo of `count` one-line files at `dir/src` that serves partial clones, and a blobless bare
/// clone of it at `dir/partial.git` (a seed's mirror: it lacks every blob, and its promisor
/// remote holds them), with the blob ids; `None` where this host has no git.
fn partial_mirror(dir: &Path, count: usize) -> Option<(PathBuf, PathBuf, Vec<String>)> {
    let run = |args: &[&str], cwd: &Path| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let src = dir.join("src");
    std::fs::create_dir_all(&src).ok()?;
    run(&["init", "-q"], &src)?;
    let mut ids = Vec::new();
    for at in 0..count {
        let text = format!("file {at}\n");
        std::fs::write(src.join(format!("f{at}")), &text).ok()?;
        ids.push(blob_id(text.as_bytes(), 40));
    }
    run(&["add", "."], &src)?;
    run(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "files"], &src)?;
    run(&["config", "uploadpack.allowFilter", "true"], &src)?;
    run(&["config", "uploadpack.allowAnySHA1InWant", "true"], &src)?;
    let url = format!("file://{}", src.display());
    run(&["clone", "-q", "--bare", "--filter=blob:none", &url, "partial.git"], dir)?;
    let full = dir.join("full.git");
    run(&["clone", "-q", "--bare", &url, "full.git"], dir)?;
    Some((dir.join("partial.git"), full, ids))
}

#[test]
fn a_seed_never_fetches_a_blob_it_lacks_from_its_promisor_remote() {
    let dir = tempfile::tempdir().unwrap();
    let Some((partial, _, ids)) = partial_mirror(dir.path(), 2) else { return };
    write_loose(&partial, HELLO, b"hello\n").unwrap();
    let mut reader = crate::git::ObjectReader::spawn(&partial).unwrap();
    // A plain `cat-file` fetched this from the promisor remote: one GitHub round trip per blob.
    assert_eq!(reader.blob(&ids[0]), None);
    // A miss ends git's reader; the next read is still answered.
    assert_eq!(reader.blob(HELLO), Some(b"hello\n".to_vec()));
    assert_eq!(reader.blob(&ids[1]), None);
    assert_eq!(reader.blob(HELLO), Some(b"hello\n".to_vec()));
    // Nothing was fetched into the seed's store.
    let mut fresh = crate::git::ObjectReader::spawn(&partial).unwrap();
    assert_eq!(fresh.blob(&ids[0]), None);
    // Over the wire: the seed streams only what it holds, and the next seed sends the rest.
    let lacking = start_seed(partial, test_limits());
    let mut got = Vec::new();
    let mut ask = ids.clone();
    ask.push(HELLO.to_owned());
    let answer = batch_request(&lacking, &ask, Duration::from_secs(2), &mut |oid, _| {
        got.push(oid.to_owned());
        true
    });
    assert_eq!(answer, BatchAnswer::Streamed);
    assert_eq!(got, vec![HELLO.to_owned()]);
}

/// The before/after harness for the PR: 54 blobs (the field's missing set) asked of a nearest
/// seed whose mirror lacks them, then a seed that holds them; `fetch_ms` is [`Chain::fill`]'s
/// wall time, alone and with 4 fills at once. Run with
/// `cargo test -p cmux-projection measure_fill -- --ignored --nocapture`.
#[test]
#[ignore = "a measurement, not a check"]
fn measure_fill_past_a_seed_that_lacks_the_blobs() {
    let dir = tempfile::tempdir().unwrap();
    let Some((partial, full, ids)) = partial_mirror(dir.path(), 54) else { return };
    let (lacking, holding) = (start_seed(partial, test_limits()), start_seed(full, test_limits()));
    let fill = || {
        let chain = Chain::new(
            vec![remote("peer", &lacking), remote("peer", &holding)],
            Box::new(Http::new().unwrap()),
        );
        let started = Instant::now();
        let (rest, filled) = chain.fill(&ids, &|_, _| Ok(()));
        assert!(rest.is_empty(), "{} left for git", rest.len());
        assert_eq!(filled.peer, ids.len());
        started.elapsed().as_millis()
    };
    println!("fetch_ms alone: {}", fill());
    let duress: Vec<u128> = std::thread::scope(|scope| {
        let runs: Vec<_> = (0..4).map(|_| scope.spawn(fill)).collect();
        runs.into_iter().map(|run| run.join().unwrap()).collect()
    });
    println!("fetch_ms 4 at once: {duress:?}");
}

/// A stand-in seed index: answers each connection by the next step of `steps` (`None` holds the
/// connection past the try's bound, as the slow index does), the last step repeating. Returns its
/// URL and the count of requests it read.
fn beat_index(steps: Vec<Option<u16>>) -> (String, Arc<Mutex<usize>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/v1/seeds/heartbeat", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(0));
    let counter = Arc::clone(&seen);
    std::thread::spawn(move || {
        for (n, stream) in listener.incoming().enumerate() {
            let Ok(mut stream) = stream else { continue };
            let step = steps[n.min(steps.len() - 1)];
            *counter.lock().unwrap() += 1;
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                let _ = stream.read(&mut buf);
                match step {
                    None => std::thread::sleep(Duration::from_secs(3)),
                    Some(code) => {
                        let _ = write!(
                            stream,
                            "HTTP/1.1 {code} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                        );
                    }
                }
            });
        }
    });
    (url, seen)
}

fn beat_client() -> reqwest::blocking::Client {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::blocking::Client::builder().pool_max_idle_per_host(0).build().unwrap()
}

const TEST_POLICY: BeatPolicy = BeatPolicy {
    attempt: Duration::from_millis(300),
    period: Duration::from_secs(5),
    backoff: Duration::from_millis(50),
};

#[test]
fn a_slow_or_failing_index_is_retried_within_the_same_beat() {
    // A try past its bound, then a 503, then the index takes it: one beat, three tries.
    let (url, seen) = beat_index(vec![None, Some(503), Some(200)]);
    let start = Instant::now();
    let tries = post_beat(&beat_client(), &url, None, b"{}", TEST_POLICY, start);
    assert_eq!(tries, Ok(3));
    assert_eq!(*seen.lock().unwrap(), 3);
    assert!(start.elapsed() < TEST_POLICY.period);
}

#[test]
fn a_refused_beat_is_not_retried() {
    let (url, seen) = beat_index(vec![Some(401)]);
    let result = post_beat(&beat_client(), &url, None, b"{}", TEST_POLICY, Instant::now());
    assert!(result.is_err_and(|error| error.contains("401")));
    assert_eq!(*seen.lock().unwrap(), 1);
}

#[test]
fn retries_stop_when_the_next_beat_is_due() {
    let policy = BeatPolicy { period: Duration::from_secs(1), ..TEST_POLICY };
    let (url, seen) = beat_index(vec![Some(503)]);
    let start = Instant::now();
    let result = post_beat(&beat_client(), &url, None, b"{}", policy, start);
    assert!(result.is_err_and(|error| error.contains("503")));
    assert!(*seen.lock().unwrap() >= 3, "retried within the beat");
    assert!(start.elapsed() < policy.period + Duration::from_millis(500));
}
