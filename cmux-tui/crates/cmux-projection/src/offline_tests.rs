//! The Mac goes away (RFD 0007, "The Mac goes away"), end to end over a real [`Link`] under an
//! [`Overlay`]: files already faulted keep working, a read of an unfetched file waits the away
//! wait (5 s) and fails with `EHOSTDOWN`, a stream back inside the wait answers the read that was
//! waiting, and a stream back after a failure makes later reads work again.

use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::link::{AWAY_WAIT, Link, Source, answer_asks};
use crate::manifest::{Item, Kind, Manifest};
use crate::overlay::{CHUNK, Overlay};
use crate::wire::{self, Part};

/// The Mac's files, by entry.
pub(crate) struct Mac(pub HashMap<u32, Vec<u8>>);

impl Source for Mac {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let Some(bytes) = self.0.get(&entry) else { return Part::status(wire::REFUSED) };
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Part::ok(bytes[start..end].to_vec())
    }

    fn whole(&self, entry: u32) -> Part {
        self.0.get(&entry).map_or(Part::status(wire::REFUSED), |bytes| Part::ok(bytes.clone()))
    }
}

/// Attaches a new stream from `mac` to `link`; the Mac's end, to drop it.
pub(crate) fn attach(link: &Arc<Link>, mac: &Arc<dyn Source + Send + Sync>) -> UnixStream {
    let (machine, far) = UnixStream::pair().unwrap();
    let served = link.clone();
    let writer = machine.try_clone().unwrap();
    std::thread::spawn(move || served.serve(machine, writer));
    let answering = far.try_clone().unwrap();
    let source = mac.clone();
    std::thread::spawn(move || {
        let writer = answering.try_clone().unwrap();
        let _ = answer_asks(answering, writer, source.as_ref());
    });
    let start = Instant::now();
    while !link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    far
}

fn file(path: &str, size: usize) -> Item {
    Item {
        path: path.into(),
        kind: Kind::File,
        mode: 0o644,
        size: size as u64,
        mtime_ns: 1,
        link: None,
    }
}

fn ino(overlay: &Overlay, path: &str) -> u64 {
    path.split('/').fold(overlay.root(), |at, name| overlay.lookup(at, name).unwrap().ino)
}

#[test]
fn the_mac_away_keeps_faulted_files_fails_unfetched_ones_after_the_wait_and_a_reconnect_resumes() {
    let big = (0..(CHUNK as usize * 3)).map(|at| (at % 251) as u8).collect::<Vec<u8>>();
    let files: [(&str, Vec<u8>); 5] = [
        ("a/x.rs", b"fn x() {}".to_vec()),
        ("a/y.rs", b"fn y() {}".to_vec()),
        ("b/z.rs", b"fn z() {}".to_vec()),
        ("c/w.rs", b"fn w() {}".to_vec()),
        ("big.bin", big.clone()),
    ];
    let manifest = Arc::new(
        Manifest::build(1, files.iter().map(|(path, b)| file(path, b.len())).collect()).unwrap(),
    );
    let mac: Arc<dyn Source + Send + Sync> = Arc::new(Mac(files
        .iter()
        .map(|(path, bytes)| (manifest.resolve(path).unwrap(), bytes.clone()))
        .collect()));
    let link = Arc::new(Link::default());
    assert_eq!(link.away_wait(), AWAY_WAIT);
    assert_eq!(AWAY_WAIT, Duration::from_secs(5), "RFD 0007: a read waits 5 s for the Mac");
    let state = tempfile::tempdir().unwrap();
    let overlay = Overlay::open(manifest, state.path(), link.clone(), (1000, 1000)).unwrap();

    let stream = attach(&link, &mac);
    assert_eq!(overlay.read(ino(&overlay, "a/x.rs"), 0, 64).unwrap(), b"fn x() {}");
    assert_eq!(overlay.read(ino(&overlay, "big.bin"), 0, 16).unwrap(), &big[..16]);
    // The Mac goes to sleep.
    stream.shutdown(std::net::Shutdown::Both).unwrap();
    let start = Instant::now();
    while link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }

    // Faulted files keep working: the read itself and its folder's readahead.
    assert_eq!(overlay.read(ino(&overlay, "a/x.rs"), 0, 64).unwrap(), b"fn x() {}");
    assert_eq!(overlay.read(ino(&overlay, "a/y.rs"), 0, 64).unwrap(), b"fn y() {}");
    assert_eq!(overlay.read(ino(&overlay, "big.bin"), 8, 8).unwrap(), &big[8..16]);
    // Metadata never needed the Mac.
    assert_eq!(overlay.getattr(ino(&overlay, "b/z.rs")).unwrap().size, 9);

    // An unfetched file waits the away wait, then "Host is down".
    let start = Instant::now();
    assert_eq!(overlay.read(ino(&overlay, "b/z.rs"), 0, 64), Err(112));
    let waited = start.elapsed();
    assert!(waited >= AWAY_WAIT && waited < AWAY_WAIT + Duration::from_secs(2), "{waited:?}");

    // A reconnect inside the wait answers the read that was waiting.
    let waiting = {
        let overlay_ino = ino(&overlay, "c/w.rs");
        let overlay = Arc::new(overlay);
        let reading = overlay.clone();
        let started = Instant::now();
        let thread =
            std::thread::spawn(move || (reading.read(overlay_ino, 0, 64), started.elapsed()));
        std::thread::sleep(Duration::from_millis(500));
        let _back = attach(&link, &mac);
        let (read, took) = thread.join().unwrap();
        assert_eq!(read.unwrap(), b"fn w() {}");
        assert!(took < AWAY_WAIT, "answered on the new stream, not after the wait: {took:?}");
        // The reconnect resumes: what failed before and the rest of the big file read now.
        assert_eq!(overlay.read(ino(&overlay, "b/z.rs"), 0, 64).unwrap(), b"fn z() {}");
        let at = CHUNK + 5;
        assert_eq!(
            overlay.read(ino(&overlay, "big.bin"), at, 32).unwrap(),
            &big[at as usize..at as usize + 32]
        );
        _back
    };
    drop(waiting);
}
