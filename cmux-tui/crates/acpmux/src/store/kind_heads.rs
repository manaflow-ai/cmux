//! A record's head for [`Store::scan_kinds_keyed`]: its kind and the ids a prompt's state follows,
//! not its text.
//!
//! A resend's prompt state (`hub/prompt_ledger.rs` `logged_prompt_state`) and an inbox answer
//! (`hub/inbox.rs` `logged_inbox_answer`) each want the few records of one prompt out of a chat's
//! indexed kinds, and a restart's resume pass asks them per session, per retry and per queued
//! prompt. A keyed scan shows the caller each record's head first and parses, and hands over, only
//! the records whose head it keeps.

use super::*;
use std::sync::Arc;

/// What [`Store::scan_kinds_keyed`] shows of a record before it is read whole.
#[derive(Clone, Copy, Debug, Default)]
pub struct KindHead<'a> {
    pub kind: &'a str,
    /// `msg.promptId`.
    pub prompt_id: Option<&'a str>,
    /// `msg.turnId`.
    pub turn_id: Option<&'a str>,
    /// `msg.joinedTurnId` (a prompt that went into another's turn, `digest.rs`).
    pub joined_turn_id: Option<&'a str>,
    /// `msg.digestPromptId` (a prompt an inbox digest took, `inbox_digest.rs`).
    pub digest_prompt_id: Option<&'a str>,
    /// The record names other prompts by a list (`msg.promptIds`, `msg.took`,
    /// `msg._meta.provenance.parts`), which the head does not hold.
    pub names_many: bool,
    /// The head could not be read (an id that is not a string, a line that does not parse): a
    /// caller keeps it to learn.
    pub unread: bool,
}

impl<'a> KindHead<'a> {
    /// The head of a record read whole.
    pub fn of(rec: &'a EventRecord) -> Self {
        let field = |k: &str| rec.msg.get(k).and_then(Value::as_str);
        let unread = ["promptId", "turnId", "joinedTurnId", "digestPromptId"]
            .iter()
            .any(|k| rec.msg.get(*k).is_some_and(|v| !v.is_string() && !v.is_null()));
        Self {
            kind: &rec.kind,
            prompt_id: field("promptId"),
            turn_id: field("turnId"),
            joined_turn_id: field("joinedTurnId"),
            digest_prompt_id: field("digestPromptId"),
            names_many: rec.msg.get("promptIds").is_some()
                || rec.msg.get("took").is_some()
                || rec.msg.pointer("/_meta/provenance/parts").is_some(),
            unread,
        }
    }
}

// A keyed scan's heads: each segment's indexed records' heads, where each record's line is (in
// the segment's copy, `store/kind_index.rs`, or in the segment past it) and how long, kept in
// memory once read. Prompt text is not kept: a chat of 300 turns of 4 KiB prompts holds about
// 1.7 MB of indexed lines and under 200 KB of heads, so the heads of every chat a restart's resume
// pass asks about stay within [`BUDGET`] where their records did not.
//
// Heads are of one segment file (device, inode, birth) and the bytes of it they cover, as a copy
// is: a segment is only appended to, or replaced whole by a rename, so heads whose file is no
// longer the segment's, or is shorter than they cover, are dropped and read again from the copy.
// A copy is only added to in place or replaced by a rename, so heads read from it are dropped once
// its inode changes. A kept record's line is read back by its place and checked (its seq, its end
// of line) before it is parsed; one that does not check drops the segment's heads and the segment
// is scanned whole, as a scan without them is.

/// The most bytes the heads hold, estimated from their size and their ids' lengths.
const BUDGET: usize = 32 << 20;

/// Where a head's line is: in the segment's copy, or in the segment.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Place {
    Copy,
    Segment,
}

/// One indexed record's head and its line's place.
#[derive(Clone)]
struct Head {
    /// Its kind's place in [`INDEXED_KINDS`]; None when the head did not read, `u16::MAX` for a
    /// kind that list does not hold.
    kind: Option<u16>,
    seq: Option<u64>,
    place: Place,
    at: u64,
    len: u32,
    prompt_id: Option<Box<str>>,
    turn_id: Option<Box<str>>,
    joined_turn_id: Option<Box<str>>,
    digest_prompt_id: Option<Box<str>>,
    names_many: bool,
}

