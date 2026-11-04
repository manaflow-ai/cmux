//! Socket-level limits regressions. Sources and sinks retain one range,
//! never the entire payload; run the large cases explicitly on the fleet.

use std::io::{BufRead as _, BufReader, Read as _, Seek as _, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::{READ_BYTES, Remote};

fn pair() -> (Remote, UnixStream) {
    let (client, server) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    client.set_write_timeout(Some(Duration::from_secs(60))).unwrap();
    server.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    server.set_write_timeout(Some(Duration::from_secs(60))).unwrap();
    (
        Remote { reader: BufReader::new(client), next_id: 1, deflate: false, no_follow: false },
        server,
    )
}

struct HashSink {
    bytes: u64,
    hash: Sha256,
    largest_write: usize,
    first_byte: Option<Instant>,
}

impl Write for HashSink {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.first_byte.get_or_insert_with(Instant::now);
        self.bytes += bytes.len() as u64;
        self.largest_write = self.largest_write.max(bytes.len());
        self.hash.update(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Runs the same bounded fs-v1 range protocol used by working files,
/// objects and seed bundles. Every byte crosses the socket and is hashed
/// at both ends; no sparse-file length or skipped bytes stand in for I/O.
fn streamed_read(total: u64) {
    let (mut remote, server) = pair();
    let mut bytes: Vec<u8> = (0..READ_BYTES).map(|n| (n.wrapping_mul(131) >> 9) as u8).collect();
    let mut source = tempfile::tempfile().unwrap();
    for offset in (0..total).step_by(READ_BYTES as usize) {
        let count = (total - offset).min(READ_BYTES) as usize;
        source.write_all(&bytes[..count]).unwrap();
    }
    source.rewind().unwrap();
    let machine = std::thread::spawn(move || {
        let mut reader = BufReader::new(server.try_clone().unwrap());
        let mut writer = server;
        let mut hash = Sha256::new();
        let mut sent = 0u64;
        while sent < total {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], "fs.read");
            assert_eq!(request["offset"], sent);
            assert_eq!(request["max_bytes"], READ_BYTES);
            let count = (total - sent).min(READ_BYTES) as usize;
            source.read_exact(&mut bytes[..count]).unwrap();
            let part = &bytes[..count];
            hash.update(part);
            sent += count as u64;
            let encoded_part = base64::engine::general_purpose::STANDARD.encode(part);
            let answer = json!({"id": request["id"], "ok": true, "data": {
                "bytes_base64": encoded_part, "truncated": sent < total,
            }});
            writeln!(writer, "{answer}").unwrap();
        }
        hash.finalize()
    });
    let mut sink = HashSink { bytes: 0, hash: Sha256::new(), largest_write: 0, first_byte: None };
    let start = Instant::now();
    let read = remote.read_into("/large.bin", &mut sink).unwrap();
    let elapsed = start.elapsed();
    assert_eq!(read, Some(total));
    assert_eq!(sink.bytes, total);
    assert!(sink.largest_write <= READ_BYTES as usize);
    let first_byte = sink.first_byte.unwrap().duration_since(start);
    assert_eq!(sink.hash.finalize(), machine.join().unwrap());
    eprintln!(
        "sync_read bytes={total} elapsed_ms={:.3} first_byte_ms={:.3} throughput_mib_s={:.3} max_write_bytes={}",
        elapsed.as_secs_f64() * 1000.0,
        first_byte.as_secs_f64() * 1000.0,
        total as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64(),
        sink.largest_write,
    );
}

#[test]
fn sync_read_multimegabyte_payload_is_complete_and_bounded() {
    streamed_read(17 * 1024 * 1024 + 13);
}

#[test]
#[ignore = "explicit fleet throughput measurement"]
fn sync_read_256_mib_throughput() {
    streamed_read(256 * 1024 * 1024);
}

#[test]
#[ignore = "explicit fleet regression transfers over 4 GiB"]
fn sync_read_past_the_old_4_gib_cap() {
    streamed_read((4 << 30) + 13 * 1024 * 1024);
}

/// Both former directory limits are crossed: over 200,000 entries and
/// over 1,000 pages. Only one page is constructed by the machine at once.
#[test]
fn sync_listing_past_old_entry_and_page_caps() {
    const TOTAL: usize = 200_201;
    const PAGE: usize = 100;
    let (mut remote, server) = pair();
    let machine = std::thread::spawn(move || {
        let mut reader = BufReader::new(server.try_clone().unwrap());
        let mut writer = server;
        for begin in (0..TOTAL).step_by(PAGE) {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["cmd"], "fs.list");
            if begin != 0 {
                assert_eq!(request["listing"], "l");
                assert_eq!(request["cursor"], format!("c{begin}"));
            }
            let end = (begin + PAGE).min(TOTAL);
            let entries: Vec<Value> = (begin..end)
                .map(|n| json!({"name": format!("f{n:08}"), "kind": "file", "size": 1, "mtime": 1}))
                .collect();
            let answer = json!({"id": request["id"], "ok": true, "data": {
                "entries": entries, "listing": "l", "total": TOTAL,
                "cursor": (end < TOTAL).then(|| format!("c{end}")),
            }});
            writeln!(writer, "{answer}").unwrap();
        }
    });
    let entries = remote.list("/large-folder").unwrap().unwrap();
    assert_eq!(entries.len(), TOTAL);
    assert!(entries.contains_key("f00000000"));
    assert!(entries.contains_key(&format!("f{:08}", TOTAL - 1)));
    machine.join().unwrap();
}

#[test]
fn sync_listing_refuses_a_changed_snapshot_or_duplicate_name() {
    for changed_snapshot in [true, false] {
        let (mut remote, server) = pair();
        let machine = std::thread::spawn(move || {
            let mut reader = BufReader::new(server.try_clone().unwrap());
            let mut writer = server;
            for n in 0..2 {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                let listing = if changed_snapshot && n == 1 { "other" } else { "l" };
                let answer = json!({"id": request["id"], "ok": true, "data": {
                    "entries": [{"name": "same", "kind": "file"}],
                    "listing": listing, "cursor": format!("c{n}"),
                }});
                writeln!(writer, "{answer}").unwrap();
            }
        });
        let error = remote.list("/folder").unwrap_err().to_string();
        assert!(error.contains(if changed_snapshot {
            "changed the listing"
        } else {
            "repeated an entry"
        }));
        machine.join().unwrap();
    }
}
