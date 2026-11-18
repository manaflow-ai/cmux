use super::*;

use std::collections::HashMap;
use std::sync::Mutex;

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

impl Get for Arc<Fake> {
    fn get(&self, url: &str, _token: Option<&str>) -> Answer {
        self.asked.lock().unwrap().push(url.to_owned());
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
    assert_eq!(filled, Filled { peer: 0, ssd: 1, r2: 0, rejected: 1 });
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
fn the_flag_off_means_no_chain() {
    // The flag is read from the environment; this process never sets it.
    if std::env::var(FLAG).is_err() {
        assert!(Chain::from_env().unwrap().is_none());
    }
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
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    drop(listener);
    let seed_addr = addr.clone();
    std::thread::spawn(move || {
        serve(&git_dir, &seed_addr, SeedLimits { load_per_core: f64::MAX, ..SeedLimits::default() })
    });
    let http = Http::new().unwrap();
    let base = format!("http://{addr}");
    let mut answer = Answer::Failed;
    // The listener starts on its own thread; a connection refused before it binds is retried.
    for _ in 0..200 {
        answer = http.get(&format!("{base}/objects/{HELLO}"), None);
        if answer != Answer::Failed {
            break;
        }
        std::thread::yield_now();
    }
    assert_eq!(answer, Answer::Found(b"hello\n".to_vec()));
    assert_eq!(http.get(&format!("{base}/objects/{EMPTY}"), None), Answer::Absent);
    assert_eq!(http.get(&format!("{base}/etc/passwd"), None), Answer::Absent);
    let chain = Chain::new(vec![remote("peer", &base)], Box::new(http));
    let (rest, filled) = chain.fill(&[HELLO.to_owned(), EMPTY.to_owned()], &|_, _| Ok(()));
    assert_eq!(rest, vec![EMPTY.to_owned()]);
    assert_eq!(filled.peer, 1);
}