#[derive(serde::Deserialize)]
struct LineHead<'a> {
    #[serde(borrow)]
    kind: std::borrow::Cow<'a, str>,
    #[serde(default, borrow)]
    msg: MsgHead<'a>,
}

#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct MsgHead<'a> {
    #[serde(rename = "promptId", borrow)]
    prompt_id: Option<std::borrow::Cow<'a, str>>,
    #[serde(rename = "turnId", borrow)]
    turn_id: Option<std::borrow::Cow<'a, str>>,
    #[serde(rename = "joinedTurnId", borrow)]
    joined_turn_id: Option<std::borrow::Cow<'a, str>>,
    #[serde(rename = "digestPromptId", borrow)]
    digest_prompt_id: Option<std::borrow::Cow<'a, str>>,
    #[serde(rename = "promptIds")]
    prompt_ids: Option<serde::de::IgnoredAny>,
    took: Option<serde::de::IgnoredAny>,
    #[serde(rename = "_meta")]
    meta: Option<MetaHead>,
}

#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct MetaHead {
    provenance: Option<ProvenanceHead>,
}

#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct ProvenanceHead {
    parts: Option<serde::de::IgnoredAny>,
}

impl Head {
    fn read(line: &[u8], place: Place, at: u64) -> Self {
        let boxed = |s: Option<std::borrow::Cow<str>>| s.map(|s| Box::<str>::from(s.into_owned()));
        let mut head = Self {
            kind: None,
            seq: record_seq(line),
            place,
            at,
            len: u32::try_from(line.len()).unwrap_or(u32::MAX),
            prompt_id: None,
            turn_id: None,
            joined_turn_id: None,
            digest_prompt_id: None,
            names_many: false,
        };
        if let Ok(LineHead { kind, msg }) = serde_json::from_slice::<LineHead<'_>>(line) {
            head.kind = Some(
                INDEXED_KINDS
                    .iter()
                    .position(|k| *k == kind)
                    .and_then(|i| u16::try_from(i).ok())
                    .unwrap_or(u16::MAX),
            );
            head.names_many = msg.prompt_ids.is_some()
                || msg.took.is_some()
                || msg.meta.and_then(|m| m.provenance).is_some_and(|p| p.parts.is_some());
            head.prompt_id = boxed(msg.prompt_id);
            head.turn_id = boxed(msg.turn_id);
            head.joined_turn_id = boxed(msg.joined_turn_id);
            head.digest_prompt_id = boxed(msg.digest_prompt_id);
        }
        head
    }

    fn view(&self) -> KindHead<'_> {
        KindHead {
            kind: self.kind.and_then(|i| INDEXED_KINDS.get(usize::from(i))).copied().unwrap_or(""),
            prompt_id: self.prompt_id.as_deref(),
            turn_id: self.turn_id.as_deref(),
            joined_turn_id: self.joined_turn_id.as_deref(),
            digest_prompt_id: self.digest_prompt_id.as_deref(),
            names_many: self.names_many,
            unread: self.kind.is_none(),
        }
    }

    fn bytes(&self) -> usize {
        let ids = [&self.prompt_id, &self.turn_id, &self.joined_turn_id, &self.digest_prompt_id];
        std::mem::size_of::<Self>()
            + ids.iter().map(|s| s.as_ref().map_or(0, |s| s.len())).sum::<usize>()
    }
}

/// One segment's heads, oldest first.
#[derive(Clone)]
struct SegmentHeads {
    file: (u64, u64, u64),
    /// The segment bytes the heads cover, whole lines.
    len: u64,
    /// The inode of the copy the [`Place::Copy`] heads were read from.
    copy: Option<u64>,
    heads: Vec<Head>,
    bytes: usize,
}

impl SegmentHeads {
    fn push(&mut self, head: Head) {
        self.bytes = self.bytes.saturating_add(head.bytes());
        self.heads.push(head);
    }
}

#[derive(Default)]
struct Map {
    map: HashMap<(String, u32), (Arc<SegmentHeads>, u64)>,
    tick: u64,
    bytes: usize,
}

