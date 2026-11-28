//! A chat's pack sealed as its log grows (`hub/pack_as_it_grows.rs`).

use super::*;
use crate::store::{LocalStore, META_SCHEMA, SessionMeta};
use std::time::{Duration, Instant};

/// A log segment as the daemon rolls it (`config.rs`'s 8 MiB).
const LOG_SEGMENT: u64 = 8 << 20;

fn hub(sessions: &Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(LocalStore::new(sessions.to_owned(), LOG_SEGMENT).unwrap()))
}

fn chat(hub: &Hub, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "fake", "cwd": "/w",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

/// About 2.2 KiB of agent text a record, little of it repeated, so zstd has real work.
struct Text(u64);

impl Text {
    fn next(&mut self) -> String {
        let mut words = String::with_capacity(2300);
        while words.len() < 2200 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            let len = 2 + (self.0 % 9) as usize;
            words.extend((0..len).map(|i| char::from(b'a' + ((self.0 >> (i * 5)) % 26) as u8)));
            words.push(' ');
        }
        words
    }
}

/// Appends records through the hub until the chat's log holds `bytes`; each append's time.
fn grow(
    hub: &Hub,
    session: &Session,
    sessions: &Path,
    bytes: u64,
    text: &mut Text,
) -> Vec<Duration> {
    let mut times = Vec::new();
    let mut n = 0u64;
    while !n.is_multiple_of(256) || log_bytes(sessions, &session.id) < bytes {
        let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": session.id, "update": {"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text.next()}}}});
        let started = Instant::now();
        hub.append(session, "in", "agent_message_chunk", msg);
        times.push(started.elapsed());
        n += 1;
    }
    times
}

fn log_bytes(sessions: &Path, id: &str) -> u64 {
    std::fs::read_dir(sessions.join(id).join("events"))
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_name().to_string_lossy().ends_with(".ndjson"))
                .map(|e| e.metadata().map(|m| m.len()).unwrap_or(0))
                .sum()
        })
        .unwrap_or(0)
}

fn manifest(hub: &Hub, id: &str) -> Option<pack::Manifest> {
    pack::Manifest::load(&hub.pack_store(id).unwrap(), id).unwrap()
}

fn sealed(m: &Option<pack::Manifest>) -> usize {
    m.as_ref().map_or(0, |m| m.segments.iter().filter(|s| s.sealed).count())
}

