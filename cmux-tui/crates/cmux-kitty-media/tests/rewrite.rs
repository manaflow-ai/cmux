//! Rewrite behavior: file, temporary-file and shared-memory Kitty commands
//! become chunked direct transmissions; everything else passes through.

use std::io::Write as _;
use std::path::Path;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_kitty_media::{CHUNK_BASE64_BYTES, KittyMediaRewriter, Limits, MediaRefusal};

fn rewrite_all(input: &[u8]) -> Vec<u8> {
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    rewriter.rewrite(input, &mut out);
    rewriter.finish(&mut out);
    out
}

fn rewrite_split(input: &[u8], split: usize) -> Vec<u8> {
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    let (head, tail) = input.split_at(split);
    rewriter.rewrite(head, &mut out);
    rewriter.rewrite(tail, &mut out);
    rewriter.finish(&mut out);
    out
}

fn file_command(control: &str, path: &Path) -> Vec<u8> {
    let encoded = STANDARD.encode(path.as_os_str().as_encoded_bytes());
    format!("\x1b_G{control};{encoded}\x1b\\").into_bytes()
}

/// The `ESC _ G ... ESC \` commands in `bytes`: (control, payload).
fn commands(bytes: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(bytes);
    let mut found = Vec::new();
    for piece in text.split("\x1b_G").skip(1) {
        let body = piece.split("\x1b\\").next().unwrap();
        let (control, payload) = body.split_once(';').unwrap_or((body, ""));
        found.push((control.to_string(), payload.to_string()));
    }
    found
}

/// Decoded image bytes of a chunked direct transmission.
fn reassemble(commands: &[(String, String)]) -> Vec<u8> {
    let joined: String = commands.iter().map(|(_, payload)| payload.as_str()).collect();
    STANDARD.decode(joined).unwrap()
}

fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|index| (index * 31 % 251) as u8).collect()
}

fn temp_file(dir: &Path, name: &str, data: &[u8]) -> std::path::PathBuf {
    let path = dir.join(name);
    std::fs::File::create(&path).unwrap().write_all(data).unwrap();
    path
}

#[test]
fn plain_output_passes_through_byte_identical() {
    let mut input = Vec::new();
    input.extend_from_slice(b"hello \x1b[31mred\x1b[0m\r\n");
    input.extend_from_slice(b"\x1b]0;title\x07\x1b_Xother apc\x1b\\");
    input.extend_from_slice(b"\x1b_Ga=T,f=24,s=1,v=1,i=3;AAAA\x1b\\");
    input.extend_from_slice(b"\x1b_Ga=d,d=A\x1b\\\x1b\x1b_\x1b_");
    input.extend_from_slice("ünïcödé \u{1F600}".as_bytes());
    for split in 0..=input.len() {
        assert_eq!(rewrite_split(&input, split), input, "split at {split}");
    }
}

#[test]
fn file_medium_becomes_chunked_direct_transmission() {
    let dir = tempfile::tempdir().unwrap();
    let data = pattern(10_000);
    let path = temp_file(dir.path(), "img.png", &data);
    let mut input = b"before ".to_vec();
    input.extend(file_command("a=T,f=100,i=7,t=f", &path));
    input.extend_from_slice(b" after");

    let out = rewrite_all(&input);
    assert!(out.starts_with(b"before \x1b_G"));
    assert!(out.ends_with(b"\x1b\\ after"));
    let found = commands(&out);
    assert_eq!(found.len(), 4, "10000 bytes need 4 chunks of 3072");
    assert_eq!(found[0].0, "a=T,f=100,i=7,m=1");
    assert_eq!(found[1].0, "m=1");
    assert_eq!(found[3].0, "m=0");
    for (_, payload) in &found {
        assert!(payload.len() <= CHUNK_BASE64_BYTES);
    }
    assert_eq!(reassemble(&found), data);
    assert!(path.exists(), "a t=f file is not deleted");
}

#[test]
fn every_read_boundary_gives_the_same_output() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "img.png", &pattern(5_000));
    let mut input = b"x\x1b[1m".to_vec();
    input.extend(file_command("a=T,f=100,t=f,q=1", &path));
    input.extend_from_slice(b"\x1b_Ga=T,t=d;QUJD\x1b\\y");
    let whole = rewrite_all(&input);
    assert_ne!(whole, input);
    for split in 0..=input.len() {
        assert_eq!(rewrite_split(&input, split), whole, "split at {split}");
    }
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    for byte in &input {
        rewriter.rewrite(std::slice::from_ref(byte), &mut out);
    }
    rewriter.finish(&mut out);
    assert_eq!(out, whole, "byte at a time");
}

