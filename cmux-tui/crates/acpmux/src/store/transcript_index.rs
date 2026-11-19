//! Where a log segment's transcript records are, kept beside the log and written as they are
//! appended, so an older page of a chat's transcript costs its records, not the log it skips.
//!
//! Leo, 2026-11-16: "how about speeding up the scrolling up of chats?" A page of the transcript
//! (`Hub::events_page`, kinds `transcript`, newest first) read the log back from its `before` and
//! passed the lines it does not want by their heads, but still read them: in a real Codex chat of
//! 353,235 records (4.73 GiB) half the bytes were load replays and almost half raw harness lines,
//! so a 2,000-record page read 103 MiB near the end and 616 MiB half way back.
//!
//! So each segment `events/NNNNNN.ndjson` has `transcript-index/NNNNNN.idx`: a fixed-width
//! [`HEADER`] and one fixed-width entry ([`WIDTH`]) per line that [`holds`] names (a line a
//! transcript page, a page with the web pane's preset approval cards, or the superseded fold's
//! prompt starts may want): the line's seq, offset and length. A page whose kinds can match
//! nothing else ([`PAGE_KINDS`], `EventFilter::reads_transcript_index`) reads the entries newest
//! first and only the lines they name ([`LocalStore::scan_back_transcript_in`]); every other read
//! is unchanged.
//!
//! Written at append time ([`LocalStore::index_line`], under the writers' lock): the entry first,
//! then the header's count, then the line. A crash between them leaves an entry whose line is not
//! there, or is another line; never a line without its entry. A reader takes an entry only when the
//! bytes it names are one whole line of the segment with that seq, and each line once, so such an
//! entry is read past, and the writer's next open cuts it off. A segment made before the index (an
//! upgrade) is indexed from where its writer then was (`from`); its bytes before are read the old
//! way. A segment with no good index is read the old way, and a read that passes all of it indexes
//! it ([`LocalStore::write_read_index`]): the index is written whole under a temporary name and
//! renamed in, under the writers' lock for that only, never while the segment is read.
//!
//! An index names its segment's file (device, inode, birth time, as `store/kind_index.rs`'s
//! copies do): a segment a retention rewrite or a cut replaced, or a file that took a removed
//! one's inode, is not its file, and it is read past. Its header says how far its entries cover
//! the segment (`covered`: up to the line its last entry was written for, and the writer's end
//! when it closes); a reader reads the bytes past that the old way, so lines a daemon without the
//! index appended (a build swapped back and forth) are never missed, and the next writer indexes
//! them. A machine that stops without writing back its page cache may keep a segment's lines and
//! lose their entries, so the header names the boot it was written in: a later boot trusts only
//! the entries the last sync of the index covered (`durable`, `durable_count`). Each entry carries
//! a check, so an entry lost to zeros is damage, and a damaged index is read past from where the
//! damage is.
//!
//! Entries also hold `call`, `span_start` and `span_len`, all 0 for now: a later change keeps a
//! tool call's key and the span of its content there, so a page leaves superseded
//! `tool_call_update` snapshots unread, with no change of format.

use super::kind_index::{Stamp, fnv};
use super::*;

/// The folder of a chat's transcript indexes, beside its `events`.
pub const DIR: &str = "transcript-index";

/// The kinds a page may name and read through the index: a page of these, with no subagent,
/// newest first. `transcript` and the cards the web pane pages with it (webviews
/// `attachParams.ts` `PRESET_APPROVAL_KINDS`).
pub const PAGE_KINDS: &[&str] =
    &["transcript", "preset_approval_request", "preset_approval_decision"];

/// The exact kinds of [`PAGE_KINDS`].
const CARD_KINDS: &[&str] = &["preset_approval_request", "preset_approval_decision"];

const MAGIC: [u8; 8] = *b"acpmuxTI";
const VERSION: u32 = 1;
/// The header's bytes.
const HEADER: u64 = 96;
/// An entry's bytes.
const WIDTH: u64 = 48;
/// An entry's flag: the line's head names no seq (not a line this daemon wrote); it is not checked
/// by seq.
const NO_SEQ: u32 = 1;

/// How many entries a read takes from an index at a time, newest first.
const ENTRY_BLOCK: u64 = 1024;
/// Lines read through the index are read together when they are this close.
const NEAR: u64 = 4 * 1024;
/// The most bytes one read of lines takes (a line longer is read alone).
const READ_SPAN: u64 = 32 * 1024;
/// A writer that opens a segment whose index covers less than the segment (a crash, another boot,
/// a daemon without the index that wrote meanwhile) indexes the bytes past it again when they are
/// at most this many (more than a segment's 8 MiB); past it, it starts the index again where it is.
const REBASE_BYTES: u64 = 16 << 20;
/// The longest tail past an index's trusted part a page reads whole (`kind_index.rs`'s).
const TAIL_SEEK_BYTES: u64 = 256 * 1024;

