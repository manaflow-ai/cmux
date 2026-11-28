//! [`Hub::pack_through`] from the pack's sealed segments: a compaction's outline or an export of
//! a long chat writes and encodes only the lines after the segments the log still holds, never
//! the whole log (`transfer_history.rs` `pack_kept_through`).

use super::*;
use crate::store::{LocalStore, META_SCHEMA, SessionMeta};
use std::time::Instant;

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

/// Agent text of about `len` bytes a record, little of it repeated.
struct Text(u64);

impl Text {
    fn next(&mut self, len: usize) -> String {
        let mut words = String::with_capacity(len + 16);
        while words.len() < len {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            let n = 2 + (self.0 % 9) as usize;
            words.extend((0..n).map(|i| char::from(b'a' + ((self.0 >> (i * 5)) % 26) as u8)));
            words.push(' ');
        }
        words
    }
}

fn append(hub: &Hub, session: &Session, records: u64, len: usize, text: &mut Text) {
    for _ in 0..records {
        let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": session.id, "update": {"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text.next(len)}}}});
        hub.append(session, "in", "agent_message_chunk", msg);
    }
}

/// The whole pack of the chat's lines through `through`, as a pack from nothing makes it, and
/// the digest of the record there.
fn whole_pack(hub: &Hub, session: &Session, through: u64, dir: &Path) -> (pack::Manifest, String) {
    let lines = dir.join(format!("whole-{through}.ndjson"));
    let (last, digest) = hub.write_lines(session, 0, through, &lines).unwrap();
    assert_eq!(last, through);
    let fresh = pack::Store::new(dir.join(format!("fresh-{through}")));
    let (m, _) = pack::pack(&fresh, &session.id, &[lines], &pack::Params::default(), true).unwrap();
    (m, digest)
}

fn sealed(m: &pack::Manifest) -> usize {
    m.segments.iter().filter(|s| s.sealed).count()
}

/// The bytes this process has passed to `write` (Linux `/proc/self/io` `wchar`: every write,
/// to a disk or a cache, by any of its threads).
fn written() -> Option<u64> {
    let io = std::fs::read_to_string("/proc/self/io").ok()?;
    io.lines().find_map(|l| l.strip_prefix("wchar:")).and_then(|v| v.trim().parse().ok())
}

/// After a seal, a pack through the newest record keeps every sealed segment and encodes only
/// the lines after them: trusted while the log's stamp is the one the seal checked, and checked
/// by hashing the lines as they stream (nothing written) in a daemon that has not checked them.
/// Whichever way, the pack is the whole pack of the same lines with the same digest; a segment
/// the log no longer holds is encoded again with every one after it, and a pack through an
/// earlier record is cut back there as a whole pack is.
#[test]
fn a_pack_through_keeps_the_sealed_segments_the_log_still_holds() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-kept-a";
    let session = chat(&hub, id);
    let mut text = Text(0x2545_f491_4f6c_dd1d);
    append(&hub, &session, 7_000, 2200, &mut text);
    let seal = hub.seal_pack(id).unwrap().unwrap();
    let n = sealed(&seal.manifest);
    assert!(n >= 3, "{n} sealed");
    append(&hub, &session, 300, 2200, &mut text);
    let store = hub.pack_store(id).unwrap();
    let through = session.read_meta(|m| m.last_seq);

    // Trusted: the seal checked the segments at this stamp.
    let work = root.path().join("work-trusted");
    let (m, stats, digest) = hub.pack_through(&session, through, &store, &work).unwrap();
    assert_eq!(stats.kept_segments as usize, n, "{stats:?}");
    assert!(stats.encoded_bytes < 4 << 20, "only the open tail is encoded: {stats:?}");
    assert!(!work.join("history.ndjson").exists(), "the tail's lines are removed");
    let (want, want_digest) = whole_pack(&hub, &session, through, root.path());
    assert_eq!(m, want, "the pack is the whole pack of the same lines");
    assert_eq!(digest, want_digest);

    // A daemon that never checked them (and kept no trust): hashed as they stream, the same pack.
    hub.forget_pack_trust(id);
    let work = root.path().join("work-checked");
    let (m, stats, digest) = hub.pack_through(&session, through, &store, &work).unwrap();
    assert_eq!(stats.kept_segments as usize, n, "{stats:?}");
    assert_eq!((m, digest.clone()), (want.clone(), want_digest.clone()));
    assert!(hub.pack_checked.lock().unwrap().contains_key(id), "checked now, so trusted next");

    // The log no longer holds the second segment: the first is kept, the rest encoded again.
    hub.pack_checked.lock().unwrap().clear();
    let mut bent = pack::Manifest::load(&store, id).unwrap().unwrap();
    bent.segments[1].raw_hash = "0".repeat(64);
    bent.save(&store).unwrap();
    let work = root.path().join("work-bent");
    let (m, stats, _) = hub.pack_through(&session, through, &store, &work).unwrap();
    assert_eq!(stats.kept_segments, 1, "{stats:?}");
    assert_eq!(m, want);

    // Through a record inside the sealed segments: cut back there, as a whole pack of it is.
    let mid = seal.manifest.segments[1].seq.unwrap().1 + 5;
    let work = root.path().join("work-mid");
    let (m, stats, digest) = hub.pack_through(&session, mid, &store, &work).unwrap();
    assert_eq!(stats.kept_segments, 2, "{stats:?}");
    let (want_mid, want_mid_digest) = whole_pack(&hub, &session, mid, root.path());
    assert_eq!((m, digest), (want_mid, want_mid_digest));

    // Through the last record of a sealed segment: nothing to encode, the digest still its own.
    let end = seal.manifest.segments[0].seq.unwrap().1;
    let work = root.path().join("work-end");
    let (m, stats, digest) = hub.pack_through(&session, end, &store, &work).unwrap();
    assert_eq!((stats.kept_segments, stats.encoded_bytes), (1, 0), "{stats:?}");
    let (want_end, want_end_digest) = whole_pack(&hub, &session, end, root.path());
    assert_eq!((m, digest), (want_end, want_end_digest));
}

