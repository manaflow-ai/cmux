//! Tool call updates a later update of the same call makes moot.
//!
//! codex-acp sends a running command's whole output so far as the `content` of each
//! `tool_call_update`, with the increment beside it in `_meta.terminal_output_delta`, so a long
//! command's records grow with the square of its output. One Codex chat (cosmic-gray, 2026-10-29)
//! logged 27,564 updates (150 MB) for 219 calls, and 123 MB of that was `content` a later update
//! replaced. In ACP an update's `content` replaces the call's content, and every reader folds it
//! that way (the web client's `mergeToolItem`, `transcript.rs`). So an update's `content` is moot
//! once a later update of the same call carries its own. No reader folds the deltas.
//!
//! A call id names a call within one prompt only (an adapter that numbers calls per process
//! reuses one in a later prompt; the web client clears its calls at each prompt, cx-jzhka), so an
//! update is only ever superseded by one of the same prompt: a `user_message` or `turn_started`
//! between them keeps both. A read cut at a prompt (a fork through a turn, an export) sees every
//! call as logged.
//!
//! It is left out in two places, and the final state of every call stays as logged:
//! - A page read newest first for a client that bounds it by bytes (`hub/paging.rs`). An update
//!   whose every field a newer update of its call in the same scan carries again is left out
//!   (unless it ends the call: its time is the call's end), and other updates drop their moot
//!   `content`. The page's byte and record bounds then go to the transcript, not to snapshots: a
//!   Codex chat's newest page used to hold a few records of one running command.
//! - A sealed segment of a live chat's log ([`LocalStore::sealed`]). Each record keeps its `seq`;
//!   a content-bearing update that a later one in the same segment and prompt supersedes loses its
//!   `content`;
//!   the deltas, each call's last content in the segment and every other record stay as written.
//!   The note `_meta.acpmux.supersededContent` (bytes) marks an update whose content was left out.
//!
//! The live stream to attached clients is unchanged: only what is read back from the log is.

use super::compact::drop_cache;
use super::*;
use serde_json::Map;
use serde_json::value::RawValue;
use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::Arc;

/// Beside a log's segments: the newest sealed segment whose superseded content is already out.
const MARKER: &str = "superseded.json";
/// The note an update whose content was left out carries in `_meta.acpmux`: the content's bytes.
const NOTE: &str = "supersededContent";
/// `_meta` keys no reader folds: Codex's output increments, which the call's content holds too.
const UNREAD_META: &[&str] = &["terminal_output_delta"];

/// Whether a record with this `dir` and `kind` starts a prompt: no call id carries across it.
fn starts_prompt(dir: &[u8], kind: &[u8]) -> bool {
    dir == b"mux" && matches!(kind, b"user_message" | b"turn_started")
}

/// The update of a `tool_call_update` record, if it is one.
fn update_of(rec: &mut EventRecord) -> Option<&mut Map<String, Value>> {
    if rec.kind != "tool_call_update" {
        return None;
    }
    let update = rec.msg.pointer_mut("/params/update")?.as_object_mut()?;
    let is_update = update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call_update");
    is_update.then_some(update)
}

/// The fields of an update a reader folds, `_meta` ones as `_meta.<key>` (and `_meta.acpmux.<key>`).
fn fields(update: &Map<String, Value>) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for (key, value) in update {
        match (key.as_str(), value.as_object()) {
            ("toolCallId" | "sessionUpdate", _) => {}
            ("content", _) if value.is_null() => {}
            ("_meta", Some(meta)) => {
                for (k, v) in meta {
                    match (k.as_str(), v.as_object()) {
                        (k, _) if UNREAD_META.contains(&k) => {}
                        ("acpmux", Some(acpmux)) => out.extend(
                            acpmux
                                .keys()
                                .filter(|k| *k != NOTE)
                                .map(|k| format!("_meta.acpmux.{k}")),
                        ),
                        _ => {
                            out.insert(format!("_meta.{k}"));
                        }
                    }
                }
            }
            _ => {
                out.insert(key.clone());
            }
        }
    }
    out
}

