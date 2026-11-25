//! How small can a phone's chat messages get on the link (ultra-connectivity P11)?
//!
//! `cargo run -p cmux-bundle --example msg_compress --release -- TRAIN_DIR... -- TEST_FILE...`
//!
//! Each NDJSON line of an acpmux session's `events/*.ndjson` is one message the phone reads. Today the
//! link sends a message under 16 KiB as text and deflates larger ones (cmux-mobile-host
//! `link_deflate.rs`). Compared, per message, in order, over the test files:
//! - `deflate-each`: every message deflated alone;
//! - `zstd-each`: every message zstd'd alone;
//! - `zstd-dict`: alone, with a dictionary trained on the TRAIN_DIR sessions (a dictionary shipped in the
//!   app must be trained on non-private samples; this run says what one could reach);
//! - `deflate-stream` / `zstd-stream`: one compressor for the whole channel, flushed after each message,
//!   so earlier messages are the dictionary (no shipped dictionary, nothing private leaves the pair).
//!
//! Prints one JSON line per method: total bytes, ratio to raw, and compress µs per message.

use flate2::Compression;
use flate2::write::DeflateEncoder;
use std::io::{BufRead, Write};
use std::time::Instant;

fn lines(path: &str, cap: usize) -> Vec<Vec<u8>> {
    let f = std::io::BufReader::new(std::fs::File::open(path).unwrap());
    f.split(b'\n').map_while(Result::ok).filter(|l| !l.is_empty()).take(cap).collect()
}

fn deflate(b: &[u8]) -> usize {
    let mut e = DeflateEncoder::new(Vec::new(), Compression::fast());
    e.write_all(b).unwrap();
    e.finish().unwrap().len()
}

fn report(name: &str, raw: usize, bytes: usize, n: usize, t: Instant) {
    println!(
        "{{\"method\":\"{name}\",\"bytes\":{bytes},\"ratio\":{:.4},\"us_per_msg\":{:.1}}}",
        bytes as f64 / raw as f64,
        t.elapsed().as_secs_f64() * 1e6 / n as f64
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let split = args.iter().position(|a| a == "--").expect("TRAIN_DIR... -- TEST_FILE...");
    let (train_dirs, test_files) = (&args[..split], &args[split + 1..]);

    let mut samples: Vec<Vec<u8>> = Vec::new();
    for dir in train_dirs {
        let mut files: Vec<_> =
            std::fs::read_dir(dir).unwrap().filter_map(|e| e.ok()).map(|e| e.path()).collect();
        files.sort();
        for f in files {
            samples.extend(lines(f.to_str().unwrap(), 20_000));
        }
    }
    let dict = zstd::dict::from_samples(&samples, 110 << 10).unwrap();
    eprintln!("dictionary {} bytes from {} samples", dict.len(), samples.len());

    let mut msgs: Vec<Vec<u8>> = Vec::new();
    for f in test_files {
        msgs.extend(lines(f, 50_000));
    }
    let raw: usize = msgs.iter().map(Vec::len).sum();
    let n = msgs.len();
    let small = msgs.iter().filter(|m| m.len() < 16 << 10).count();
    eprintln!("{n} messages, {raw} bytes, {small} under 16 KiB (sent as text today)");
    report("raw", raw, raw, n, Instant::now());

    let t = Instant::now();
    let today: usize = msgs
        .iter()
        .map(|m| if m.len() < 16 << 10 { m.len() } else { deflate(m).min(m.len()) + 9 })
        .sum();
    report("today (text <16KiB, deflate above)", raw, today, n, t);

    let t = Instant::now();
    let b: usize = msgs.iter().map(|m| deflate(m)).sum();
    report("deflate-each", raw, b, n, t);

    let t = Instant::now();
    let b: usize = msgs.iter().map(|m| zstd::bulk::compress(m, 3).unwrap().len()).sum();
    report("zstd-each", raw, b, n, t);

    let t = Instant::now();
    let mut c = zstd::bulk::Compressor::with_dictionary(3, &dict).unwrap();
    let b: usize = msgs.iter().map(|m| c.compress(m).unwrap().len()).sum();
    report("zstd-dict", raw, b, n, t);

    let t = Instant::now();
    let mut e = DeflateEncoder::new(Vec::new(), Compression::fast());
    let mut b = 0;
    for m in &msgs {
        e.write_all(m).unwrap();
        e.flush().unwrap();
        b += e.get_ref().len();
        e.get_mut().clear();
    }
    report("deflate-stream (context kept, sync flush)", raw, b, n, t);

    let t = Instant::now();
    let mut z = zstd::stream::write::Encoder::new(Vec::new(), 3).unwrap();
    z.window_log(std::env::var("WLOG").ok().and_then(|v| v.parse().ok()).unwrap_or(23)).unwrap();
    let mut b = 0;
    for m in &msgs {
        z.write_all(m).unwrap();
        z.flush().unwrap();
        b += z.get_ref().len();
        z.get_mut().clear();
    }
    report("zstd-stream (context kept, flush)", raw, b, n, t);

    let t = Instant::now();
    let mut z = zstd::stream::write::Encoder::with_dictionary(Vec::new(), 3, &dict).unwrap();
    z.window_log(std::env::var("WLOG").ok().and_then(|v| v.parse().ok()).unwrap_or(23)).unwrap();
    let mut b = 0;
    for m in &msgs {
        z.write_all(m).unwrap();
        z.flush().unwrap();
        b += z.get_ref().len();
        z.get_mut().clear();
    }
    report("zstd-stream + dict", raw, b, n, t);
}
