//! Packing a log into a store, from scratch or from where the last pack sealed.

use crate::Result;
use crate::codec::{BlobIndex, Events, encode_segment};
use crate::manifest::{Manifest, Params, SCHEMA, Segment, TURN_RULE, check_name};
use crate::read::par_map;
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
        // segments in place), so every kept segment is checked against the log, not just the
        // last. Hashing one is about 4 ms and encoding one about a second; the checks run on
        // every core, so a gigabyte's worth is checked in the time of a few.
        let old_rule = old.turn_rule;
        let mut spans = Vec::new();
        let mut offset = 0u64;
        for s in old.segments.into_iter().take_while(|s| s.sealed) {
            let end = offset + s.raw;
            if end > total {
                break;
            }
            spans.push((offset, end, s));
            offset = end;
        }
        let same = par_map(&spans, |(start, end, s)| {
            Ok(blake3::hash(&read_span(files, &lens, *start, *end)?).to_hex().as_str()
                == s.raw_hash)
        })?;
        let n = same.iter().take_while(|ok| **ok).count();
        spans.truncate(n);
        if old_rule < TURN_RULE {
            // Its marks were found by an older rule, which knew only acpmux's records: a
            // segment holding any other line (a Claude Code transcript's) is encoded again to
            // find its turns. Encoding is deterministic, so that writes the same chunks.
            let plain = par_map(&spans, |(_, _, s)| {
                let events = store.get(&unhex(&s.events)?).and_then(Events::decode);
                Ok(s.seq.is_some() && events.is_ok_and(|e| e.seqs.iter().all(Option::is_some)))
            })?;
            spans.truncate(plain.iter().take_while(|ok| **ok).count());
        }
        kept.extend(spans.into_iter().map(|(_, _, s)| s));
    }
    let offset: u64 = kept.iter().map(|s| s.raw).sum();
    let data = read_span(files, &lens, offset, total)?;
    encode_after(store, name, kept, &data, params)
}

/// Packs session `name`'s log from line `after` on into `store`, when the store's pack of it
/// (with the same `params`) has sealed segments that end at line `after`: `files` back to back
/// are the log's lines from `after` on, and the sealed segments are kept as they are, unchecked.
/// What a writer that appends calls as its log grows, once a [`pack`] of the same log has
/// checked them: it reads only the new lines, never the log before them. `Ok(None)` when the
/// pack's sealed segments do not end at `after` (none there, other params, or a pack that
/// sealed less or more since): the caller packs with [`pack`].
pub fn pack_after(
    store: &Store,
    name: &str,
    after: u64,
    files: &[PathBuf],
    params: &Params,
) -> Result<Option<(Manifest, PackStats)>> {
    check_name(name)?;
    let Some(old) = Manifest::load(store, name)? else { return Ok(None) };
    // Segments marked by an older turn rule are packed again whole (`pack` does it).
    if old.params != *params || old.turn_rule < TURN_RULE {
        return Ok(None);
    }
    let kept: Vec<Segment> = old.segments.into_iter().take_while(|s| s.sealed).collect();
    if kept.last().map_or(0, |s| s.line + s.lines) != after || kept.is_empty() {
        return Ok(None);
    }
    let mut data = Vec::new();
    for path in files {
        let mut f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        f.read_to_end(&mut data)?;
    }
    encode_after(store, name, kept, &data, params).map(Some)
}

/// Packs session `name`'s log after its pack's first `keep` sealed segments into `store`: `files`
/// back to back are the log's lines after them, and those segments are kept as they are,
/// unchecked (the caller checked them against the log, or trusts that nothing rewrote it since a
/// pack that did). Unlike [`pack_after`] the pack may hold more sealed segments than `keep`: the
/// ones after are packed again from `files`, so a pack through an earlier line than the pack
/// reaches cuts it back there, as [`pack`] does. A writer that holds the log as records, not as a
/// file, calls it so that a pack costs the lines after the kept segments, not the whole log.
/// `Ok(None)` when the pack has fewer than `keep` sealed segments, none at all, other params or
/// marks of an older turn rule: the caller packs with [`pack`].
pub fn pack_kept(
    store: &Store,
    name: &str,
    keep: usize,
    files: &[PathBuf],
    params: &Params,
) -> Result<Option<(Manifest, PackStats)>> {
    check_name(name)?;
    let Some(old) = Manifest::load(store, name)? else { return Ok(None) };
    if old.params != *params || old.turn_rule < TURN_RULE || keep == 0 {
        return Ok(None);
    }
    let kept: Vec<Segment> = old.segments.into_iter().take_while(|s| s.sealed).take(keep).collect();
    if kept.len() != keep {
        return Ok(None);
    }
    let mut data = Vec::new();
    for path in files {
        let mut f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        f.read_to_end(&mut data)?;
    }
    encode_after(store, name, kept, &data, params).map(Some)
}