/// The heads of a store's segments a keyed scan read.
#[derive(Default)]
pub(crate) struct KindHeads {
    map: Mutex<Map>,
}

impl KindHeads {
    fn lock(&self) -> std::sync::MutexGuard<'_, Map> {
        self.map.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Segment `index` of chat `id`'s heads, when they are of the file `stamp` is and no longer;
    /// heads of another file are dropped.
    fn get(&self, id: &str, index: u32, stamp: &kind_index::Stamp) -> Option<Arc<SegmentHeads>> {
        let mut map = self.lock();
        map.tick = map.tick.wrapping_add(1);
        let tick = map.tick;
        let key = (id.to_owned(), index);
        let (heads, used) = map.map.get_mut(&key)?;
        if heads.file == stamp.id && stamp.id.2 != 0 && stamp.len >= heads.len {
            *used = tick;
            return Some(Arc::clone(heads));
        }
        if let Some((gone, _)) = map.map.remove(&key) {
            map.bytes = map.bytes.saturating_sub(gone.bytes);
        }
        None
    }

    /// Keeps `heads` as segment `index` of chat `id`'s, the least recently read going past
    /// [`BUDGET`].
    fn put(&self, id: &str, index: u32, heads: Arc<SegmentHeads>) {
        let mut map = self.lock();
        map.tick = map.tick.wrapping_add(1);
        let tick = map.tick;
        let bytes = heads.bytes;
        if let Some((old, _)) = map.map.insert((id.to_owned(), index), (heads, tick)) {
            map.bytes = map.bytes.saturating_sub(old.bytes);
        }
        map.bytes = map.bytes.saturating_add(bytes);
        while map.bytes > BUDGET {
            let Some(oldest) =
                map.map.iter().min_by_key(|(_, (_, used))| *used).map(|(k, _)| k.clone())
            else {
                break;
            };
            if let Some((gone, _)) = map.map.remove(&oldest) {
                map.bytes = map.bytes.saturating_sub(gone.bytes);
            }
        }
    }

    fn forget_segment(&self, id: &str, index: u32) {
        let mut map = self.lock();
        if let Some((gone, _)) = map.map.remove(&(id.to_owned(), index)) {
            map.bytes = map.bytes.saturating_sub(gone.bytes);
        }
    }

    /// Drops chat `id`'s heads (its folder is gone).
    pub(super) fn forget(&self, id: &str) {
        let mut map = self.lock();
        let gone: usize =
            map.map.iter().filter(|((chat, _), _)| chat == id).map(|(_, (h, _))| h.bytes).sum();
        map.map.retain(|(chat, _), _| chat != id);
        map.bytes = map.bytes.saturating_sub(gone);
    }
}

/// The inode of the copy at `path`; None when there is none.
fn copy_inode(path: &Path) -> Option<u64> {
    let meta = crate::home_fs::symlink_metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        Some(0)
    }
}

/// Reads `len` bytes of `file` at `at`.
fn read_at(file: &mut std::fs::File, at: u64, len: u32) -> std::io::Result<Vec<u8>> {
    use std::io::Seek as _;
    file.seek(std::io::SeekFrom::Start(at))?;
    let mut buf = vec![0u8; usize::try_from(len).unwrap_or(usize::MAX)];
    file.read_exact(&mut buf)?;
    Ok(buf)
}

impl LocalStore {
    /// [`Store::scan_kinds_keyed`]: each segment's heads (read once, then past them), and the
    /// lines of the ones `keep` keeps. Kinds a copy does not hold are scanned whole.
    pub(super) fn scan_kinds_keyed_in(
        &self,
        id: &str,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        if !kinds.iter().all(|k| INDEXED_KINDS.contains(k)) {
            return self.scan_kinds_in(id, kinds, false, &mut |rec| {
                let kept = keep(&KindHead::of(&rec));
                !kept || visit(rec)
            });
        }
        kind_index::test_scan_delay();
        for (index, path) in self.segments(id)? {
            if !self.keyed_segment(id, index, &path, kinds, keep, visit)? {
                break;
            }
        }
        Ok(())
    }

