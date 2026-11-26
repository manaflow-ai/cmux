//! The `Store` impl for `LocalStore`.

use super::*;

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        // No sessions folder yet: no chat. One that is there and does not read is a failed list,
        // never an empty one: an empty list proves every chat gone (`hub/hosts.rs`).
        if !crate::home_fs::try_exists_nofollow(&self.root)? {
            return Ok(Vec::new());
        }
        let root = match crate::home_fs::PrivateDir::open(&self.root) {
            Ok(root) => root,
            Err(error) if is_not_found(&error) => return Ok(Vec::new()),
            Err(error) => return Err(error.context(format!("list {}", self.root.display()))),
        };
        // Only enumeration fails the pass. Entry checks belong to each worker.
        let entries = root.names()?;
        if entries.is_empty() {
            return Ok(Vec::new());
        }
        // Hold the checked store for the pass. Each worker checks only its chats and their
        // events folders, never the same ancestors again.
        let workers = std::thread::available_parallelism().map_or(1, usize::from).min(8);
        std::thread::scope(|scope| {
            let workers: Vec<_> = entries
                .chunks(entries.len().div_ceil(workers))
                .map(|chunk| {
                    let root = &root;
                    scope.spawn(move || {
                        let mut metas = Vec::new();
                        for name in chunk {
                            // One chat that is refused or does not read is left out (and
                            // counted unread), never the reason no chat is listed.
                            match self.list_entry(root, name) {
                                Ok(Some(meta)) => metas.push(meta),
                                Ok(None) => {}
                                Err(e) => {
                                    tracing::warn!(
                                        "skip {}: {e:#}",
                                        root.path().join(name).display()
                                    );
                                    let id = name.to_string_lossy().into_owned();
                                    self.mark_unlisted(&id, true);
                                }
                            }
                        }
                        Ok::<_, anyhow::Error>(metas)
                    })
                })
                .collect();
            let mut metas = Vec::new();
            for worker in workers {
                metas.extend(
                    worker.join().map_err(|_| anyhow::anyhow!("store list worker failed"))??,
                );
            }
            Ok(metas)
        })
    }

    fn unlisted(&self) -> Vec<String> {
        let unlisted = self.unlisted.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        unlisted.iter().cloned().collect()
    }

    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        // An absent chat needs only search access, before opening folders for reading.
        if !crate::home_fs::try_exists_nofollow(self.dir(id))? {
            return Ok(None);
        }
        let root = match crate::home_fs::PrivateDir::open(&self.root) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let held = match self.validate_session_dir(&root, std::ffi::OsStr::new(id)) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let file = match held.private_file(std::ffi::OsStr::new("session.json")) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let mut text = String::new();
        BufReader::new(file).read_to_string(&mut text)?;
        let mut meta: SessionMeta = serde_json::from_str(&text)?;
        self.parts.merge_held(&held, text.as_bytes(), &mut meta);
        Ok(Some(meta))
    }

    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        let Some(meta) = self.load(id)? else { return Ok(None) };
        if self.purged_startup_entry(id, meta.status)? {
            return Ok(None);
        }
        Ok(Some(meta))
    }

    fn save(&self, meta: &SessionMeta) -> Result<()> {
        #[cfg(test)]
        self.meta_saves.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let _open = self.writable()?;
        let dir = self.dir(&meta.id);
        crate::config::private_state_dir(&dir)?;
        // The large fields only when they changed (`store/meta_parts.rs`), then the rest.
        let parts = self.parts.write(&dir, meta)?;
        let text = meta_parts::to_string_pretty(meta, &parts)?;
        meta_parts::note_written(text.len());
        write_atomic(&dir.join("session.json"), text.as_bytes())
    }

    fn flush_session(&self, id: &str) -> Result<()> {
        let writers = self.writers.lock_or_recover();
        if let Some(writer) = writers.open.get(id) {
            log_sync::sync_segment(writer.file(), true).map_err(SyncFailed)?;
        }
        let session = self.dir(id);
        sync_directory(&session.join("events"))?;
        sync_directory(&session)?;
        sync_directory(&self.root)?;
        Ok(())
    }

    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        note_write_budget(record, line.len());
        self.append_line(id, line.as_bytes())
    }

    fn read_log(
        &self,
        id: &str,
        from: u64,
        filter: LogFilter<'_>,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogChunk> {
        self.read_log_bytes(id, from, filter, stamp, marks, out)
    }

    fn read_log_part(
        &self,
        id: &str,
        seq: u64,
        offset: u64,
        max: usize,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogPart> {
        self.read_log_part_bytes(id, seq, offset, max, stamp, marks, out)
    }

    fn log_stamp(&self, id: &str) -> Result<u64> {
        self.read_stamp(id)
    }

    fn bump_log_stamp(&self, id: &str, by: u64) -> Result<()> {
        self.bump_stamp(id, by)
    }

    fn writes_history(&self) -> bool {
        true
    }

    /// Segment `000000`, written beside the log under a temporary name and renamed in whole.
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        // An archived log comes back before a segment is written beside it.
        self.rehydrate(id)?;
        #[cfg(test)]
        log_sync::hold(&cold::HOLD_AFTER_HISTORY_REHYDRATE);
        let _open = self.writable()?;
        let dir = self.dir(id).join("events");
        crate::config::private_state_dir(&self.dir(id))?;
        crate::config::private_state_dir(&dir)?;
        let path = dir.join("000000.ndjson");
        let tmp = dir.join("000000.ndjson.history");
        let _ = crate::home_fs::remove_file(&tmp);
        let file = std::io::BufWriter::with_capacity(256 * 1024, open_private_append(&tmp)?);
        Ok(Some(Box::new(SegmentZero { file: Some(file), tmp, path, dir })))
    }

    /// Reads only past `after`: a segment whose successor starts at or before `after + 1`
    /// holds nothing past it and is not opened, and a line at or before `after` is passed
    /// on its `seq` alone, unparsed. A forward page of a long log costs its own records,
    /// not the log's prefix (perf100: a 70 MB log read in 10,000-record pages parsed
    /// every earlier record again on each page).
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        self.scan_lines(id, after, false, None, visit)
    }

    fn scan_matching(
        &self,
        id: &str,
        after: u64,
        may_match: &dyn Fn(&[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, false, Some(may_match), visit)
    }

    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, true, None, visit)
    }

    /// Reads from `hint` when the line there holds `from` (an adoption's checkpoint: no byte
    /// before it), else from the start of the segment that holds `from`, passing the lines
    /// before `from` on their `seq` alone.
    fn scan_heads_from(
        &self,
        id: &str,
        from: u64,
        hint: Option<LinePos>,
        visit: &mut dyn FnMut(&RecordHead<'_>, Option<LinePos>) -> bool,
    ) -> Result<()> {
        use std::io::{Seek, SeekFrom};
        let segments = self.segments(id)?;
        let mut line = Vec::new();
        let hinted = hint.and_then(|h| {
            let (index, (_, path)) =
                segments.iter().enumerate().find(|(_, (n, _))| *n == h.segment)?;
            let mut reader =
                BufReader::with_capacity(64 * 1024, crate::config::private_state_file(path).ok()?);
            reader.seek(SeekFrom::Start(h.offset)).ok()?;
            line.clear();
            reader.read_until(b'\n', &mut line).ok()?;
            (record_seq(&line) == Some(from)).then_some((index, h.offset, reader))
        });
        let (start, mut first) = match hinted {
            Some((index, offset, reader)) => (index, Some((offset, reader))),
            None => (self.segment_starts.start(id, &segments, from.saturating_sub(1))?, None),
        };
        for (index, path) in segments.get(start..).unwrap_or_default() {
            let (mut pos, mut reader) = match first.take() {
                Some((offset, reader)) => (offset, reader),
                None => {
                    line.clear();
                    let file = crate::config::private_state_file(path)?;
                    (0, BufReader::with_capacity(256 * 1024, file))
                }
            };
            loop {
                // The hinted line was read already.
                let n =
                    if line.is_empty() { reader.read_until(b'\n', &mut line)? } else { line.len() };
                if n == 0 {
                    break;
                }
                let at = LinePos { segment: *index, offset: pos };
                pos += n as u64;
                let more = if line.iter().all(u8::is_ascii_whitespace)
                    || record_seq(&line).is_some_and(|seq| seq < from)
                {
                    true
                } else {
                    match RecordHead::read(&line) {
                        Some(head) => visit(&head, Some(at)),
                        None => match parse_record(&line) {
                            Ok(rec) if rec.seq >= from => {
                                visit(&RecordHead::parsed(&rec), Some(at))
                            }
                            _ => true,
                        },
                    }
                };
                line.clear();
                if !more {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    /// None once the log was compacted since it was saved: a compaction cuts records' strings
    /// in place (`store/compact.rs`), which a fold of them would read differently. The file's
    /// first line is the digest of the compaction marker it was saved under.
    fn adoption_checkpoint(&self, id: &str) -> Option<Vec<u8>> {
        let bytes = held_file_bytes(&self.dir(id).join(ADOPTION_CHECKPOINT))?;
        let nl = bytes.iter().position(|&b| b == b'\n')?;
        let (head, body) = bytes.split_at(nl);
        (head == self.compaction_digest(id).as_bytes())
            .then(|| body.get(1..).unwrap_or_default().to_vec())
    }

    fn save_adoption_checkpoint(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let dir = self.dir(id);
        // As `save_restore_point`: a chat whose folder went away gets no file of its own again.
        let folder = crate::home_fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_dir());
        anyhow::ensure!(folder, "no folder for {id}");
        let mut file = self.compaction_digest(id).into_bytes();
        file.push(b'\n');
        file.extend_from_slice(bytes);
        write_atomic(&dir.join(ADOPTION_CHECKPOINT), &file)
    }

    /// Reads each line's head (`RecordHead::read`) and parses only the lines the reader asks
    /// for, or a line whose head does not read.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        let mut line = Vec::new();
        let mut pass = crate::perf_watch::LogPass::start(id, true);
        for (_, path) in self.segments(id)? {
            let mut reader =
                BufReader::with_capacity(256 * 1024, cold_segments::open_segment(&path)?);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                crate::perf_watch::LogPass::line(&mut pass, line.len());
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let more = match RecordHead::read(&line) {
                    Some(head) => visit(&head),
                    None => {
                        let Ok(rec) = parse_record(&line) else { continue };
                        visit(&RecordHead::parsed(&rec))
                    }
                };
                if !more {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let mut count = 0;
        let mut last = after;
        let mut done = false;
        for (_, path) in self.segments(id)?.into_iter().rev() {
            for_each_line_rev(&path, &mut |line| {
                let Ok(rec) = serde_json::from_slice::<EventRecord>(line) else { return true };
                if rec.seq <= after {
                    done = true;
                    return false;
                }
                count += 1;
                last = last.max(rec.seq);
                true
            })?;
            if done {
                break;
            }
        }
        Ok((count, last))
    }

    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_in(id, kinds, false, visit)
    }

    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_in(id, kinds, true, visit)
    }

    /// Back from the end of the records before `before`, segment by segment, reading each line's
    /// seq from its first bytes: no line is parsed but one whose header does not read.
    fn newest_window(&self, id: &str, before: u64, n: u64) -> Result<NewestWindow> {
        let mut window = NewestWindow::default();
        let mut seen = 0u64;
        let mut done = false;
        for (_, path) in self.segments(id)?.into_iter().rev() {
            if first_seq(&path)?.is_some_and(|first| first >= before) {
                continue;
            }
            let mut file = crate::config::private_state_file(&path)?;
            let end = offset_of_seq(&mut file, before)?;
            for_each_line_rev_from(&mut file, end, &mut |line| {
                let Some(seq) = record_seq(line).or_else(|| parse_record(line).ok().map(|r| r.seq))
                else {
                    return true;
                };
                if seq >= before {
                    return true;
                }
                window.newest = window.newest.max(seq);
                seen += 1;
                if seen > n {
                    window.after = seq;
                    done = true;
                    return false;
                }
                true
            })?;
            if done {
                break;
            }
        }
        Ok(window)
    }

    /// Through the copies of the kinds (`store/kind_index.rs`), past `after`: a scan of the log
    /// from the segment that holds `after + 1` parses that whole segment, for each fold of a
    /// load, and read more than the copies do (`a_restored_chats_log_load_reads_the_copies_not_its_log`).
    /// Only the copies from the segment that holds `after + 1` on (`scan_kinds_past`).
    fn scan_kinds_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_past(id, after, kinds, false, visit)
    }

    fn scan_kinds_after_strict(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_past(id, after, kinds, true, visit)
    }

    fn scan_kinds_keyed(
        &self,
        id: &str,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_keyed_in(id, kinds, keep, visit)
    }

    fn restore_point(&self, id: &str) -> Option<Vec<u8>> {
        std::fs::read(self.dir(id).join(RESTORE_POINT)).ok()
    }

    fn save_restore_point(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let dir = self.dir(id);
        // A chat whose folder went away (a delete) gets no file of its own again. Read in the
        // held home, never by path (#41721 review F1).
        let folder = crate::home_fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_dir());
        anyhow::ensure!(folder, "no folder for {id}");
        write_atomic(&dir.join(RESTORE_POINT), bytes)
    }

    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        self.text_entries_in(id, visit)
    }

    fn search_records(&self, id: &str, visit: &mut dyn FnMut(EventRecord)) -> Result<()> {
        if self.is_cold(id) {
            self.cold_search_records(id, visit)
        } else {
            self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
                visit(rec);
                true
            })
        }
    }

    /// Segments newest first, so a page from the end reads only the segments it
    /// needs however long the log is. A segment whose first record is at or past
    /// `before` holds nothing for the page and is skipped after one line.
    /// Reads backwards from the end of the records before `before` only: the
    /// segment is read in blocks from the offset where `before` starts (found
    /// by a search on the line headers), never whole, and a line `skip` names,
    /// or one at or past `before`, is passed on its header unparsed. A page
    /// costs its own bytes, not its segment's (perf100: every older page of a
    /// scroll to the first message read and parsed its whole 8 MiB segment,
    /// and opening a chat read the log once for each of its three reads).
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back_in(id, after, before, skip, visit, false)
    }

    fn scan_back_indexed(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back_in(id, after, before, skip, visit, true)
    }

    fn flush(&self) -> Result<()> {
        for w in self.writers.lock_or_recover().open.values() {
            log_sync::sync_segment(w.file(), false)?;
        }
        Ok(())
    }

    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let mut out = Vec::new();
        self.scan(id, after, &mut |rec| {
            out.push(rec);
            out.len() < limit
        })?;
        Ok(out)
    }

    fn close_log(&self, id: &str) {
        let mut writers = self.writers.lock_or_recover();
        self.close_writer_locked(id, &mut writers);
    }

    fn compacted_seq(&self, id: &str) -> Option<u64> {
        LocalStore::compacted_seq(self, id)
    }

    fn log_written_at(&self, id: &str) -> Option<u64> {
        LocalStore::log_written_at(self, id)
    }

    fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        // Not under the seal: staging writes only copies beside the log, and a large log's
        // stage would hold a shutdown's seal for as long as it reads (router review of #28503).
        // The commit that puts them in place is sealed.
        LocalStore::stage_compaction(self, id, mode)
    }

    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        let _open = self.writable()?;
        LocalStore::commit_compaction(self, id, staged)
    }

    fn stage_cold(&self, id: &str) -> Result<Option<StagedCold>> {
        LocalStore::stage_cold(self, id)
    }

    fn commit_cold(&self, id: &str, staged: StagedCold) -> Result<bool> {
        let _open = self.writable()?;
        LocalStore::commit_cold(self, id, staged)
    }

    fn rehydrate(&self, id: &str) -> Result<bool> {
        LocalStore::rehydrate(self, id)
    }

    fn is_cold(&self, id: &str) -> bool {
        LocalStore::is_cold(self, id)
    }

    fn offload_cold(&self, id: &str) -> Result<Option<u64>> {
        let _open = self.writable()?;
        LocalStore::offload_cold(self, id)
    }

    fn register_cloud_root(&self) -> Result<Option<usize>> {
        LocalStore::register_cloud_root(self)
    }

    fn on_rehydrate(&self, hook: RehydrateHook) {
        let _ = self.rehydrate_hook.set(hook);
    }

    fn stage_cold_segments(
        &self,
        id: &str,
        max: usize,
        level: i32,
    ) -> Result<Option<StagedColdSegments>> {
        LocalStore::stage_cold_segments(self, id, max, level)
    }

    fn prepare_cold_segments(&self, _id: &str, _staged: &StagedColdSegments) -> Result<bool> {
        Ok(true)
    }

    fn commit_cold_segments(&self, id: &str, staged: StagedColdSegments) -> Result<ColdMoved> {
        LocalStore::commit_cold_segments(self, id, staged)
    }

    fn settle_cold_segments(&self, id: &str) -> Result<()> {
        LocalStore::settle_cold_segments(self, id)
    }

    fn warm_cold_segments(&self, id: &str) -> Result<ColdWarmed> {
        LocalStore::warm_cold_segments(self, id)
    }

    fn on_segment_sealed(&self, hook: SealHook) {
        let _ = self.seal_hook.set(hook);
    }

    fn on_log_grown(&self, hook: SealHook) {
        let _ = self.grow_hook.set(hook);
    }

    fn seal(&self) {
        *self.sealed.write().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    }

    /// `<id>/parked.json`, beside the chat's `events/`: written whole by a rename, its file and
    /// folder synced before it answers. Never makes the chat's folder: a purged chat keeps none.
    fn keep_parked(&self, id: &str, kept: Option<&[u8]>) -> Result<()> {
        let _open = self.writable()?;
        let path = self.dir(id).join(PARKED);
        match kept {
            Some(bytes) => compact::write_durably(&path, bytes),
            None => match crate::home_fs::remove_file(&path) {
                Ok(()) => sync_directory(&self.dir(id)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
            },
        }
    }

    fn kept_parked(&self, id: &str) -> Result<Option<Vec<u8>>> {
        #[cfg(test)]
        if fails_kept_read(id) {
            anyhow::bail!("a test failed this read of {id}'s kept records");
        }
        let path = self.dir(id).join(PARKED);
        match crate::config::private_state_file(&path) {
            Ok(file) => {
                let mut bytes = Vec::new();
                BufReader::new(file).read_to_end(&mut bytes)?;
                Ok(Some(bytes))
            }
            Err(_) if crate::home_fs::symlink_metadata(&path).is_err() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// `<id>/held/<slot>.json`, beside the chat's `events/`: written whole by a rename, not
    /// synced (a kill keeps what the kernel was given). Never makes the chat's folder: a deleted
    /// chat gets no file of its own again.
    fn keep_held(&self, id: &str, slot: &str, held: Option<&[u8]>) -> Result<()> {
        anyhow::ensure!(deferred::is_slot(slot), "{slot:?} names no held slot");
        let _open = self.writable()?;
        let dir = self.dir(id).join(HELD);
        let path = dir.join(format!("{slot}.json"));
        match held {
            Some(bytes) => {
                // `held/` alone, never its parent: whenever a delete removed the chat's folder,
                // this fails. Read in the held home, never by path (#41721 review F1).
                if crate::home_fs::symlink_metadata(&dir).is_err() {
                    match crate::home_fs::create_dir(&dir, 0o700) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(e) => {
                            return Err(e).with_context(|| format!("create {}", dir.display()));
                        }
                    }
                }
                crate::config::write_atomic_unsynced(&path, bytes)
            }
            None => match crate::home_fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
            },
        }
    }

    /// Every `<slot>.json` in `<id>/held/`; none without the folder. A copy a write left (named
    /// `<slot>.tmp-<pid>`) is no slot's.
    fn kept_held(&self, id: &str) -> Result<Vec<(String, Vec<u8>)>> {
        let dir = self.dir(id).join(HELD);
        let entries = match crate::home_fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).with_context(|| format!("list {}", dir.display())),
        };
        let mut out = Vec::new();
        for entry in entries {
            let name = entry.name.to_str().and_then(|n| n.strip_suffix(".json"));
            let Some(slot) = name.filter(|s| entry.is_file && deferred::is_slot(s)) else {
                continue;
            };
            let mut bytes = Vec::new();
            crate::home_fs::private_state_file(dir.join(&entry.name))?.read_to_end(&mut bytes)?;
            out.push((slot.to_owned(), bytes));
        }
        Ok(out)
    }

    fn delete(&self, id: &str) -> Result<()> {
        let _open = self.writable()?;
        if let Some(w) = self.writers.lock_or_recover().open.remove(id) {
            w.retire();
        }
        self.kind_heads.forget(id);
        self.kind_index_checks.forget(id);
        self.segment_starts.forget(id);
        self.segment_table.forget(id);
        let dir = self.dir(id);
        // macOS returns ENOTEMPTY when a file lands mid-removal; retry briefly.
        let mut last = None;
        for _ in 0..5 {
            if !crate::home_fs::try_exists_nofollow(&dir)? {
                return Ok(());
            }
            match crate::home_fs::remove_dir_all(&dir) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last = Some(e);
                    std::thread::sleep(std::time::Duration::from_millis(40));
                }
            }
        }
        match last {
            Some(e) => Err(e.into()),
            None => Ok(()),
        }
    }

    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        Some(self.dir(id))
    }

    fn handoff_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("handoffs"))
    }

    fn peer_cache_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("peers"))
    }

    fn briefs_path(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("briefs.json"))
    }

    fn audit_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("audit"))
    }
}