/// Encodes `data`, the log after the segments `kept`, into `store` and saves the manifest.
fn encode_after(
    store: &Store,
    name: &str,
    kept: Vec<Segment>,
    data: &[u8],
    params: &Params,
) -> Result<(Manifest, PackStats)> {
    let offset: u64 = kept.iter().map(|s| s.raw).sum();
    let total = offset + data.len() as u64;
    let mut index = BlobIndex::default();
    let with_blobs: Vec<&Segment> = kept.iter().filter(|s| s.blob_chunks.is_some()).collect();
    let tables = par_map(&with_blobs, |s| match &s.blob_chunks {
        Some((_, table)) => store.get(&unhex(table)?),
        None => Ok(Vec::new()),
    })?;
    for (s, table) in with_blobs.iter().zip(&tables) {
        index.add_table(s.blob, table)?;
    }

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
            let Some(tail) = data.get(at..) else { break };
            match memchr::memchr(b'\n', tail).and_then(|p| tail.get(..p)) {
                Some(line) => {
                    lines.push(line);
                    at += line.len() + 1;
                    if (at - start) as u64 >= params.segment_bytes {
                        sealed = true;
                        break;
                    }
                }
                None => {
                    lines.push(tail);
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
            raw_hash: blake3::hash(data.get(start..at).ok_or("a segment past the log's end")?)
                .to_hex()
                .to_string(),
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
                    if let Ok(mut d) = done.lock()
                        && let Some(slot) = d.get_mut(i)
                    {
                        *slot = Some(r);
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
        let s = segments.get_mut(seg).ok_or("a chunk for no segment")?;
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
        turn_rule: TURN_RULE,
        segments,
    };
    manifest.save(store)?;
    stats.stored_bytes = manifest.stored_bytes();
    stats.manifest_bytes = manifest.to_json()?.len() as u64;
    Ok((manifest, stats))
}

/// Checks a pack's sealed segments against the log's lines as they are made: each segment's
/// BLAKE3 of its `raw` bytes against its `raw_hash`, in order, nothing written anywhere. The
/// first that differs stops the lines ([`std::io::Write`] fails, `diverged` set).
pub struct SegmentCheck {
    want: Vec<(u64, String)>,
    at: usize,
    filled: u64,
    hasher: blake3::Hasher,
    diverged: bool,
}

impl SegmentCheck {
    /// A check of `segments`, the first of a pack and in order, against lines from the log's start.
    pub fn new(segments: &[&Segment]) -> Self {
        Self {
            want: segments.iter().map(|s| (s.raw, s.raw_hash.clone())).collect(),
            at: 0,
            filled: 0,
            hasher: blake3::Hasher::new(),
            diverged: false,
        }
    }

    /// How many segments, from the first, the lines held byte for byte.
    pub fn matched(&self) -> usize {
        self.at
    }

    /// Whether a segment differed (the write that failed was this check, not the lines).
    pub fn diverged(&self) -> bool {
        self.diverged
    }

    fn diverge(&mut self) -> std::io::Error {
        self.diverged = true;
        std::io::Error::other("the log no longer holds the pack's segment")
    }
}

impl std::io::Write for SegmentCheck {
    fn write(&mut self, mut buf: &[u8]) -> std::io::Result<usize> {
        if self.diverged {
            return Err(std::io::Error::other("the log no longer holds the pack's segment"));
        }
        let len = buf.len();
        while !buf.is_empty() {
            let Some(&(raw, _)) = self.want.get(self.at) else { return Err(self.diverge()) };
            let room = usize::try_from(raw.saturating_sub(self.filled)).unwrap_or(usize::MAX);
            let (now, rest) = buf.split_at(room.min(buf.len()));
            self.hasher.update(now);
            self.filled += now.len() as u64;
            buf = rest;
            if self.filled >= raw {
                let hash = self.hasher.finalize();
                if self.want.get(self.at).is_none_or(|(_, want)| hash.to_hex().as_str() != want) {
                    return Err(self.diverge());
                }
                self.at += 1;
                self.filled = 0;
                self.hasher.reset();
            }
        }
        Ok(len)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