/// Waits up to a minute for the chat's pack to hold `want` sealed segments.
async fn sealed_by_worker(hub: &Hub, id: &str, want: usize) -> pack::Manifest {
    let started = Instant::now();
    loop {
        let m = manifest(hub, id);
        if sealed(&m) >= want {
            return m.unwrap();
        }
        assert!(started.elapsed() < Duration::from_secs(60), "{} sealed of {want}", sealed(&m));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The chat's lines as an export writes them, through its last seq.
fn export_lines(hub: &Hub, session: &Session, dir: &Path) -> Vec<u8> {
    let path = dir.join("export.ndjson");
    let through = session.read_meta(|m| m.last_seq);
    let (last, _) = hub.write_lines(session, 0, through, &path).unwrap();
    assert_eq!(last, through);
    std::fs::read(path).unwrap()
}

fn pct(times: &mut [Duration], p: f64) -> Duration {
    times.sort();
    times[((times.len() as f64 - 1.0) * p).round() as usize]
}

/// A log grown past two 4 MiB marks has its pack sealed with nobody asking for one, and no
/// append waits for it: while the seal cannot run (its chat's pack turn is held) every append
/// still lands. Past a third mark the seal extends the pack from its sealed end, reading only
/// the new records; the pack then reads back byte for byte as the export's lines, is the pack a
/// whole pack of them makes, and a move's pack after it keeps every sealed segment.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_growing_log_has_its_pack_sealed_unasked_and_no_append_waits_for_it() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-grows-a";
    let session = chat(&hub, id);
    let worker = hub.pack_as_it_grows_worker().expect("on by default");
    let mut text = Text(0x9e37_79b9_7f4a_7c15);

    // (c) The seal cannot run, and the log passes two marks anyway.
    let held = PackTurn::take(id);
    let times = grow(&hub, &session, &sessions, (8 << 20) + (1 << 20), &mut text);
    assert_eq!(sealed(&manifest(&hub, id)), 0, "nothing sealed while the turn is held");
    let slowest = times.iter().max().unwrap();
    assert!(*slowest < Duration::from_secs(2), "an append took {slowest:?}");
    drop(held);

    // (a) The manifest lists both sealed segments: nobody asked for a pack.
    let first = sealed_by_worker(&hub, id, 2).await;
    assert!(first.segments.iter().take(2).all(|s| s.raw >= 4 << 20));

    // Past a third mark: extended from the sealed end.
    grow(&hub, &session, &sessions, (12 << 20) + (1 << 20), &mut text);
    sealed_by_worker(&hub, id, 3).await;
    // Once more by hand, so the pack covers every record appended.
    let last = hub.seal_pack(id).unwrap().unwrap();
    assert!(last.extended, "a seal after the first reads only what follows the sealed end");
    assert!(last.stats.encoded_bytes < 8 << 20, "{:?}", last.stats);

    // (b) Byte for byte the export's lines, and the same pack a whole pack of them makes.
    let want = export_lines(&hub, &session, root.path());
    let store = hub.pack_store(id).unwrap();
    let mut back = Vec::new();
    pack::Pack::open(&store, id).unwrap().cat(&mut back).unwrap();
    assert_eq!(back.len(), want.len());
    assert!(back == want, "the pack does not read back as the export's lines");
    let fresh = pack::Store::new(root.path().join("fresh"));
    let file = root.path().join("export.ndjson");
    let (whole, _) = pack::pack(&fresh, id, &[file], &pack::Params::default(), true).unwrap();
    assert_eq!(last.manifest, whole, "the grown pack is the whole pack of the export's lines");

    // A move's pack keeps every sealed segment and encodes only the open one.
    let through = session.read_meta(|m| m.last_seq);
    let work = root.path().join("move");
    let (_, stats, _) = hub.pack_through(&session, through, &store, &work).unwrap();
    assert_eq!(stats.kept_segments as usize, sealed(&Some(whole)), "{stats:?}");

    hub.shutdown_all().await;
    tokio::time::timeout(Duration::from_secs(10), worker)
        .await
        .expect("the worker ends at shutdown")
        .unwrap();
}

/// A log whose lines were rewritten (its stamp went up) is packed whole again, never extended
/// from segments that may no longer be its lines.
#[test]
fn a_rewritten_log_is_packed_whole_again() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-grows-b";
    let session = chat(&hub, id);
    let mut text = Text(7);
    grow(&hub, &session, &sessions, (4 << 20) + (1 << 20), &mut text);
    assert!(!hub.seal_pack(id).unwrap().unwrap().extended, "a daemon's first seal is whole");
    grow(&hub, &session, &sessions, (8 << 20) + (1 << 20), &mut text);
    assert!(hub.seal_pack(id).unwrap().unwrap().extended);
    hub.store.bump_log_stamp(id, 1).unwrap();
    grow(&hub, &session, &sessions, (9 << 20) + (512 << 10), &mut text);
    let again = hub.seal_pack(id).unwrap().unwrap();
    assert!(!again.extended, "a rewritten log is packed whole");
    assert_eq!(again.stats.kept_segments, 2, "{:?}", again.stats);
}

