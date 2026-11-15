//! Compaction of a live chat's sealed log segments (`hub/sealed_compaction.rs`): a segment no
//! longer written (every one but the newest; never `000000`, a fork's history) is rewritten
//! without the tool call updates a later update of the same call in it makes moot, every kept
//! record with its `seq`. Retention (`store/compact.rs`) takes closed chats only; this takes any.
//!
//! What goes is what a page already leaves out (`store/superseded.rs`, [`Superseded`]): an
//! update that carries nothing but its call's output (its status and text content, beside
//! Codex's increments no reader folds), whose every field a newer update of the call carries
//! again, and that does not end the call; the oldest such update is kept, unless the call's
//! `tool_call` is older in the same segment (a reader takes a call's start from the first record
//! it sees of it). An update a newer one replaces the content of and that stays loses its
//! `content`, noted as `_meta.acpmux.supersededContent`. In ACP an update's content replaces the
//! call's, and every reader folds it so (the web client's `mergeToolItem`, `rows/fold.rs`,
//! `transcript.rs`); the time breakdown (`hub/time_breakdown.rs`) only extends the span the
//! update was in. On top of what a page leaves out:
//! - Only within one segment, read newest first from its end, and never across a prompt or
//!   turn's start or end, nor across a fork's `through_seq` (`barriers`, `store/fork_view.rs`):
//!   a fork shows the chat's records through that seq, and an update it shows must not go for
//!   one past it. The fork view checks at the commit that no fork came since with another seq.
//! - Never an update next to a message or thought chunk, or first or last in its segment: a
//!   record between two chunks ends the reply in `rows/fold.rs`, and dropping it would join two
//!   replies into one.
//!
//! Message and thought chunks are not merged: a reader resumes after a seq (an attach's
//! `lastSeq`, a peer copy's catch-up `afterSeq`, `hub/peer_snapshot.rs`), and a merged record
//! under one seq makes one inside its run lose or repeat text; the web client times a thought
//! from its first chunk to its last (`appendThought`), which one record cannot hold.
//!
//! Seqs keep their gaps: pages read `after < seq < before` and end on what they find
//! (`hub/paging.rs`), v2's raw source reads seqs "with gaps" (`hub/v1_source.rs`), the web client
//! fills any gap it sees with a read after it (`fetchMissedEvents`), a peer copy is bounded by the
//! page's own `afterSeq`/`through` (`hub/peer_snapshot.rs`), and retention already drops raw
//! stream lines of chats that reopen. Nothing is renumbered.
//!
//! Crash safety: each compacted segment is written beside its segment
//! (`NNNNNN.ndjson.sealed`) and synced with no lock held ([`LocalStore::stage_sealed_segments`]); the
//! commit ([`LocalStore::commit_sealed_segments`]), under the writers' lock and only when no staged
//! segment changed (length and file) and each is still not the newest, renames each over its
//! segment, bumping the log's count before the first and after the last (`store/log_bytes.rs`).
//! A rename replaces one file whole with records a reader folds the same, so a crash anywhere
//! leaves every segment old or compacted, both of which read the same; the copies left beside
//! are never listed and the next pass removes them. [`MARKER`] then records the last segment
//! done, so a pass a crash cut short is done again (a compacted segment compacts to itself).
//! Through the journal (`store/journal_store.rs`), every journal record of the chat up to its
//! newest when the pass staged is checkpointed first, so a replay never writes a dropped line
//! back.

use super::*;

/// [`Store::on_segment_sealed`]'s hook.
pub type SealHook = std::sync::Arc<dyn Fn(&str) + Send + Sync>;

/// The last sealed segment compacted, beside the segments.
pub const MARKER: &str = "sealed.json";
/// A compacted copy's extension, beside its segment.
const TMP: &str = "ndjson.sealed";

#[derive(Serialize, Deserialize)]
struct Marker {
    through: u32,
}

/// Compacted copies of sealed segments, written beside them and not yet in place. Dropping it
/// removes them.
pub struct StagedSealed {
    stats: Compaction,
    /// The last segment the pass read: [`MARKER`] once it is in place.
    through: u32,
    barriers: Vec<u64>,
    segments: Vec<SealedSegment>,
    /// The chat's newest journal record when the pass staged (`store/journal_store.rs`).
    pub(super) lsn: Option<u64>,
}

struct SealedSegment {
    index: u32,
    path: PathBuf,
    len: u64,
    file: (u64, u64),
    first_seq: u64,
    last_seq: u64,
    /// The compacted copy; none when it would be the same.
    tmp: Option<PathBuf>,
}

impl StagedSealed {
    /// What the commit would change.
    pub fn stats(&self) -> Compaction {
        self.stats
    }

