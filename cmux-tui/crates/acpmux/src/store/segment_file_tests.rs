//! A segment read through [`SegmentFile`], plain or compressed (`store/segment_file.rs`).

use super::*;

struct Dir(PathBuf);

impl Dir {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("acpmux-segment-file-{}", uuid::Uuid::now_v7()));
        crate::config::private_state_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `count` log lines with growing seqs.
fn lines(count: u64) -> Vec<u8> {
    let mut out = Vec::new();
    for seq in 1..=count {
        out.extend_from_slice(
            format!("{{\"seq\":{seq},\"at\":1,\"dir\":\"mux\",\"kind\":\"k\",\"msg\":{{\"n\":\"{}\"}}}}\n", "x".repeat((seq % 97) as usize))
                .as_bytes(),
        );
    }
    out
}

/// Writes `bytes` owner-only at `path`.
fn write(path: &Path, bytes: &[u8]) {
    let mut file = open_private_append(path).unwrap();
    file.write_all(bytes).unwrap();
}

/// `bytes` as one zstd frame; `size`: whether the frame says its content size.
fn frame(bytes: &[u8], size: bool) -> Vec<u8> {
    let mut encoder = zstd::stream::write::Encoder::new(Vec::new(), 3).unwrap();
    encoder.include_checksum(true).unwrap();
    if size {
        encoder.set_pledged_src_size(Some(bytes.len() as u64)).unwrap();
    } else {
        encoder.include_contentsize(false).unwrap();
    }
    encoder.write_all(bytes).unwrap();
    encoder.finish().unwrap()
}

#[test]
fn names() {
    assert_eq!(segment_name("000012.ndjson"), Some((12, false)));
    assert_eq!(segment_name("000012.ndjson.zst"), Some((12, true)));
    assert_eq!(segment_name("000012.ndjson.compact"), None);
    assert_eq!(segment_name(".000012.ndjson.zst.compress-7"), None);
    let plain = Path::new("/s/events/000003.ndjson");
    assert_eq!(zst_path(plain), Path::new("/s/events/000003.ndjson.zst"));
    assert_eq!(plain_path(&zst_path(plain)), plain);
    assert_eq!(plain_path(plain), plain);
}

#[test]
fn frame_headers_give_the_plain_length() {
    let dir = Dir::new();
    let bytes = lines(5_000);
    let sized = dir.0.join("a.zst");
    write(&sized, &frame(&bytes, true));
    assert_eq!(frames_len(&File::open(&sized).unwrap()).unwrap(), Some(bytes.len() as u64));
    // Two frames one after the other, as `cat a.zst b.zst` makes: both count.
    let two = dir.0.join("b.zst");
    let mut joined = frame(&bytes, true);
    joined.extend(frame(b"{\"seq\":5001}\n", true));
    write(&two, &joined);
    assert_eq!(frames_len(&File::open(&two).unwrap()).unwrap(), Some(bytes.len() as u64 + 13));
    // A frame from a pipe says no size: the decode says.
    let unsized_path = dir.0.join("000003.ndjson.zst");
    write(&unsized_path, &frame(&bytes, false));
    assert_eq!(frames_len(&File::open(&unsized_path).unwrap()).unwrap(), None);
    let mut file = SegmentFile::open(&unsized_path).unwrap();
    assert_eq!(file.len().unwrap(), bytes.len() as u64);
    // Not zstd at all.
    let junk = dir.0.join("d.zst");
    write(&junk, b"not zstd at all");
    assert!(frames_len(&File::open(&junk).unwrap()).is_err());
}