#[test]
fn single_chunk_carries_no_more_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "small", &pattern(100));
    let out = rewrite_all(&file_command("a=t,f=100,i=1,t=f", &path));
    let found = commands(&out);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].0, "a=t,f=100,i=1");
    assert_eq!(reassemble(&found), pattern(100));
}

#[test]
fn size_and_offset_select_the_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let data = pattern(9_000);
    let path = temp_file(dir.path(), "big", &data);
    let out = rewrite_all(&file_command("a=T,f=32,s=10,v=10,t=f,S=400,O=4000", &path));
    let found = commands(&out);
    assert_eq!(found[0].0, "a=T,f=32,s=10,v=10");
    assert_eq!(reassemble(&found), &data[4000..4400]);

    // Asking past the end is the terminal's error, not a short image.
    let past = file_command("a=T,t=f,S=400,O=8800", &path);
    assert_eq!(rewrite_all(&past), past);
}

#[test]
fn quiet_key_rides_every_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "q", &pattern(7_000));
    let found = commands(&rewrite_all(&file_command("a=T,q=2,t=f", &path)));
    assert_eq!(found[0].0, "a=T,q=2,m=1");
    assert_eq!(found[1].0, "q=2,m=1");
    assert_eq!(found[2].0, "q=2,m=0");
}

#[test]
fn temporary_file_is_read_then_deleted() {
    let dir = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
    let data = pattern(3_000);
    let path = temp_file(dir.path(), "tty-graphics-protocol-1.png", &data);
    let found = commands(&rewrite_all(&file_command("a=T,f=100,t=t", &path)));
    assert_eq!(reassemble(&found), data);
    assert!(!path.exists(), "t=t deletes the file after reading");
}

#[test]
fn temporary_file_without_marker_or_outside_temp_passes_through() {
    let dir = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
    let unmarked = temp_file(dir.path(), "plain.png", &pattern(10));
    let input = file_command("a=T,t=t", &unmarked);
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    rewriter.rewrite(&input, &mut out);
    assert_eq!(out, input);
    assert_eq!(rewriter.last_refusal(), Some(&MediaRefusal::NotTemporary));
    assert!(unmarked.exists());

    let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let outside = temp_file(home.path(), "tty-graphics-protocol-x", &pattern(10));
    let input = file_command("a=T,t=t", &outside);
    assert_eq!(rewrite_all(&input), input);
    assert!(outside.exists());
}

#[test]
fn unsafe_or_missing_paths_pass_through_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let fifo = dir.path().join("fifo");
    let status = std::process::Command::new("mkfifo").arg(&fifo).status().unwrap();
    assert!(status.success());
    let link = dir.path().join("link");
    // /dev exists on Linux and macOS; macOS has no /proc, so its case is Linux-only.
    std::os::unix::fs::symlink("/dev/zero", &link).unwrap();
    let mut cases: Vec<(Vec<u8>, MediaRefusal)> = vec![
        (file_command("t=f", &link), MediaRefusal::Forbidden),
        (file_command("t=f", Path::new("/dev/zero")), MediaRefusal::Forbidden),
        (file_command("t=f", dir.path()), MediaRefusal::NotRegular),
        (file_command("t=f", &fifo), MediaRefusal::NotRegular),
        (file_command("t=f", Path::new("relative.png")), MediaRefusal::BadPath),
        (
            file_command("t=f", &dir.path().join("missing")),
            MediaRefusal::Io(std::io::ErrorKind::NotFound),
        ),
        (b"\x1b_Ga=T,t=f;!!!not base64\x1b\\".to_vec(), MediaRefusal::BadEncoding),
    ];
    if cfg!(target_os = "linux") {
        cases.push((file_command("t=f", Path::new("/proc/self/status")), MediaRefusal::Forbidden));
    }
    for (input, refusal) in cases {
        let mut rewriter = KittyMediaRewriter::new();
        let mut out = Vec::new();
        rewriter.rewrite(&input, &mut out);
        rewriter.finish(&mut out);
        assert_eq!(out, input, "{}", String::from_utf8_lossy(&input));
        assert_eq!(rewriter.last_refusal(), Some(&refusal));
        assert_eq!(rewriter.rewritten_commands(), 0);
    }
}

#[test]
fn file_over_the_cap_passes_through() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "huge", &pattern(2_000));
    let input = file_command("a=T,t=f", &path);
    let mut rewriter =
        KittyMediaRewriter::with_limits(Limits { max_file_bytes: 1_999, ..Limits::default() });
    let mut out = Vec::new();
    rewriter.rewrite(&input, &mut out);
    assert_eq!(out, input);
    assert_eq!(rewriter.last_refusal(), Some(&MediaRefusal::TooLarge));
}

