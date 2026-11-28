//! `serde_json::from_reader` reads its source one byte per `read` call: on a bare `File` that is
//! one syscall per byte. The daemon's machine credential (624 bytes) was read that way about 11
//! times a second, 67,148 one-byte `read`s in 12 s on fs-agent-lane-29 (acpmux c6890b551). This
//! lint reads acpmux's own sources: every `serde_json::from_reader(` outside tests takes a
//! `BufReader`, or its line says why not with `// unbuffered-json: <why>`.

use std::io::Read;
use std::path::{Path, PathBuf};

const CALL: &str = "serde_json::from_reader(";
const ALLOW: &str = "// unbuffered-json:";

/// `path:line` of each unbuffered call in `files` (relative, `/`-separated), outside tests.
fn unbuffered(files: &[(String, String)]) -> Vec<String> {
    let mut out = Vec::new();
    for (path, text) in files {
        if path.ends_with("tests.rs") || path.contains("/tests/") {
            continue;
        }
        let lines: Vec<&str> = text.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            let Some(at) = line.find(CALL) else { continue };
            // The argument may start on the next line (rustfmt breaks long calls).
            let mut arg = line[at + CALL.len()..].trim_start().to_owned();
            if arg.is_empty() {
                arg = lines.get(i + 1).map(|next| next.trim_start().to_owned()).unwrap_or_default();
            }
            let buffered = arg.starts_with("std::io::BufReader") || arg.starts_with("BufReader");
            let allowed =
                line.contains(ALLOW) || i > 0 && lines[i - 1].trim_start().starts_with(ALLOW);
            if !buffered && !allowed {
                out.push(format!("{path}:{}", i + 1));
            }
        }
    }
    out
}

fn sources(root: &Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut dirs = vec![PathBuf::from(root)];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).expect("read src").flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "rs") {
                let rel = path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
                out.push((rel, std::fs::read_to_string(&path).unwrap_or_default()));
            }
        }
    }
    out
}

#[test]
fn every_json_file_read_is_buffered() {
    let tree = sources(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"));
    assert!(tree.len() > 100, "read acpmux's sources ({} files)", tree.len());
    let stray = unbuffered(&tree);
    assert!(
        stray.is_empty(),
        "serde_json::from_reader on an unbuffered source reads one byte per syscall: {stray:?}. \
         Wrap the source in std::io::BufReader::new (or parse std::fs::read's bytes with \
         from_slice); a source already in memory says so with `{ALLOW} <why>`."
    );
}

#[test]
fn a_planted_unbuffered_read_is_refused() {
    let file = |name: &str, text: &str| (name.to_owned(), text.to_owned());
    let tree = [
        file("bare.rs", "let v: Value = serde_json::from_reader(file)?;"),
        file(
            "split.rs",
            "let v: Value = serde_json::from_reader(\n    std::fs::File::open(p)?,\n)?;",
        ),
        file("ok.rs", "let v: Value = serde_json::from_reader(std::io::BufReader::new(file))?;"),
        file("ok_split.rs", "let v = serde_json::from_reader(\n    BufReader::new(f),\n)?;"),
        file(
            "why.rs",
            "// unbuffered-json: a slice, in memory\nserde_json::from_reader(&bytes[..])",
        ),
        file("x_tests.rs", "serde_json::from_reader(file)"),
    ];
    assert_eq!(unbuffered(&tree), ["bare.rs:1", "split.rs:1"]);
}

/// A reader that counts the `read` calls it gets (each is one syscall on a `File`).
struct Counting<'a> {
    bytes: &'a [u8],
    reads: usize,
}

impl Read for Counting<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.reads += 1;
        let n = buf.len().min(self.bytes.len());
        buf[..n].copy_from_slice(&self.bytes[..n]);
        self.bytes = &self.bytes[n..];
        Ok(n)
    }
}

/// What the lint guards, counted: a credential-sized record costs a read per byte bare, and at
/// most two (the bytes, then end of file) through a BufReader.
#[test]
fn a_buffered_parse_reads_a_record_in_two_calls_not_one_per_byte() {
    let record = serde_json::json!({
        "credential": format!("cmm_{}", "a".repeat(400)),
        "hub_origin": "https://hub.example.com",
        "machine_id": "vm_0123456789",
        "revoked": false,
    })
    .to_string();
    let mut bare = Counting { bytes: record.as_bytes(), reads: 0 };
    let _: serde_json::Value = serde_json::from_reader(&mut bare).unwrap(); // unbuffered-json: the counted case
    let mut counted = Counting { bytes: record.as_bytes(), reads: 0 };
    let _: serde_json::Value =
        serde_json::from_reader(std::io::BufReader::new(&mut counted)).unwrap();
    assert!(bare.reads >= record.len(), "bare: {} reads for {} bytes", bare.reads, record.len());
    assert!(counted.reads <= 2, "buffered: {} reads", counted.reads);
}