#[test]
fn a_compressed_segment_reads_as_the_plain_one_at_every_offset() {
    let dir = Dir::new();
    let bytes = lines(20_000);
    let plain = dir.0.join("000001.ndjson");
    let zst = dir.0.join("000002.ndjson.zst");
    write(&plain, &bytes);
    write(&zst, &frame(&bytes, true));
    let mut a = SegmentFile::open(&plain).unwrap();
    let mut b = SegmentFile::open(&zst).unwrap();
    assert!(b.is_zst() && !a.is_zst());
    assert_eq!(b.len().unwrap(), a.len().unwrap());
    // Forward from the start (a stream), then back (a scratch copy), then past the end.
    let len = bytes.len() as u64;
    for offset in [0, 10, 4_000, 70_000, 5, len - 100, 1, len, len + 9] {
        let (mut x, mut y) = (vec![0u8; 3_000], vec![0u8; 3_000]);
        let n = a.read_at(offset, &mut x).unwrap();
        let m = b.read_at(offset, &mut y).unwrap();
        assert_eq!((n, &x[..n]), (m, &y[..m]), "at {offset}");
    }
    // Read and Seek as a file.
    let mut tail = Vec::new();
    b.seek(SeekFrom::End(-50)).unwrap();
    b.read_to_end(&mut tail).unwrap();
    assert_eq!(tail, bytes[bytes.len() - 50..]);
    b.seek(SeekFrom::Start(0)).unwrap();
    let mut whole = Vec::new();
    b.read_to_end(&mut whole).unwrap();
    assert_eq!(whole, bytes);
    // The reverse read and the seek by seq agree with the plain file's.
    for before in [1, 2, 777, 19_999, 20_000, u64::MAX] {
        let mut a = SegmentFile::open(&plain).unwrap();
        let mut b = SegmentFile::open(&zst).unwrap();
        assert_eq!(
            log_line::offset_of_seq(&mut a, before).unwrap(),
            log_line::offset_of_seq(&mut b, before).unwrap(),
            "before {before}"
        );
    }
    let (mut x, mut y) = (Vec::new(), Vec::new());
    log_line::for_each_line_rev(&plain, &mut |l| {
        x.push(l.to_vec());
        true
    })
    .unwrap();
    log_line::for_each_line_rev(&zst, &mut |l| {
        y.push(l.to_vec());
        true
    })
    .unwrap();
    assert_eq!(x, y);
    assert_eq!(log_line::first_seq(&zst).unwrap(), Some(1));
    // Its identity is the compressed file's, across opens.
    let id = SegmentFile::open(&zst).unwrap().id().unwrap();
    assert_eq!(SegmentFile::open(&zst).unwrap().id().unwrap(), id);
}

#[test]
fn a_scan_from_the_start_streams_and_a_page_decodes_once() {
    let dir = Dir::new();
    let bytes = lines(30_000);
    let zst = dir.0.join("000001.ndjson.zst");
    write(&zst, &frame(&bytes, true));
    forget_scratch();
    let decoded = decoded_count();
    let mut file = SegmentFile::open(&zst).unwrap();
    let mut reader = BufReader::with_capacity(64 * 1024, &mut file);
    let mut line = Vec::new();
    let mut n = 0;
    while reader.read_until(b'\n', &mut line).unwrap() > 0 {
        n += 1;
        line.clear();
    }
    assert_eq!(n, 30_000);
    assert_eq!(decoded_count(), decoded, "a forward scan made no scratch copy");
    // Reads out of order decode once, and later opens of the same file use that copy.
    let mut file = SegmentFile::open(&zst).unwrap();
    let mut buf = [0u8; 100];
    file.read_at(200_000, &mut buf).unwrap();
    file.read_at(100, &mut buf).unwrap();
    let mut again = SegmentFile::open(&zst).unwrap();
    again.read_at(50_000, &mut buf).unwrap();
    assert_eq!(decoded_count(), decoded + 1);
}

#[test]
fn an_open_finds_the_segment_under_its_other_name() {
    let dir = Dir::new();
    let bytes = lines(100);
    let plain = dir.0.join("000001.ndjson");
    write(&zst_path(&plain), &frame(&bytes, true));
    // Listed plain a moment ago, compressed since: the open reads the compressed file.
    let mut file = SegmentFile::open(&plain).unwrap();
    assert!(file.is_zst());
    let mut read = Vec::new();
    file.read_to_end(&mut read).unwrap();
    assert_eq!(read, bytes);
    // And back: a compressed name a rewrite replaced with a plain file.
    let other = dir.0.join("000002.ndjson");
    write(&other, &bytes);
    let mut file = SegmentFile::open(&zst_path(&other)).unwrap();
    assert!(!file.is_zst());
    let mut read = Vec::new();
    file.read_to_end(&mut read).unwrap();
    assert_eq!(read, bytes);
}