/// Whether a line with this `dir` and `kind` gets an entry: one a transcript page may want
/// (`hub/paging.rs` `transcript_may_match`), a prompt start the superseded fold reads whatever the
/// page's kinds (`starts_prompt`), or a preset approval card.
pub(crate) fn holds(dir: &[u8], kind: &[u8]) -> bool {
    crate::hub::transcript_may_match(dir, kind)
        || starts_prompt(dir, kind)
        || CARD_KINDS.iter().any(|k| k.as_bytes() == kind)
}

/// [`holds`] for a whole line: a line whose head does not read is held too (a reader parses it).
/// An `in` line whose message is a notification of another method than `session/update` is not
/// an agent update, so no transcript record (`hub/paging.rs` `is_transcript`): a harness's raw
/// lines (`codex.response` and the like, half a long Codex chat's bytes) get no entry.
fn holds_line(line: &[u8]) -> bool {
    match (record_dir(line), record_kind(line)) {
        (Some(dir), Some(kind)) => {
            holds(dir, kind) && !(dir == b"in" && other_method(line) && !held_by_kind(kind))
        }
        _ => !line.iter().all(u8::is_ascii_whitespace),
    }
}

/// Whether a line of this kind is held whatever its message: the exact kinds a page may name.
fn held_by_kind(kind: &[u8]) -> bool {
    CARD_KINDS.iter().any(|k| k.as_bytes() == kind)
}

/// Whether the line's `msg` surely names a method other than `session/update`: it begins
/// `{"jsonrpc":"2.0","method":"<m>"` (or `{"method":"<m>"`) with a plain `<m>` that is not
/// `session/update`. False whenever the line does not say so plainly.
fn other_method(line: &[u8]) -> bool {
    let head = line.get(..256).unwrap_or(line);
    let Some(at) = memchr::memmem::find(head, b"\"msg\":{") else { return false };
    let rest = &head[at + 7..];
    let rest = rest.strip_prefix(b"\"jsonrpc\":\"2.0\",").unwrap_or(rest);
    let Some(rest) = rest.strip_prefix(b"\"method\":\"") else { return false };
    let Some(end) = memchr::memchr(b'"', rest) else { return false };
    let method = &rest[..end];
    !method.contains(&b'\\') && method != b"session/update"
}

/// The boot this process runs in (hashed; 0 where the system does not say, which trusts only an
/// index's synced part).
fn boot() -> u64 {
    #[cfg(test)]
    if let Some(boot) = TEST_BOOT.with(std::cell::Cell::get) {
        return boot;
    }
    *BOOT
}

static BOOT: std::sync::LazyLock<u64> = std::sync::LazyLock::new(read_boot);

#[cfg(target_os = "linux")]
fn read_boot() -> u64 {
    std::fs::read("/proc/sys/kernel/random/boot_id")
        .ok()
        .map(|id| fnv(id.trim_ascii().iter().copied()))
        .unwrap_or(0)
}

#[cfg(target_os = "macos")]
fn read_boot() -> u64 {
    let mut time = libc::timeval { tv_sec: 0, tv_usec: 0 };
    let mut size = std::mem::size_of::<libc::timeval>();
    // SAFETY: the name is NUL-terminated, and the kernel writes at most `size` bytes into `time`.
    let failed = unsafe {
        libc::sysctlbyname(
            c"kern.boottime".as_ptr(),
            (&raw mut time).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    } != 0;
    if failed || time.tv_sec == 0 {
        return 0;
    }
    #[allow(clippy::useless_conversion)]
    let (sec, usec) = (i64::from(time.tv_sec), i64::from(time.tv_usec));
    fnv(sec.to_le_bytes().into_iter().chain(usec.to_le_bytes()))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read_boot() -> u64 {
    0
}

#[cfg(test)]
thread_local! {
    static TEST_BOOT: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
}

/// Tests: this thread runs as if in boot `boot` (None: the machine's).
#[cfg(test)]
pub(crate) fn as_if_booted(boot: Option<u64>) {
    TEST_BOOT.with(|b| b.set(boot));
}

/// An index's header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Header {
    /// The segment file it indexes: device, inode, birth time.
    file: (u64, u64, u64),
    /// The segment offset its entries start at: bytes before are read the old way.
    from: u64,
    /// The boot its entries were written in ([`boot`]).
    boot: u64,
    /// Every held line of the segment before this offset has an entry among the first
    /// `durable_count`, and those entries were synced: what a later boot trusts.
    durable: u64,
    durable_count: u64,
    /// The entries the index holds (more bytes past them are a crash's).
    count: u64,
    /// Every held line of the segment before this offset has an entry: what this boot trusts.
    /// Bytes past it (a daemon without the index may have appended them) are read the old way.
    covered: u64,
}

impl Header {
    fn fresh(file: (u64, u64, u64), from: u64) -> Self {
        Self { file, from, boot: boot(), durable: from, durable_count: 0, count: 0, covered: from }
    }

    fn encode(&self) -> [u8; HEADER as usize] {
        let mut b = [0u8; HEADER as usize];
        b[0..8].copy_from_slice(&MAGIC);
        b[8..12].copy_from_slice(&VERSION.to_le_bytes());
        b[12..16].copy_from_slice(&(WIDTH as u32).to_le_bytes());
        let fields = [
            self.file.0,
            self.file.1,
            self.file.2,
            self.from,
            self.boot,
            self.durable,
            self.durable_count,
            self.count,
            self.covered,
        ];
        for (n, field) in fields.iter().enumerate() {
            b[16 + n * 8..24 + n * 8].copy_from_slice(&field.to_le_bytes());
        }
        let seal = fnv(b[..88].iter().copied());
        b[88..96].copy_from_slice(&seal.to_le_bytes());
        b
    }

    fn decode(b: &[u8]) -> Option<Self> {
        let b = b.get(..HEADER as usize)?;
        let u64_at = |at: usize| u64::from_le_bytes(b[at..at + 8].try_into().unwrap_or_default());
        let u32_at = |at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap_or_default());
        if b[0..8] != MAGIC
            || u32_at(8) != VERSION
            || u64::from(u32_at(12)) != WIDTH
            || u64_at(88) != fnv(b[..88].iter().copied())
        {
            return None;
        }
        let header = Self {
            file: (u64_at(16), u64_at(24), u64_at(32)),
            from: u64_at(40),
            boot: u64_at(48),
            durable: u64_at(56),
            durable_count: u64_at(64),
            count: u64_at(72),
            covered: u64_at(80),
        };
        (header.durable_count <= header.count
            && header.durable >= header.from
            && header.covered >= header.durable)
            .then_some(header)
    }
}

