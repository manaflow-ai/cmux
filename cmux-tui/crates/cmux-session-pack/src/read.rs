//! Reading a pack: a range of lines, one record by `seq`, one blob, or the whole log.

use crate::Result;
use crate::codec::{Blobs, Events};
use crate::manifest::{Manifest, Segment};
use crate::store::{Store, unhex};
use std::collections::{BTreeSet, HashMap};
use std::ops::Range;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// `f` of each item, on as many threads as there are items and cores; the results in order.
fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> Result<R> + Sync) -> Result<Vec<R>> {
    if items.len() < 2 {
        return items.iter().map(f).collect();
    }
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<Result<R>>>> = Mutex::new(items.iter().map(|_| None).collect());
    let workers = std::thread::available_parallelism().map_or(1, usize::from).min(items.len());
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = items.get(i) else { break };
                    let r = f(item);
                    if let Ok(mut o) = out.lock() {
                        o[i] = Some(r);
                    }
                }
            });
        }
    });
    let out = out.into_inner().map_err(|_| "a read worker panicked")?;
    out.into_iter().map(|r| r.ok_or("a read worker stopped early")?).collect()
}

/// An open pack. It keeps the blob chunks it has read, so a second range that names the same
/// blobs does not read them again.
pub struct Pack {
    store: Store,
    /// The session's manifest.
    pub manifest: Manifest,
    blobs: Mutex<HashMap<usize, Arc<Blobs>>>,
}

impl Pack {
    /// Opens session `name` in `store`.
    pub fn open(store: &Store, name: &str) -> Result<Self> {
        let manifest = Manifest::load(store, name)?
            .ok_or_else(|| format!("{} holds no session {name:?}", store.root().display()))?;
        Ok(Self::with_manifest(store, manifest))
    }

    /// A pack of `manifest`, whose chunks are in `store`.
    pub fn with_manifest(store: &Store, manifest: Manifest) -> Self {
        Self { store: store.clone(), manifest, blobs: Mutex::new(HashMap::new()) }
    }

    fn cached(&self, seg: usize) -> Option<Arc<Blobs>> {
        self.blobs.lock().ok()?.get(&seg).cloned()
    }

    fn segment_blobs(&self, seg: usize) -> Result<Arc<Blobs>> {
        if let Some(b) = self.cached(seg) {
            return Ok(b);
        }
        let (blobs, table) =
            self.manifest.segments[seg].blob_chunks.as_ref().ok_or("a segment with no blobs")?;
        let b = Arc::new(Blobs::decode(
            self.store.get(&unhex(blobs)?)?,
            &self.store.get(&unhex(table)?)?,
        )?);
        if let Ok(mut cache) = self.blobs.lock() {
            cache.insert(seg, b.clone());
        }
        Ok(b)
    }

    /// The segment that was the first to hold blob `n`.
    fn blob_segment(&self, n: u64) -> Result<usize> {
        let segs = &self.manifest.segments;
        let seg = segs.partition_point(|s| s.blob + s.blobs <= n);
        match segs.get(seg) {
            Some(s) if s.blob <= n => Ok(seg),
            _ => Err(format!("no blob {n}").into()),
        }
    }

    fn push_blob(&self, n: u64, out: &mut Vec<u8>) -> Result<()> {
        let seg = self.blob_segment(n)?;
        self.segment_blobs(seg)?.get((n - self.manifest.segments[seg].blob) as usize, out)
    }