/// Bytes written and time per compaction-time pack of a long chat: `ACPMUX_BENCH_EVENTS` records
/// (1,000,000 by default) of about 200 bytes, sealed as the daemon seals as it grows, then 1,000
/// more (the change) and a pack through the newest, as a compaction's outline packs. Once while
/// the seal's check holds (the daemon that sealed) and once in a daemon that has not checked the
/// pack (a restart). Linux only (`/proc/self/io`).
///
/// ```text
/// cargo test -p acpmux --lib pack_through_bench -- --ignored --nocapture --test-threads=1
/// ```
#[test]
#[ignore = "a bench: about a minute, prints bytes written per pack"]
fn pack_through_bench() {
    let events: u64 =
        std::env::var("ACPMUX_BENCH_EVENTS").ok().and_then(|v| v.parse().ok()).unwrap_or(1_000_000);
    let root =
        tempfile::tempdir_in(std::env::var("ACPMUX_BENCH_DIR").unwrap_or("/tmp".into())).unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(&sessions);
    let id = "pack-bench";
    let session = chat(&hub, id);
    let mut text = Text(0x9e37_79b9_7f4a_7c15);
    let started = Instant::now();
    // Grown and sealed in steps, as the daemon seals every 4 MiB.
    let step = 50_000u64.min(events);
    let mut grown = 0;
    while grown < events {
        let n = step.min(events - grown);
        append(&hub, &session, n, 200, &mut text);
        grown += n;
        hub.seal_pack(id).unwrap();
    }
    let log: u64 = std::fs::read_dir(sessions.join(id).join("events"))
        .unwrap()
        .flatten()
        .map(|e| e.metadata().map(|m| m.len()).unwrap_or(0))
        .sum();
    eprintln!("grew {events} records, {log} log bytes, in {:?}", started.elapsed());
    let store = hub.pack_store(id).unwrap();
    // Before: what every pack through did, the whole log's lines written, then packed.
    {
        append(&hub, &session, 1_000, 200, &mut text);
        let through = session.read_meta(|m| m.last_seq);
        let work = root.path().join("work-before");
        std::fs::create_dir_all(&work).unwrap();
        let lines = work.join("history.ndjson");
        let (before, at) = (written(), Instant::now());
        let (last, _) = hub.write_lines(&session, 0, through, &lines).unwrap();
        assert_eq!(last, through);
        let params = pack::Params::default();
        let (_, stats) =
            pack::pack(&store, id, std::slice::from_ref(&lines), &params, false).unwrap();
        let took = at.elapsed();
        let bytes = written().zip(before).map(|(a, b)| a - b);
        eprintln!(
            "BENCH before (whole log written, then packed): {} bytes written, {took:?}, {} of {} \
             log bytes encoded, {} segments kept",
            bytes.map_or("?".into(), |b| b.to_string()),
            stats.encoded_bytes,
            stats.raw_bytes,
            stats.kept_segments,
        );
        let _ = std::fs::remove_dir_all(&work);
    }
    // After a seal (this daemon checked the segments); after a restart that kept no trust (the
    // segments checked against the whole log again, as every restart did before
    // `pack_trust.rs`); after a restart that kept it.
    for (case, restart) in [
        ("after a seal", None),
        ("after a restart, trust not kept", Some(false)),
        ("after a restart, trust kept", Some(true)),
    ] {
        append(&hub, &session, 1_000, 200, &mut text);
        match restart {
            None => {}
            Some(false) => hub.forget_pack_trust(id),
            Some(true) => hub.pack_checked.lock().unwrap().clear(),
        }
        let through = session.read_meta(|m| m.last_seq);
        let work = root.path().join(format!("work-{restart:?}"));
        let (before, cpu, at) = (written(), cpu_ms(), Instant::now());
        let (_, stats, _) = hub.pack_through(&session, through, &store, &work).unwrap();
        let took = at.elapsed();
        let bytes = written().zip(before).map(|(a, b)| a - b);
        let cpu = cpu_ms().zip(cpu).map(|(a, b)| a - b);
        eprintln!(
            "BENCH after, pack_through {case}: {} bytes written, {took:?}, {} ms CPU, {} of {} log \
             bytes encoded, {} segments kept",
            bytes.map_or("?".into(), |b| b.to_string()),
            cpu.map_or("?".into(), |c| c.to_string()),
            stats.encoded_bytes,
            stats.raw_bytes,
            stats.kept_segments,
        );
        let _ = std::fs::remove_dir_all(&work);
    }
    // A daemon's first seal of the chat after a restart, as the pack worker runs it.
    for (case, kept) in [("trust not kept", false), ("trust kept", true)] {
        append(&hub, &session, 25_000, 200, &mut text);
        match kept {
            false => hub.forget_pack_trust(id),
            true => hub.pack_checked.lock().unwrap().clear(),
        }
        let (cpu, at) = (cpu_ms(), Instant::now());
        let sealed = hub.seal_pack(id).unwrap().unwrap();
        let took = at.elapsed();
        let cpu = cpu_ms().zip(cpu).map(|(a, b)| a - b);
        eprintln!(
            "BENCH first seal after a restart, {case}: {took:?}, {} ms CPU, extended {}, {} of {} \
             log bytes encoded",
            cpu.map_or("?".into(), |c| c.to_string()),
            sealed.extended,
            sealed.stats.encoded_bytes,
            sealed.stats.raw_bytes,
        );
    }
}

