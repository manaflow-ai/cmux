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

/// The kinds a keyed scan reads from held heads: a resend's prompt state (`hub/prompt_ledger.rs`
/// `PROMPT_STATE_KINDS`) and its inbox answer (`hub/inbox.rs` `INBOX_ANSWER_KINDS`), which a test
/// keeps within these. Only their heads are held: a chat's other indexed records (a busy
/// coordinator's `process_update` and `background_task_update`, half its copies' lines) are
/// never shown to a keyed scan's `keep`, and holding their heads too put one chat of Leo's past
/// [`BUDGET`], so every resend read every one of its copies again (below). A keyed scan of any
/// other kind reads the log as a scan of a kind no copy holds does.
pub(crate) const KEYED_KINDS: &[&str] = &[
    "turn_stop_requested",
    "queued",
    "user_message",
    "turn_started",
    "turn_result",
    "prompt_refused",
    "queue_declined",
    "queue_removed",
    "dequeued",
    "inbox",
    "inbox_noticed",
    "inbox_answered",
    "inbox_removed",
];

/// Whether a line's head is held: its kind is keyed, or its head does not say (it is read, and
/// shown unread when it does not parse).
fn keyed(line: &[u8]) -> bool {
    #[cfg(test)]
    if EVERY_KIND.with(std::cell::Cell::get) {
        return kind_index::indexed(line);
    }
    record_kind(line).is_none_or(|kind| KEYED_KINDS.iter().any(|k| k.as_bytes() == kind))
}

/// What [`Store::scan_kinds_keyed`] shows of a record before it is read whole.
#[derive(Clone, Copy, Debug, Default)]
pub struct KindHead<'a> {
    /// Sequence and direction let indexed readers select a prompt without reading its text.
    pub seq: Option<u64>,
    pub is_mux: bool,
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
    /// `msg._meta.provenance.parts`): [`Self::names`] says which.
    pub names_many: bool,
    /// The head could not be read (an id that is not a string, a line that does not parse): a
    /// caller keeps it to learn.
    pub unread: bool,
    /// The prompts those lists name.
    named: Named<'a>,
}

/// The prompts a record's lists name, as a head holds them.
#[derive(Clone, Copy, Debug, Default)]
enum Named<'a> {
    /// No list.
    #[default]
    Nothing,
    /// The ids, read when the head was.
    Ids(&'a [Box<str>]),
    /// A record read whole: its message's lists.
    Msg(&'a Value),
    /// A list the head could not read: it may name any prompt.
    Unknown,
}

impl<'a> KindHead<'a> {
    /// The head of a record read whole.
    pub fn of(rec: &'a EventRecord) -> Self {
        let field = |k: &str| rec.msg.get(k).and_then(Value::as_str);
        let unread = ["promptId", "turnId", "joinedTurnId", "digestPromptId"]
            .iter()
            .any(|k| rec.msg.get(*k).is_some_and(|v| !v.is_string() && !v.is_null()));
        let names_many = rec.msg.get("promptIds").is_some()
            || rec.msg.get("took").is_some()
            || rec.msg.pointer("/_meta/provenance/parts").is_some();
        Self {
            seq: Some(rec.seq),
            is_mux: rec.dir == "mux",
            kind: &rec.kind,
            prompt_id: field("promptId"),
            turn_id: field("turnId"),
            joined_turn_id: field("joinedTurnId"),
            digest_prompt_id: field("digestPromptId"),
            names_many,
            unread,
            named: if names_many { Named::Msg(&rec.msg) } else { Named::Nothing },
        }
    }

    /// Whether the record's lists name a prompt `wanted` keeps; true for a list that did not
    /// read, which may name any. So a keyed scan of one prompt reads the records whose lists name
    /// it, not every record with a list (a coordinator's 3,213 of 23,349 heads, 41 segments,
    /// on every resend).
    pub fn names(&self, mut wanted: impl FnMut(&str) -> bool) -> bool {
        match self.named {
            Named::Nothing => false,
            Named::Unknown => true,
            Named::Ids(ids) => ids.iter().any(|id| wanted(id)),
            Named::Msg(msg) => match listed(
                msg.get("promptIds"),
                msg.get("took"),
                msg.pointer("/_meta/provenance/parts"),
            ) {
                Some(ids) => ids.into_iter().any(wanted),
                None => true,
            },
        }
    }
}

/// The prompt ids a record's lists name: `promptIds` (strings), `took` and provenance `parts`
/// (objects with a `promptId`). None when one is not of that shape.
fn listed<'v>(
    prompt_ids: Option<&'v Value>,
    took: Option<&'v Value>,
    parts: Option<&'v Value>,
) -> Option<Vec<&'v str>> {
    let mut ids = Vec::new();
    for (list, by_object) in [(prompt_ids, false), (took, true), (parts, true)] {
        let Some(list) = list.filter(|v| !v.is_null()) else { continue };
        for item in list.as_array()? {
            let id = if by_object { item.get("promptId")? } else { item };
            ids.push(id.as_str()?);
        }
    }
    Some(ids)
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
    is_mux: bool,
    place: Place,
    at: u64,
    len: u32,
    prompt_id: Option<Box<str>>,
    turn_id: Option<Box<str>>,
    joined_turn_id: Option<Box<str>>,
    digest_prompt_id: Option<Box<str>>,
    names_many: bool,
    /// The ids its lists name; None with `names_many` for a list that did not read ([`listed`]).
    named: Option<Box<[Box<str>]>>,
}

