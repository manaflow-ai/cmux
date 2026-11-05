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
    /// A `frozen` record was replayed: a run after the checkpoint had a sync fail.
    pub(super) frozen: bool,
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
            KIND_FROZEN => self.frozen = true,
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

/// A log segment's range that the open's repair read and found equal to the journal's merged
/// lines: the segment's file id when it was read, the range's start, and its bytes
/// (`Order::read_segments`). The checkpoint writes these bytes back over the range, then syncs
/// ([`Inner::rewrite_verified`]), only while the same file is there and still reaches the range.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Verified {
    pub(super) ino: u64,
    pub(super) offset: u64,
    pub(super) bytes: Vec<u8>,
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
        // `frozen` was read at the open into `Order::rewrite_all`, which `repair` reads for every
        // replayed chat: a replayed freeze makes the open write every chat's lines again.
        let Replay { chats, metas, frozen: _ } = replay;
        let replayed: Vec<String> = chats
            .iter()
            .filter(|(_, lines)| !lines.is_empty())
            .map(|(chat, _)| chat.clone())
            .collect();
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
                    // Kept for the next open, which journals them again and repairs the chat; the
                    // checkpoint of every other chat goes on ([`Inner::take_repairs`]).
                    let kept = self.keep_for_repair(&chat, first_lsn, &keep)?;
                    self.order.lock_or_recover().repairs.insert(chat.clone(), kept.clone());
                    tracing::error!(session = %chat, kept = %kept.display(), "the chat's log could not be repaired; the next start tries again with its kept lines: {error:#}");
                }
                #[cfg(test)]
                Err(RepairError::Stopped) => anyhow::bail!("stopped after the cut (a test)"),
            }
        }
        let mut order = self.order.lock_or_recover();
        order.applied = self.journal.last_lsn();
        // Every replayed chat has records past the checkpoint (the replay's, and the lines its
        // repair journaled again): an upper bound for each.
        let newest = order.applied;
        for chat in replayed {
            order.log_lsn.insert(chat, newest);
        }
        Ok(())
    }

    /// Repairs `id`'s log with its journaled lines (`journaled`, in LSN order): it never deletes a
    /// whole line or a folder.
    ///
    /// The log is read from just after its last line with a `seq` below the first journaled one
    /// (the repair start). A log that already holds every merged line in order, with nothing
    /// torn, is left as it is; its segments are synced by the next checkpoint (below). Its lines and the journal's merge by `seq`: a line in both must be the
    /// same bytes; a line only the log has stays; a line only the journal has goes in its place.
    /// A line is a whole JSON line: bytes that do not parse (a torn tail, a hole of zeros, a line
    /// a hole ran into a later one) are not a line and go.
    ///
    /// Otherwise every merged line is written again from the repair start; also when the
    /// previous run froze (a failed sync: the kernel may have dropped pages it still shows and
    /// that a later sync reports as written), which a replayed `frozen` record says, and for a
    /// chat whose lines come from a repair file. Either way the first
    /// checkpoint after this open syncs the bytes before it retires their records (review 2 of
    /// #34901, finding 1). The lines that only the log has from the repair
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
        // The log already holds every merged line, in order, with nothing torn among them: it
        // stays as it is, and the next checkpoint syncs the segments read here before it retires
        // their records (a killed daemon's writes may be in the page cache only). After a frozen
        // run (`rewrite_all`), the kernel may have dropped pages that still read back, so every
        // replayed chat's lines are written again, as are those of a chat whose earlier repair
        // failed (its repair file's).
        let rewrite = {
            let order = self.order.lock_or_recover();
            order.rewrite_all || order.rewrite.contains(id)
        };
        let whole = pieces.len() == merged.len()
            && pieces.iter().zip(&merged).all(|(piece, (seq, line))| {
                piece
                    .line
                    .as_ref()
                    .is_some_and(|(at, bytes)| at == seq && bytes.as_slice() == *line)
            });
        if whole && !rewrite {
            // Each segment's verified range: from its first piece to its last piece's end, the
            // pieces' bytes in order (they are contiguous: `read_pieces` reads every byte).
            let mut read: BTreeMap<PathBuf, Verified> = BTreeMap::new();
            for (index, path) in self.local.segments(id).map_err(chat_error)? {
                let mut verified: Option<Verified> = None;
                for piece in pieces.iter().filter(|piece| piece.segment == index) {
                    let Some((_, line)) = &piece.line else { continue };
                    let range = verified.get_or_insert_with(|| Verified {
                        ino: 0,
                        offset: piece.offset,
                        bytes: Vec::new(),
                    });
                    range.bytes.extend_from_slice(line);
                }
                if let Some(mut range) = verified {
                    range.ino = file_ino(&path).map_err(chat_error)?;
                    read.insert(path, range);
                }
            }
            self.order.lock_or_recover().read_segments.extend(read);
            return Ok(Repaired::Done);
        }
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
                .append_waiting(&encode_log(id, line))
                .context("journal a line only the log held")?;
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
        log_sync::sync_directory_ordered(&self.local.dir(id).join("events"))
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
    /// that path: for a person, nothing applies it.
    fn keep_aside(&self, id: &str, first_lsn: Lsn, lines: &[Vec<u8>]) -> Result<PathBuf> {
        self.write_kept(id, &format!("{first_lsn}.ndjson"), None, lines)
    }

    /// Keeps the lines of chat `id`, whose repair failed (its log could not be read or written),
    /// in its repair file `<home>/journal-unapplied/<id>.<first_lsn>.repair.ndjson` (a header
    /// line with the chat's id and its folder's identity, then the lines), owner-only and synced:
    /// a later open journals them again and repairs the chat with them, but only in that same
    /// folder ([`Inner::take_repairs`]). With no folder to bind them to, they are kept for a
    /// person, as any line the store cannot apply.
    fn keep_for_repair(&self, id: &str, first_lsn: Lsn, lines: &[Vec<u8>]) -> Result<PathBuf> {
        let Ok(Some(folder)) = super::meta::folder_id(&self.local.dir(id)) else {
            return self.keep_aside(id, first_lsn, lines);
        };
        let header = serde_json::to_vec(
            &serde_json::json!({ "schema": REPAIR_SCHEMA, "chat": id, "folder": folder }),
        )?;
        self.write_kept(id, &format!("{first_lsn}{REPAIR_SUFFIX}"), Some(&header), lines)
    }

    /// Writes `<home>/journal-unapplied/<id>.<rest>` whole: `header` (a line) and `lines`,
    /// owner-only, into a temporary copy that is synced and renamed into place, then the folder
    /// synced. A crash leaves the file whole or not there (review of #35562, D2: a file written in
    /// place could keep a torn last line); not there, its lines are still in the journal, as no
    /// checkpoint ran after it.
    fn write_kept(
        &self,
        id: &str,
        rest: &str,
        header: Option<&[u8]>,
        lines: &[Vec<u8>],
    ) -> Result<PathBuf> {
        let dir = self.home.join(UNAPPLIED_DIR);
        crate::config::refuse_lost_home(&dir)?;
        crate::config::private_state_dir(&dir)?;
        let name: String = id
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') { c } else { '_' })
            .collect();
        let path = dir.join(format!("{name}.{rest}"));
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let rest = rest.strip_suffix(".ndjson").unwrap_or(rest);
        let tmp = dir.join(format!("{name}.{rest}{KEPT_TEMPORARY}{}-{n}", std::process::id()));
        let written = (|| -> Result<()> {
            let mut options = OpenOptions::new();
            options.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
            }
            let mut file =
                options.open(&tmp).with_context(|| format!("write {}", tmp.display()))?;
            if let Some(header) = header {
                file.write_all(header)?;
                file.write_all(b"\n")?;
            }
            for line in lines {
                file.write_all(line)?;
            }
            file.sync_all()?;
            drop(file);
            std::fs::rename(&tmp, &path)
                .with_context(|| format!("rename to {}", path.display()))?;
            sync_directory(&dir)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        written.map(|()| path)
    }

    /// The open's first step after the journal's replay: each repair file in `journal-unapplied/`
    /// (a chat whose repair failed at an earlier open) whose chat folder is the one its lines
    /// were kept for is journaled again, made durable and removed, and its lines join the chat's
    /// replayed lines, so the repair below runs on them as on any journaled line (a line in both
    /// is the same bytes, so a file journaled twice after a crash changes nothing). A file whose
    /// folder is not there or was replaced stays (review of #35562, D1: a transfer may hold the
    /// folder aside at the open and put it back after it): a later open applies it when that
    /// folder is back, and else it is a person's. A file that does not read, or whose lines the
    /// journal refuses, stays too, with an error: the next open tries again. The temporary copy
    /// of a kept file a crash left before its rename goes.
    pub(super) fn take_repairs(&self, replay: &mut Replay) {
        let dir = self.home.join(UNAPPLIED_DIR);
        let Ok(entries) = std::fs::read_dir(&dir) else { return };
        let mut paths = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = entry.path();
            if name.contains(KEPT_TEMPORARY) {
                if let Err(error) = crate::config::refuse_lost_home(&path)
                    .and_then(|()| std::fs::remove_file(&path).map_err(anyhow::Error::from))
                {
                    tracing::warn!("remove {}: {error:#}", path.display());
                }
            } else if name.ends_with(REPAIR_SUFFIX) {
                paths.push(path);
            }
        }
        paths.sort();
        let mut taken = Vec::new();
        for path in paths {
            match self.journal_repair(&path) {
                Ok(Some((chat, lines))) => taken.push((path, chat, lines)),
                Ok(None) => {}
                Err(error) => {
                    tracing::error!(kept = %path.display(), "a repair file could not be journaled again; the next start tries again: {error:#}");
                }
            }
        }
        let Some(last) =
            taken.iter().flat_map(|(_, _, lines)| lines.iter().map(|(lsn, _)| *lsn)).max()
        else {
            return;
        };
        if let Err(error) = self.journal.wait_durable(last, REPAIR_WAIT) {
            tracing::error!(
                "the repair files' lines did not become durable; the next start tries again: {error}"
            );
            return;
        }
        let mut removed = false;
        for (path, chat, lines) in taken {
            self.order.lock_or_recover().rewrite.insert(chat.clone());
            replay.chats.entry(chat).or_default().extend(lines);
            match crate::config::refuse_lost_home(&path)
                .and_then(|()| std::fs::remove_file(&path).map_err(anyhow::Error::from))
            {
                Ok(()) => removed = true,
                Err(error) => tracing::warn!("remove {}: {error:#}", path.display()),
            }
        }
        if removed && let Err(error) = sync_directory(&dir) {
            tracing::warn!("sync {}: {error:#}", dir.display());
        }
    }

    /// Reads one repair file and, when its chat's folder is the one its lines were kept for,
    /// appends them to the journal: the chat and each line's LSN. `None`: the file stays for a
    /// later open (its folder is not there or was replaced).
    fn journal_repair(&self, path: &Path) -> Result<Option<(String, Vec<(Lsn, Vec<u8>)>)>> {
        #[derive(Deserialize)]
        struct Header {
            schema: String,
            chat: String,
            folder: super::meta::FolderId,
        }
        let reader = BufReader::new(crate::config::private_state_file(path)?);
        let mut lines = reader.split(b'\n');
        let header = lines.next().transpose()?.unwrap_or_default();
        let header: Header = serde_json::from_slice(&header).context("its header")?;
        anyhow::ensure!(header.schema == REPAIR_SCHEMA, "its schema is {}", header.schema);
        let dir = self.local.dir(&header.chat);
        match super::meta::folder_id(&dir).with_context(|| format!("stat {}", dir.display()))? {
            Some(here) if here == header.folder => {}
            here => {
                let why = if here.is_some() { "was replaced since" } else { "is not there" };
                tracing::warn!(session = %header.chat, kept = %path.display(), "the folder of a chat whose repair failed {why}: its kept lines stay for the start that finds it");
                return Ok(None);
            }
        }
        let mut journaled = Vec::new();
        let mut skipped = 0usize;
        for line in lines {
            let mut line = line?;
            if line.is_empty() {
                continue;
            }
            // A whole JSON line only, as in a log: bytes that do not parse are not a line.
            if piece_seq(&line).is_none() {
                skipped = skipped.saturating_add(1);
                continue;
            }
            line.push(b'\n');
            let lsn = self
                .append_waiting(&encode_log(&header.chat, &line))
                .context("journal a kept line")?;
            journaled.push((lsn, line));
        }
        if skipped > 0 {
            tracing::warn!(session = %header.chat, kept = %path.display(), skipped, "a repair file held bytes that are not whole lines: passed");
        }
        Ok(Some((header.chat, journaled)))
    }

    /// Appends one log record (`Ack`) for the open's repair. When the journal's queue is full
    /// (`AppendError::Backlog`: the open appends faster than the writer syncs), waits until every
    /// record appended so far is durable and tries once more (review of #35562, D4: a repair file
    /// larger than `max_pending_bytes` was never applied).
    fn append_waiting(&self, payload: &[u8]) -> Result<Lsn> {
        match self.journal.append(KIND_LOG, Class::Ack, payload) {
            Err(AppendError::Backlog) => {
                self.journal
                    .wait_durable(self.journal.last_lsn(), REPAIR_WAIT)
                    .map_err(|error| anyhow::anyhow!("the event journal: {error}"))?;
                self.journal
                    .append(KIND_LOG, Class::Ack, payload)
                    .map_err(|error| anyhow::anyhow!("the event journal: {error}"))
            }
            appended => appended.map_err(|error| anyhow::anyhow!("the event journal: {error}")),
        }
    }

    /// Removes a repair file (`Store::delete` of its chat) and syncs its folder.
    pub(super) fn remove_repair(&self, path: &Path) -> Result<()> {
        crate::config::refuse_lost_home(path)?;
        match std::fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(
                    anyhow::Error::from(error).context(format!("remove {}", path.display()))
                );
            }
        }
        sync_directory(&self.home.join(UNAPPLIED_DIR))
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
        // A hole of zeros an OS crash left runs into the next line, after a torn line or not: the
        // bytes up to the hole's last zero are one piece, the line after them another. A whole
        // line holds no zero byte (JSON escapes every control character).
        let after_hole = line
            .iter()
            .rposition(|byte| *byte == 0)
            .and_then(|at| at.checked_add(1))
            .and_then(|at| Some((at, line.get(at..)?)));
        if whole && let Some(seq) = piece_seq(&line) {
            out.push(Piece { segment, offset, line: Some((seq, line.clone())) });
        } else if whole
            && let Some((at, after)) = after_hole
            && let Some(seq) = piece_seq(after)
        {
            out.push(Piece { segment, offset, line: None });
            let at = offset.saturating_add(u64::try_from(at).unwrap_or(u64::MAX));
            out.push(Piece { segment, offset: at, line: Some((seq, after.to_vec())) });
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
        Ok(_) => log_sync::sync_directory_ordered(path),
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
    log_sync::sync_segment_ordered(&file)?;
    Ok(())
}

/// The file id (inode) of `path`; 0 where the platform gives none.
pub(super) fn file_ino(path: &Path) -> Result<u64> {
    let meta =
        std::fs::symlink_metadata(path).with_context(|| format!("stat {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        Ok(0)
    }
}