/// A seal that failed is not trusted: the next one packs whole and re-verifies, it does not try
/// the same extension again.
#[test]
fn a_failed_seal_is_followed_by_a_whole_pack() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-grows-c";
    let session = chat(&hub, id);
    let mut text = Text(11);
    grow(&hub, &session, &sessions, (4 << 20) + (1 << 20), &mut text);
    assert!(!hub.seal_pack(id).unwrap().unwrap().extended);
    grow(&hub, &session, &sessions, (8 << 20) + (1 << 20), &mut text);
    assert!(hub.seal_pack(id).unwrap().unwrap().extended);
    // The manifest cannot be read, so the extension fails.
    let path = hub.pack_store(id).unwrap().root().join("sessions").join(format!("{id}.json"));
    let good = std::fs::read(&path).unwrap();
    std::fs::write(&path, b"{ not a manifest").unwrap();
    grow(&hub, &session, &sessions, (9 << 20) + (512 << 10), &mut text);
    assert!(hub.seal_pack(id).is_err());
    assert_eq!(work_dirs(&hub, id), Vec::<String>::new(), "a failed seal leaves no scratch");
    assert!(!hub.pack_checked.lock().unwrap().contains_key(id), "a failed seal is forgotten");
    std::fs::write(&path, good).unwrap();
    let again = hub.seal_pack(id).unwrap().unwrap();
    assert!(!again.extended, "the seal after a failed one is whole");
    assert_eq!(again.stats.kept_segments, 2, "{:?}", again.stats);
}

/// The duress number (`--ignored`, prints): each append's time through the hub on a chat whose
/// log grows to 56 MB, with no pack worker and with it sealing every 4 MiB.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "a measurement: prints append p50/p99 with and without sealing"]
async fn append_latency_with_and_without_sealing() {
    const LOG: u64 = 56 << 20;
    let mut rows = Vec::new();
    for sealing in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let sessions = root.path().join("sessions");
        let hub = hub(&sessions);
        let id = if sealing { "pack-duress-on" } else { "pack-duress-off" };
        let session = chat(&hub, id);
        let worker = sealing.then(|| hub.pack_as_it_grows_worker().unwrap());
        let mut text = Text(0x2545_f491_4f6c_dd1d);
        let started = Instant::now();
        let mut times = grow(&hub, &session, &sessions, LOG, &mut text);
        let wall = started.elapsed();
        let segments = if sealing {
            sealed_by_worker(&hub, id, (LOG / (4 << 20)) as usize - 1).await.segments.len()
        } else {
            0
        };
        rows.push(format!(
            "sealing={sealing} appends={} log={} MB wall={wall:?} p50={:?} p99={:?} p999={:?} max={:?} pack_segments={segments}",
            times.len(),
            log_bytes(&sessions, id) >> 20,
            pct(&mut times, 0.50),
            pct(&mut times, 0.99),
            pct(&mut times, 0.999),
            pct(&mut times, 1.0),
        ));
        hub.shutdown_all().await;
        if let Some(worker) = worker {
            let _ = tokio::time::timeout(Duration::from_secs(30), worker).await;
        }
    }
    for row in rows {
        println!("{row}");
    }
}

/// A chat that is purged is not packed, and what the hub remembered of its pack goes with it.
#[test]
fn a_purged_chat_is_not_packed_and_is_forgotten() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-grows-d";
    let session = chat(&hub, id);
    let mut text = Text(13);
    grow(&hub, &session, &sessions, (4 << 20) + (1 << 20), &mut text);
    assert!(hub.seal_pack(id).unwrap().is_some());
    assert!(hub.pack_checked.lock().unwrap().contains_key(id));
    session.purged.store(true, Ordering::SeqCst);
    assert!(hub.seal_pack(id).unwrap().is_none(), "a purged chat is not packed");
    assert!(!hub.pack_checked.lock().unwrap().contains_key(id), "and its entry is dropped");
    // A chat gone from the session map loses its entry too.
    hub.pack_checked.lock().unwrap().insert("no-such-chat".to_owned(), 1);
    assert!(hub.seal_pack("no-such-chat").unwrap().is_none());
    assert!(!hub.pack_checked.lock().unwrap().contains_key("no-such-chat"));
}

/// The `work-*` folders in chat `id`'s pack store.
fn work_dirs(hub: &Hub, id: &str) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(hub.pack_store(id).unwrap().root())
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("work-"))
        .collect();
    names.sort();
    names
}