#[derive(serde::Deserialize)]
struct LineHead<'a> {
    #[serde(default, borrow)]
    dir: std::borrow::Cow<'a, str>,
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
    prompt_ids: Option<Value>,
    took: Option<Value>,
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
    parts: Option<Value>,
}

impl Head {
    fn read(line: &[u8], place: Place, at: u64) -> Self {
        let boxed = |s: Option<std::borrow::Cow<str>>| s.map(|s| Box::<str>::from(s.into_owned()));
        let mut head = Self {
            kind: None,
            seq: record_seq(line),
            is_mux: false,
            place,
            at,
            len: u32::try_from(line.len()).unwrap_or(u32::MAX),
            prompt_id: None,
            turn_id: None,
            joined_turn_id: None,
            digest_prompt_id: None,
            names_many: false,
            named: None,
        };
        if let Ok(LineHead { dir, kind, msg }) = serde_json::from_slice::<LineHead<'_>>(line) {
            head.is_mux = dir == "mux";
            head.kind = Some(
                INDEXED_KINDS
                    .iter()
                    .position(|k| *k == kind)
                    .and_then(|i| u16::try_from(i).ok())
                    .unwrap_or(u16::MAX),
            );
            let parts = msg.meta.and_then(|m| m.provenance).and_then(|p| p.parts);
            head.names_many = msg.prompt_ids.is_some() || msg.took.is_some() || parts.is_some();
            if head.names_many {
                head.named = listed(msg.prompt_ids.as_ref(), msg.took.as_ref(), parts.as_ref())
                    .map(|ids| ids.into_iter().map(Box::from).collect());
            }
            head.prompt_id = boxed(msg.prompt_id);
            head.turn_id = boxed(msg.turn_id);
            head.joined_turn_id = boxed(msg.joined_turn_id);
            head.digest_prompt_id = boxed(msg.digest_prompt_id);
        }
        head
    }

    fn view(&self) -> KindHead<'_> {
        KindHead {
            seq: self.seq,
            is_mux: self.is_mux,
            kind: self.kind.and_then(|i| INDEXED_KINDS.get(usize::from(i))).copied().unwrap_or(""),
            prompt_id: self.prompt_id.as_deref(),
            turn_id: self.turn_id.as_deref(),
            joined_turn_id: self.joined_turn_id.as_deref(),
            digest_prompt_id: self.digest_prompt_id.as_deref(),
            names_many: self.names_many,
            unread: self.kind.is_none(),
            named: match (&self.named, self.names_many) {
                (_, false) => Named::Nothing,
                (Some(ids), true) => Named::Ids(ids),
                (None, true) => Named::Unknown,
            },
        }
    }

    fn bytes(&self) -> usize {
        let ids = [&self.prompt_id, &self.turn_id, &self.joined_turn_id, &self.digest_prompt_id];
        let named = self.named.iter().flatten();
        std::mem::size_of::<Self>()
            + ids.iter().map(|s| s.as_ref().map_or(0, |s| s.len())).sum::<usize>()
            + named.map(|id| id.len() + std::mem::size_of::<Box<str>>()).sum::<usize>()
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
    /// The chat's folders as they were ([`Folders`]) when these heads were read to the end of
    /// a segment that was no longer the log's last: a sealed segment is never appended to, so
    /// while the folders are still so its heads are whole, and a keyed scan uses them without
    /// opening the segment or its copy ([`LocalStore::scan_kinds_keyed_in`]).
    whole_under: Option<Folders>,
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

/// A folder as `lstat` shows it: device, inode, and its change and modify times in ns. A name
/// made, renamed or removed in it moves both times; an append to a file in it moves neither.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct DirStamp(u64, u64, i128, i128);

/// A chat's `events/` and `events-index/` folders' stamps (the second None while there is none):
/// a segment or a copy replaced by a rename, a new segment, a cut or a rehydrate each change one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Folders {
    events: DirStamp,
    copies: Option<DirStamp>,
}