/// This process's CPU time so far, user and system, in ms (Linux `/proc/self/stat`, in clock
/// ticks of 10 ms).
fn cpu_ms() -> Option<u64> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let fields: Vec<&str> = stat.rsplit_once(") ")?.1.split(' ').collect();
    let ticks: u64 = fields.get(11)?.parse::<u64>().ok()? + fields.get(12)?.parse::<u64>().ok()?;
    Some(ticks * 10)
}

/// The scratch of a daemon killed while it wrote a chat's lines (`transfer_out.rs` `scratch_dir`)
/// is removed by the next sweep at once, not a day later; a live daemon's scratch, one named before
/// pids that is newer than this daemon, and a move's bundle are kept.
#[cfg(unix)]
#[test]
fn a_dead_daemons_scratch_is_swept_at_once() {
    use super::transfer_out::{note_started, sweep_transfers_in};
    let dir = tempfile::tempdir().unwrap();
    let transfers = dir.path();
    // A process killed with SIGKILL halfway through writing its lines.
    let status = std::process::Command::new("sh")
        .arg("-c")
        .arg(r#"d="$1/work-$$-outline-x"; mkdir "$d"; head -c 1048576 /dev/zero > "$d/history.ndjson"; kill -9 $$"#)
        .arg("sh")
        .arg(transfers)
        .status()
        .unwrap();
    assert!(!status.success());
    note_started();
    let own = transfers.join(format!("work-{}-outline-y", std::process::id()));
    let fresh_legacy = transfers.join("outline-fresh");
    let old_legacy = transfers.join("history-read-old");
    let bundle = transfers.join("pre-bundle");
    for d in [&own, &fresh_legacy, &old_legacy, &bundle] {
        std::fs::create_dir(d).unwrap();
    }
    let long_ago = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000);
    std::fs::File::open(&old_legacy).unwrap().set_modified(long_ago).unwrap();
    // A file system clock coarser than the system one can date a folder made just now before
    // the start noted above: this one is dated plainly after it.
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
    std::fs::File::open(&fresh_legacy).unwrap().set_modified(later).unwrap();
    let dead: Vec<_> = std::fs::read_dir(transfers)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with("-outline-x"))
        .map(|e| e.path())
        .collect();
    assert_eq!(dead.len(), 1);
    sweep_transfers_in(transfers, &[]);
    assert!(!dead[0].exists(), "a dead daemon's scratch goes at once");
    assert!(!old_legacy.exists(), "scratch named before pids, older than this daemon, goes");
    for kept in [&own, &fresh_legacy, &bundle] {
        assert!(kept.exists(), "{} is kept", kept.display());
    }
}