/// A seal that ends leaves no scratch in the chat's `history-pack`; one a daemon was killed in
/// (SIGKILL halfway through writing its lines, as a NIGHTLY's take-over or a crash does) is
/// removed by the next daemon's start, and by the chat's next seal, and so is a `work-<uuid>`
/// of a build that named them without a pid. Scratch of a daemon still running (this one) and
/// the pack itself stay. Leo's Mac held 24 GB of these in one chat (5 folders, 11-26 to 11-27).
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_interrupted_seals_scratch_is_removed_at_restart_and_a_finished_one_leaves_none() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-grows-scratch";
    let session = chat(&hub, id);
    let mut text = Text(13);
    grow(&hub, &session, &sessions, (4 << 20) + (1 << 20), &mut text);
    assert!(hub.seal_pack(id).unwrap().is_some());
    assert_eq!(work_dirs(&hub, id), Vec::<String>::new(), "a finished seal leaves no scratch");
    grow(&hub, &session, &sessions, (8 << 20) + (1 << 20), &mut text);
    assert!(hub.seal_pack(id).unwrap().unwrap().extended);
    assert_eq!(work_dirs(&hub, id), Vec::<String>::new(), "an extending seal leaves none");
    let packed = manifest(&hub, id).unwrap();

    let store = hub.pack_store(id).unwrap().root().to_owned();
    let killed_mid_seal = || {
        // A daemon killed with SIGKILL halfway through writing a seal's lines.
        let status = std::process::Command::new("sh")
            .arg("-c")
            .arg(r#"d="$1/work-$$-seal-x"; mkdir "$d"; head -c 1048576 /dev/zero > "$d/history.ndjson"; kill -9 $$"#)
            .arg("sh")
            .arg(&store)
            .status()
            .unwrap();
        assert!(!status.success());
    };
    killed_mid_seal();
    super::transfer_out::note_started();
    // A build before pids were in the names, long before this daemon began.
    let legacy = store.join("work-019ac1f2a3b47c5d8e9f0a1b2c3d4e5f");
    std::fs::create_dir(&legacy).unwrap();
    std::fs::write(legacy.join("history.ndjson"), vec![b'x'; 1 << 20]).unwrap();
    let long_ago = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
    std::fs::File::open(&legacy).unwrap().set_modified(long_ago).unwrap();
    // One of this daemon (it runs), and one unowned but dated after this daemon began.
    let own = store.join(format!("work-{}-seal-live", std::process::id()));
    let fresh = store.join("work-019ac1f2a3b47c5d8e9f0a1b2c3d4e60");
    for d in [&own, &fresh] {
        std::fs::create_dir(d).unwrap();
    }
    let later = std::time::SystemTime::now() + Duration::from_secs(3600);
    std::fs::File::open(&fresh).unwrap().set_modified(later).unwrap();
    assert_eq!(work_dirs(&hub, id).len(), 4);

    // A daemon's start (`store_load.rs`) sweeps every chat's pack store.
    hub.sweep_pack_work();
    let want = vec![
        fresh.file_name().unwrap().to_string_lossy().into_owned(),
        own.file_name().unwrap().to_string_lossy().into_owned(),
    ];
    let started = Instant::now();
    while work_dirs(&hub, id) != want {
        assert!(started.elapsed() < Duration::from_secs(30), "left: {:?}", work_dirs(&hub, id));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let kept = manifest(&hub, id).unwrap();
    assert_eq!(kept.segments.len(), packed.segments.len(), "the pack itself is kept");
    assert_eq!(kept.lines, packed.lines);

    // A daemon killed sealing while this one runs (a take-over's overlap): the chat's next
    // seal removes its scratch before writing its own, and leaves none of its own.
    killed_mid_seal();
    grow(&hub, &session, &sessions, (9 << 20) + (512 << 10), &mut text);
    assert!(hub.seal_pack(id).unwrap().is_some());
    assert_eq!(work_dirs(&hub, id), want);
    std::fs::remove_dir(&own).unwrap();
}

/// A whole pack of a log larger than a piece (`WHOLE_PIECE`, 6 MiB in tests) runs in pieces,
/// each saving its sealed segments, and makes the same pack one pass over the export does;
/// it leaves no lines file behind.
#[test]
fn a_whole_pack_runs_in_pieces_and_is_the_one_pass_pack() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-grows-pieces";
    let session = chat(&hub, id);
    let mut text = Text(17);
    grow(&hub, &session, &sessions, (18 << 20) + (1 << 20), &mut text);
    let through = session.read_meta(|m| m.last_seq);
    let store = hub.pack_store(id).unwrap();
    let work = root.path().join("whole");
    let (manifest, stats, _) = hub.pack_through(&session, through, &store, &work).unwrap();
    let raw = log_bytes(&sessions, id);
    assert!(stats.encoded_bytes > raw.min(stats.raw_bytes), "one piece only: {stats:?}");
    assert_eq!(stats.kept_segments, 0, "{stats:?}");
    assert!(!work.join("history.ndjson").exists(), "the lines file is removed");

    let want = export_lines(&hub, &session, root.path());
    let fresh = pack::Store::new(root.path().join("fresh"));
    let file = root.path().join("export.ndjson");
    let (one_pass, _) = pack::pack(&fresh, id, &[file], &pack::Params::default(), true).unwrap();
    assert_eq!(manifest, one_pass, "the pieces make the one-pass pack");
    let mut back = Vec::new();
    pack::Pack::open(&store, id).unwrap().cat(&mut back).unwrap();
    assert!(back == want, "the pack reads back as the export's lines");

    // A pack after it keeps every sealed segment the pieces saved.
    let (_, again, _) = hub.pack_through(&session, through, &store, &work).unwrap();
    assert_eq!(again.kept_segments as usize, sealed(&Some(one_pass)), "{again:?}");
}