/// How long before its stamp a folder must have last changed for the stamp to be trusted: well
/// past any file system's time granularity (ext4's coarse clock ticks in milliseconds, FAT's in
/// two seconds).
const SETTLED: std::time::Duration = std::time::Duration::from_secs(3);

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

    /// Keeps `heads` as segment `index` of chat `id`'s, other chats' least recently read going
    /// past [`BUDGET`]. A chat's own heads are never evicted for its own: a keyed scan reads a
    /// chat's segments in order, and a least-recently-read eviction of a chat larger than the
    /// budget dropped each segment's heads just before the next scan asked for them, so every
    /// scan read every copy whole again (cmux NEXT nightly, 2026-11-22: `prompt_with`'s resend
    /// reads 23% of the daemon's CPU, `read_kind_index`, `fnv_on` and `Head::read` most of it, of
    /// a chat of 771 segments and 221,388 indexed lines). Such a chat keeps the heads it fit,
    /// its first segments, and the scan reads only the rest's copies.
    fn put(&self, id: &str, index: u32, heads: Arc<SegmentHeads>) {
        let mut map = self.lock();
        map.tick = map.tick.wrapping_add(1);
        let tick = map.tick;
        let bytes = heads.bytes;
        let key = (id.to_owned(), index);
        if let Some((old, _)) = map.map.insert(key.clone(), (heads, tick)) {
            map.bytes = map.bytes.saturating_sub(old.bytes);
        }
        map.bytes = map.bytes.saturating_add(bytes);
        let budget = budget();
        while map.bytes > budget {
            #[cfg(test)]
            let any_chat = EVERY_KIND.with(std::cell::Cell::get);
            #[cfg(not(test))]
            let any_chat = false;
            let oldest = map
                .map
                .iter()
                .filter(|((chat, _), _)| any_chat || chat != id)
                .min_by_key(|(_, (_, used))| *used)
                .map(|(k, _)| k.clone())
                .unwrap_or_else(|| key.clone());
            if let Some((gone, _)) = map.map.remove(&oldest) {
                map.bytes = map.bytes.saturating_sub(gone.bytes);
            }
            if oldest == key {
                break;
            }
        }
    }

    /// Segment `index` of chat `id`'s heads when they are whole under `folders`, with no check
    /// of the segment file: its folders are as they were when its heads were read to its end.
    fn whole(&self, id: &str, index: u32, folders: Folders) -> Option<Arc<SegmentHeads>> {
        let mut map = self.lock();
        map.tick = map.tick.wrapping_add(1);
        let tick = map.tick;
        let (heads, used) = map.map.get_mut(&(id.to_owned(), index))?;
        if heads.whole_under != Some(folders) {
            return None;
        }
        *used = tick;
        Some(Arc::clone(heads))
    }

    /// Chat `id`'s segments as listed under `folders`, if they were.
    fn forget_segment(&self, id: &str, index: u32) {
        let mut map = self.lock();
        if let Some((gone, _)) = map.map.remove(&(id.to_owned(), index)) {
            map.bytes = map.bytes.saturating_sub(gone.bytes);
        }
    }

    /// The heads' bytes held, as [`BUDGET`] counts them.
    #[cfg(test)]
    pub(super) fn held_bytes(&self) -> usize {
        self.lock().bytes
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
        if !kinds.iter().all(|k| KEYED_KINDS.contains(k)) {
            return self.scan_kinds_in(id, kinds, false, &mut |rec| {
                let kept = keep(&KindHead::of(&rec));
                !kept || visit(rec)
            });
        }
        kind_index::test_scan_delay();
        let (segments, folders) = self.keyed_listing(id)?;
        let last = segments.last().map(|(index, _)| *index);
        for (index, path) in segments {
            let sealed = folders.filter(|_| Some(index) != last);
            if !self.keyed_segment(id, index, &path, kinds, keep, visit, sealed)? {
                break;
            }
        }
        Ok(())
    }

    /// Chat `id`'s segments, and its folders' stamps when both were last changed [`SETTLED`]
    /// ago or more. With such stamps a keyed scan reads the folder again only once one of them
    /// changed: a resend asks a chat of hundreds of segments its prompt state three times, and
    /// a listing, an open and two stats of every segment each time held the daemon at a core
    /// (cmux NEXT nightly 1.0.0-nightly.4424316677601: `scan_kinds_keyed` 2,078 of 5 s of
    /// samples, 1,419 of them in `open` and `lstat`).
    fn keyed_listing(&self, id: &str) -> Result<(SegmentList, Option<Folders>)> {
        let folders = self.settled_folders(id);
        // The common segment table shares this listing with every other reader. Folder
        // stamps still validate sealed kind heads separately.
        let segments = self.segments(id)?;
        Ok((segments, folders))
    }

    /// Chat `id`'s [`Folders`], None unless both were last changed [`SETTLED`] ago or more (or
    /// off Unix, where no stamp is kept).
    fn settled_folders(&self, id: &str) -> Option<Folders> {
        let now = std::time::SystemTime::now();
        let dir = self.dir(id);
        let events = dir_stamp(&dir.join("events"), now).ok()??;
        let copies = match dir_stamp(&dir.join(kind_index::DIR), now) {
            Ok(stamp) => Some(stamp?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => return None,
        };
        Some(Folders { events, copies })
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
    /// `sealed`: the chat's settled folders, when this segment is not the log's last. Its heads
    /// read to its end under those folders are then used as they are: neither the segment nor
    /// its copy is opened unless a kept record's line is in it.
    #[allow(clippy::too_many_arguments)]
    fn keyed_segment(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
        sealed: Option<Folders>,
    ) -> Result<bool> {
        let scan = kind_index::Scan { kinds, copied: true, strict: false, heads: false };
        if let Some(folders) = sealed
            && let Some(heads) = self.kind_heads.whole(id, index, folders)
        {
            #[cfg(test)]
            SEALED_HITS.with(|n| n.set(n.get() + 1));
            return match self.read_picked(id, index, path, None, &heads, kinds, keep) {
                Some(records) => Ok(records.into_iter().all(visit)),
                None => {
                    self.kind_heads.forget_segment(id, index);
                    self.keyed_whole(id, index, path, &scan, keep, visit)
                }
            };
        }
        #[cfg(test)]
        SEGMENT_OPENS.with(|n| n.set(n.get() + 1));
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
                let Some(kind_index::Copied { lines, len: from, .. }) = copy else {
                    return self.keyed_whole(id, index, path, &scan, keep, visit);
                };
                let mut heads = SegmentHeads {
                    file: stamp.id,
                    len: from,
                    copy: copy_inode(&copy_path),
                    whole_under: None,
                    heads: Vec::new(),
                    bytes: std::mem::size_of::<SegmentHeads>(),
                };
                let mut at = kind_index::HEADER_WIDTH as u64;
                #[cfg(test)]
                COPY_READS.with(|n| n.set(n.get() + 1));
                for line in lines.split_inclusive(|b| *b == b'\n') {
                    if !line.iter().all(u8::is_ascii_whitespace) && keyed(line) {
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
                if !line.iter().all(u8::is_ascii_whitespace) && keyed(&line) {
                    heads.push(Head::read(&line, Place::Segment, heads.len));
                }
                heads.len = heads.len.saturating_add(line.len() as u64);
            }
        }
        // Read to the segment's end while a later one exists: nothing is appended to it again,
        // so its heads are whole while the folders stay as stamped.
        if sealed.is_some() && heads.whole_under != sealed {
            self.kind_heads.forget_segment(id, index);
            Arc::make_mut(&mut heads).whole_under = sealed;
        }
        let Some(records) = self.read_picked(id, index, path, Some(file), &heads, kinds, keep)
        else {
            self.kind_heads.forget_segment(id, index);
            return self.keyed_whole(id, index, path, &scan, keep, visit);
        };
        self.kind_heads.put(id, index, heads);
        for rec in records {
            if !visit(rec) {
                return Ok(false);
            }
        }
        Ok(true)
    }

    /// The records of the heads `keep` keeps, read back by their places, the segment (`file`,
    /// opened here if None) and its copy opened only for a line in them. None when a line does
    /// not check (its seq, its end of line) or cannot be read: the caller scans the segment
    /// whole.
    #[allow(clippy::too_many_arguments)]
    fn read_picked(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        mut file: Option<std::fs::File>,
        heads: &SegmentHeads,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
    ) -> Option<Vec<EventRecord>> {
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
        for head in picked {
            let source = match head.place {
                Place::Segment => {
                    if file.is_none() {
                        file = Some(crate::config::private_state_file(path).ok()?);
                    }
                    file.as_mut()?
                }
                Place::Copy => {
                    if copy_file.is_none() {
                        let copy =
                            crate::config::private_state_file(&self.kind_index_path(id, index));
                        copy_file = Some(copy.ok()?);
                    }
                    copy_file.as_mut()?
                }
            };
            let line = read_at(source, head.at, head.len).ok()?;
            if !line.ends_with(b"\n") || record_seq(&line) != head.seq {
                return None;
            }
            // A line that does not read is skipped, as a scan skips it.
            if let Ok(rec) = parse_record(&line)
                && kinds.contains(&rec.kind.as_str())
            {
                records.push(rec);
            }
        }
        Some(records)
    }
}

/// The [`DirStamp`] of the folder at `path`, None while it changed within [`SETTLED`] of `now`
/// (or off Unix).
pub(super) fn dir_stamp(
    path: &Path,
    now: std::time::SystemTime,
) -> std::io::Result<Option<DirStamp>> {
    let meta = crate::home_fs::symlink_metadata(path)?;
    if !meta.is_dir() {
        return Ok(None);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let ns = |s: i64, n: i64| i128::from(s) * 1_000_000_000 + i128::from(n);
        let Ok(before) = now
            .checked_sub(settled_for())
            .unwrap_or(std::time::UNIX_EPOCH)
            .duration_since(std::time::UNIX_EPOCH)
        else {
            return Ok(None);
        };
        let before = i128::try_from(before.as_nanos()).unwrap_or(i128::MAX);
        let (mtime, ctime) =
            (ns(meta.mtime(), meta.mtime_nsec()), ns(meta.ctime(), meta.ctime_nsec()));
        if mtime > before || ctime > before {
            return Ok(None);
        }
        Ok(Some(DirStamp(meta.dev(), meta.ino(), mtime, ctime)))
    }
    #[cfg(not(unix))]
    {
        let _ = (now, settled_for);
        Ok(None)
    }
}

#[cfg(test)]
thread_local! {
    /// Sealed segments a keyed scan on this thread used the heads of without opening them.
    pub(super) static SEALED_HITS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    /// Segments a keyed scan on this thread opened.
    pub(super) static SEGMENT_OPENS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    /// Copies a keyed scan on this thread read whole for their heads (a held heads miss).
    pub(super) static COPY_READS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    /// [`BUDGET`] for this thread's scans, when a test sets it.
    pub(super) static BUDGET_FOR: std::cell::Cell<Option<usize>> =
        const { std::cell::Cell::new(None) };
    /// The heads held before `KEYED_KINDS`, for a before-and-after bench: every indexed kind's,
    /// any chat's evicted for any other's.
    pub(super) static EVERY_KIND: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// [`SETTLED`] for this thread's scans, when a test sets it.
    pub(super) static SETTLED_FOR: std::cell::Cell<Option<std::time::Duration>> =
        const { std::cell::Cell::new(None) };
}

/// [`BUDGET`], or a test's own.
fn budget() -> usize {
    #[cfg(test)]
    if let Some(budget) = BUDGET_FOR.with(std::cell::Cell::get) {
        return budget;
    }
    BUDGET
}

/// [`SETTLED`], or a test's own.
fn settled_for() -> std::time::Duration {
    #[cfg(test)]
    if let Some(settled) = SETTLED_FOR.with(std::cell::Cell::get) {
        return settled;
    }
    SETTLED
}