/// One entry: where a held line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Entry {
    seq: u64,
    offset: u64,
    /// With its newline.
    len: u32,
    flags: u32,
}

impl Entry {
    /// The entry of `line` (without its newline) at `offset`.
    fn of(line: &[u8], offset: u64) -> Option<Self> {
        let len = u32::try_from(line.len() + 1).ok()?;
        Some(match record_seq(line) {
            Some(seq) => Self { seq, offset, len, flags: 0 },
            None => Self { seq: 0, offset, len, flags: NO_SEQ },
        })
    }

    fn end(&self) -> u64 {
        self.offset.saturating_add(u64::from(self.len))
    }

    /// Bytes 24..44 are `call` (u64), `span_start` and `span_len` (u32) and a reserved u32: 0
    /// here (module docs). The last 4 bytes check the rest.
    fn encode(&self) -> [u8; WIDTH as usize] {
        let mut b = [0u8; WIDTH as usize];
        b[0..8].copy_from_slice(&self.seq.to_le_bytes());
        b[8..16].copy_from_slice(&self.offset.to_le_bytes());
        b[16..20].copy_from_slice(&self.len.to_le_bytes());
        b[20..24].copy_from_slice(&self.flags.to_le_bytes());
        let check = check(&b[..44]);
        b[44..48].copy_from_slice(&check.to_le_bytes());
        b
    }

    /// None when its check fails: damage.
    fn decode(b: &[u8]) -> Option<Self> {
        let b = b.get(..WIDTH as usize)?;
        if u32::from_le_bytes(b[44..48].try_into().ok()?) != check(&b[..44]) {
            return None;
        }
        Some(Self {
            seq: u64::from_le_bytes(b[0..8].try_into().ok()?),
            offset: u64::from_le_bytes(b[8..16].try_into().ok()?),
            len: u32::from_le_bytes(b[16..20].try_into().ok()?),
            flags: u32::from_le_bytes(b[20..24].try_into().ok()?),
        })
    }
}

fn check(bytes: &[u8]) -> u32 {
    let h = fnv(bytes.iter().copied());
    (h ^ (h >> 32)) as u32
}

fn read_at(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::FileExt::read_exact_at(file, buf, offset)
    }
    #[cfg(not(unix))]
    {
        use std::io::{Seek, SeekFrom};
        let mut file = file;
        file.seek(SeekFrom::Start(offset))?;
        file.read_exact(buf)
    }
}

fn write_at(file: &File, buf: &[u8], offset: u64) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::FileExt::write_all_at(file, buf, offset)
    }
    #[cfg(not(unix))]
    {
        use std::io::{Seek, SeekFrom};
        let mut file = file;
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(buf)
    }
}

/// `path` opened to read and write, owner-only, never through a link.
fn open_rw(path: &Path) -> Result<File> {
    crate::config::refuse_lost_home(path)?;
    let mut options = crate::home_fs::OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    Ok(options.open(path)?)
}

/// An index a read may take: of the segment it is read with, whole as far as it is trusted.
struct Trusted {
    file: File,
    header: Header,
    /// The entries trusted: all of them in the boot that wrote them, else the synced ones.
    entries: u64,
    /// The segment offset the trusted entries cover to: `covered` in the boot that wrote them,
    /// else `durable`.
    to: u64,
}

