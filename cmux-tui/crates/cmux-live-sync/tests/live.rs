//! Both sides for real: two folders, two watchers, the leader dialing the follower over a
//! socketpair a test can cut (a paused VM, a dropped network, a Mac asleep) and restore.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cmux_live_sync::{Event, Follower, Leader};
use crossbeam_channel::{Receiver, Sender, unbounded};

const CONFLICT: &str = ".cmux-sync-conflict";

struct Pair {
    _dirs: tempfile::TempDir,
    mac: PathBuf,
    vm: PathBuf,
    online: Arc<AtomicBool>,
    live: Arc<Mutex<Option<UnixStream>>>,
    stop: Sender<()>,
    events: Receiver<Event>,
    seen: Vec<Event>,
    leader: Option<thread::JoinHandle<()>>,
}

impl Pair {
    fn new() -> Self {
        Self::with(|_, _| {})
    }

    /// `seed` fills both folders before either side starts.
    fn with(seed: impl FnOnce(&Path, &Path)) -> Self {
        let dirs = tempfile::tempdir().unwrap();
        let mac = dirs.path().join("mac");
        let vm = dirs.path().join("vm");
        fs::create_dir_all(&mac).unwrap();
        fs::create_dir_all(&vm).unwrap();
        seed(&mac, &vm);
        let (conn_tx, conn_rx) = unbounded::<UnixStream>();
        let vm_root = vm.clone();
        let vm_state = dirs.path().join("vm-state");
        thread::spawn(move || {
            let mut f = Follower::new(vm_root, vm_state).unwrap();
            for s in conn_rx {
                let r = s.try_clone().unwrap();
                let _ = f.serve(r, s);
            }
        });
        let online = Arc::new(AtomicBool::new(true));
        let live: Arc<Mutex<Option<UnixStream>>> = Arc::default();
        let (stop, stop_rx) = unbounded();
        let (ev_tx, events) = unbounded();
        let (mac_root, mac_state) = (mac.clone(), dirs.path().join("mac-state"));
        let (on, slot) = (online.clone(), live.clone());
        let leader = thread::spawn(move || {
            let mut l = Leader::new(mac_root, mac_state, ev_tx).unwrap();
            l.run(
                || {
                    if !on.load(Ordering::SeqCst) {
                        return Err(std::io::Error::other("offline"));
                    }
                    let (a, b) = UnixStream::pair()?;
                    *slot.lock().unwrap() = Some(a.try_clone()?);
                    conn_tx.send(b).map_err(std::io::Error::other)?;
                    Ok((a.try_clone()?, a))
                },
                &stop_rx,
            );
        });
        let mut p = Self {
            _dirs: dirs,
            mac,
            vm,
            online,
            live,
            stop,
            events,
            seen: vec![],
            leader: Some(leader),
        };
        p.wait_event(Duration::from_secs(30), |e| matches!(e, Event::Online { .. }));
        p
    }

    fn cut(&mut self) {
        self.online.store(false, Ordering::SeqCst);
        if let Some(s) = self.live.lock().unwrap().take() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
        self.wait_event(Duration::from_secs(10), |e| matches!(e, Event::Offline { .. }));
    }

    fn restore(&mut self) {
        self.online.store(true, Ordering::SeqCst);
        self.wait_event(Duration::from_secs(30), |e| matches!(e, Event::Online { .. }));
    }

    fn wait_event(&mut self, within: Duration, want: impl Fn(&Event) -> bool) -> Event {
        let end = Instant::now() + within;
        loop {
            let left = end.saturating_duration_since(Instant::now());
            let e = self
                .events
                .recv_timeout(left)
                .unwrap_or_else(|_| panic!("no such event in {within:?}; saw {:?}", self.seen));
            self.seen.push(e.clone());
            if want(&e) {
                return e;
            }
        }
    }

    fn drain(&mut self) {
        while let Ok(e) = self.events.try_recv() {
            self.seen.push(e);
        }
    }

