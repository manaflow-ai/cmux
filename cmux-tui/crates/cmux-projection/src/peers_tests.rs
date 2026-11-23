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
    fn get(&self, url: &str, _headers: &[(&'static str, String)], _deadline: Duration) -> Answer {
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
    Remote { tier, base: base.to_owned(), token: None, s3: None }
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
    assert_eq!(filled, Filled { peer: 0, ssd: 1, r2: 0, s3: 0, rejected: 1, dropped: 0 });
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
        serve_on(
            &git_dir,
            listener,
            &SeedLimits { load_per_core: f64::MAX, ..SeedLimits::default() },
        );
    });
    let http = Http::new().unwrap();
    let base = format!("http://{addr}");
    let wait = Duration::from_secs(2);
    assert_eq!(
        http.get(&format!("{base}/objects/{HELLO}"), &[], wait),
        Answer::Found(b"hello\n".to_vec())
    );
    assert_eq!(http.get(&format!("{base}/objects/{EMPTY}"), &[], wait), Answer::Absent);
    assert_eq!(http.get(&format!("{base}/etc/passwd"), &[], wait), Answer::Absent);
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

/// A bucket that answers only a request signed with SigV4 for its key, and a controller that
/// answers only its bearer token: what each tier sends.
struct Guarded;

impl Get for Guarded {
    fn get(&self, url: &str, headers: &[(&'static str, String)], _deadline: Duration) -> Answer {
        let auth = headers.iter().find(|(name, _)| *name == "authorization").map(|(_, v)| v);
        let ok = if url.starts_with("http://bucket:9000/") {
            auth.is_some_and(|auth| {
                auth.starts_with("AWS4-HMAC-SHA256 Credential=AKID/")
                    && auth.contains("/auto/s3/aws4_request")
            }) && headers
                .iter()
                .any(|(name, v)| *name == "x-amz-content-sha256" && v == crate::s3::EMPTY_SHA256)
        } else {
            auth.is_some_and(|auth| auth == "Bearer t0k")
        };
        if !ok {
            return Answer::Failed;
        }
        if url.ends_with(HELLO) { Answer::Found(b"hello\n".to_vec()) } else { Answer::Absent }
    }
}

#[test]
fn the_bucket_tier_signs_each_request_and_counts_as_s3() {
    let key = crate::s3::Key { id: "AKID".into(), secret: "s".into(), region: "auto".into() };
    let bucket = Remote {
        tier: "s3",
        base: "http://bucket:9000/blobs/fleet".into(),
        token: None,
        s3: Some(key),
    };
    let chain = Chain::new(vec![bucket], Box::new(Guarded));
    let (rest, filled) = chain.fill(&[HELLO.to_owned(), EMPTY.to_owned()], &|_, _| Ok(()));
    assert_eq!(rest, vec![EMPTY.to_owned()]);
    assert_eq!(filled, Filled { s3: 1, ..Filled::default() });

    let ssd =
        Remote { tier: "ssd", base: "http://ssd".into(), token: Some("t0k".into()), s3: None };
    let (rest, filled) =
        Chain::new(vec![ssd], Box::new(Guarded)).fill(&[HELLO.to_owned()], &|_, _| Ok(()));
    assert!(rest.is_empty());
    assert_eq!(filled.ssd, 1);
}

#[test]
fn a_bucket_url_the_signer_refuses_fails_that_source_only() {
    let key = crate::s3::Key { id: "AKID".into(), secret: "s".into(), region: "auto".into() };
    let bad =
        Remote { tier: "s3", base: "http://bucket:9000/a b".into(), token: None, s3: Some(key) };
    let fake = Arc::new(Fake::new(&[(&format!("http://r2/objects/{HELLO}"), b"hello\n")]));
    let chain = Chain::new(vec![bad, remote("r2", "http://r2")], Box::new(fake.clone()));
    let (rest, filled) = chain.fill(&[HELLO.to_owned()], &|_, _| Ok(()));
    assert!(rest.is_empty());
    assert_eq!((filled.s3, filled.r2), (0, 1));
    assert_eq!(fake.asked.lock().unwrap().len(), 1, "the unsigned URL never went out");
}