/// The child side of [`a_daemon_killed_mid_pack_leaves_a_pack_the_next_one_completes`]: opens the
/// chat its parent grew and packs it from nothing until the parent kills it.
#[test]
#[ignore = "run by its parent test only"]
fn pack_child_killed_mid_pack() {
    let Ok(sessions) = std::env::var("ACPMUX_TEST_PACK_SESSIONS") else { return };
    let hub = hub(Path::new(&sessions));
    hub.load_from_store(false);
    let session = hub.sessions.lock().unwrap().get("pack-killed").cloned().unwrap();
    let store = hub.pack_store(&session.id).unwrap();
    let through = session.read_meta(|m| m.last_seq);
    loop {
        let work = super::transfer_out::scratch_dir("outline");
        let _ = hub.pack_through(&session, through, &store, &work);
        let _ = std::fs::remove_dir_all(&work);
    }
}

/// Under duress: a daemon killed (SIGKILL) while it packs a long chat's history leaves its pack
/// readable and its scratch behind; the next daemon's sweep removes the scratch at once, and its
/// pack through the newest record keeps what the killed one sealed and is the whole pack.
#[cfg(target_os = "linux")]
#[test]
fn a_daemon_killed_mid_pack_leaves_a_pack_the_next_one_completes() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let home = root.path().join("home");
    std::fs::create_dir_all(home.join("transfers")).unwrap();
    let id = "pack-killed";
    {
        let hub = hub(&sessions);
        let session = chat(&hub, id);
        let mut text = Text(77);
        append(&hub, &session, 30_000, 2200, &mut text);
    }
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["pack_child_killed_mid_pack", "--ignored", "--nocapture", "--test-threads=1"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_TEST_PACK_SESSIONS", &sessions)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    // Killed while it writes the chat's lines.
    let started = Instant::now();
    loop {
        let writing =
            std::fs::read_dir(home.join("transfers")).into_iter().flatten().flatten().any(|e| {
                std::fs::metadata(e.path().join("history.ndjson")).is_ok_and(|m| m.len() > 1 << 20)
            });
        if writing {
            break;
        }
        assert!(started.elapsed() < std::time::Duration::from_secs(120), "the child never packed");
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    child.kill().unwrap();
    assert!(!child.wait().unwrap().success());
    let left = std::fs::read_dir(home.join("transfers")).unwrap().count();
    assert!(left >= 1, "the killed daemon left its scratch");

    super::transfer_out::sweep_transfers_in(&home.join("transfers"), &[]);
    assert_eq!(std::fs::read_dir(home.join("transfers")).unwrap().count(), 0);

    let hub = hub(&sessions);
    hub.load_from_store(false);
    let session = hub.sessions.lock().unwrap().get(id).cloned().unwrap();
    let store = hub.pack_store(id).unwrap();
    let held = pack::Manifest::load(&store, id).unwrap();
    let through = session.read_meta(|m| m.last_seq);
    let work = root.path().join("work-after");
    let (m, stats, digest) = hub.pack_through(&session, through, &store, &work).unwrap();
    if let Some(held) = held {
        assert_eq!(stats.kept_segments as usize, sealed(&held), "{stats:?}");
    }
    let (want, want_digest) = whole_pack(&hub, &session, through, root.path());
    assert_eq!((m, digest), (want, want_digest));
    let mut back = Vec::new();
    pack::Pack::open(&store, id).unwrap().cat(&mut back).unwrap();
    let lines = std::fs::read(root.path().join(format!("whole-{through}.ndjson"))).unwrap();
    assert!(back == lines, "the completed pack reads back as the chat's lines");
}