/// Takes the update's content out and notes how many bytes it held.
fn leave_out_content(update: &mut Map<String, Value>) -> bool {
    let Some(content) = update.remove("content") else { return false };
    let bytes = serde_json::to_string(&content).map_or(0, |s| s.len());
    let meta = update.entry("_meta").or_insert_with(|| Value::Object(Map::new()));
    if let Some(meta) = meta.as_object_mut() {
        let acpmux = meta.entry("acpmux").or_insert_with(|| Value::Object(Map::new()));
        if let Some(acpmux) = acpmux.as_object_mut() {
            acpmux.insert(NOTE.into(), Value::from(bytes));
        }
    }
    true
}

/// A newest-first read of a log's records: what each tool call's newer updates already carry.
#[derive(Default)]
pub struct Superseded {
    calls: HashMap<String, BTreeSet<String>>,
}

impl Superseded {
    /// Whether `rec`, the next older record of the read, stays; its content goes when a newer
    /// update of its call carries content. An update whose every field a newer one of its call
    /// carries goes whole, unless it ends the call. Every other record stays as it is.
    pub fn keep(&mut self, rec: &mut EventRecord) -> bool {
        // Older than a prompt: no newer update of this read is of the same call.
        if starts_prompt(rec.dir.as_bytes(), rec.kind.as_bytes()) {
            self.calls.clear();
            return true;
        }
        let Some(update) = update_of(rec) else { return true };
        let Some(id) = update.get("toolCallId").and_then(Value::as_str).map(str::to_owned) else {
            return true;
        };
        let fields = fields(update);
        let Some(newer) = self.calls.get_mut(&id) else {
            self.calls.insert(id, fields);
            return true;
        };
        let ends =
            matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        if !ends && fields.is_subset(newer) {
            return false;
        }
        if newer.contains("content") {
            leave_out_content(update);
        }
        newer.extend(fields);
        true
    }
}

/// The record head the first read of a segment takes from a `tool_call_update` line: the content
/// stays raw text, never a parsed tree.
#[derive(Deserialize)]
struct Head<'a> {
    #[serde(borrow)]
    msg: HeadMsg<'a>,
}

#[derive(Deserialize)]
struct HeadMsg<'a> {
    #[serde(borrow)]
    params: Option<HeadParams<'a>>,
}

#[derive(Deserialize)]
struct HeadParams<'a> {
    #[serde(borrow)]
    update: Option<HeadUpdate<'a>>,
}

#[derive(Deserialize)]
struct HeadUpdate<'a> {
    #[serde(rename = "sessionUpdate", borrow)]
    session_update: Option<Cow<'a, str>>,
    #[serde(rename = "toolCallId", borrow)]
    tool_call_id: Option<Cow<'a, str>>,
    #[serde(borrow)]
    content: Option<&'a RawValue>,
}

/// The call of a `tool_call_update` line that carries content.
fn content_call(line: &[u8]) -> Option<String> {
    if record_kind(line) != Some(b"tool_call_update".as_slice()) {
        return None;
    }
    let update = serde_json::from_slice::<Head>(line).ok()?.msg.params?.update?;
    (update.session_update.as_deref() == Some("tool_call_update") && update.content.is_some())
        .then_some(update.tool_call_id?.into_owned())
}

#[derive(Default, Serialize, Deserialize)]
struct Marker {
    through: u32,
}

fn read_marker(events: &Path) -> Marker {
    std::fs::read(events.join(MARKER))
        .ok()
        .and_then(|text| serde_json::from_slice(&text).ok())
        .unwrap_or_default()
}

/// Whether a sealed segment (any but the newest) past the marker waits.
fn waiting(events: &Path) -> Result<bool> {
    let segments = segments_in(events)?;
    let through = read_marker(events).through;
    Ok(segments.split_last().is_some_and(|(_, sealed)| sealed.iter().any(|(i, _)| *i > through)))
}

/// A pass over a log's sealed segments.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Pass {
    pub stats: Compaction,
    /// A segment changed under the pass (a retention rewrite, a delete, a move): it stopped there
    /// and left the marker before it, and nothing more is done until the next seal.
    pub stopped: bool,
}

/// The copy a rewrite writes beside a segment.
fn copy_path(segment: &Path) -> PathBuf {
    segment.with_extension("ndjson.superseded")
}