#[test]
fn oversized_held_command_passes_through_without_reading() {
    let mut input = b"\x1b_Ga=T,t=f;".to_vec();
    input.extend(std::iter::repeat_n(b'A', 9_000));
    input.extend_from_slice(b"\x1b\\tail");
    assert_eq!(rewrite_all(&input), input);
}

#[test]
fn cancelled_or_aborted_command_is_never_read() {
    let dir = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
    let path = temp_file(dir.path(), "tty-graphics-protocol-c", &pattern(10));
    let command = file_command("a=T,t=t", &path);
    let unterminated = &command[..command.len() - 2];
    for ending in [&b"\x18"[..], b"\x1a", b"\x1b[0m", b"\x9b"] {
        let mut input = unterminated.to_vec();
        input.extend_from_slice(ending);
        input.extend_from_slice(b"rest");
        assert_eq!(rewrite_all(&input), input);
        assert!(path.exists(), "a cancelled t=t command must not delete the file");
    }
}

#[test]
fn only_the_command_is_held_back() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "img", &pattern(10));
    let command = file_command("a=T,t=f", &path);
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    rewriter.rewrite(b"text\x1b", &mut out);
    assert_eq!(out, b"text\x1b", "a trailing ESC is not held");
    assert!(!rewriter.is_holding());
    out.clear();
    rewriter.rewrite(&command[1..6], &mut out);
    assert_eq!(out, b"_G", "ESC _ G goes out before the control data");
    assert!(rewriter.is_holding());
    out.clear();
    rewriter.finish(&mut out);
    assert_eq!(out, &command[3..6], "finish releases the held bytes unchanged");
    assert!(!rewriter.is_holding());
}

#[test]
fn direct_upload_payload_is_never_held() {
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    rewriter.rewrite(b"\x1b_Ga=T,f=100,m=1;AAAA", &mut out);
    assert_eq!(out, b"\x1b_Ga=T,f=100,m=1;AAAA");
    assert!(!rewriter.is_holding());
}

#[test]
fn file_command_inside_open_direct_load_closes_it_first() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "img", &pattern(10));
    let mut input = b"\x1b_Ga=T,f=100,i=1,m=1;AAAA\x1b\\".to_vec();
    input.extend(file_command("a=T,f=100,i=2,t=f", &path));
    let found = commands(&rewrite_all(&input));
    assert_eq!(found.len(), 3);
    assert_eq!(found[1], ("m=0,q=2".to_string(), String::new()));
    assert_eq!(found[2].0, "a=T,f=100,i=2");

    // A load that finished needs no close.
    let mut input = b"\x1b_Ga=T,f=100,i=1,m=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\".to_vec();
    input.extend(file_command("a=T,f=100,i=2,t=f", &path));
    assert_eq!(commands(&rewrite_all(&input)).len(), 3);
}

#[cfg(target_os = "linux")]
#[test]
fn shared_memory_is_read_then_unlinked() {
    let name = format!("/cmux-kitty-media-test-{}", std::process::id());
    let data = pattern(5_000);
    std::fs::write(format!("/dev/shm{name}"), &data).unwrap();
    let encoded = STANDARD.encode(name.as_bytes());
    let input = format!("\x1b_Ga=T,f=32,s=50,v=25,t=s,S=5000;{encoded}\x1b\\").into_bytes();
    let found = commands(&rewrite_all(&input));
    assert_eq!(found[0].0, "a=T,f=32,s=50,v=25,m=1");
    assert_eq!(reassemble(&found), data);
    assert!(!Path::new(&format!("/dev/shm{name}")).exists());
}

fn rewrite_borrowed_split(input: &[u8], split: usize) -> Vec<u8> {
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    for part in [&input[..split], &input[split..]] {
        let mut scratch = Vec::new();
        out.extend_from_slice(rewriter.rewrite_borrowed(part, &mut scratch));
    }
    rewriter.finish(&mut out);
    out
}

#[test]
fn borrowed_rewrite_matches_and_copies_nothing_without_a_command() {
    let dir = tempfile::tempdir().unwrap();
    let path = temp_file(dir.path(), "img.png", &pattern(5_000));
    let mut input = b"x\x1b[1m\x1b_Xother\x1b\\".to_vec();
    input.extend(file_command("a=T,f=100,t=f", &path));
    input.extend_from_slice(b"\x1b_Ga=T,t=d;QUJD\x1b\\y\x1b_");
    let whole = rewrite_all(&input);
    for split in 0..=input.len() {
        assert_eq!(rewrite_borrowed_split(&input, split), whole, "split at {split}");
    }

    let plain = b"hello \x1b[31mred\x1b[0m\r\n";
    let mut rewriter = KittyMediaRewriter::new();
    let mut scratch = Vec::new();
    let out = rewriter.rewrite_borrowed(plain, &mut scratch);
    assert!(std::ptr::eq(out, &plain[..]), "plain output is not copied");
}