    /// Waits until both folders hold the same files, then a little longer to see they stay so.
    fn converge(&mut self, within: Duration) -> BTreeMap<String, Vec<u8>> {
        let end = Instant::now() + within;
        loop {
            self.drain();
            let (m, v) = (files(&self.mac), files(&self.vm));
            if m == v {
                thread::sleep(Duration::from_millis(300));
                self.drain();
                if files(&self.mac) == m && files(&self.vm) == m {
                    return m;
                }
                continue;
            }
            if Instant::now() > end {
                let diff: Vec<_> =
                    m.keys().chain(v.keys()).filter(|k| m.get(*k) != v.get(*k)).take(10).collect();
                panic!(
                    "not converged in {within:?}; differing {diff:?}; alerts {:?}",
                    self.alerts()
                );
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn alerts(&self) -> Vec<&String> {
        self.seen
            .iter()
            .filter_map(|e| if let Event::Alert { reason } = e { Some(reason) } else { None })
            .collect()
    }

    fn conflicts(&self) -> Vec<(String, String)> {
        self.seen
            .iter()
            .filter_map(|e| {
                if let Event::Conflict { path, copy } = e {
                    Some((path.clone(), copy.clone()))
                } else {
                    None
                }
            })
            .collect()
    }
}

impl Drop for Pair {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(s) = self.live.lock().unwrap().take() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
        if let Some(h) = self.leader.take() {
            let _ = h.join();
        }
    }
}

fn files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut out = BTreeMap::new();
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if name == ".git" || name == ".cmux-sync" || name.starts_with(".cmux-sync-tmp-") {
                continue;
            }
            let ft = e.file_type().unwrap();
            if ft.is_dir() {
                walk(root, &p, out);
            } else if ft.is_symlink() {
                let t = fs::read_link(&p).unwrap();
                out.insert(rel(root, &p), format!("->{}", t.display()).into_bytes());
            } else if let Ok(b) = fs::read(&p) {
                out.insert(rel(root, &p), b);
            }
        }
    }
    fn rel(root: &Path, p: &Path) -> String {
        p.strip_prefix(root).unwrap().to_string_lossy().into_owned()
    }
    walk(root, root, &mut out);
    out
}

fn put(root: &Path, rel: &str, bytes: impl AsRef<[u8]>) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, bytes).unwrap();
}

fn wait_for(within: Duration, mut ok: impl FnMut() -> bool) -> Duration {
    let start = Instant::now();
    while !ok() {
        assert!(start.elapsed() < within, "condition not met in {within:?}");
        thread::sleep(Duration::from_millis(1));
    }
    start.elapsed()
}

/// A small deterministic generator (no rand dependency).
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