/// Removes the copy unless it was put in place.
struct Copy(Option<PathBuf>);

impl Drop for Copy {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// A file's identity: a segment replaced since it was read (a delete and a new chat of the same
/// id, a move's replacement) is another file even at the same length.
#[cfg(unix)]
fn identity(meta: &std::fs::Metadata) -> (u64, u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (meta.dev(), meta.ino(), meta.len())
}

#[cfg(not(unix))]
fn identity(meta: &std::fs::Metadata) -> (u64, u64, u64) {
    (0, 0, meta.len())
}

/// Leaves superseded content out of each sealed segment of the log in `events` past the marker,
/// oldest first, and moves the marker past each. The newest segment, the one appends go to, is
/// never read. Each copy goes in under `writers`, the lock a retention commit holds from its
/// length check to its last rename (`compact.rs`), and only over the very file it was read from.
pub(super) fn compact_sealed(events: &Path, writers: &Mutex<Writers>) -> Result<Pass> {
    let segments = segments_in(events)?;
    let mut pass = Pass::default();
    let Some(((_, _), sealed)) = segments.split_last() else { return Ok(pass) };
    // A copy a crash left (one thread per chat at a time: none is being written now).
    for (_, path) in &segments {
        let _ = std::fs::remove_file(copy_path(path));
    }
    let mut marker = read_marker(events);
    for (index, path) in sealed {
        if *index <= marker.through {
            continue;
        }
        let Some(done) = compact_segment(path, writers)? else {
            pass.stopped = true;
            return Ok(pass);
        };
        pass.stats.bytes_before += done.bytes_before;
        pass.stats.bytes_after += done.bytes_after;
        pass.stats.trimmed += done.trimmed;
        marker.through = *index;
        write_atomic(&events.join(MARKER), &serde_json::to_vec(&marker)?)?;
    }
    Ok(pass)
}

/// Rewrites one sealed segment beside itself without the content a later update of the same call
/// and prompt in it supersedes, and renames the copy over it. Nothing appends to a sealed segment;
/// one that is not the file it read any more (a retention pass rewrote it, the chat was deleted or
/// replaced) is left as it is now: None.
fn compact_segment(path: &Path, writers: &Mutex<Writers>) -> Result<Option<Compaction>> {
    let file = crate::config::private_state_file(path)?;
    let read = identity(&file.metadata()?);
    let len = read.2;
    let mut stats = Compaction { bytes_before: len, bytes_after: len, ..Compaction::default() };
    // First read: each content-bearing update, and each call's last one, by prompt.
    let mut bearing: Vec<(u64, (u64, String))> = Vec::new();
    let mut last: HashMap<(u64, String), u64> = HashMap::new();
    let mut prompt = 0u64;
    let mut line = Vec::new();
    let mut reader = BufReader::with_capacity(256 * 1024, (&file).take(len));
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        if let (Some(dir), Some(kind)) = (record_dir(&line), record_kind(&line))
            && starts_prompt(dir, kind)
        {
            prompt += 1;
        }
        if let Some(seq) = record_seq(&line)
            && let Some(call) = content_call(&line).map(|call| (prompt, call))
        {
            last.insert(call.clone(), seq);
            bearing.push((seq, call));
        }
    }
    let moot: HashSet<u64> = bearing
        .into_iter()
        .filter(|(seq, call)| last.get(call) != Some(seq))
        .map(|(seq, _)| seq)
        .collect();
    if moot.is_empty() {
        drop_cache(&file);
        return Ok(Some(stats));
    }
    let tmp = copy_path(path);
    let _ = std::fs::remove_file(&tmp);
    let mut copy = Copy(Some(tmp.clone()));
    let mut out = std::io::BufWriter::with_capacity(256 * 1024, open_private_append(&tmp)?);
    let mut after = 0u64;
    std::io::Seek::seek(&mut &file, std::io::SeekFrom::Start(0))?;
    let mut reader = BufReader::with_capacity(256 * 1024, (&file).take(len));
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        let shorter = record_seq(&line)
            .filter(|seq| moot.contains(seq))
            .and_then(|_| serde_json::from_slice::<EventRecord>(&line).ok())
            .and_then(|mut rec| {
                let left_out = update_of(&mut rec).is_some_and(leave_out_content);
                left_out.then(|| serde_json::to_vec(&rec).ok()).flatten()
            });
        match shorter {
            Some(mut record) => {
                record.push(b'\n');
                after += record.len() as u64;
                stats.trimmed += 1;
                out.write_all(&record)?;
            }
            None => {
                after += line.len() as u64;
                out.write_all(&line)?;
            }
        }
    }
    let out = out.into_inner().map_err(|e| e.into_error())?;
    out.sync_all()?;
    drop_cache(&out);
    drop_cache(&file);
    {
        let _writers = writers.lock_or_recover();
        if std::fs::symlink_metadata(path).map(|m| identity(&m)).ok() != Some(read) {
            return Ok(None);
        }
        std::fs::rename(&tmp, path)?;
        copy.0 = None;
    }
    if let Some(dir) = path.parent() {
        sync_directory(dir)?;
    }
    stats.bytes_after = after;
    Ok(Some(stats))
}