    /// A segment scanned whole, as `scan_kinds` scans it, its records' heads shown to `keep` as
    /// they are read; false when `visit` stopped the scan.
    fn keyed_whole(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        scan: &kind_index::Scan<'_>,
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<bool> {
        self.scan_segment(id, index, path, scan, &mut |rec| {
            let kept = keep(&KindHead::of(&rec));
            !kept || visit(rec)
        })
    }

    /// One segment of [`Self::scan_kinds_keyed_in`]; false when `visit` stopped the scan.
    fn keyed_segment(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<bool> {
        let scan = kind_index::Scan { kinds, copied: true, strict: false };
        let mut file = crate::config::private_state_file(path)?;
        let stamp = kind_index::Stamp::of(&file)?;
        // A system that names no birth time keeps no copy, so no heads.
        if stamp.id.2 == 0 {
            return self.keyed_whole(id, index, path, &scan, keep, visit);
        }
        let copy_path = self.kind_index_path(id, index);
        let held = self
            .kind_heads
            .get(id, index, &stamp)
            .filter(|h| h.copy.is_none() || h.copy == copy_inode(&copy_path));
        let mut heads = match held {
            Some(heads) => heads,
            None => {
                // No copy yet: the segment is scanned whole, which makes one (on a system that
                // names a birth time); the next keyed scan reads its heads from it.
                let copy = self.read_kind_index(id, index, &stamp);
                let Some((lines, from, _)) = copy else {
                    return self.keyed_whole(id, index, path, &scan, keep, visit);
                };
                let mut heads = SegmentHeads {
                    file: stamp.id,
                    len: from,
                    copy: copy_inode(&copy_path),
                    heads: Vec::new(),
                    bytes: std::mem::size_of::<SegmentHeads>(),
                };
                let mut at = kind_index::HEADER_WIDTH as u64;
                for line in lines.split_inclusive(|b| *b == b'\n') {
                    if !line.iter().all(u8::is_ascii_whitespace) {
                        heads.push(Head::read(line, Place::Copy, at));
                    }
                    at = at.saturating_add(line.len() as u64);
                }
                Arc::new(heads)
            }
        };
        if stamp.len > heads.len {
            // The map's own reference dropped first, so the heads are added to, not copied.
            self.kind_heads.forget_segment(id, index);
            let heads = Arc::make_mut(&mut heads);
            std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(heads.len))?;
            let mut reader = BufReader::with_capacity(256 * 1024, &mut file);
            let mut line = Vec::new();
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 || !line.ends_with(b"\n") {
                    break;
                }
                if !line.iter().all(u8::is_ascii_whitespace) && kind_index::indexed(&line) {
                    heads.push(Head::read(&line, Place::Segment, heads.len));
                }
                heads.len = heads.len.saturating_add(line.len() as u64);
            }
        }
        let picked: Vec<&Head> = heads
            .heads
            .iter()
            .filter(|h| {
                let view = h.view();
                (view.unread || kinds.contains(&view.kind)) && keep(&view)
            })
            .collect();
        let mut copy_file = None;
        let mut records = Vec::with_capacity(picked.len());
        let mut sound = true;
        for head in picked {
            if head.place == Place::Copy && copy_file.is_none() {
                copy_file = crate::config::private_state_file(&copy_path).ok();
            }
            let source = match head.place {
                Place::Segment => &mut file,
                Place::Copy => match copy_file.as_mut() {
                    Some(f) => f,
                    None => {
                        sound = false;
                        break;
                    }
                },
            };
            let Ok(line) = read_at(source, head.at, head.len) else {
                sound = false;
                break;
            };
            if !line.ends_with(b"\n") || record_seq(&line) != head.seq {
                sound = false;
                break;
            }
            // A line that does not read is skipped, as a scan skips it.
            if let Ok(rec) = parse_record(&line)
                && kinds.contains(&rec.kind.as_str())
            {
                records.push(rec);
            }
        }
        if !sound {
            self.kind_heads.forget_segment(id, index);
            return self.keyed_whole(id, index, path, &scan, keep, visit);
        }
        self.kind_heads.put(id, index, heads);
        for rec in records {
            if !visit(rec) {
                return Ok(false);
            }
        }
        Ok(true)
    }
}
