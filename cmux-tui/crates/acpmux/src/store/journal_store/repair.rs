//! Recovery: the replay of the records after the checkpoint and the repair of each chat's log
//! ([module docs](super), DESIGN.md 3.3c).

use super::*;
use cmux_journal::Record;

#[cfg(test)]
thread_local! {
    /// Tests: a repair on this thread stops the open with an error right after it cut a log, as a
    /// crash there would.
    pub(crate) static STOP_AFTER_CUT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The records after the checkpoint, by chat.
#[derive(Default)]
pub(super) struct Replay {
    chats: BTreeMap<String, Vec<(Lsn, Vec<u8>)>>,
    /// Each chat's newest metadata image after its last `forget` (S3a, `journal_store/meta.rs`).
    pub(super) metas: BTreeMap<String, super::meta::Replayed>,
}

impl Replay {
    pub(super) fn take(&mut self, record: Record<'_>) -> std::result::Result<(), String> {
        match record.kind {
            KIND_LOG => {
                let (chat, line) = decode_log(record.payload)
                    .ok_or_else(|| format!("log record {} does not read", record.lsn))?;
                self.chats.entry(chat).or_default().push((record.lsn, line.to_vec()));
            }
            // The chat's earlier lines are not its own any more: a chat made again under the same
            // id gets only the lines after this.
            KIND_FORGET => {
                let chat = std::str::from_utf8(record.payload)
                    .map_err(|_| format!("forget record {} does not read", record.lsn))?;
                self.chats.entry(chat.to_owned()).or_default().clear();
                self.metas.remove(chat);
            }
            super::meta::KIND_META => self.take_meta(&record)?,
            other => return Err(format!("unknown event journal record kind {other}")),
        }
        Ok(())
    }
}

/// What a repair did with one chat's log.
enum Repaired {
    /// It holds every journaled line now (nothing was missing, or they were written).
    Done,
    /// Its folder is gone: the chat was deleted, or lost with its `session.json`. Not written.
    Gone,
    /// The log moved on without the journal: left as it is.
    MovedOn(String),
}

/// Why a repair stopped.
enum RepairError {
    /// The chat's log could not be read or written; `keep` are the lines that only the journal
    /// may hold now.
    Chat { error: anyhow::Error, keep: Vec<Vec<u8>> },
    /// Tests: stopped right after its cut, as a crash would.
    #[cfg(test)]
    Stopped,
}

/// One piece of a log read back from a repair's start: a whole line with its `seq`, or bytes
/// that do not read (a torn tail, a hole of zeros, a line that does not parse).
struct Piece {
    segment: u32,
    offset: u64,
    line: Option<(u64, Vec<u8>)>,
}

impl Inner {
    /// Writes the replayed records' effects to the logs and the chats' metadata
    /// ([module docs](self)). One chat's failure
    /// keeps its lines in `journal-unapplied/` and the open goes on; only a failure to keep them
    /// fails it.
    pub(super) fn apply(&self, replay: Replay) -> Result<()> {
        let Replay { chats, metas } = replay;
        // The metadata, then the logs. Neither makes a folder that is gone (`meta.rs`).
        self.apply_metas(metas)?;
        for (chat, journaled) in chats {
            let Some(first_lsn) = journaled.first().map(|(lsn, _)| *lsn) else { continue };
            match self.repair(&chat, &journaled) {
                Ok(Repaired::Done) => {
                    self.order.lock_or_recover().dirty.insert(chat);
                }
                Ok(Repaired::Gone) => {
                    tracing::info!(session = %chat, "journaled lines of a chat whose folder is gone: not written again");
                }
                Ok(Repaired::MovedOn(why)) => {
                    let lines: Vec<Vec<u8>> = journaled.into_iter().map(|(_, line)| line).collect();
                    let kept = self.keep_aside(&chat, first_lsn, &lines)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "the chat's log moved on without the event journal ({why}); left as it is");
                }
                Err(RepairError::Chat { error, keep }) => {
                    let kept = self.keep_aside(&chat, first_lsn, &keep)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "the chat's log could not be repaired: {error:#}");
                }
                #[cfg(test)]
                Err(RepairError::Stopped) => anyhow::bail!("stopped after the cut (a test)"),
            }
        }
        let mut order = self.order.lock_or_recover();
        order.applied = self.journal.last_lsn();
        Ok(())
    }

    /// Repairs `id`'s log with its journaled lines (`journaled`, in LSN order): it never deletes a
    /// whole line or a folder.
    ///
    /// The log is read from just after its last line with a `seq` below the first journaled one
    /// (the repair start). Its lines and the journal's merge by `seq`: a line in both must be the
    /// same bytes; a line only the log has stays; a line only the journal has goes in its place.
    /// A line is a whole JSON line: bytes that do not parse (a torn tail, a hole of zeros, a line
    /// a hole ran into a later one) are not a line and go.
    ///
    /// Every merged line is written again from the repair start, even when the log has them all:
    /// a killed daemon's log writes may be in the page cache only, and after a failed sync the
    /// kernel may have dropped pages it still shows and that a later sync reports as written. So
    /// the first checkpoint after this open syncs bytes this process wrote before it retires their
    /// records (review 2 of #34901, finding 1). The lines that only the log has from the repair
    /// start are journaled and made durable first; then the log is cut there and the merged lines
    /// written, so a crash at any step loses no line: the next open repairs the same way.
    fn repair(
        &self,
        id: &str,
        journaled: &[(Lsn, Vec<u8>)],
    ) -> std::result::Result<Repaired, RepairError> {
        let keep_journaled = || journaled.iter().map(|(_, line)| line.clone()).collect::<Vec<_>>();
        let chat_error = |error: anyhow::Error| RepairError::Chat { error, keep: keep_journaled() };
        match std::fs::symlink_metadata(self.local.dir(id)) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Repaired::Gone);
            }
            Err(error) => return Err(chat_error(error.into())),
        }
        let mut wanted: BTreeMap<u64, &[u8]> = BTreeMap::new();
        for (_, line) in journaled {
            let Some(seq) = line_seq(line) else {
                return Ok(Repaired::MovedOn("a journaled line has no seq".into()));
            };
            if wanted.insert(seq, line).is_some_and(|other| other != line.as_slice()) {
                return Ok(Repaired::MovedOn(format!("two journaled lines with seq {seq}")));
            }
        }
        let Some(&first) = wanted.keys().next() else { return Ok(Repaired::Done) };
        let pieces = self.read_from(id, first).map_err(chat_error)?;
        let mut merged = wanted.clone();
        let mut last = None;
        for (seq, bytes) in pieces.iter().filter_map(|piece| piece.line.as_ref()) {
            if last.is_some_and(|last| *seq <= last) {
                return Ok(Repaired::MovedOn(format!("its line {seq} is out of seq order")));
            }
            last = Some(*seq);
            if wanted.get(seq).is_some_and(|held| *held != bytes.as_slice()) {
                return Ok(Repaired::MovedOn(format!("its line {seq} differs from the journal's")));
            }
            merged.insert(*seq, bytes);
        }
        let merged: Vec<(u64, &[u8])> = merged.into_iter().collect();
        let keep_merged = || merged.iter().map(|(_, line)| line.to_vec()).collect::<Vec<_>>();
        if let Some(start) = pieces.first() {
            // The lines only the log holds from the repair start: into the journal first.
            let only_logged: Vec<&[u8]> = merged
                .iter()
                .filter(|(seq, _)| !wanted.contains_key(seq))
                .map(|(_, line)| *line)
                .collect();
            self.journal_lines(id, &only_logged).map_err(chat_error)?;
            self.cut_at(id, start.segment, start.offset)
                .map_err(|error| RepairError::Chat { error, keep: keep_merged() })?;
            #[cfg(test)]
            if STOP_AFTER_CUT.with(std::cell::Cell::get) {
                return Err(RepairError::Stopped);
            }
        }
        for (_, line) in &merged {
            self.local
                .append_line(id, line)
                .map_err(|error| RepairError::Chat { error, keep: keep_merged() })?;
        }
        Ok(Repaired::Done)
    }

    /// Appends `lines` of chat `id` to the journal and waits until they are durable.
    fn journal_lines(&self, id: &str, lines: &[&[u8]]) -> Result<()> {
        let mut last = None;
        for line in lines {
            let lsn = self
                .journal
                .append(KIND_LOG, Class::Ack, &encode_log(id, line))
                .map_err(|error| anyhow::anyhow!("journal a line only the log held: {error}"))?;
            last = Some(lsn);
        }
        if let Some(lsn) = last {
            self.journal
                .wait_durable(lsn, REPAIR_WAIT)
                .map_err(|error| anyhow::anyhow!("journal the lines only the log held: {error}"))?;
        }
        Ok(())
    }

    /// The pieces of `id`'s log from just after its last whole line with a `seq` below `first`.
    fn read_from(&self, id: &str, first: u64) -> Result<Vec<Piece>> {
        let segments = self.local.segments(id)?;
        // The last segment whose first readable line is below `first`; else the first segment.
        let mut start = 0usize;
        for (at, (_, path)) in segments.iter().enumerate().rev() {
            if first_seq(path)?.is_some_and(|seq| seq < first) {
                start = at;
                break;
            }
        }
        let mut pieces = Vec::new();
        for (at, (index, path)) in segments.iter().enumerate().skip(start) {
            let from = if at == start { end_of_last_line_before(path, first)? } else { 0 };
            read_pieces(path, *index, from, &mut pieces)?;
        }
        Ok(pieces)
    }

    /// Cuts `id`'s log at `offset` of segment `segment`: later segments go, and that one is
    /// shortened. The kind-index copy of each segment that changes goes first, durably: a crash
    /// between a cut and its copy's removal would leave a copy that a log written back to the same
    /// length passes for current. The removals are durable before the merged lines are written
    /// again: else a crash could bring a removed segment back beside them.
    fn cut_at(&self, id: &str, segment: u32, offset: u64) -> Result<()> {
        let segments = self.local.segments(id)?;
        for (index, _) in segments.iter().filter(|(index, _)| *index >= segment) {
            self.forget_index_copy(id, *index)?;
        }
        sync_if_there(&self.local.dir(id).join(kind_index::DIR))?;
        for (index, path) in segments.iter().rev() {
            if *index > segment {
                crate::config::refuse_lost_home(path)?;
                std::fs::remove_file(path).with_context(|| format!("remove {}", path.display()))?;
            } else if *index == segment {
                truncate_private(path, offset)?;
            }
        }
        sync_directory(&self.local.dir(id).join("events"))
    }

    fn forget_index_copy(&self, id: &str, index: u32) -> Result<()> {
        let copy = self.local.dir(id).join(kind_index::DIR).join(format!("{index:06}.ndjson"));
        crate::config::refuse_lost_home(&copy)?;
        match std::fs::remove_file(&copy) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => {
                Err(anyhow::Error::from(error).context(format!("remove {}", copy.display())))
            }
        }
    }

    /// Keeps `lines` of chat `id` (its journaled lines from LSN `first_lsn` on) in
    /// `<home>/journal-unapplied/<id>.<first_lsn>.ndjson`, owner-only and synced, and returns
    /// that path.
    fn keep_aside(&self, id: &str, first_lsn: Lsn, lines: &[Vec<u8>]) -> Result<PathBuf> {
        let dir = self.home.join(UNAPPLIED_DIR);
        crate::config::refuse_lost_home(&dir)?;
        crate::config::private_state_dir(&dir)?;
        let name: String = id
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') { c } else { '_' })
            .collect();
        let path = dir.join(format!("{name}.{first_lsn}.ndjson"));
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&path).with_context(|| format!("write {}", path.display()))?;
        for line in lines {
            file.write_all(line)?;
        }
        file.sync_all()?;
        drop(file);
        sync_directory(&dir)?;
        Ok(path)
    }
}

