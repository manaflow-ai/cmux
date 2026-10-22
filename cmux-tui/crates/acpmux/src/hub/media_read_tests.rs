//! Unit tests of `media_read.rs`: the sniff, the path checks on the opened descriptor, the handle
//! table, and the race tests (a file or a folder swapped between the checks and the reads).

use super::*;
use std::path::PathBuf;

fn reason(e: &RpcError) -> String {
    e.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default().to_owned()
}

fn png(fill: u8, n: usize) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    bytes.resize(n, fill);
    bytes
}

fn mp4(fill: u8, n: usize) -> Vec<u8> {
    let mut bytes = b"\0\0\0\x18ftypisom\0\0\x02\0isomiso2".to_vec();
    bytes.resize(n, fill);
    bytes
}

/// A folder of its own: `root/out/clip.mp4` inside the session's root, and `outside/` with a
/// stand-in key that is a valid PNG, so a refusal never comes from the sniff.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("acpmux-media-{tag}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(dir.join("root/out")).unwrap();
        std::fs::create_dir_all(dir.join("outside")).unwrap();
        std::fs::write(dir.join("root/out/clip.mp4"), mp4(1, 64)).unwrap();
        std::fs::write(dir.join("outside/id_ed25519"), png(9, 64)).unwrap();
        std::fs::write(dir.join("outside/clip.mp4"), mp4(9, 64)).unwrap();
        Scratch(dir)
    }

    fn root(&self) -> PathBuf {
        self.0.join("root")
    }

    fn at(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }

    fn open(&self, path: &str, at: &mut dyn FnMut(Step)) -> Result<Opened, RpcError> {
        open_in(&[self.root()], path, None, at)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn read_all(opened: &Opened) -> Result<Vec<u8>, RpcError> {
    read_range(&opened.file, &opened.identity, 0, opened.identity.size)
}

fn never_outside(result: Result<Vec<u8>, RpcError>, original: &[u8]) {
    if let Ok(bytes) = result {
        assert_eq!(bytes, original, "bytes from outside the root came back");
    }
}

#[test]
fn the_type_comes_from_the_bytes() {
    let mut webp = b"RIFF\0\0\0\0WEBPVP8 ".to_vec();
    webp.resize(32, 0);
    let mut webm = vec![0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86, 0x81, 0x01];
    webm.extend_from_slice(&[0x42, 0x82, 0x84, b'w', b'e', b'b', b'm']);
    let brand = |b: &[u8; 4]| [&b"\0\0\0\x14ftyp"[..], b, b"\0\0\0\0"].concat();
    for (bytes, mime) in [
        (png(0, 32), "image/png"),
        (vec![0xff, 0xd8, 0xff, 0xe0, 0, 0x10], "image/jpeg"),
        (b"GIF89a\x01\0\x01\0".to_vec(), "image/gif"),
        (webp, "image/webp"),
        (brand(b"isom"), "video/mp4"),
        (brand(b"mp42"), "video/mp4"),
        (brand(b"qt  "), "video/quicktime"),
        (brand(b"M4V "), "video/x-m4v"),
        (webm, "video/webm"),
    ] {
        assert_eq!(sniff(&bytes), Some(mime), "{mime}");
    }
    let mut matroska = vec![0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x82, 0x88];
    matroska.extend_from_slice(b"matroska");
    for (bytes, what) in [
        (b"<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>".to_vec(), "svg"),
        (b"%PDF-1.7\n".to_vec(), "pdf"),
        (b"<html><body>".to_vec(), "html"),
        (brand(b"heic"), "heic"),
        (brand(b"avif"), "avif"),
        (vec![0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1], "mach-o"),
        (matroska, "matroska"),
        (b"\x89PN".to_vec(), "truncated png"),
        (Vec::new(), "empty"),
    ] {
        assert_eq!(sniff(&bytes), None, "{what}");
    }
}

#[test]
fn a_file_in_the_root_is_read_by_ranges_and_a_change_refuses_the_next() {
    let s = Scratch::new("ranges");
    let original = mp4(1, 64);
    let opened = s.open("out/clip.mp4", &mut |_| {}).unwrap();
    assert_eq!((opened.mime, opened.identity.size), ("video/mp4", 64));
    let head = read_range(&opened.file, &opened.identity, 0, 40).unwrap();
    let tail = read_range(&opened.file, &opened.identity, 40, 40).unwrap();
    assert_eq!([head, tail].concat(), original);
    // The same file by its absolute path.
    let absolute = s.root().join("out/clip.mp4");
    let again = open_in(&[s.root()], &absolute.to_string_lossy(), None, &mut |_| {}).unwrap();
    assert_eq!(read_all(&again).unwrap(), original);
    // A range past the end, of no bytes, or over the cap is refused.
    for (offset, length) in [(64, 1), (0, 0), (0, MAX_RANGE as u64 + 1)] {
        let e = read_range(&opened.file, &opened.identity, offset, length).unwrap_err();
        assert_eq!(reason(&e), "media.range", "{offset}+{length}");
    }
    // The file grows in place: the next range is refused.
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new().append(true).open(&absolute).unwrap();
    file.write_all(b"more").unwrap();
    let e = read_range(&opened.file, &opened.identity, 0, 8).unwrap_err();
    assert_eq!(reason(&e), "media.changed");
}

#[test]
fn a_path_outside_the_roots_on_the_deny_list_or_of_another_type_is_refused() {
    let s = Scratch::new("refusals");
    let root = s.root();
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::write(root.join(".git/shot.png"), png(0, 32)).unwrap();
    std::fs::create_dir_all(root.join("Library")).unwrap();
    std::fs::write(root.join("Library/shot.png"), png(0, 32)).unwrap();
    std::fs::write(root.join("notes.png"), b"just text, named as an image").unwrap();
    std::fs::write(root.join("logo.svg"), b"<svg xmlns='http://www.w3.org/2000/svg'/>").unwrap();
    std::fs::write(root.join("id.pem"), png(0, 32)).unwrap();
    let big = std::fs::File::create(root.join("big.png")).unwrap();
    std::io::Write::write_all(&mut &big, &png(0, 32)).unwrap();
    big.set_len(MAX_IMAGE_BYTES + 1).unwrap();
    std::fs::write(root.join("linked.png"), png(0, 32)).unwrap();
    std::fs::hard_link(root.join("linked.png"), s.at("outside/linked.png")).unwrap();
    let outside = s.at("outside/id_ed25519");
    for (path, why) in [
        ("../outside/id_ed25519", "media.path"),
        ("out/../../outside/id_ed25519", "media.path"),
        ("", "media.path"),
        ("a\0b", "media.path"),
        (outside.to_str().unwrap(), "media.outside"),
        ("/etc/hosts", "media.outside"),
        (".git/shot.png", "media.denied"),
        ("id.pem", "media.denied"),
        ("out", "media.notFile"),
        ("missing.png", "media.unreadable"),
        ("notes.png", "media.type"),
        ("logo.svg", "media.type"),
        ("big.png", "media.tooLarge"),
        ("linked.png", "media.linked"),
    ] {
        let e = s.open(path, &mut |_| {}).err().unwrap_or_else(|| panic!("{path} was read"));
        assert_eq!(reason(&e), why, "{path:?}: {}", e.message);
    }
    // `Library` under the home folder is denied, wherever the chat's folder is.
    let e = open_in(&[root.clone()], "Library/shot.png", Some(&root), &mut |_| {}).err().unwrap();
    assert_eq!(reason(&e), "media.denied");
    assert!(open_in(&[root.clone()], "Library/shot.png", None, &mut |_| {}).is_ok());
}

/// Race: `out/clip.mp4` becomes a symlink to `~/.ssh/id_ed25519` (a stand-in outside the root):
/// before the open, between the folder's open and the file's, and after the open.
#[test]
fn a_file_swapped_for_a_symlink_is_never_followed() {
    let s = Scratch::new("symlink");
    let (clip, key) = (s.root().join("out/clip.mp4"), s.at("outside/id_ed25519"));
    let swap = || {
        let _ = std::fs::remove_file(&clip);
        std::os::unix::fs::symlink(&key, &clip).unwrap();
    };
    let restore = || {
        let _ = std::fs::remove_file(&clip);
        std::fs::write(&clip, mp4(1, 64)).unwrap();
    };
    swap();
    let e = s.open("out/clip.mp4", &mut |_| {}).err().unwrap();
    assert_eq!(reason(&e), "media.unreadable", "{}", e.message);
    restore();
    let e = s
        .open("out/clip.mp4", &mut |step| {
            if step == Step::Dir(0) {
                swap();
            }
        })
        .err()
        .unwrap();
    assert_eq!(reason(&e), "media.unreadable", "{}", e.message);
    restore();
    let opened = s
        .open("out/clip.mp4", &mut |step| {
            if step == Step::File {
                swap();
            }
        })
        .unwrap();
    never_outside(read_all(&opened), &mp4(1, 64));
    assert_eq!(read_all(&opened).unwrap(), mp4(1, 64));
}

/// Race: the folder `out` becomes a symlink out of the root, after the root is opened and after
/// `out` itself is opened.
#[test]
fn a_parent_swapped_for_a_symlink_out_of_the_root_is_refused() {
    let s = Scratch::new("parent");
    let (out, moved) = (s.root().join("out"), s.root().join("out.old"));
    let outside = s.at("outside");
    let swap = || {
        std::fs::rename(&out, &moved).unwrap();
        std::os::unix::fs::symlink(&outside, &out).unwrap();
    };
    let e = s
        .open("out/clip.mp4", &mut |step| {
            if step == Step::Root {
                swap();
            }
        })
        .err()
        .unwrap();
    assert!(matches!(reason(&e).as_str(), "media.unreadable" | "media.outside"), "{}", e.message);
    std::fs::remove_file(&out).unwrap();
    std::fs::rename(&moved, &out).unwrap();
    // Once `out` is open the walk goes on in it, wherever it moved inside the root.
    let opened = s.open("out/clip.mp4", &mut |step| {
        if step == Step::Dir(0) {
            swap();
        }
    });
    never_outside(opened.and_then(|o| read_all(&o)), &mp4(1, 64));
}

/// Race: the file is replaced by another inode between the open and the first range, and between
/// two ranges: the reads keep the opened file's bytes, or are refused.
#[test]
fn a_file_replaced_by_another_inode_gives_the_original_bytes_or_is_refused() {
    let s = Scratch::new("inode");
    let clip = s.root().join("out/clip.mp4");
    let replace = |fill| {
        let next = s.root().join("out/next.mp4");
        std::fs::write(&next, mp4(fill, 64)).unwrap();
        std::fs::rename(&next, &clip).unwrap();
    };
    let opened = s.open("out/clip.mp4", &mut |_| {}).unwrap();
    replace(7);
    never_outside(read_all(&opened), &mp4(1, 64));
    let opened = s.open("out/clip.mp4", &mut |_| {}).unwrap();
    let head = read_range(&opened.file, &opened.identity, 0, 32).unwrap();
    assert_eq!(head, mp4(7, 64)[..32]);
    replace(8);
    let tail = read_range(&opened.file, &opened.identity, 32, 32);
    never_outside(tail, &mp4(7, 64)[32..]);
}

#[test]
fn handles_are_capped_scoped_to_their_chat_and_expire() {
    let s = Scratch::new("handles");
    let handles = Handles::default();
    let now = Instant::now();
    let open = || s.open("out/clip.mp4", &mut |_| {}).unwrap();
    let first = handles.insert("chat", open(), now).unwrap();
    for _ in 1..MAX_HANDLES {
        handles.insert("chat", open(), now).unwrap();
    }
    let e = handles.insert("chat", open(), now).unwrap_err();
    assert_eq!(reason(&e), "media.handles");
    assert!(handles.get("chat", &first, now).is_ok());
    let e = handles.get("other-chat", &first, now).unwrap_err();
    assert_eq!(reason(&e), "media.handle");
    let e = handles.get("chat", "not-a-handle", now).unwrap_err();
    assert_eq!(reason(&e), "media.handle");
    // Two minutes idle: every handle is gone, and the table takes new ones.
    let later = now + IDLE;
    assert_eq!(reason(&handles.get("chat", &first, later).unwrap_err()), "media.handle");
    let fresh = handles.insert("chat", open(), later).unwrap();
    handles.close(&fresh);
    assert_eq!(reason(&handles.get("chat", &fresh, later).unwrap_err()), "media.handle");
    handles.insert("chat", open(), later).unwrap();
    handles.close_all();
    for _ in 0..MAX_HANDLES {
        handles.insert("chat", open(), later).unwrap();
    }
}

#[test]
fn a_range_reply_stays_under_the_rpc_cap_and_an_older_peers_frame() {
    let base64 = MAX_RANGE.div_ceil(3) * 4;
    assert_eq!(base64, 8 << 20);
    assert!(base64 + 4096 < crate::rpc::MAX_MESSAGE_BYTES);
    assert!(base64 + 4096 < 16 << 20);
}

#[test]
fn the_identity_names_the_file_not_the_spelling() {
    let s = Scratch::new("identity");
    let a = s.open("out/clip.mp4", &mut |_| {}).unwrap();
    let path = s.root().join("out/clip.mp4");
    let b = open_in(&[s.root()], &path.to_string_lossy(), None, &mut |_| {}).unwrap();
    assert_eq!(a.identity.token(), b.identity.token());
    assert_eq!(a.identity.token().len(), 32);
    std::fs::write(&path, mp4(2, 65)).unwrap();
    let c = s.open("out/clip.mp4", &mut |_| {}).unwrap();
    assert_ne!(a.identity.token(), c.identity.token());
}
