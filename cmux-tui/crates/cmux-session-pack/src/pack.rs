//! Packing a log into a store, from scratch or from where the last pack sealed.

use crate::Result;
use crate::codec::{BlobIndex, encode_segment};
use crate::manifest::{Manifest, Params, SCHEMA, Segment, check_name};
use crate::store::{
    KIND_BLOBS, KIND_EVENTS, KIND_TABLE, Store, chunk_id, encode_chunk, hex, unhex,
};
use std::fs::File;
use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

/// What one [`pack`] did.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PackStats {
    /// The log's size.
    pub raw_bytes: u64,
    /// The size of the session's chunk files.
    pub stored_bytes: u64,
    /// The manifest's size.
    pub manifest_bytes: u64,
    /// Bytes of the log this pack encoded (the rest were only hashed).
    pub encoded_bytes: u64,
    /// Chunk files this pack wrote, and their size.
    pub new_chunks: u64,
    pub new_bytes: u64,
    /// Segments kept from the last pack.
    pub kept_segments: u64,
}

/// A written chunk: its id, its file's size, and whether this pack wrote it.
type Written = Result<(String, u64, bool)>;

fn read_span(files: &[PathBuf], lens: &[u64], start: u64, end: u64) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity((end - start) as usize);
    let mut base = 0u64;
    for (path, len) in files.iter().zip(lens) {
        let (lo, hi) = (start.max(base), end.min(base + len));
        if lo < hi {
            let mut f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
            f.seek(SeekFrom::Start(lo - base))?;
            let before = out.len();
            f.take(hi - lo).read_to_end(&mut out)?;
            if (out.len() - before) as u64 != hi - lo {
                return Err(format!("{}: shorter than when it was measured", path.display()).into());
            }
        }
        base += len;
    }
    Ok(out)
}

/// Packs the log that is `files` back to back into `store` as session `name`.
///
/// When the store holds a pack of the session with the same `params`, its sealed segments are
/// kept up to the first one the log no longer holds byte for byte, and only the log after them
/// is encoded. `full` packs the whole log again whatever the store holds.
pub fn pack(
    store: &Store,
    name: &str,
    files: &[PathBuf],
    params: &Params,
    full: bool,
) -> Result<(Manifest, PackStats)> {
    check_name(name)?;
    let mut lens = Vec::with_capacity(files.len());
    for path in files {
        lens.push(std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?.len());
    }
    let total: u64 = lens.iter().sum();

    let mut kept: Vec<Segment> = Vec::new();
    if !full
        && let Some(old) = Manifest::load(store, name)?
        && old.params == *params
    {
        // A log is not always only appended to (a retention pass rewrites a closed chat's
        // segments in place), so every kept segment is checked against the log, not just the last:
        // hashing is about 1 ms a segment, encoding one is about a second.
        let mut offset = 0u64;
        for s in old.segments.into_iter().take_while(|s| s.sealed) {
            let end = offset + s.raw;
            if end > total
                || blake3::hash(&read_span(files, &lens, offset, end)?).to_hex().as_str()
                    != s.raw_hash
            {
                break;
            }
            offset = end;
            kept.push(s);
        }
    }
    let offset: u64 = kept.iter().map(|s| s.raw).sum();
    let mut index = BlobIndex::default();
    for s in &kept {
        if let Some((_, table)) = &s.blob_chunks {
            index.add_table(s.blob, &store.get(&unhex(table)?)?)?;
        }
    }
    let data = read_span(files, &lens, offset, total)?;

    // Cut into segments and encode, in order (a blob's number depends on what came before).
    let mut line_no = kept.last().map_or(0, |s| s.line + s.lines);
    let mut segments = kept.clone();
    let mut tasks: Vec<(u8, Vec<u8>)> = Vec::new();
    let mut owners: Vec<(usize, u8)> = Vec::new();
    let mut at = 0usize;
    while at < data.len() {
        let mut lines: Vec<&[u8]> = Vec::new();
        let (start, mut sealed) = (at, false);
        while at < data.len() {
            match memchr::memchr(b'\n', &data[at..]) {
                Some(p) => {
                    lines.push(&data[at..at + p]);
                    at += p + 1;
                    if (at - start) as u64 >= params.segment_bytes {
                        sealed = true;
                        break;
                    }
                }
                None => {
                    lines.push(&data[at..]);
                    at = data.len();
                }
            }
        }
        let blob = index.next;
        let enc = encode_segment(&lines, line_no, params, &mut index);
        let has_blobs = index.next > blob;
        let seg = segments.len();
        segments.push(Segment {
            line: line_no,
            lines: lines.len() as u64,
            raw: (at - start) as u64,
            raw_hash: blake3::hash(&data[start..at]).to_hex().to_string(),
            seq: enc.seq,
            blob,
            blobs: index.next - blob,
            events: String::new(),
            blob_chunks: has_blobs.then(|| (String::new(), String::new())),
            sealed,
            stored: 0,
            marks: enc.marks,
        });
        line_no += lines.len() as u64;
        tasks.push((KIND_EVENTS, enc.events));
        owners.push((seg, KIND_EVENTS));
        if has_blobs {
            tasks.push((KIND_BLOBS, enc.blobs));
            owners.push((seg, KIND_BLOBS));
            tasks.push((KIND_TABLE, enc.table));
            owners.push((seg, KIND_TABLE));
        }
    }

    // Compress and write the chunks, on every core.
    let next = AtomicUsize::new(0);
    let done: Mutex<Vec<Option<Written>>> = Mutex::new((0..tasks.len()).map(|_| None).collect());
    let workers =
        std::thread::available_parallelism().map_or(1, usize::from).min(tasks.len().max(1));
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some((kind, payload)) = tasks.get(i) else { break };
                    let one = || -> Written {
                        let id = chunk_id(*kind, payload);
                        if store.has(&id) {
                            return Ok((hex(&id), store.stored_len(&id)?, false));
                        }
                        let file = encode_chunk(*kind, payload, params.level)?;
                        store.put_stored(&id, &file)?;
                        Ok((hex(&id), file.len() as u64, true))
                    };
                    let r = one();
                    if let Ok(mut d) = done.lock() {
                        d[i] = Some(r);
                    }
                }
            });
        }
    });
    let mut stats = PackStats {
        raw_bytes: total,
        encoded_bytes: data.len() as u64,
        kept_segments: kept.len() as u64,
        ..Default::default()
    };
    let done = done.into_inner().map_err(|_| "a pack worker panicked")?;
    for (r, (seg, kind)) in done.into_iter().zip(owners) {
        let (id, len, new) = r.ok_or("a pack worker stopped early")??;
        if new {
            stats.new_chunks += 1;
            stats.new_bytes += len;
        }
        let s = &mut segments[seg];
        s.stored += len;
        match (kind, &mut s.blob_chunks) {
            (KIND_EVENTS, _) => s.events = id,
            (KIND_BLOBS, Some(b)) => b.0 = id,
            (_, Some(b)) => b.1 = id,
            _ => {}
        }
    }

    let manifest = Manifest {
        schema: SCHEMA.into(),
        name: name.into(),
        lines: line_no,
        raw_bytes: total,
        final_newline: data.last().is_none_or(|b| *b == b'\n'),
        params: params.clone(),
        segments,
    };
    manifest.save(store)?;
    stats.stored_bytes = manifest.stored_bytes();
    stats.manifest_bytes = manifest.to_json()?.len() as u64;
    Ok((manifest, stats))
}