/// The chats whose sealed segments a thread is compacting now.
pub(super) type Sealing = Arc<Mutex<HashSet<String>>>;

impl LocalStore {
    /// Compact each segment of a chat once it is sealed (the daemon's store, `store::open`).
    pub fn compacting_sealed(mut self) -> Self {
        self.sealing = Some(Sealing::default());
        self
    }

    /// A segment of chat `id` was sealed (`append` opened its next one): its superseded content
    /// goes on a thread of its own, which takes the writers' lock only for each rename (appends
    /// never wait on a rewrite). One thread per chat at a time;
    /// its stop condition is that no sealed segment past the marker waits, checked under the lock
    /// a new seal takes, so a segment sealed while it runs is compacted by it or by the next one.
    /// On an error, or a segment that changed under it, it ends; the next seal tries again from
    /// the marker. A copy it leaves (a crash) is removed by the next pass.
    pub(super) fn sealed(&self, id: &str) {
        let Some(sealing) = &self.sealing else { return };
        if !sealing.lock_or_recover().insert(id.to_owned()) {
            return;
        }
        let events = self.dir(id).join("events");
        let writers = self.writers.clone();
        let (thread_sealing, thread_id) = (sealing.clone(), id.to_owned());
        let spawned =
            std::thread::Builder::new().name("acpmux-sealed-log".into()).spawn(move || {
                let (sealing, id) = (thread_sealing, thread_id);
                loop {
                    match compact_sealed(&events, &writers) {
                        Ok(pass) => {
                            let stats = pass.stats;
                            if stats.trimmed > 0 {
                                tracing::info!(
                                    session = %id,
                                    "sealed log segments: {} of {} bytes were superseded tool output",
                                    stats.bytes_before.saturating_sub(stats.bytes_after),
                                    stats.bytes_before
                                );
                            }
                            if pass.stopped {
                                sealing.lock_or_recover().remove(&id);
                                return;
                            }
                        }
                        Err(e) => {
                            tracing::warn!(session = %id, "sealed log segments: {e:#}");
                            sealing.lock_or_recover().remove(&id);
                            return;
                        }
                    }
                    let mut held = sealing.lock_or_recover();
                    if !waiting(&events).unwrap_or(false) {
                        held.remove(&id);
                        return;
                    }
                }
            });
        if spawned.is_err() {
            sealing.lock_or_recover().remove(id);
        }
    }

    /// Compacts chat `id`'s sealed segments now, on this thread.
    #[cfg(test)]
    pub(crate) fn compact_sealed_log(&self, id: &str) -> Result<Compaction> {
        Ok(compact_sealed(&self.dir(id).join("events"), &self.writers)?.stats)
    }

    /// Whether a thread compacts a sealed segment of chat `id` now.
    #[cfg(test)]
    pub(super) fn sealing_now(&self, id: &str) -> bool {
        self.sealing.as_ref().is_some_and(|s| s.lock_or_recover().contains(id))
    }
}

#[cfg(test)]
#[path = "superseded_tests.rs"]
mod tests;