/// The duress number (`--ignored`, prints; `ACPMUX_DURESS_SESSION=<a session folder>`): a whole
/// pack of a copy of a real chat's log: its time, the most scratch its work folder held, and the
/// process's peak memory (VmHWM).
#[test]
#[ignore]
fn duress_whole_pack_of_a_real_chat() {
    let Ok(src) = std::env::var("ACPMUX_DURESS_SESSION") else { return };
    let src = PathBuf::from(src);
    let id = src.file_name().unwrap().to_string_lossy().into_owned();
    let root = tempfile::tempdir_in(std::env::var("ACPMUX_DURESS_TMP").unwrap_or("/tmp".into())).unwrap();
    let sessions = root.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let st = std::process::Command::new("cp").arg("-a").arg(&src).arg(sessions.join(&id)).status();
    assert!(st.is_ok_and(|s| s.success()));
    let _ = std::fs::remove_dir_all(sessions.join(&id).join("history-pack"));
    let hub = hub(&sessions);
    let meta = hub.store.load(&id).unwrap().expect("a meta");
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.clone(), session.clone());
    let through = session.read_meta(|m| m.last_seq);
    let store = hub.pack_store(&id).unwrap();
    let work = root.path().join("work");
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let watcher = {
        let (work, done) = (work.clone(), done.clone());
        std::thread::spawn(move || {
            let mut peak = 0u64;
            while !done.load(Ordering::Relaxed) {
                let n: u64 = std::fs::read_dir(&work).into_iter().flatten().flatten()
                    .filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum();
                peak = peak.max(n);
                std::thread::sleep(Duration::from_millis(20));
            }
            peak
        })
    };
    let started = Instant::now();
    let (manifest, stats, _) = hub.pack_through(&session, through, &store, &work).unwrap();
    let took = started.elapsed();
    done.store(true, Ordering::Relaxed);
    let peak = watcher.join().unwrap();
    let hwm = std::fs::read_to_string("/proc/self/status").unwrap_or_default().lines()
        .find(|l| l.starts_with("VmHWM")).unwrap_or("").to_owned();
    println!(
        "DURESS log={} MB seq={through} segments={} took={:.1}s peak_scratch={} MB {hwm} encoded={} MB",
        log_bytes(&sessions, &id) >> 20, manifest.segments.len(), took.as_secs_f64(),
        peak >> 20, stats.encoded_bytes >> 20,
    );
}