    /// Whether the pass kept apart every seq of `barriers` that falls inside a segment it changes.
    pub(super) fn keeps_apart(&self, barriers: &[u64]) -> bool {
        barriers.iter().all(|b| {
            self.barriers.contains(b)
                || !self
                    .segments
                    .iter()
                    .any(|s| s.tmp.is_some() && s.first_seq <= *b && *b < s.last_seq)
        })
    }
}

impl Drop for StagedSealed {
    fn drop(&mut self) {
        for tmp in self.segments.iter().filter_map(|s| s.tmp.as_ref()) {
            let _ = crate::home_fs::remove_file(tmp);
        }
    }
}

/// The file a segment is: its device and inode (its length alone elsewhere).
fn file_of(meta: &std::fs::Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        (0, 0)
    }
}

impl LocalStore {
    fn sealed_marker(&self, id: &str) -> PathBuf {
        self.dir(id).join("events").join(MARKER)
    }

    /// The last sealed segment compacted (0: none).
    fn sealed_through(&self, id: &str) -> u32 {
        std::fs::read(self.sealed_marker(id))
            .ok()
            .and_then(|text| serde_json::from_slice::<Marker>(&text).ok())
            .map_or(0, |m| m.through)
    }

    /// [`Store::stage_sealed`].
    pub(super) fn stage_sealed_segments(
        &self,
        id: &str,
        barriers: &[u64],
        max: usize,
    ) -> Result<Option<StagedSealed>> {
        // An archived log stays archived; a cut left halfway is finished by the next read first.
        if self.is_cold(id) {
            return Ok(None);
        }
        let (segments, cut_pending) = self.listed_files(id)?;
        if cut_pending || segments.len() < 2 {
            return Ok(None);
        }
        let events = self.dir(id).join("events");
        // What a crash left of an earlier pass.
        for entry in crate::home_fs::read_dir(&events)? {
            if entry.is_file && entry.name.to_string_lossy().ends_with(&format!(".{TMP}")) {
                let _ = crate::home_fs::remove_file(events.join(&entry.name));
            }
        }
        let through = self.sealed_through(id);
        let newest = segments.last().map_or(0, |(i, _)| *i);
        let todo: Vec<(u32, PathBuf)> = segments
            .into_iter()
            .filter(|(i, _)| *i > 0 && *i > through && *i < newest)
            .take(max)
            .collect();
        let Some(last) = todo.last().map(|(i, _)| *i) else { return Ok(None) };
        let mut barriers = barriers.to_vec();
        barriers.sort_unstable();
        barriers.dedup();
        let mut staged = StagedSealed {
            stats: Compaction::default(),
            through: last,
            barriers,
            segments: Vec::new(),
            lsn: None,
        };
        for (index, path) in todo {
            let file = crate::config::private_state_file(&path)?;
            let meta = file.metadata()?;
            let len = meta.len();
            let mut bytes = Vec::with_capacity(usize::try_from(len).unwrap_or(0));
            (&file).take(len).read_to_end(&mut bytes)?;
            drop_cache_of(&file);
            let (out, stats) = compact_segment(&bytes, &staged.barriers);
            let seqs = || bytes.split(|b| *b == b'\n').filter_map(record_seq);
            let first_seq = seqs().next().unwrap_or(0);
            let last_seq = seqs().last().unwrap_or(0);
            staged.stats.bytes_before += stats.bytes_before;
            staged.stats.bytes_after += stats.bytes_after;
            staged.stats.dropped += stats.dropped;
            staged.stats.trimmed += stats.trimmed;
            let tmp = if out == bytes {
                None
            } else {
                let tmp = path.with_extension(TMP);
                let written = (|| -> Result<()> {
                    let mut copy = open_private_append(&tmp)?;
                    copy.write_all(&out)?;
                    copy.sync_all()?;
                    drop_cache_of(&copy);
                    Ok(())
                })();
                if let Err(e) = written {
                    let _ = crate::home_fs::remove_file(&tmp);
                    return Err(e);
                }
                Some(tmp)
            };
            staged.segments.push(SealedSegment {
                index,
                path,
                len,
                file: file_of(&meta),
                first_seq,
                last_seq,
                tmp,
            });
        }
        Ok(Some(staged))
    }

