//! Reading a pack: a range of lines, one record by `seq`, one blob, or the whole log.

use crate::Result;
use crate::codec::{Blobs, Events};
use crate::manifest::{Manifest, Segment};
use crate::store::{Store, unhex};
use std::cell::RefCell;
use std::collections::HashMap;
use std::ops::Range;
use std::rc::Rc;

/// An open pack. It keeps the blob chunks it has read, so a second range that names the same
/// blobs does not read them again.
pub struct Pack {
    store: Store,
    /// The session's manifest.
    pub manifest: Manifest,
    blobs: RefCell<HashMap<usize, Rc<Blobs>>>,
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
        Self { store: store.clone(), manifest, blobs: RefCell::new(HashMap::new()) }
    }

    fn segment_blobs(&self, seg: usize) -> Result<Rc<Blobs>> {
        if let Some(b) = self.blobs.borrow().get(&seg) {
            return Ok(b.clone());
        }
        let (blobs, table) =
            self.manifest.segments[seg].blob_chunks.as_ref().ok_or("a segment with no blobs")?;
        let b = Rc::new(Blobs::decode(
            self.store.get(&unhex(blobs)?)?,
            &self.store.get(&unhex(table)?)?,
        )?);
        self.blobs.borrow_mut().insert(seg, b.clone());
        Ok(b)
    }

    fn push_blob(&self, n: u64, out: &mut Vec<u8>) -> Result<()> {
        let segs = &self.manifest.segments;
        let seg = segs.partition_point(|s| s.blob + s.blobs <= n);
        let s = segs.get(seg).filter(|s| s.blob <= n).ok_or_else(|| format!("no blob {n}"))?;
        self.segment_blobs(seg)?.get((n - s.blob) as usize, out)
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

    /// The lines of `range` (cut to the log's end), each without its newline.
    pub fn read_lines(&self, range: Range<u64>) -> Result<Vec<Vec<u8>>> {
        let end = range.end.min(self.manifest.lines);
        let mut out = Vec::new();
        let segs = &self.manifest.segments;
        let first = segs.partition_point(|s| s.line + s.lines <= range.start);
        let mut blob = |n: u64, o: &mut Vec<u8>| self.push_blob(n, o);
        for s in &segs[first..] {
            if s.line >= end {
                break;
            }
            let e = self.events(s)?;
            for l in range.start.max(s.line)..end.min(s.line + s.lines) {
                let mut line = Vec::new();
                e.line((l - s.line) as usize, &mut blob, &mut line)?;
                out.push(line);
            }
        }
        Ok(out)
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

    /// One segment's bytes of the log.
    fn segment_raw(&self, s: &Segment) -> Result<Vec<u8>> {
        let e = self.events(s)?;
        let mut blob = |n: u64, o: &mut Vec<u8>| self.push_blob(n, o);
        let mut out = Vec::with_capacity(s.raw as usize);
        for i in 0..e.len() {
            e.line(i, &mut blob, &mut out)?;
            if self.manifest.final_newline || s.line + (i as u64) + 1 < self.manifest.lines {
                out.push(b'\n');
            }
        }
        Ok(out)
    }

    /// Writes the whole log to `out`, each segment checked against its hash first.
    pub fn cat(&self, out: &mut dyn std::io::Write) -> Result<()> {
        for s in &self.manifest.segments {
            let raw = self.segment_raw(s)?;
            if blake3::hash(&raw).to_hex().as_str() != s.raw_hash {
                return Err(format!(
                    "segment at line {} does not read back as it was packed",
                    s.line
                )
                .into());
            }
            out.write_all(&raw)?;
            self.blobs.borrow_mut().retain(|_, b| Rc::strong_count(b) > 1);
        }
        Ok(())
    }

    /// Reads every segment back and checks it against its hash.
    pub fn verify(&self) -> Result<()> {
        self.cat(&mut std::io::sink())
    }
}