/// The index at `path` when it is of the segment `segment` (its stamp) and whole as far as it is
/// trusted; None for none, another file's, a damaged header or one with entries missing.
fn trusted(path: &Path, segment: &Stamp) -> Option<Trusted> {
    if segment.id.2 == 0 {
        return None;
    }
    let file = crate::config::private_state_file(path).ok()?;
    let len = file.metadata().ok()?.len();
    let mut head = [0u8; HEADER as usize];
    read_at(&file, &mut head, 0).ok()?;
    // A header read while the writer rewrites it may tear: read it once more.
    let header = Header::decode(&head).or_else(|| {
        read_at(&file, &mut head, 0).ok()?;
        Header::decode(&head)
    })?;
    if header.file != segment.id || header.from > segment.len {
        return None;
    }
    let present = len.saturating_sub(HEADER) / WIDTH;
    let (entries, to) = if header.boot != 0 && header.boot == boot() {
        (header.count, header.covered)
    } else {
        (header.durable_count, header.durable)
    };
    (present >= entries).then_some(Trusted { file, header, entries, to })
}

/// The writer's side of a segment's index (`SegmentWriter::tx`).
#[derive(Default)]
pub(super) struct Appender {
    state: TxState,
    /// Where this writer began in the segment: every line since is its own, so an index it makes
    /// covers from here (0 for a segment it began).
    since: u64,
    /// The index, open while the handles' bound allows ([`LocalStore::index_handles`]).
    file: Option<File>,
    /// The writers' clock at its last write: the least recent handle closes first.
    used: u64,
}

#[derive(Default)]
enum TxState {
    /// Not looked at yet: the first held line opens or makes the index.
    #[default]
    Unknown,
    /// No index for this segment: the file system names no birth time, or a failed write took it
    /// away.
    Off,
    On(Header),
}

impl Appender {
    /// The index side of a writer that begins at `since` in its segment.
    pub(super) fn from(since: u64) -> Self {
        Self { since, ..Self::default() }
    }

    fn holds_handle(&self) -> bool {
        self.file.is_some()
    }
}

/// Lines of `bytes` (whole lines from segment offset `base`) that [`holds`] names, as entries.
fn entries_of(bytes: &[u8], base: u64) -> Vec<Entry> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while let Some(nl) = memchr::memchr(b'\n', bytes.get(at..).unwrap_or_default()) {
        let line = &bytes[at..at + nl];
        if holds_line(line)
            && let Some(entry) = Entry::of(line, base + at as u64)
        {
            out.push(entry);
        }
        at += nl + 1;
    }
    out
}

impl LocalStore {
    pub(super) fn transcript_index_path(&self, id: &str, index: u32) -> PathBuf {
        self.dir(id).join(DIR).join(format!("{index:06}.idx"))
    }

    /// The most index files the writers hold open: a quarter of the logs held open
    /// (`store/open_logs.rs`), at least 16. Past it the least recently written one is closed (no
    /// sync: an index's durable part is what its last sync said).
    fn index_handles(&self) -> usize {
        (self.open_logs / 4).max(16)
    }

