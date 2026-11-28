use super::*;
use std::io::{Cursor, Read, Seek, SeekFrom};

/// A reader that counts the bytes read from it.
struct Counted {
    inner: Cursor<Vec<u8>>,
    read: usize,
}

impl Read for Counted {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.read += n;
        Ok(n)
    }
}

impl Seek for Counted {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        self.inner.seek(pos)
    }
}

/// A segment of `n` records, line `i` padded to `pad(i)` bytes: its bytes and each line's start.
fn segment(n: u64, pad: impl Fn(u64) -> usize) -> (Vec<u8>, Vec<u64>) {
    let (mut bytes, mut starts) = (Vec::new(), Vec::new());
    for seq in 1..=n {
        starts.push(bytes.len() as u64);
        let line = format!("{{\"seq\":{seq},\"at\":1,\"text\":\"{}\"}}\n", "x".repeat(pad(seq)));
        bytes.extend_from_slice(line.as_bytes());
    }
    (bytes, starts)
}

/// Every record before `before` ends at or before the offset, and the offset is a line start
/// (or the end): the read back from it misses none and starts on a line.
fn check(bytes: &[u8], starts: &[u64], before: u64) -> usize {
    let mut file = Counted { inner: Cursor::new(bytes.to_vec()), read: 0 };
    let at = offset_of_seq(&mut file, before).unwrap();
    let len = bytes.len() as u64;
    assert!(at == len || starts.contains(&at), "before {before}: {at} is no line start");
    let first_at_or_past = starts.get(before.saturating_sub(1) as usize).copied().unwrap_or(len);
    assert!(at >= first_at_or_past, "before {before}: {at} cuts a record before it");
    assert!(at - first_at_or_past <= 64 * 1024, "before {before}: {at} is past the window");
    file.read
}

#[test]
fn offset_of_seq_is_exact_with_short_long_and_mixed_lines() {
    let pads: [(&str, Box<dyn Fn(u64) -> usize>); 3] = [
        ("short", Box::new(|_| 300_usize)),
        ("over the head", Box::new(|_| 12_usize * 1024)),
        (
            "mixed",
            Box::new(
                |seq| if seq % 7 == 0 { 20_usize * 1024 } else { 1500 + (seq as usize % 900) },
            ),
        ),
    ];
    for (name, pad) in pads {
        let (bytes, starts) = segment(4000, pad);
        let n = starts.len() as u64;
        for before in [1, 2, 3, n / 20, n / 2, n * 9 / 10, n - 1, n, n + 1, u64::MAX] {
            check(&bytes, &starts, before);
        }
        let _ = name;
    }
}

/// A probe reads a line's header, not the 64 KiB window: a deep page's search in an 8 MiB
/// segment reads about what a 1 MB chat's does (goal infinite-chats, scrollDeepUs at 1 GB).
#[test]
fn offset_of_seq_probes_read_heads_not_windows() {
    let small = segment(500, |seq| 1500 + (seq as usize % 900));
    let big = segment(4000, |seq| 1500 + (seq as usize % 900));
    assert!(big.0.len() > 7 << 20, "{}", big.0.len());
    let small_read = check(&small.0, &small.1, 500 / 20);
    let big_read = check(&big.0, &big.1, 4000 / 20);
    // 7 probes and the tail's look at 8 KiB each, not 64 KiB.
    assert!(big_read <= 10 * 8 * 1024, "big segment read {big_read} bytes");
    assert!(big_read <= small_read + 4 * 8 * 1024, "{big_read} vs {small_read}");
}
