//! P2: a second machine in the region fetches a toolchain from the first, verified; nothing
//! private, nothing cross-region, nothing past the upload cap leaves a seeder.

use cmux_cas::assemble::assemble;
use cmux_cas::public::{Algo, Checksum, Entry, Kind, Public, Source};
use cmux_cas::seed::{Peer, Seeder, UploadCap, Want, fetch};
use cmux_cas::{Id, Manifest, Result};
use sha2::Digest as _;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const T: Duration = Duration::from_secs(5);

fn noise(seed: u64, n: usize) -> Vec<u8> {
    let mut x = seed;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

fn sha256(b: &[u8]) -> Checksum {
    let h = sha2::Sha256::digest(b);
    Checksum::new(Algo::Sha256, &h.iter().map(|b| format!("{b:02x}")).collect::<String>()).unwrap()
}

/// A toolchain tarball (`rust-1.0.0/bin/rustc`, `rust-1.0.0/lib/libstd.so`), published by its
/// sha256 into `public`.
fn publish_toolchain(public: &Public) -> (Entry, Vec<(String, Vec<u8>)>) {
    let files = vec![
        ("bin/rustc".to_string(), noise(11, 3 << 20)),
        ("lib/libstd.so".to_string(), noise(12, 2 << 20)),
    ];
    let mut tar =
        tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
    for (p, b) in &files {
        let mut h = tar::Header::new_gnu();
        h.set_size(b.len() as u64);
        h.set_mode(0o755);
        h.set_cksum();
        tar.append_data(&mut h, format!("rust-1.0.0/{p}"), b.as_slice()).unwrap();
    }
    let archive = tar.into_inner().unwrap().finish().unwrap();
    let source = Source {
        kind: Kind::Toolchain,
        name: "rust".into(),
        version: "1.0.0".into(),
        checksum: sha256(&archive),
    };
    public.publish_archive(&source, &archive, 1).unwrap();
    let entry = public.entries().unwrap().pop().unwrap();
    (entry, files)
}

/// Serves `seeder` on a loopback port until the returned guard drops.
struct Serving {
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
    seeder: Arc<Seeder>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Serving {
    fn start(seeder: Seeder) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let seeder = Arc::new(seeder);
        let (s, st) = (seeder.clone(), stop.clone());
        let thread = std::thread::spawn(move || s.serve(listener, &st));
        Self { addr, stop, seeder, thread: Some(thread) }
    }

    fn peer(&self, region: &str) -> Peer {
        Peer { addr: self.addr, region: region.into() }
    }
}

impl Drop for Serving {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = TcpStream::connect(self.addr);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn no_floor(_: Want, _: &Id) -> Result<Vec<u8>> {
    panic!("the floor was asked")
}

#[test]
fn a_second_machine_in_the_region_fetches_a_toolchain_from_the_first_verified() {
    let (a_dir, b_dir, c_dir, out) = (
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
        tempfile::tempdir().unwrap(),
    );
    let a = Public::new(a_dir.path());
    let (entry, files) = publish_toolchain(&a);
    let seeding = Serving::start(Seeder::new(a, "eu-1", UploadCap::new(1 << 30, 1 << 30)).unwrap());

    let b = Public::new(b_dir.path());
    let s = fetch(&b, &entry, "eu-1", &[seeding.peer("eu-1")], T, &mut no_floor).unwrap();
    assert!(s.peer_items > 1 && s.peer_bytes > 0, "{s:?}");
    assert_eq!((s.floor_items, s.floor_bytes, s.held), (0, 0, 0), "{s:?}");
    assert!(s.dropped.is_empty(), "{s:?}");
    assert_eq!(seeding.seeder.stats().sent_bytes, s.peer_bytes);

    // Verified: the tree rebuilds bit-exact (assemble checks every file's hash too).
    let m =
        Manifest::from_bytes(&b.manifest_bytes(&entry.manifest).unwrap(), &entry.manifest).unwrap();
    assemble(b.store(), &m, out.path()).unwrap();
    for (p, bytes) in &files {
        assert_eq!(&std::fs::read(out.path().join(p)).unwrap(), bytes, "{p}");
    }

    // Adopted: B now seeds it, so a third machine fetches from B with A gone.
    assert_eq!(b.entries().unwrap(), vec![entry.clone()]);
    drop(seeding);
    let from_b = Serving::start(Seeder::new(b, "eu-1", UploadCap::new(1 << 30, 1 << 30)).unwrap());
    let c = Public::new(c_dir.path());
    let s = fetch(&c, &entry, "eu-1", &[from_b.peer("eu-1")], T, &mut no_floor).unwrap();
    assert!(s.peer_bytes > 0 && s.floor_items == 0, "{s:?}");
}

#[test]
fn another_region_is_never_asked_and_never_answered() {
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = Public::new(a_dir.path());
    let (entry, _) = publish_toolchain(&a);
    let origin = Public::new(a_dir.path());
    let seeding = Serving::start(Seeder::new(a, "us-1", UploadCap::new(1 << 30, 1 << 30)).unwrap());

    // The asker skips a peer that says it is in another region and goes to the floor.
    let b = Public::new(b_dir.path());
    let mut floor = |w: Want, id: &Id| match w {
        Want::Manifest => origin.manifest_bytes(id),
        Want::Chunk => origin.store().file(id),
    };
    let s = fetch(&b, &entry, "eu-1", &[seeding.peer("us-1")], T, &mut floor).unwrap();
    assert_eq!((s.skipped_region, s.peer_items), (1, 0), "{s:?}");
    assert!(s.floor_items > 1);

    // A peer listed under the wrong region: the seeder itself answers every id NOPE.
    let c_dir = tempfile::tempdir().unwrap();
    let c = Public::new(c_dir.path());
    let s = fetch(&c, &entry, "eu-1", &[seeding.peer("eu-1")], T, &mut floor).unwrap();
    assert_eq!(s.peer_items, 0, "{s:?}");
    let st = seeding.seeder.stats();
    assert_eq!(st.sent_items, 0);
    assert!(st.refused_region > 0, "{st:?}");
}

#[test]
fn a_chunk_no_published_manifest_names_is_never_sent() {
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = Public::new(a_dir.path());
    publish_toolchain(&a);
    // A chunk sits in the seeder's store but no published entry names it.
    let private = noise(99, 40_000);
    let id = Id::of(&private);
    a.store().put(&id, &private).unwrap();
    // A forged entry naming a manifest that holds it: the seeder still refuses the chunk,
    // because its own index does not name it.
    let m = Manifest::build(
        &[("secret".to_string(), (private, false))].into_iter().collect(),
        |_, _| Ok(()),
    )
    .unwrap();
    let mbytes = m.to_bytes().unwrap();
    let forged = Entry {
        source: Source {
            kind: Kind::Crate,
            name: "x".into(),
            version: "0".into(),
            checksum: sha256(b"x"),
        },
        manifest: Id::of(&mbytes),
    };
    let seeding = Serving::start(Seeder::new(a, "eu-1", UploadCap::new(1 << 30, 1 << 30)).unwrap());
    let b = Public::new(b_dir.path());
    let mut floor = |w: Want, _: &Id| -> Result<Vec<u8>> {
        match w {
            Want::Manifest => Ok(mbytes.clone()),
            Want::Chunk => Err("not on the floor either".into()),
        }
    };
    let err = fetch(&b, &forged, "eu-1", &[seeding.peer("eu-1")], T, &mut floor).unwrap_err();
    assert!(err.to_string().contains("not on the floor"), "{err}");
    assert!(!b.store().has(&id));
    let st = seeding.seeder.stats();
    assert_eq!(st.sent_items, 0, "{st:?}");
    assert_eq!(st.refused_not_public, 2, "manifest and chunk: {st:?}");
}

#[test]
fn a_lying_peer_is_dropped_and_the_next_peer_finishes() {
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = Public::new(a_dir.path());
    let (entry, _) = publish_toolchain(&a);
    let honest = Serving::start(Seeder::new(a, "eu-1", UploadCap::new(1 << 30, 1 << 30)).unwrap());

    // A liar echoes each id and sends garbage for it.
    let liar = TcpListener::bind("127.0.0.1:0").unwrap();
    let liar_addr = liar.local_addr().unwrap();
    let t = std::thread::spawn(move || {
        for conn in liar.incoming().take(2) {
            let mut conn = conn.unwrap();
            let mut head = [0u8; 6 + 1 + 4 + 1 + 4];
            conn.read_exact(&mut head).unwrap();
            let n = u32::from_le_bytes(head[12..16].try_into().unwrap());
            let mut ids = vec![0u8; 32 * n as usize];
            conn.read_exact(&mut ids).unwrap();
            for id in ids.chunks(32) {
                let _ = conn.write_all(id);
                let _ = conn.write_all(&8u32.to_le_bytes());
                let _ = conn.write_all(b"garbage!");
            }
        }
    });
    let peers = [Peer { addr: liar_addr, region: "eu-1".into() }, honest.peer("eu-1")];
    let b = Public::new(b_dir.path());
    let s = fetch(&b, &entry, "eu-1", &peers, T, &mut no_floor).unwrap();
    assert_eq!(s.dropped.len(), 1, "{s:?}");
    assert_eq!(s.dropped[0].0, liar_addr);
    assert_eq!(s.floor_items, 0, "{s:?}");
    assert_eq!(b.entries().unwrap(), vec![entry]);
    drop(t);
}

#[test]
fn the_upload_cap_refuses_past_its_burst() {
    let cap = UploadCap::new(0, 100);
    assert!(cap.take(60));
    assert!(!cap.take(60), "past the burst with no refill");
    assert!(cap.take(40));

    // A seeder whose burst holds the manifest but not every chunk: the rest comes from the floor.
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a = Public::new(a_dir.path());
    let (entry, _) = publish_toolchain(&a);
    let origin = Public::new(a_dir.path());
    let seeding = Serving::start(Seeder::new(a, "eu-1", UploadCap::new(0, 200 << 10)).unwrap());
    let b = Public::new(b_dir.path());
    let mut floor = |w: Want, id: &Id| match w {
        Want::Manifest => origin.manifest_bytes(id),
        Want::Chunk => origin.store().file(id),
    };
    let s = fetch(&b, &entry, "eu-1", &[seeding.peer("eu-1")], T, &mut floor).unwrap();
    assert!(s.peer_bytes <= 200 << 10, "{s:?}");
    assert!(s.floor_items > 0, "{s:?}");
    assert!(seeding.seeder.stats().refused_cap > 0);
    assert_eq!(b.entries().unwrap(), vec![entry]);
}