    /// Makes `dir/transcript-index`, never the chat's folder: a write that outlived a delete leaves
    /// none behind.
    fn make_index_dir(&self, id: &str) -> Result<()> {
        let dir = self.dir(id).join(DIR);
        if let Err(e) = crate::home_fs::create_dir(&dir, 0o700)
            && e.kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(e.into());
        }
        crate::config::private_state_dir(&dir)?;
        Ok(())
    }

    /// A new index at `path` holding `header` and `entries`, written whole and renamed in.
    fn write_index(&self, id: &str, path: &Path, header: &Header, entries: &[Entry]) -> Result<()> {
        self.make_index_dir(id)?;
        let mut bytes = Vec::with_capacity((HEADER + WIDTH * entries.len() as u64) as usize);
        bytes.extend_from_slice(&header.encode());
        for entry in entries {
            bytes.extend_from_slice(&entry.encode());
        }
        crate::config::write_atomic_unsynced(path, &bytes)
    }

    /// Closes the least recently written index handle of `open` but `id`'s when the writers hold
    /// as many as they may. Called before an append whose line gets an entry.
    pub(super) fn bound_index_handles(
        &self,
        open: &mut HashMap<String, SegmentWriter>,
        id: &str,
        line: &[u8],
    ) {
        let needs = open
            .get(id)
            .is_some_and(|w| !w.tx.holds_handle() && !matches!(w.tx.state, TxState::Off));
        if !self.index_transcript || !needs || !holds_line(line.strip_suffix(b"\n").unwrap_or(line))
        {
            return;
        }
        let held = open.values().filter(|w| w.tx.holds_handle()).count();
        if held < self.index_handles() {
            return;
        }
        if let Some(oldest) = open
            .iter_mut()
            .filter(|(k, w)| k.as_str() != id && w.tx.holds_handle())
            .min_by_key(|(_, w)| w.tx.used)
            .map(|(_, w)| w)
        {
            oldest.tx.file = None;
        }
    }

    /// Before `line` goes to the end of `w`'s segment: its entry, when [`holds`] names it, at the
    /// end of the segment's index (made when the segment has none). True when an entry was
    /// written. An index that cannot be written is removed, so no line goes without its entry; an
    /// error (and no line) only when that fails too.
    pub(super) fn index_line(
        &self,
        id: &str,
        w: &mut SegmentWriter,
        line: &[u8],
        clock: u64,
    ) -> Result<bool> {
        if !self.index_transcript || matches!(w.tx.state, TxState::Off) {
            return Ok(false);
        }
        let body = line.strip_suffix(b"\n").unwrap_or(line);
        if !holds_line(body) {
            return Ok(false);
        }
        let path = self.transcript_index_path(id, w.index);
        let wrote = self.start_index(id, w, &path).and_then(|()| {
            let TxState::On(header) = &mut w.tx.state else { return Ok(false) };
            if w.tx.file.is_none() {
                w.tx.file = Some(open_rw(&path)?);
            }
            let Some(file) = w.tx.file.as_ref() else { return Ok(false) };
            let Some(entry) = Entry::of(body, w.written) else {
                anyhow::bail!("a line of {} bytes is past what an entry holds", body.len());
            };
            write_at(file, &entry.encode(), HEADER + header.count * WIDTH)?;
            let mut next = *header;
            next.count += 1;
            // Every line before this one has its entry: this writer's own lines since `covered`.
            next.covered = w.written;
            write_at(file, &next.encode(), 0)?;
            *header = next;
            w.tx.used = clock;
            Ok(true)
        });
        match wrote {
            Ok(wrote) => Ok(wrote),
            Err(error) => {
                w.tx.file = None;
                match crate::home_fs::remove_file(&path) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => {
                        return Err(error.context(format!(
                            "write the transcript index {} (and remove it: {e})",
                            path.display()
                        )));
                    }
                }
                tracing::warn!(session = %id, segment = w.index, "the transcript index could not be written, so the segment is read without it: {error:#}");
                w.tx.state = TxState::Off;
                Ok(false)
            }
        }
    }

    /// Takes back the entry [`Self::index_line`] wrote for a line that was then not written (a
    /// failed append cut back). A failure leaves it: a reader reads past an entry with no line.
    pub(super) fn unindex_line(&self, w: &mut SegmentWriter) {
        let (TxState::On(header), Some(file)) = (&mut w.tx.state, w.tx.file.as_ref()) else {
            return;
        };
        let mut next = *header;
        next.count = next.count.saturating_sub(1);
        next.durable_count = next.durable_count.min(next.count);
        if write_at(file, &next.encode(), 0).is_ok() {
            *header = next;
            let _ = file.set_len(HEADER + next.count * WIDTH);
        }
    }

    /// On `w`'s first held line: opens the segment's index and heals it, or makes it.
    fn start_index(&self, id: &str, w: &mut SegmentWriter, path: &Path) -> Result<()> {
        if !matches!(w.tx.state, TxState::Unknown) {
            return Ok(());
        }
        let stamp = Stamp::of(&w.file)?;
        if stamp.id.2 == 0 {
            w.tx.state = TxState::Off;
            return Ok(());
        }
        if let Some((header, file)) = self.reopen_index(id, w, path, &stamp) {
            w.tx.state = TxState::On(header);
            w.tx.file = Some(file);
            return Ok(());
        }
        // No line this writer wrote before is held (it would have started the index): the index
        // covers from where the writer began.
        let header = Header::fresh(stamp.id, w.tx.since.min(w.written));
        self.write_index(id, path, &header, &[])?;
        w.tx.file = Some(open_rw(path)?);
        w.tx.state = TxState::On(header);
        Ok(())
    }

    /// The index at `path` when it is of `w`'s segment and can go on, made to cover all of the
    /// segment: its entries past what it trusts (`covered` in the boot that wrote it, `durable` in
    /// another) go, and the segment's lines from there to the writer's end are indexed again (a
    /// crash's lines, a daemon's without the index, lines whose entries a machine's crash lost).
    /// None when those bytes are many, or the index is not this segment's: it is made again from
    /// where the writer is.
    fn reopen_index(
        &self,
        id: &str,
        w: &SegmentWriter,
        path: &Path,
        stamp: &Stamp,
    ) -> Option<(Header, File)> {
        let file = open_rw(path).ok()?;
        let len = file.metadata().ok()?.len();
        let mut head = [0u8; HEADER as usize];
        read_at(&file, &mut head, 0).ok()?;
        let mut header = Header::decode(&head)?;
        let written = w.written;
        if header.file != stamp.id || header.from > written {
            return None;
        }
        let present = len.saturating_sub(HEADER) / WIDTH;
        let this_boot = header.boot != 0 && header.boot == boot();
        let (mut count, base) = if this_boot {
            (header.count, header.covered)
        } else {
            (header.durable_count, header.durable)
        };
        let base = base.min(written);
        if present < count || written - base > REBASE_BYTES {
            return None;
        }
        // Entries of lines from `base` on go: those lines are indexed again below.
        let mut entry = [0u8; WIDTH as usize];
        while count > 0 {
            read_at(&file, &mut entry, HEADER + (count - 1) * WIDTH).ok()?;
            if Entry::decode(&entry)?.end() <= base {
                break;
            }
            count -= 1;
        }
        let mut added = Vec::new();
        if written > base {
            let segment = self.dir(id).join("events").join(format!("{:06}.ndjson", w.index));
            let reader = crate::config::private_state_file(&segment).ok()?;
            let mut bytes = vec![0u8; usize::try_from(written - base).ok()?];
            read_at(&reader, &mut bytes, base).ok()?;
            added = entries_of(&bytes, base);
        }
        file.set_len(HEADER + count * WIDTH).ok()?;
        let mut out = Vec::with_capacity(added.len() * WIDTH as usize);
        for entry in &added {
            out.extend_from_slice(&entry.encode());
        }
        write_at(&file, &out, HEADER + count * WIDTH).ok()?;
        header.durable_count = header.durable_count.min(count);
        header.durable = header.durable.min(base).max(header.from);
        header.count = count + added.len() as u64;
        header.covered = written;
        header.boot = boot();
        write_at(&file, &header.encode(), 0).ok()?;
        Some((header, file))
    }

    /// Notes in `w`'s index that its entries cover the segment to the writer's end (the writer
    /// closes: a daemon without the index may append next). No sync.
    pub(super) fn cover_index(w: &mut SegmentWriter) {
        let written = w.written;
        let (TxState::On(header), Some(file)) = (&mut w.tx.state, w.tx.file.as_ref()) else {
            return;
        };
        if header.covered == written {
            return;
        }
        let mut next = *header;
        next.covered = written;
        if write_at(file, &next.encode(), 0).is_ok() {
            *header = next;
        }
    }

    /// Syncs `w`'s index and notes in its header that its entries cover the segment to here: what a
    /// later boot trusts. Under the writers' lock (a full segment's close, `flush`).
    pub(super) fn sync_index_locked(w: &mut SegmentWriter) {
        let written = w.written;
        let (TxState::On(header), Some(file)) = (&mut w.tx.state, w.tx.file.as_ref()) else {
            return;
        };
        if header.durable_count == header.count && header.durable == written {
            return;
        }
        if file.sync_data().is_err() {
            return;
        }
        let mut next = *header;
        next.durable = written;
        next.durable_count = next.count;
        next.covered = written;
        if write_at(file, &next.encode(), 0).is_ok() {
            *header = next;
        }
    }

    /// [`Self::sync_index_locked`] for `id`'s open segment with the disk's work off the writers'
    /// lock (the journal store's checkpoint, `LocalStore::sync_log`).
    pub(super) fn sync_index(&self, id: &str) {
        let taken = {
            let mut writers = self.writers.lock_or_recover();
            let Some(w) = writers.open.get_mut(id) else { return };
            let TxState::On(header) = &w.tx.state else { return };
            if header.durable_count == header.count && header.durable == w.written {
                return;
            }
            let (count, written, file) = (header.count, w.written, header.file);
            // A handle of its own, never kept: the writers' handles stay bounded
            // (`bound_index_handles`).
            let handle = match w.tx.file.as_ref() {
                Some(held) => held.try_clone().ok(),
                None => open_rw(&self.transcript_index_path(id, w.index)).ok(),
            };
            let Some(handle) = handle else { return };
            (w.index, file, count, written, handle)
        };
        let (index, file, count, written, handle) = taken;
        if handle.sync_data().is_err() {
            return;
        }
        let mut writers = self.writers.lock_or_recover();
        let Some(w) = writers.open.get_mut(id).filter(|w| w.index == index) else { return };
        let TxState::On(header) = &mut w.tx.state else { return };
        // Entries taken back since (`unindex_line`) or another index: the next sync notes it.
        if header.file != file || header.count < count || header.durable_count >= count {
            return;
        }
        let mut next = *header;
        next.durable = written;
        next.durable_count = count;
        next.covered = next.covered.max(written);
        if write_at(&handle, &next.encode(), 0).is_ok() {
            *header = next;
        }
    }

    /// Removes segment `index`'s transcript index (a cut of the segment, `journal_store/repair.rs`).
    pub(super) fn forget_transcript_index(&self, id: &str, index: u32) -> Result<()> {
        let path = self.transcript_index_path(id, index);
        crate::config::refuse_lost_home(&path)?;
        match crate::home_fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => {
                Err(anyhow::Error::from(error).context(format!("remove {}", path.display())))
            }
        }
    }

    /// The index of segment `index` (at `segment`, read with stamp `stamp`) a read made of the
    /// whole segment, `entries` newest first: written under a temporary name off every lock, then
    /// renamed in under the writers' lock, only while the segment is no writer's and is still the
    /// file read, as long, and has no good index.
    fn write_read_index(
        &self,
        id: &str,
        index: u32,
        segment: &Path,
        stamp: &Stamp,
        mut entries: Vec<Entry>,
    ) {
        // One such write at a time in this process: its temporary name is one per index and
        // process (`config.rs` `write_atomic_with` says why).
        static ONE: std::sync::Mutex<()> = std::sync::Mutex::new(());
        entries.reverse();
        let count = entries.len() as u64;
        let header = Header {
            file: stamp.id,
            from: 0,
            boot: boot(),
            durable: stamp.len,
            durable_count: count,
            count,
            covered: stamp.len,
        };
        let path = self.transcript_index_path(id, index);
        let _one = ONE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let tmp = path.with_extension(format!("read-{}", std::process::id()));
        if let Err(e) = self.write_index(id, &tmp, &header, &entries) {
            tracing::debug!(session = %id, segment = index, "saving the transcript index a read made failed: {e:#}");
            let _ = crate::home_fs::remove_file(&tmp);
            return;
        }
        let renamed = (|| {
            let _open = self.writable().ok()?;
            let writers = self.writers.lock_or_recover();
            if writers.open.get(id).is_some_and(|w| w.index == index) {
                return None;
            }
            let same = crate::config::private_state_file(segment)
                .and_then(|file| Ok(Stamp::of(&file)?))
                .is_ok_and(|now| now.id == stamp.id && now.len == stamp.len);
            if !same || trusted(&path, stamp).is_some() {
                return None;
            }
            crate::home_fs::rename(&tmp, &path).ok()
        })();
        if renamed.is_none() {
            let _ = crate::home_fs::remove_file(&tmp);
        }
    }

    /// `scan_back` for a page whose `skip` passes only lines [`holds`] names (module docs):
    /// segments newest first; one with a good index reads its entries' lines (and the bytes the
    /// index does not cover the old way), one without is read back from `before` as `scan_back`
    /// reads it, and indexed when the read passed all of it.
    pub(super) fn scan_back_transcript_in(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let done = std::cell::Cell::new(false);
        // One line, newest first, as `scan_back_in` reads it: false once the read is over.
        let mut line = |line: &[u8]| {
            match record_seq(line) {
                Some(seq) if seq >= before => return true,
                Some(seq) if seq <= after => {
                    done.set(true);
                    return false;
                }
                _ => {}
            }
            if let (Some(dir), Some(kind)) = (record_dir(line), record_kind(line))
                && skip(dir, kind)
            {
                return true;
            }
            let Ok(rec) = parse_record(line) else { return true };
            if rec.seq >= before {
                return true;
            }
            if rec.seq <= after || !visit(rec) {
                done.set(true);
                return false;
            }
            true
        };
        let segments = self.segments(id)?;
        let last = segments.last().map(|(index, _)| *index);
        for (index, path) in segments.into_iter().rev() {
            if first_seq(&path)?.is_some_and(|first| first >= before) {
                continue;
            }
            let mut file = crate::config::private_state_file(&path)?;
            let stamp = Stamp::of(&file)?;
            match trusted(&self.transcript_index_path(id, index), &stamp) {
                Some(kept) => read_indexed(&mut file, stamp.len, &kept, before, &mut line, &done)?,
                None => {
                    let end = offset_of_seq(&mut file, before)?;
                    // The segment still written to is indexed by its writer; any other is
                    // indexed by this read: the lines it visits, then (once the page is full) the
                    // rest of the segment, its heads only. At most one segment more than the read
                    // takes, once: a page that stops in a segment no longer reads it the old way
                    // on every scroll.
                    let mut made = (Some(index) != last && stamp.id.2 != 0).then(Vec::new);
                    let mut stop = end;
                    // A last line with no newline is a torn append: no index is made of it.
                    let mut torn = false;
                    for_each_line_rev_at(&mut file, 0, end, &mut |offset, text| {
                        stop = offset;
                        torn |= offset + text.len() as u64 >= stamp.len;
                        if let Some(entries) = made.as_mut()
                            && holds_line(text)
                            && let Some(entry) = Entry::of(text, offset)
                        {
                            entries.push(entry);
                        }
                        line(text)
                    })?;
                    if let Some(mut entries) = made.filter(|_| !torn) {
                        let mut collect = |into: &mut Vec<Entry>, from: u64, to: u64| {
                            for_each_line_rev_at(&mut file, from, to, &mut |offset, text| {
                                if offset + text.len() as u64 >= stamp.len {
                                    torn = true;
                                    return false;
                                }
                                if holds_line(text)
                                    && let Some(entry) = Entry::of(text, offset)
                                {
                                    into.push(entry);
                                }
                                true
                            })
                        };
                        let mut newer = Vec::new();
                        collect(&mut newer, end, stamp.len)?;
                        if done.get() {
                            collect(&mut entries, 0, stop)?;
                        }
                        if !torn {
                            newer.append(&mut entries);
                            self.write_read_index(id, index, &path, &stamp, newer);
                        }
                    }
                }
            }
            if done.get() {
                return Ok(());
            }
        }
        Ok(())
    }
}

