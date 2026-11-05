//! A log segment's messages as `_acpmux/session_search` reads them (`session_search.rs`), kept
//! beside the log as the kind index keeps its records (`store/kind_index.rs`).
//!
//! The text a search looks in is a small part of a log: a 25,000-record, 18 MB Claude log holds
//! about 1 MB of prompts, replies and tool titles, and the replies are logged a few words per
//! `agent_message_chunk` record. So a search writes each segment's messages, chunks joined, to
//! `<session>/search-index/NNNNNN.ndjson` (one `Entry` per line under a header naming the segment
//! file and how many of its bytes they cover), and a later search reads the copy, then the segment
//! past those bytes only. A reply still being written at the copy's end stays open (the header's
//! `open`) and takes the chunks that follow.
//!
//! The rules are the kind index's: a copy of another file (a segment replaced by retention, an
//! inode reused), of another schema, longer than its segment, or damaged is read past and made
//! again; it is written whole under a temporary name and renamed into place; it is written only
//! when there was none or a search read at least [`super::kind_index::COPY_AFTER`] bytes past it,
//! never on the append path; a chat's folder is deleted with it. Messages do not run across
//! segments: a reply cut by a segment's start is two messages.

use super::kind_index::{COPY_AFTER, Stamp, fnv};
use super::*;
use crate::session_search::{Entry, KINDS, Projector};

/// The folder of a chat's text copies, beside its `events`.
pub const DIR: &str = "search-index";
const SCHEMA: &str = "acpmux.search-index.v1";

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Header {
    schema: String,
    dev: u64,
    ino: u64,
    born_ns: u64,
    /// The bytes of the segment the entries cover.
    len: u64,
    /// The last entry's `messageId` while it still takes chunks ([`Projector::open`]).
    open: Option<String>,
    lines_len: u64,
    /// FNV-1a of the other fields and the lines: a damaged or cut copy is read past.
    lines_hash: u64,
}

fn seal(id: (u64, u64, u64), len: u64, open: Option<&str>, lines: &[u8]) -> u64 {
    let fields = [id.0, id.1, id.2, len, u64::try_from(lines.len()).unwrap_or(u64::MAX)];
    let open = open.map_or(&[0xff_u8][..], str::as_bytes);
    fnv(fields
        .iter()
        .flat_map(|f| f.to_le_bytes())
        .chain(open.iter().copied())
        .chain(lines.iter().copied()))
}

/// Whether a log line may hold a message: its kind is one of [`KINDS`], or its head does not say.
fn wanted(line: &[u8]) -> bool {
    record_kind(line).is_none_or(|kind| KINDS.iter().any(|k| k.as_bytes() == kind))
}

impl LocalStore {
    fn text_index_path(&self, id: &str, index: u32) -> PathBuf {
        self.dir(id).join(DIR).join(format!("{index:06}.ndjson"))
    }

    /// [`Store::text_entries`]: each segment's copy, then the segment past it.
    pub(super) fn text_entries_in(&self, id: &str, visit: &mut dyn FnMut(Entry)) -> Result<()> {
        for (index, path) in self.segments(id)? {
            self.text_segment(id, index, &path)?.into_iter().for_each(&mut *visit);
        }
        Ok(())
    }

    /// One segment's messages, its copy saved again when the read went far past it.
    fn text_segment(&self, id: &str, index: u32, path: &Path) -> Result<Vec<Entry>> {
        let mut file = crate::config::private_state_file(path)?;
        let stamp = Stamp::of(&file)?;
        let (mut projector, from, had_copy) = match self.read_text_index(id, index, &stamp) {
            Some((entries, len, open)) => (Projector { entries, open }, len, true),
            None => (Projector::default(), 0, false),
        };
        if from > 0 {
            std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(from))?;
        }
        let mut covered = 0_u64;
        let mut reader = BufReader::with_capacity(256 * 1024, file);
        let mut line = Vec::new();
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line)? == 0 {
                break;
            }
            // A line still being written ends the read: the copy covers none of it.
            if !line.ends_with(b"\n") {
                break;
            }
            covered = covered.saturating_add(u64::try_from(line.len()).unwrap_or(u64::MAX));
            if wanted(&line)
                && let Ok(rec) = parse_record(&line)
            {
                projector.feed(&rec);
            }
        }
        if (!had_copy || covered >= COPY_AFTER)
            && let Err(e) =
                self.write_text_index(id, index, &stamp, from.saturating_add(covered), &projector)
        {
            tracing::warn!(session = %id, segment = index, "saving the log's text index failed: {e}");
        }
        Ok(projector.entries)
    }

    /// Segment `index`'s copied entries, the bytes of it they cover, and the open reply, when
    /// the copy is of the file `segment` and this schema, no longer than it, and whole. A system
    /// that names no birth time keeps no copy, as for the kind index.
    fn read_text_index(
        &self,
        id: &str,
        index: u32,
        segment: &Stamp,
    ) -> Option<(Vec<Entry>, u64, Option<String>)> {
        let mut bytes = Vec::new();
        crate::config::private_state_file(&self.text_index_path(id, index))
            .ok()?
            .read_to_end(&mut bytes)
            .ok()?;
        let end = bytes.iter().position(|b| *b == b'\n')?;
        let header: Header = serde_json::from_slice(bytes.get(..end)?).ok()?;
        let lines = bytes.get(end.saturating_add(1)..)?;
        let file = (header.dev, header.ino, header.born_ns);
        let whole = u64::try_from(lines.len()).unwrap_or(u64::MAX) == header.lines_len
            && seal(file, header.len, header.open.as_deref(), lines) == header.lines_hash;
        let same = header.schema == SCHEMA && segment.id.2 != 0 && file == segment.id;
        if !(same && whole && segment.len >= header.len) {
            return None;
        }
        let mut entries = Vec::new();
        for line in lines.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
            entries.push(serde_json::from_slice::<Entry>(line).ok()?);
        }
        Some((entries, header.len, header.open))
    }

    fn write_text_index(
        &self,
        id: &str,
        index: u32,
        segment: &Stamp,
        len: u64,
        projector: &Projector,
    ) -> Result<()> {
        let (dev, ino, born_ns) = segment.id;
        if born_ns == 0 {
            return Ok(());
        }
        // Never makes the chat's folder: a search that outlived a delete leaves none behind.
        let dir = self.dir(id).join(DIR);
        let mut made = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut made, 0o700);
        if let Err(e) = made.create(&dir)
            && e.kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(e.into());
        }
        crate::config::private_state_dir(&dir)?;
        let mut lines = Vec::new();
        for entry in &projector.entries {
            serde_json::to_writer(&mut lines, entry)?;
            lines.push(b'\n');
        }
        let open = projector.open.clone();
        let header = Header {
            schema: SCHEMA.into(),
            dev,
            ino,
            born_ns,
            len,
            lines_len: u64::try_from(lines.len()).unwrap_or(u64::MAX),
            lines_hash: seal(segment.id, len, open.as_deref(), &lines),
            open,
        };
        let mut out = serde_json::to_vec(&header)?;
        out.push(b'\n');
        out.extend_from_slice(&lines);
        write_atomic(&self.text_index_path(id, index), &out)
    }
}

#[cfg(test)]
#[path = "text_index_tests.rs"]
mod tests;
