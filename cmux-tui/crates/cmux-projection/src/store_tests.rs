use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;
use crate::link::{Source, answer_asks};
use crate::manifest::{Item, Kind, Manifest};
use crate::peers::{Answer, Get, Remote};
use crate::upload::{Store, Uploader, prefetch_order};
use crate::wire::{self, Part};

/// A store in memory: what the Mac puts, the chain's `GET <base>/objects/<id>` reads.
#[derive(Default)]
struct Bucket {
    objects: Mutex<HashMap<String, Vec<u8>>>,
    gets: AtomicUsize,
}

impl Store for Arc<Bucket> {
    fn put(&self, oid: &str, bytes: &[u8]) -> anyhow::Result<()> {
        self.objects.lock().unwrap().insert(oid.to_owned(), bytes.to_vec());
        Ok(())
    }
}

impl Get for Arc<Bucket> {
    fn get(&self, url: &str, _token: Option<&str>, _deadline: Duration) -> Answer {
        self.gets.fetch_add(1, Ordering::Relaxed);
        let oid = url.rsplit('/').next().unwrap_or_default();
        self.objects.lock().unwrap().get(oid).cloned().map_or(Answer::Absent, Answer::Found)
    }
}

fn chain(bucket: &Arc<Bucket>) -> Chain {
    let remote = Remote { tier: "r2", base: "http://store.test/u".into(), token: None };
    Chain::new(vec![remote], Box::new(bucket.clone()))
}

/// The Mac's folder: bytes by entry.
struct Folder(HashMap<u32, Vec<u8>>);

impl Source for Folder {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let Some(bytes) = self.0.get(&entry) else { return Part::status(wire::FAILED) };
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Part::ok(bytes[start..end].to_vec())
    }

    fn whole(&self, entry: u32) -> Part {
        self.0.get(&entry).map_or(Part::status(wire::FAILED), |bytes| Part::ok(bytes.clone()))
    }
}

/// A workspace of `crates` crates, each `Cargo.toml` and `src/{lib,a,b}.rs`, beside a `docs/`
/// folder and a big file the store never takes.
fn folder(crates: usize) -> (Arc<Manifest>, Folder, Vec<String>) {
    let mut files: Vec<(String, Vec<u8>)> = vec![
        ("Cargo.toml".into(), b"[workspace]\n".to_vec()),
        ("docs/guide.md".into(), b"# guide\n".to_vec()),
        ("big.bin".into(), vec![7u8; (crate::upload::MAX_WHOLE + 1) as usize]),
    ];
    for at in 0..crates {
        files.push((format!("crates/c{at}/Cargo.toml"), format!("[package] c{at}").into_bytes()));
        for name in ["lib", "a", "b"] {
            files.push((
                format!("crates/c{at}/src/{name}.rs"),
                format!("// c{at} {name}\npub fn {name}() {{}}\n").into_bytes(),
            ));
        }
    }
    let items = files
        .iter()
        .map(|(path, bytes)| Item {
            path: path.clone(),
            kind: Kind::File,
            mode: 0o644,
            size: bytes.len() as u64,
            mtime_ns: 1_700_000_000_000_000_000,
            link: None,
        })
        .collect();
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let mut bytes = HashMap::new();
    let mut paths = Vec::new();
    for (path, content) in files {
        bytes.insert(manifest.resolve(&path).unwrap(), content);
        paths.push(path);
    }
    (manifest, Folder(bytes), paths)
}

/// Attaches a stream from the Mac (`source` answering) to `link`; the returned end, shut down,
/// is the Mac going to sleep.
fn wake(link: &Arc<Link>, source: Arc<dyn Source + Send + Sync>) -> UnixStream {
    let (machine, mac) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    let answering = mac.try_clone().unwrap();
    std::thread::spawn(move || {
        let writer = answering.try_clone().unwrap();
        let _ = answer_asks(answering, writer, source.as_ref());
    });
    wait_until(|| link.attached());
    mac
}