/// Reads `path` (segment `segment`) from `from` into `out`, piece by piece.
fn read_pieces(path: &Path, segment: u32, from: u64, out: &mut Vec<Piece>) -> Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut file = crate::config::private_state_file(path)?;
    file.seek(SeekFrom::Start(from))?;
    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    let mut offset = from;
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            return Ok(());
        }
        let len = u64::try_from(read).unwrap_or(u64::MAX);
        let whole = line.last() == Some(&b'\n');
        // A hole of zeros an OS crash left runs into the next line: the zeros are one piece, the
        // line after them another.
        let zeros = line.iter().take_while(|byte| **byte == 0).count();
        let after_zeros = line.get(zeros..).unwrap_or_default();
        if whole && let Some(seq) = piece_seq(&line) {
            out.push(Piece { segment, offset, line: Some((seq, line.clone())) });
        } else if whole
            && zeros > 0
            && let Some(seq) = piece_seq(after_zeros)
        {
            out.push(Piece { segment, offset, line: None });
            let at = offset.saturating_add(u64::try_from(zeros).unwrap_or(u64::MAX));
            out.push(Piece { segment, offset: at, line: Some((seq, after_zeros.to_vec())) });
        } else {
            out.push(Piece { segment, offset, line: None });
        }
        offset = offset.saturating_add(len);
    }
}