    /// Blob `n`: the string, as the log has it between its quotes.
    pub fn blob(&self, n: u64) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        self.push_blob(n, &mut out)?;
        Ok(out)
    }

    fn events(&self, s: &Segment) -> Result<Events> {
        let e = Events::decode(self.store.get(&unhex(&s.events)?)?)?;
        if e.len() as u64 != s.lines {
            return Err(format!(
                "segment at line {} holds {} lines, not {}",
                s.line,
                e.len(),
                s.lines
            )
            .into());
        }
        Ok(e)
    }

    /// The segments that hold lines of `range`.
    fn covering(&self, range: &Range<u64>) -> &[Segment] {
        let segs = &self.manifest.segments;
        let first = segs.partition_point(|s| s.line + s.lines <= range.start);
        let last = segs.partition_point(|s| s.line < range.end);
        &segs[first.min(last)..last]
    }

    /// Reads, at once, every blob chunk the lines `range` of `events` name and the cache lacks.
    fn load_blobs(&self, parts: &[(&Segment, Events)], range: &Range<u64>) -> Result<()> {
        let mut refs = Vec::new();
        for (s, e) in parts {
            for l in range.start.max(s.line)..range.end.min(s.line + s.lines) {
                e.blob_refs((l - s.line) as usize, &mut refs);
            }
        }
        let mut need = BTreeSet::new();
        for n in refs {
            let seg = self.blob_segment(n)?;
            if self.cached(seg).is_none() {
                need.insert(seg);
            }
        }
        let need: Vec<usize> = need.into_iter().collect();
        par_map(&need, |seg| self.segment_blobs(*seg).map(drop))?;
        Ok(())
    }

    /// The lines of `range` (cut to the log's end), each without its newline. The segments and
    /// blob chunks it needs are read and decompressed side by side, one a core.
    pub fn read_lines(&self, range: Range<u64>) -> Result<Vec<Vec<u8>>> {
        let range = range.start..range.end.min(self.manifest.lines);
        let segs: Vec<&Segment> = self.covering(&range).iter().collect();
        let events = par_map(&segs, |s| self.events(s))?;
        let parts: Vec<(&Segment, Events)> = segs.into_iter().zip(events).collect();
        self.load_blobs(&parts, &range)?;
        let mut out = Vec::new();
        let mut blob = |n: u64, o: &mut Vec<u8>| self.push_blob(n, o);
        for (s, e) in &parts {
            for l in range.start.max(s.line)..range.end.min(s.line + s.lines) {
                let mut line = Vec::new();
                e.line((l - s.line) as usize, &mut blob, &mut line)?;
                out.push(line);
            }
        }
        Ok(out)
    }

    /// The lines numbered in `lines` (ascending), each with its long strings left empty, so
    /// only the events chunks are read.
    pub fn skim_lines(&self, lines: &[u64]) -> Result<Vec<Vec<u8>>> {
        let segs = &self.manifest.segments;
        let mut groups: Vec<(&Segment, Vec<u64>)> = Vec::new();
        for l in lines {
            let i = segs.partition_point(|s| s.line + s.lines <= *l);
            let s = segs.get(i).ok_or_else(|| format!("no line {l}"))?;
            match groups.last_mut() {
                Some((g, ls)) if g.line == s.line => ls.push(*l),
                _ => groups.push((s, vec![*l])),
            }
        }
        let parts = par_map(&groups, |(s, ls)| {
            let e = self.events(s)?;
            let mut skip = |_: u64, _: &mut Vec<u8>| Ok(());
            ls.iter()
                .map(|l| {
                    let mut line = Vec::new();
                    e.line((l - s.line) as usize, &mut skip, &mut line)?;
                    Ok(line)
                })
                .collect::<Result<Vec<_>>>()
        })?;
        Ok(parts.into_iter().flatten().collect())
    }

    /// The acpmux record with this `seq`: its line number and the line.
    pub fn by_seq(&self, seq: u64) -> Result<Option<(u64, Vec<u8>)>> {
        let mut blob = |n: u64, o: &mut Vec<u8>| self.push_blob(n, o);
        for s in &self.manifest.segments {
            if !s.seq.is_some_and(|(lo, hi)| lo <= seq && seq <= hi) {
                continue;
            }
            let e = self.events(s)?;
            if let Some(i) = e.seqs.iter().position(|x| *x == Some(seq)) {
                let mut line = Vec::new();
                e.line(i, &mut blob, &mut line)?;
                return Ok(Some((s.line + i as u64, line)));
            }
        }
        Ok(None)
    }

    /// Writes the whole log to `out`, each segment checked against its hash first.
    pub fn cat(&self, out: &mut dyn std::io::Write) -> Result<()> {
        let mut blob = |n: u64, o: &mut Vec<u8>| self.push_blob(n, o);
        let segs: Vec<&Segment> = self.manifest.segments.iter().collect();
        // A few segments at a time: the whole log is never held decoded at once.
        for group in segs.chunks(4) {
            let events = par_map(group, |s| self.events(s))?;
            let parts: Vec<(&Segment, Events)> = group.iter().copied().zip(events).collect();
            self.load_blobs(&parts, &(0..self.manifest.lines))?;
            for (s, e) in &parts {
                let mut raw = Vec::with_capacity(s.raw as usize);
                for i in 0..e.len() {
                    e.line(i, &mut blob, &mut raw)?;
                    if self.manifest.final_newline || s.line + (i as u64) + 1 < self.manifest.lines
                    {
                        raw.push(b'\n');
                    }
                }
                if blake3::hash(&raw).to_hex().as_str() != s.raw_hash {
                    return Err(format!(
                        "segment at line {} does not read back as it was packed",
                        s.line
                    )
                    .into());
                }
                out.write_all(&raw)?;
            }
        }
        Ok(())
    }

    /// Reads every segment back and checks it against its hash.
    pub fn verify(&self) -> Result<()> {
        self.cat(&mut std::io::sink())
    }
}