/// One segment of `len` bytes read through its index `index`, newest first: the bytes past what
/// the index covers the old way, then its entries' lines below `before`, then the bytes before
/// its `from` the old way. A damaged entry ends the index's part: the segment below the last line
/// read through it is read the old way.
fn read_indexed(
    file: &mut File,
    len: u64,
    index: &Trusted,
    before: u64,
    line: &mut dyn FnMut(&[u8]) -> bool,
    done: &std::cell::Cell<bool>,
) -> Result<()> {
    let from = index.header.from;
    let to = index.to.min(len);
    if to < len {
        let end = if before != u64::MAX && len - to > TAIL_SEEK_BYTES {
            offset_of_seq(file, before)?.clamp(to, len)
        } else {
            len
        };
        for_each_line_rev_between(file, to, end, line)?;
        if done.get() {
            return Ok(());
        }
    }
    // Every line read through the index ends at or before `bound`, the start of the last one:
    // a line is read once, however many entries name it.
    let mut bound = to;
    let mut left = index.entries;
    let mut group: Vec<Entry> = Vec::new();
    let mut damaged = false;
    // Reads `group`'s lines in one read and passes each that is the line its entry names.
    let mut flush = |group: &mut Vec<Entry>, bound: &mut u64| -> std::io::Result<bool> {
        let (Some(lo), Some(hi)) =
            (group.iter().map(|e| e.offset).min(), group.iter().map(Entry::end).max())
        else {
            return Ok(true);
        };
        let base = lo.saturating_sub(1);
        let mut bytes = vec![0u8; usize::try_from(hi - base).unwrap_or(0)];
        read_at(file, &mut bytes, base)?;
        for entry in group.drain(..) {
            if entry.end() > *bound {
                continue;
            }
            let Some(text) = whole_line(&bytes, base, &entry) else { continue };
            *bound = entry.offset;
            if !line(text) {
                return Ok(false);
            }
        }
        Ok(true)
    };
    'blocks: while left > 0 {
        let n = left.min(ENTRY_BLOCK);
        left -= n;
        let mut block = vec![0u8; usize::try_from(n * WIDTH).unwrap_or(0)];
        if read_at(&index.file, &mut block, HEADER + left * WIDTH).is_err() {
            damaged = true;
            break;
        }
        for raw in block.chunks_exact(WIDTH as usize).rev() {
            let Some(entry) = Entry::decode(raw) else {
                damaged = true;
                break 'blocks;
            };
            if entry.offset < from || entry.end() > to || entry.len == 0 {
                continue;
            }
            if entry.flags & NO_SEQ == 0 && entry.seq >= before {
                continue;
            }
            // Read with the group when near it, else the group first.
            if let (Some(lo), Some(hi)) =
                (group.iter().map(|e| e.offset).min(), group.iter().map(Entry::end).max())
            {
                let near = entry.end().saturating_add(NEAR) >= lo
                    && entry.offset <= hi.saturating_add(NEAR);
                let span = hi.max(entry.end()) - lo.min(entry.offset);
                if (!near || span > READ_SPAN) && !flush(&mut group, &mut bound)? {
                    return Ok(());
                }
            }
            group.push(entry);
        }
    }
    if !flush(&mut group, &mut bound)? {
        return Ok(());
    }
    let rest = if damaged { bound } else { from };
    if rest > 0 {
        for_each_line_rev_between(file, 0, rest, line)?;
    }
    Ok(())
}

/// The line `entry` names in `bytes` (the segment from offset `base`), without its newline, when
/// those bytes are one whole line with the entry's seq; None for an entry a crash or a cut left.
fn whole_line<'a>(bytes: &'a [u8], base: u64, entry: &Entry) -> Option<&'a [u8]> {
    let start = usize::try_from(entry.offset.checked_sub(base)?).ok()?;
    let end = start.checked_add(usize::try_from(entry.len).ok()?)?;
    if entry.offset > 0 && bytes.get(start.checked_sub(1)?) != Some(&b'\n') {
        return None;
    }
    let (newline, text) = bytes.get(start..end)?.split_last()?;
    if *newline != b'\n' || memchr::memchr(b'\n', text).is_some() {
        return None;
    }
    if entry.flags & NO_SEQ == 0 && record_seq(text) != Some(entry.seq) {
        return None;
    }
    Some(text)
}

#[cfg(test)]
#[path = "transcript_index_tests.rs"]
mod tests;
