//! RFD 0007, hard case 7: a file changed on the Mac after the manifest is read at its new version,
//! through a real link to a Mac serving a folder on this disk ([`crate::test_mac`]).

use std::path::Path;
use std::sync::Arc;

use super::*;
use crate::test_mac::{FolderMac, rewrite};

/// A Mac folder with `files`, its manifest taken now, and the machine's overlay of it.
fn projected(files: &[(&str, Vec<u8>)]) -> (tempfile::TempDir, tempfile::TempDir, Overlay) {
    let mac = tempfile::tempdir().unwrap();
    for (path, bytes) in files {
        let path = mac.path().join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
    let (manifest, source) = FolderMac::list(mac.path());
    let state = tempfile::tempdir().unwrap();
    let overlay = Overlay::open(manifest, state.path(), source.linked(), (1000, 1000)).unwrap();
    (mac, state, overlay)
}

fn ino(overlay: &Overlay, path: &str) -> u64 {
    let mut ino = overlay.root();
    for name in path.split('/') {
        ino = overlay.lookup(ino, name).unwrap().ino;
    }
    ino
}

fn read_all(overlay: &Overlay, ino: u64) -> Vec<u8> {
    let size = overlay.getattr(ino).unwrap().size;
    overlay.read(ino, 0, u32::try_from(size).unwrap()).unwrap()
}

fn pattern(len: u64, seed: u8) -> Vec<u8> {
    (0..len).map(|at| (at % 251) as u8 ^ seed).collect()
}

#[test]
fn a_file_rewritten_on_the_mac_before_its_first_read_reads_its_new_bytes_and_size() {
    let (mac, _state, overlay) =
        projected(&[("src/a.txt", b"alpha\n".to_vec()), ("src/b.txt", b"beta\n".to_vec())]);
    let a = ino(&overlay, "src/a.txt");
    assert_eq!(overlay.getattr(a).unwrap().size, 6, "the manifest's size until a fault");
    rewrite(&mac.path().join("src/a.txt"), b"alpha, changed on the mac after the start\n");

    // Before: the Mac answered CHANGED and this read failed with ESTALE.
    let bytes = overlay.read(a, 0, 4096).unwrap();
    assert_eq!(bytes, b"alpha, changed on the mac after the start\n");
    assert_eq!(overlay.getattr(a).unwrap().size, 42, "the new size from the fault on");
    assert_eq!(overlay.take_restated(), [a], "the mount is told to drop the kernel's copy");
    // The new version is the base: cached, served again without the Mac.
    let remote = overlay.stats().remote_reads;
    assert_eq!(read_all(&overlay, a), b"alpha, changed on the mac after the start\n");
    assert_eq!(overlay.stats().remote_reads, remote);
    // Its unchanged sibling came in the same batch, as it was.
    assert_eq!(read_all(&overlay, ino(&overlay, "src/b.txt")), b"beta\n");
    assert!(overlay.take_restated().is_empty());
}

#[test]
fn a_rewrite_after_a_cached_read_is_read_after_the_next_fault_invalidates_it() {
    let big = CHUNK * 2 + 100;
    let (mac, _state, overlay) = projected(&[("big.bin", pattern(big, 0))]);
    let file = ino(&overlay, "big.bin");
    // Chunk 0 read and cached at the manifest's version.
    assert_eq!(overlay.read(file, 0, 16).unwrap(), pattern(16, 0));
    rewrite(&mac.path().join("big.bin"), &pattern(big + 7, 0x5a));
    // Cached bytes are the session's base until a fault asks the Mac.
    assert_eq!(overlay.read(file, 0, 16).unwrap(), pattern(16, 0));
    // A fault (chunk 1, not cached) finds the change: the read is answered at the new version,
    // and every chunk of the old one is forgotten.
    let new = pattern(big + 7, 0x5a);
    let at = CHUNK + 3;
    assert_eq!(overlay.read(file, at, 64).unwrap(), new[at as usize..at as usize + 64]);
    assert_eq!(overlay.take_restated(), [file]);
    assert_eq!(overlay.getattr(file).unwrap().size, big + 7);
    // The next read of chunk 0 after the invalidation sees the new bytes, never the old chunk.
    assert_eq!(overlay.read(file, 0, 16).unwrap(), new[..16]);
    assert_eq!(read_all(&overlay, file), new);
}

#[test]
fn a_file_that_shrinks_reads_at_its_new_size() {
    let big = CHUNK + 4096;
    let (mac, _state, overlay) =
        projected(&[("small.txt", b"0123456789".to_vec()), ("big.bin", pattern(big, 1))]);
    let small = ino(&overlay, "small.txt");
    rewrite(&mac.path().join("small.txt"), b"0123");
    // Asked for past the new end: answered up to it, nothing more.
    assert_eq!(overlay.read(small, 2, 100).unwrap(), b"23");
    assert_eq!(overlay.read(small, 6, 100).unwrap(), b"");
    assert_eq!(overlay.getattr(small).unwrap().size, 4);

    // A big file that shrinks below a chunk is read whole from then on.
    let file = ino(&overlay, "big.bin");
    rewrite(&mac.path().join("big.bin"), b"short now");
    assert_eq!(overlay.read(file, CHUNK, 100).unwrap(), b"");
    assert_eq!(overlay.getattr(file).unwrap().size, 9);
    assert_eq!(overlay.read(file, 0, 100).unwrap(), b"short now");
}

#[test]
fn a_small_file_that_grows_past_a_chunk_is_read_in_chunks() {
    let (mac, _state, overlay) = projected(&[("grows.bin", b"tiny".to_vec())]);
    let file = ino(&overlay, "grows.bin");
    let grown = pattern(CHUNK * 2 + 1, 9);
    rewrite(&mac.path().join("grows.bin"), &grown);
    // Too big for a batch now: the Mac answers its stat only, and the read goes by chunk.
    assert_eq!(overlay.read(file, 0, 4).unwrap(), grown[..4]);
    assert_eq!(overlay.getattr(file).unwrap().size, CHUNK * 2 + 1);
    assert_eq!(overlay.read(file, CHUNK - 2, 4).unwrap(), grown[CHUNK as usize - 2..][..4]);
    assert_eq!(read_all(&overlay, file), grown);
}

#[test]
fn opening_a_file_not_on_the_machine_re_lists_it_before_the_opener_can_stat_it() {
    let (mac, _state, overlay) = projected(&[
        (".git/index", b"index version one".to_vec()),
        (".git/HEAD", b"ref: refs/heads/main\n".to_vec()),
        ("empty.py", Vec::new()),
    ]);
    let index = ino(&overlay, ".git/index");
    rewrite(&mac.path().join(".git/index"), b"index v2");
    assert!(overlay.open_lower(index), "re-listed at open");
    assert_eq!(overlay.getattr(index).unwrap().size, 8);
    // Now on the machine: a second open asks nothing.
    let remote = overlay.stats().remote_reads;
    assert!(!overlay.open_lower(index));
    assert_eq!(overlay.stats().remote_reads, remote);
    assert_eq!(read_all(&overlay, index), b"index v2");

    // An empty file has no bytes to cache: its open asks once whether it is still empty.
    let empty = ino(&overlay, "empty.py");
    assert!(!overlay.open_lower(empty));
    rewrite(&mac.path().join("empty.py"), b"print()\n");
    assert!(!overlay.open_lower(empty), "checked once, then the session's base");
    let (mac2, _state2, overlay2) = projected(&[("empty.py", Vec::new())]);
    let empty = ino(&overlay2, "empty.py");
    rewrite(&mac2.path().join("empty.py"), b"print()\n");
    assert!(overlay2.open_lower(empty));
    assert_eq!(read_all(&overlay2, empty), b"print()\n");
    drop(mac);
}

#[test]
fn a_write_to_a_file_changed_on_the_mac_copies_up_its_new_version() {
    let (mac, state, overlay) = projected(&[("notes.md", b"old notes\n".to_vec())]);
    let notes = ino(&overlay, "notes.md");
    rewrite(&mac.path().join("notes.md"), b"new notes from the mac\n");
    overlay.write(notes, 0, b"NEW").unwrap();
    let upper = fs::read(state.path().join("upper/notes.md")).unwrap();
    assert_eq!(upper, b"NEW notes from the mac\n");
}

#[test]
fn a_re_listed_stat_survives_a_reopen_with_its_cached_bytes() {
    let (mac, state, overlay) = projected(&[("a.txt", b"one".to_vec())]);
    let a = ino(&overlay, "a.txt");
    rewrite(&mac.path().join("a.txt"), b"version two");
    assert_eq!(overlay.read(a, 0, 64).unwrap(), b"version two");
    let manifest = Arc::clone(overlay.manifest.head());
    drop(overlay);
    // The daemon restarts with the same manifest; the Mac is away.
    let away = Arc::new(crate::link::Link::new(Duration::from_millis(50)));
    let reopened = Overlay::open(manifest, state.path(), away, (1000, 1000)).unwrap();
    let a = ino(&reopened, "a.txt");
    assert_eq!(reopened.getattr(a).unwrap().size, 11);
    assert_eq!(read_all(&reopened, a), b"version two");
    assert!(Path::new(&state.path().join("cache").join(RESTATED_FILE)).exists());
}