    /// [`Store::commit_sealed`]: false when a staged segment changed, went, or is the newest now.
    pub(super) fn commit_sealed_segments(
        &self,
        id: &str,
        mut staged: StagedSealed,
    ) -> Result<bool> {
        let _open = self.writable()?;
        {
            let mut writers = self.writers.lock_or_recover();
            let (now, cut_pending) = self.listed_files(id)?;
            let newest = now.last().map_or(0, |(i, _)| *i);
            let unchanged = !cut_pending
                && staged.segments.iter().all(|s| {
                    s.index < newest
                        && now.iter().any(|(i, p)| *i == s.index && *p == s.path)
                        && crate::home_fs::symlink_metadata(&s.path)
                            .is_ok_and(|m| m.len() == s.len && file_of(&m) == s.file)
                });
            if !unchanged {
                return Ok(false);
            }
            let changes = staged.segments.iter().any(|s| s.tmp.is_some());
            if changes {
                self.bump_stamp_locked(id, &mut writers, 1)?;
            }
            let mut renamed = 0usize;
            for segment in &mut staged.segments {
                let Some(tmp) = segment.tmp.take() else { continue };
                // Tests only: a crash between two renames.
                #[cfg(test)]
                if renamed > 0 {
                    between_segments(id);
                }
                crate::home_fs::rename(&tmp, &segment.path)?;
                renamed += 1;
            }
            if changes {
                self.bump_stamp_locked(id, &mut writers, 1)?;
            }
        }
        // Off the writers' lock: every name holds a whole segment, old or compacted, either way.
        sync_directory(&self.dir(id).join("events"))?;
        compact::write_durably(
            &self.sealed_marker(id),
            &serde_json::to_vec(&Marker { through: staged.through })?,
        )?;
        Ok(true)
    }

    /// Calls the seal hook (`append_line`, as a segment rolls over).
    pub(super) fn note_sealed(&self, id: &str) {
        if let Some(hook) = self.seal_hook.get() {
            hook(id);
        }
    }
}

fn drop_cache_of(file: &File) {
    compact::drop_cache(file);
}

fn is_chunk(kind: &[u8]) -> bool {
    matches!(kind, b"agent_message_chunk" | b"agent_thought_chunk")
}

/// Whether no tool call update newer than a record with this `dir` and `kind` may make an older
/// one moot: a turn's start or end. (A prompt's, `starts_prompt`, [`Superseded`] reads itself.)
fn ends_turn(dir: &[u8], kind: &[u8]) -> bool {
    dir == b"mux" && matches!(kind, b"turn_started" | b"turn_result" | b"turn_end")
}

/// One segment's bytes as the module docs keep them, and what changed.
pub(super) fn compact_segment(bytes: &[u8], barriers: &[u64]) -> (Vec<u8>, Compaction) {
    let lines: Vec<&[u8]> = bytes.split_inclusive(|b| *b == b'\n').collect();
    let kinds: Vec<&[u8]> = lines.iter().map(|l| record_kind(l).unwrap_or_default()).collect();
    let mut keep = vec![true; lines.len()];
    let mut edited: HashMap<usize, Vec<u8>> = HashMap::new();
    let mut superseded = Superseded::default();
    let mut newer_seq = u64::MAX;
    for at in (0..lines.len()).rev() {
        let line = lines[at];
        let Some(seq) = record_seq(line) else {
            // A line that does not read (a torn one): nothing carries across it.
            superseded = Superseded::default();
            continue;
        };
        if barriers.iter().any(|b| seq <= *b && *b < newer_seq) {
            superseded = Superseded::default();
        }
        newer_seq = seq;
        let (dir, kind) = (record_dir(line).unwrap_or_default(), kinds[at]);
        if ends_turn(dir, kind) {
            superseded = Superseded::default();
            continue;
        }
        if !(starts_prompt(dir, kind) || kind == b"tool_call" || kind == b"tool_call_update") {
            continue;
        }
        let Ok(mut rec) = serde_json::from_slice::<EventRecord>(line) else {
            superseded = Superseded::default();
            continue;
        };
        let noted = memchr::memmem::find(line, super::superseded::NOTE.as_bytes()).is_some();
        let moot = superseded.read(&mut rec, at, |_| true);
        if !noted
            && rec.kind == "tool_call_update"
            && rec
                .msg
                .pointer(&format!("/params/update/_meta/acpmux/{}", super::superseded::NOTE))
                .is_some()
            && let Ok(mut out) = serde_json::to_vec(&rec)
        {
            out.push(b'\n');
            edited.insert(at, out);
        }
        if let Some(moot) = moot {
            // Never a record next to a chunk, nor one whose neighbour is in another segment.
            let beside_chunk = moot == 0
                || moot + 1 == lines.len()
                || is_chunk(kinds[moot - 1])
                || is_chunk(kinds[moot + 1]);
            if !beside_chunk {
                keep[moot] = false;
                edited.remove(&moot);
            }
        }
    }
    let mut stats = Compaction { bytes_before: bytes.len() as u64, ..Compaction::default() };
    let mut out = Vec::with_capacity(bytes.len());
    for (at, line) in lines.iter().enumerate() {
        if !keep[at] {
            stats.dropped += 1;
            continue;
        }
        match edited.get(&at) {
            Some(record) => {
                stats.trimmed += 1;
                out.extend_from_slice(record);
            }
            None => out.extend_from_slice(line),
        }
    }
    stats.bytes_after = out.len() as u64;
    (out, stats)
}