fn sleep_mac(link: &Link, mac: &UnixStream) {
    mac.shutdown(std::net::Shutdown::Both).unwrap();
    wait_until(|| !link.attached());
}

fn wait_until(done: impl Fn() -> bool) {
    let start = Instant::now();
    while !done() {
        assert!(start.elapsed() < Duration::from_secs(5), "timed out");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn prefetch_order_puts_a_faults_folder_then_project_folders_then_the_rest() {
    let (manifest, _, _) = folder(2);
    let id = |path: &str| manifest.resolve(path).unwrap();
    let base = prefetch_order(&manifest, &[]);
    let at = |order: &[u32], path: &str| order.iter().position(|index| *index == id(path)).unwrap();
    // Project folders' top-level files come before anything breadth-first.
    assert!(at(&base, "crates/c1/Cargo.toml") < at(&base, "docs/guide.md"));
    assert!(at(&base, "Cargo.toml") < at(&base, "crates/c0/src/a.rs"));
    // The big file stays with the Mac; every small file is there once.
    assert!(!base.contains(&id("big.bin")));
    assert_eq!(base.len(), manifest.len() - 1 - 6 - 1, "all but the root, 6 folders and big.bin");
    let mut sorted = base.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(sorted.len(), base.len());
    // A fault in c1's sources puts its folder first.
    let after = prefetch_order(&manifest, &[id("crates/c1/src/a.rs")]);
    assert_eq!(
        &after[..3],
        &[id("crates/c1/src/a.rs"), id("crates/c1/src/b.rs"), id("crates/c1/src/lib.rs")]
    );
}

#[test]
fn the_uploader_puts_a_faulted_folder_next() {
    let (manifest, source, _) = folder(3);
    let uploader = Uploader::new(source, manifest.clone(), 1);
    let fault = manifest.resolve("crates/c2/src/b.rs").unwrap();
    let _ = Source::whole(&uploader, fault);
    let bucket = Arc::new(Bucket::default());
    let uploaded = uploader.run(&bucket);
    assert_eq!(uploaded.skipped, 0);
    assert_eq!(uploaded.files, manifest.len() - 1 - 8 - 1);
    let first: Vec<String> =
        uploader.stored_files().iter().take(3).map(|(entry, _)| manifest.path_of(*entry)).collect();
    assert_eq!(first, ["crates/c2/src/a.rs", "crates/c2/src/b.rs", "crates/c2/src/lib.rs"]);
    // Every id names the bytes put under it.
    for (_, oid) in uploader.stored_files() {
        let objects = bucket.objects.lock().unwrap();
        assert!(crate::peers::verify(&oid, &objects[&oid]));
    }
}

/// How many of `paths` a session reads, byte for byte, through an overlay over `fetch`.
#[cfg(target_os = "linux")]
fn readable(
    fetch: Arc<dyn Fetch>,
    manifest: &Arc<Manifest>,
    folder: &Folder,
    paths: &[String],
) -> usize {
    let state = tempfile::tempdir().unwrap();
    // SAFETY: getuid and getgid have no preconditions.
    let owner = unsafe { (libc::getuid(), libc::getgid()) };
    let overlay =
        crate::overlay::Overlay::open(manifest.clone(), state.path(), fetch, owner).unwrap();
    paths
        .iter()
        .filter(|path| {
            let mut ino = overlay.root();
            for name in path.split('/') {
                ino = overlay.lookup(ino, name).unwrap().ino;
            }
            let want = &folder.0[&manifest.resolve(path).unwrap()];
            overlay.read(ino, 0, 1 << 20).is_ok_and(|bytes| &bytes == want)
        })
        .count()
}

/// RFD 0007 slice 3's proof: the Mac uploads, then sleeps, and a session keeps reading files
/// it never read before. The same session over the link alone (before this slice) reads none.
#[cfg(target_os = "linux")]
#[test]
fn a_session_keeps_reading_new_files_with_the_mac_asleep() {
    let (manifest, source, paths) = folder(20);
    let small: Vec<String> = paths.iter().filter(|path| *path != "big.bin").cloned().collect();
    let (_, mirror, _) = folder(20);
    let uploader = Arc::new(Uploader::new(source, manifest.clone(), 42));
    let bucket = Arc::new(Bucket::default());

    // Before: the link alone, the Mac asleep from the start.
    let link = Arc::new(Link::new(Duration::from_millis(20)));
    let before = readable(link, &manifest, &mirror, &small);

    // After: the Mac uploads in prefetch order while awake, the machine learns the list, then
    // the Mac sleeps.
    let link = Arc::new(Link::new(Duration::from_millis(20)));
    let mac = wake(&link, uploader.clone());
    let uploaded = uploader.run(&bucket);
    assert_eq!(uploaded.files, small.len());
    let fetch = Arc::new(StoreFirst::new(link.clone(), chain(&bucket)));
    assert_eq!(fetch.refresh(), small.len());
    sleep_mac(&link, &mac);
    assert_eq!(fetch.refresh(), 0, "nothing is asked of a sleeping Mac");
    let after = readable(fetch.clone(), &manifest, &mirror, &small);
    // The big file still needs the Mac.
    let big = readable(fetch.clone(), &manifest, &mirror, &["big.bin".to_owned()]);

    eprintln!(
        "files readable with the Mac asleep ({} small files): before {before}, after {after}",
        small.len()
    );
    assert_eq!((before, after, big), (0, small.len(), 0));
    let faults = fetch.faults();
    assert_eq!(faults.missed, 0);
    assert!(faults.store >= small.len() as u64);
}

#[test]
fn a_wrong_store_answer_is_dropped_and_the_mac_answers() {
    let (manifest, source, _) = folder(1);
    let (_, mirror, _) = folder(1);
    let uploader = Arc::new(Uploader::new(source, manifest.clone(), 7));
    let bucket = Arc::new(Bucket::default());
    uploader.run(&bucket);
    let link = Arc::new(Link::new(Duration::from_millis(200)));
    let _mac = wake(&link, uploader.clone());
    let fetch = StoreFirst::new(link, chain(&bucket));
    fetch.refresh();
    let entry = manifest.resolve("crates/c0/src/a.rs").unwrap();
    let oid = uploader.stored_files().into_iter().find(|(at, _)| *at == entry).unwrap().1;
    bucket.objects.lock().unwrap().insert(oid, b"not the file".to_vec());
    assert_eq!(fetch.read(entry, 0, 1 << 20).unwrap(), mirror.0[&entry]);
    assert_eq!(fetch.faults(), Faults { store: 0, mac: 1, missed: 1 });
    // A batch mixes the two: the store's good answers, the Mac for the rest.
    let other = manifest.resolve("crates/c0/src/b.rs").unwrap();
    let answers = fetch.batch(&[other, entry]);
    assert_eq!(answers[0].as_deref().unwrap(), mirror.0[&other].as_slice());
    assert_eq!(answers[1].as_deref().unwrap(), mirror.0[&entry].as_slice());
}

#[test]
fn a_restarted_mac_upload_is_learned_from_its_start() {
    let (manifest, source, _) = folder(1);
    let (_, again, _) = folder(1);
    let first = Arc::new(Uploader::new(source, manifest.clone(), 1));
    let bucket = Arc::new(Bucket::default());
    first.run(&bucket);
    let link = Arc::new(Link::new(Duration::from_millis(200)));
    let mac = wake(&link, first);
    let fetch = StoreFirst::new(link.clone(), chain(&bucket));
    assert_eq!(fetch.refresh(), 6);
    sleep_mac(&link, &mac);
    // A new process on the Mac: a new epoch, its list from 0, the same files again.
    let second = Arc::new(Uploader::new(again, manifest, 2));
    let _mac = wake(&link, second.clone());
    second.run(&bucket);
    assert_eq!(fetch.refresh(), 0);
    assert_eq!(fetch.listed(), 6);
}