/// The `seq` of a piece that is one whole JSON line; `None` for bytes that are not. A hole an OS
/// crash left inside a line runs that line into a later one's tail: it keeps the first line's
/// `{"seq":N,` head but is not JSON (review 2 of #34901, finding 2).
fn piece_seq(line: &[u8]) -> Option<u64> {
    serde_json::from_slice::<serde::de::IgnoredAny>(line).ok()?;
    line_seq(line)
}

/// Syncs the folder at `path`; nothing when it is not there.
fn sync_if_there(path: &Path) -> Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => sync_directory(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(anyhow::Error::from(error).context(format!("stat {}", path.display()))),
    }
}

/// The offset right after the last whole line of `path` whose `seq` reads and is below
/// `from_seq`; 0 when there is none.
fn end_of_last_line_before(path: &Path, from_seq: u64) -> Result<u64> {
    let mut reader = BufReader::new(crate::config::private_state_file(path)?);
    let mut line = Vec::new();
    let (mut offset, mut keep) = (0u64, 0u64);
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            return Ok(keep);
        }
        offset = offset.saturating_add(u64::try_from(read).unwrap_or(u64::MAX));
        if line.last() != Some(&b'\n') {
            return Ok(keep);
        }
        if line_seq(&line).is_some_and(|seq| seq < from_seq) {
            keep = offset;
        }
    }
}

/// Shortens the log segment at `path` (owner-only, never through a symlink) and syncs it.
fn truncate_private(path: &Path, len: u64) -> Result<()> {
    crate::config::refuse_lost_home(path)?;
    let mut options = OpenOptions::new();
    options.write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).with_context(|| format!("open {}", path.display()))?;
    file.set_len(len).with_context(|| format!("shorten {}", path.display()))?;
    #[cfg(all(test, unix))]
    sync_model::cut(&file, len);
    log_sync::sync_segment(&file, true)?;
    Ok(())
}