#[test]
fn live_sync_both_ways_within_a_second() {
    let mut p = Pair::new();
    put(&p.mac, "a/from-mac.txt", "mac\n");
    let t1 = wait_for(Duration::from_secs(5), || {
        fs::read(p.vm.join("a/from-mac.txt")).is_ok_and(|b| b == b"mac\n")
    });
    put(&p.vm, "b/from-vm.txt", "vm\n");
    let t2 = wait_for(Duration::from_secs(5), || {
        fs::read(p.mac.join("b/from-vm.txt")).is_ok_and(|b| b == b"vm\n")
    });
    assert!(
        t1 < Duration::from_secs(1) && t2 < Duration::from_secs(1),
        "mac->vm {t1:?} vm->mac {t2:?}"
    );

    fs::remove_file(p.vm.join("a/from-mac.txt")).unwrap();
    wait_for(Duration::from_secs(5), || !p.mac.join("a/from-mac.txt").exists());
    std::os::unix::fs::symlink("b/from-vm.txt", p.mac.join("link")).unwrap();
    let mut x = fs::File::create(p.mac.join("tool.sh")).unwrap();
    std::io::Write::write_all(&mut x, b"#!/bin/sh\n").unwrap();
    drop(x);
    std::os::unix::fs::PermissionsExt::set_mode(
        &mut fs::metadata(p.mac.join("tool.sh")).unwrap().permissions(),
        0o755,
    );
    fs::set_permissions(p.mac.join("tool.sh"), std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .unwrap();
    put(&p.mac, ".gitignore", "target/\n");
    put(&p.mac, "target/big.o", "build output\n");
    let all = p.converge(Duration::from_secs(5));
    assert!(all.contains_key("link") && all.contains_key("tool.sh"));
    assert!(!p.vm.join("target/big.o").exists(), "ignored path synced");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(fs::metadata(p.vm.join("tool.sh")).unwrap().permissions().mode() & 0o111, 0o111);
    assert!(fs::symlink_metadata(p.vm.join("link")).unwrap().file_type().is_symlink());
}

#[test]
fn live_sync_starts_from_both_folders() {
    let mut p = Pair::with(|mac, vm| {
        put(mac, "only-mac", "m");
        put(vm, "only-vm", "v");
        put(mac, "same", "s");
        put(vm, "same", "s");
    });
    let all = p.converge(Duration::from_secs(5));
    assert_eq!(all.len(), 3, "{all:?}");
}

#[test]
fn live_sync_clean_text_conflict_merges() {
    let mut p = Pair::new();
    put(&p.mac, "notes.md", "one\ntwo\nthree\nfour\nfive\n");
    p.converge(Duration::from_secs(5));
    p.cut();
    put(&p.mac, "notes.md", "ONE\ntwo\nthree\nfour\nfive\n");
    put(&p.vm, "notes.md", "one\ntwo\nthree\nfour\nFIVE\n");
    p.restore();
    let all = p.converge(Duration::from_secs(5));
    assert_eq!(all["notes.md"], b"ONE\ntwo\nthree\nfour\nFIVE\n");
    assert!(!all.keys().any(|k| k.contains(CONFLICT)), "{all:?}");
}

#[test]
fn live_sync_conflict_keeps_both_copies_and_says_so_once() {
    let mut p = Pair::new();
    put(&p.mac, "x.txt", "base\n");
    p.converge(Duration::from_secs(5));
    p.cut();
    put(&p.mac, "x.txt", "mac edit\n");
    put(&p.vm, "x.txt", "vm edit\n");
    put(&p.mac, "bin.dat", [0u8, 1, 2]);
    put(&p.vm, "bin.dat", [0u8, 9, 9]);
    p.restore();
    let all = p.converge(Duration::from_secs(5));
    assert_eq!(all["x.txt"], b"vm edit\n");
    assert_eq!(all[&format!("x.txt{CONFLICT}")], b"mac edit\n");
    assert_eq!(all["bin.dat"], [0u8, 9, 9]);
    assert_eq!(all[&format!("bin.dat{CONFLICT}")], [0u8, 1, 2]);
    thread::sleep(Duration::from_millis(300));
    p.drain();
    let mut c = p.conflicts();
    c.sort();
    assert_eq!(
        c,
        vec![
            ("bin.dat".into(), format!("bin.dat{CONFLICT}")),
            ("x.txt".into(), format!("x.txt{CONFLICT}"))
        ]
    );
}

#[test]
fn live_sync_edit_beats_delete() {
    let mut p = Pair::new();
    put(&p.mac, "a", "1\n");
    put(&p.mac, "b", "1\n");
    p.converge(Duration::from_secs(5));
    p.cut();
    fs::remove_file(p.mac.join("a")).unwrap();
    put(&p.vm, "a", "vm kept\n");
    put(&p.mac, "b", "mac kept\n");
    fs::remove_file(p.vm.join("b")).unwrap();
    p.restore();
    let all = p.converge(Duration::from_secs(5));
    assert_eq!(all["a"], b"vm kept\n");
    assert_eq!(all["b"], b"mac kept\n");
}

/// Both sides write the same files at once. An edit is lost when it is in no file at the end
/// and the other side never saw it before writing over it (each writer records what it found at
/// the path before each write: a user overwriting what they saw is not a loss).
#[test]
fn live_sync_concurrent_edits_lose_nothing() {
    let mut p = Pair::new();
    let paths: Vec<String> = (0..40).map(|i| format!("d{}/f{i}.txt", i % 5)).collect();
    let handles: Vec<_> = [("mac", p.mac.clone(), 1u64), ("vm", p.vm.clone(), 2u64)]
        .into_iter()
        .map(|(side, root, seed)| {
            let paths = paths.clone();
            thread::spawn(move || {
                let mut rng = Rng(0x9E37_79B9_7F4A_7C15 ^ seed);
                let mut mine: BTreeMap<String, Vec<u8>> = BTreeMap::new();
                let mut saw: std::collections::BTreeSet<Vec<u8>> = Default::default();
                for n in 0..400 {
                    let path = &paths[rng.below(paths.len() as u64) as usize];
                    if let Ok(now) = fs::read(root.join(path)) {
                        saw.insert(now);
                    }
                    let body = format!("{side} {path} {n}\n").into_bytes();
                    put(&root, path, &body);
                    mine.insert(path.clone(), body);
                    if n % 7 == 0 {
                        thread::sleep(Duration::from_millis(rng.below(15)));
                    }
                }
                (mine, saw)
            })
        })
        .collect();
    let sides: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    let all = p.converge(Duration::from_secs(20));
    let contents: std::collections::BTreeSet<&Vec<u8>> = all.values().collect();
    let mut lost = vec![];
    for (i, (mine, _)) in sides.iter().enumerate() {
        let other_saw = &sides[1 - i].1;
        for (path, body) in mine {
            if !contents.contains(body) && !other_saw.contains(body) {
                lost.push((path.clone(), String::from_utf8_lossy(body).into_owned()));
            }
        }
    }
    let copies = all.keys().filter(|k| k.contains(CONFLICT)).count();
    eprintln!(
        "concurrent: {} writes, {} paths, {copies} conflict copies, {} lost",
        800,
        all.len(),
        lost.len()
    );
    assert!(lost.is_empty(), "lost edits: {lost:?}");
    assert!(p.alerts().is_empty(), "{:?}", p.alerts());
}

#[test]
fn live_sync_ten_thousand_files() {
    let n: usize =
        std::env::var("CMUX_LIVE_SYNC_TREE").ok().and_then(|s| s.parse().ok()).unwrap_or(10_000);
    let mut p = Pair::new();
    let start = Instant::now();
    for i in 0..n {
        put(&p.mac, &format!("src/m{}/f{i}.rs", i % 100), format!("// {i}\n"));
    }
    let wrote = start.elapsed();
    let all = p.converge(Duration::from_secs(120));
    let mac_to_vm = start.elapsed();
    assert_eq!(all.len(), n);
    let start = Instant::now();
    for i in 0..n {
        put(&p.vm, &format!("vm/m{}/f{i}.rs", i % 100), format!("// vm {i}\n"));
    }
    let all = p.converge(Duration::from_secs(120));
    let vm_to_mac = start.elapsed();
    assert_eq!(all.len(), 2 * n);
    eprintln!(
        "tree {n} files: write {wrote:?}, mac->vm settled {mac_to_vm:?}, vm->mac settled {vm_to_mac:?}"
    );
    // A reconnect with the tree in place is a catch-up of nothing.
    p.cut();
    p.restore();
    let online = p.seen.iter().rev().find_map(|e| {
        if let Event::Online { paths, took } = e { Some((*paths, *took)) } else { None }
    });
    eprintln!("reconnect over {} files: {online:?}", 2 * n);
    assert_eq!(online.map(|o| o.0), Some(0));
}

/// Offline (paused VM, Mac asleep) with edits on both sides, then reconnect: everything caught
/// up, nothing lost. CMUX_LIVE_SYNC_OFFLINE_SECS=600 is the 10-minute run.
#[test]
fn live_sync_offline_then_reconnect() {
    let secs: u64 =
        std::env::var("CMUX_LIVE_SYNC_OFFLINE_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(2);
    let mut p = Pair::new();
    for i in 0..200 {
        put(&p.mac, &format!("f{i}"), format!("v0 {i}\n"));
    }
    p.converge(Duration::from_secs(10));
    p.cut();
    let end = Instant::now() + Duration::from_secs(secs);
    let mut rng = Rng(77);
    let mut expect: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut n = 0u64;
    while Instant::now() < end || n < 400 {
        n += 1;
        let i = rng.below(200);
        // Disjoint halves: no conflicts, so the final tree is known exactly.
        let (root, side) = if i < 100 { (&p.mac, "mac") } else { (&p.vm, "vm") };
        let body = format!("{side} {i} {n}\n").into_bytes();
        put(root, &format!("f{i}"), &body);
        expect.insert(format!("f{i}"), body);
        if rng.below(10) == 0 {
            let path = format!("new/{side}-{n}");
            put(root, &path, b"x");
            expect.insert(path, b"x".to_vec());
        }
        if n > 400 {
            thread::sleep(Duration::from_millis(50));
        }
    }
    thread::sleep(Duration::from_millis(200));
    let caught = Instant::now();
    p.restore();
    let all = p.converge(Duration::from_secs(30));
    eprintln!("offline {secs} s, {n} edits: caught up in {:?}", caught.elapsed());
    for (k, v) in &expect {
        assert_eq!(all.get(k), Some(v), "{k}");
    }
}

/// The link drops in the middle of steady writes, many times: no edit is lost or doubled.
#[test]
fn live_sync_survives_flapping_link() {
    let mut p = Pair::new();
    let mut rng = Rng(5);
    let mut expect: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for round in 0..8 {
        for n in 0..50 {
            let i = rng.below(60);
            let (root, side) = if i < 30 { (&p.mac, "mac") } else { (&p.vm, "vm") };
            let body = format!("{side} {i} {round} {n}\n").into_bytes();
            put(root, &format!("g/{i}"), &body);
            expect.insert(format!("g/{i}"), body);
        }
        p.cut();
        p.restore();
    }
    let all = p.converge(Duration::from_secs(20));
    assert_eq!(all, expect);
}
