//! Part of `Hub` (a child of `transfer_out.rs`). A move whose history follows the chat: the
//! freeze carries the chat's last turns only, the chat runs on the target at once, and the
//! history before them arrives after, as a session pack (`cmux-session-pack`: about 12 times
//! smaller than the lines, and a target that holds an older copy is sent only the chunks it
//! lacks). Nothing is packed or hashed inside the freeze.
//!
//! Daemons that serve it list `crate::capabilities::TRANSFER_HISTORY_LATER`. A client asks for
//! it only when it is told to (`cli/run/transfer.rs` `history_later_turns`); without that every
//! move is as it was.
//!
//! 1. source `_acpmux/transfer_prepare {sessionId, historyLater: {keepTurns}}`: no freeze, and
//!    no copy of the log. `afterSeq` is the seq before the chat's last `keepTurns` turns began
//!    (earlier when a prompt that still waits was queued before that: the queue moves whole, in
//!    the freeze). The answer says `historyLater: true`; its files are the agent's own
//!    transcript, pre-copied as ever. The log through `afterSeq` is packed into the chat's pack
//!    store on a thread of its own at the lowest CPU priority meanwhile ([`Prepack`]), never inside a freeze.
//! 2. target `transfer_stage`, `transfer_write`, `transfer_stage_finish`: as for any prefix, but
//!    the staged segment is empty.
//! 3. source `transfer_begin {prepareId, afterSeq}`, target `transfer_receive {manifest,
//!    stageId}` and `transfer_finish`, source `transfer_commit`: unchanged. The chat's log on the
//!    target begins at `afterSeq + 1`, and its folder notes that the history through `afterSeq`
//!    is awaited (`transfer-history-pending.json`: that seq and the digest of its record).
//! 4. target `_acpmux/transfer_history_have {sessionId}`: the pack chunks it holds of the chat.
//!    source `_acpmux/transfer_history_export {sessionId, throughSeq, have}` (the chat has moved
//!    away; its copy keeps the log): the lines through `throughSeq` packed into the chat's
//!    pack store (`history-pack` in its folder; a chat packed before keeps its sealed segments) and
//!    bundled without the chunks in `have`. A prepare's pack of the same prefix that still holds
//!    is waited for and bundled as it is; one that does not (another prefix, a log rewritten, a
//!    pack that failed, a daemon restarted since) is packed again here. The answer is a prefix
//!    manifest with `packed`, read with `transfer_read`.
//! 5. target `transfer_stage {manifest}`, `transfer_write`, `transfer_stage_finish`: the bundle
//!    is unpacked into the chat's pack store there and read back as lines, each record then checked
//!    and written as for any staged prefix.
//! 6. target `_acpmux/transfer_history {sessionId, stageId}`: the staged records become the
//!    live chat's segment `000000` (`Store::history_writer`, as a fork's history does), the
//!    log's stamp goes up so no page cached before is served, the note goes, and a
//!    `history_arrived` record says so. Refused `transfer.diverged` unless the stage ends at
//!    the awaited seq with the awaited digest.
//!
//! Until step 6 the chat on the target shows and pages only its tail, and what a daemon folds
//! from the whole log is folded from the tail. A client that dies between 3 and 6 leaves the
//! note: the history is still on the source, whose copy of a moved chat keeps its log, and
//! steps 4 to 6 can run again. A chat that awaits its history does not move on.

use super::transfer_precopy::PREFIX_SCHEMA;
use super::*;
use crate::hub::transfer_out::{bundle_files, inside, transfers_dir};
use cmux_session_pack as pack;

/// The one file of a history export's manifest: a session-pack bundle.
pub(in crate::hub) const HISTORY_FILE: &str = "events/history.cspb";

#[path = "pack_as_it_grows.rs"]
mod pack_as_it_grows;
/// Each chat's newest history-later prepare's pack ([`Hub::prepack_history`]): the seq it packs
/// through, and its result once done.
static PREPACKS: std::sync::LazyLock<std::sync::Mutex<HashMap<String, (u64, Arc<Prepack>)>>> =
    std::sync::LazyLock::new(Default::default);

/// The chats whose log is being packed or bundled, one at a time each: two packs of one chat
/// would write its manifest and the pack's temporary files at once, and a pack that ends
/// between an export's read of the manifest and its bundle would change what it bundles.
static PACKING: std::sync::LazyLock<(
    std::sync::Mutex<std::collections::HashSet<String>>,
    std::sync::Condvar,
)> = std::sync::LazyLock::new(Default::default);

/// A chat's turn at its pack store ([`PACKING`]), held until dropped.
pub(in crate::hub) struct PackTurn(String);

impl PackTurn {
    /// Waits for chat `id`'s turn.
    pub(in crate::hub) fn take(id: &str) -> Self {
        let (packing, freed) = &*PACKING;
        let mut packing = packing.lock().unwrap_or_else(|e| e.into_inner());
        while packing.contains(id) {
            packing = freed.wait(packing).unwrap_or_else(|e| e.into_inner());
        }
        packing.insert(id.to_owned());
        Self(id.to_owned())
    }
}

impl Drop for PackTurn {
    fn drop(&mut self) {
        let (packing, freed) = &*PACKING;
        packing.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.0);
        freed.notify_all();
    }
}

/// A prepare's pack of a chat's history: `None` while it runs, then `Some` of what it made
/// (`None` inside when it failed).
#[derive(Default)]
struct Prepack {
    packed: std::sync::Mutex<Option<Option<Prepacked>>>,
    ready: std::sync::Condvar,
}

#[derive(Clone)]
struct Prepacked {
    stamp: u64,
    digest: String,
    manifest: pack::Manifest,
    stats: pack::PackStats,
    ms: u64,
}

/// About the most bytes of lines one piece of a whole pack writes and holds in memory
/// ([`Hub::pack_whole_in_pieces`]): 64 of the pack's 4 MiB segments. Small in tests, so a whole
/// pack of a test chat runs in several pieces.
const WHOLE_PIECE: u64 = if cfg!(test) { 6 << 20 } else { 256 << 20 };

/// A writer that counts the bytes written through it.
struct Counted<W>(W, u64);

impl<W: std::io::Write> std::io::Write for Counted<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.0.write(buf)?;
        self.1 += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

/// The most records one scan of [`Hub::write_lines`] writes before it lets the store's
/// fork-view lock go and scans on from the last one. Three in tests, so every export and pack
/// test writes its lines in several passes and checks they are the bytes one pass wrote.
const WRITE_LINES_PASS: usize = if cfg!(test) { 3 } else { 2_000 };

/// The calling thread at the lowest CPU priority, and the threads it starts after: nice 19 on
/// Linux (a thread's own, inherited by the threads it starts), the background band on macOS.
/// Best effort: a refusal leaves it as it was.
pub(in crate::hub) fn lower_this_thread() {
    #[cfg(target_os = "linux")]
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS, tid, 19);
    }
    #[cfg(target_os = "macos")]
    unsafe {
        libc::setpriority(libc::PRIO_DARWIN_THREAD, 0, libc::PRIO_DARWIN_BG);
    }
}

/// Ends a [`Prepack`] when dropped, with what it made.
struct PrepackDone<'a> {
    slot: &'a Prepack,
    packed: Option<Prepacked>,
}

impl Drop for PrepackDone<'_> {
    fn drop(&mut self) {
        let mut slot = self.slot.packed.lock().unwrap_or_else(|e| e.into_inner());
        *slot = Some(self.packed.take());
        self.slot.ready.notify_all();
    }
}

/// The chat folder's note that its history through a seq has not arrived.
const PENDING_FILE: &str = "transfer-history-pending.json";

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

/// The digest a prefix token (`<prepare>:<seq>:<digest>`) ends with.
fn token_digest(token: &Value) -> &str {
    token.as_str().and_then(|t| t.rsplit(':').next()).unwrap_or_default()
}

pub(in crate::hub) fn pack_error(e: pack::Error) -> anyhow::Error {
    anyhow::anyhow!("session pack: {e}")
}

/// The folder of a chat's pack store, in the chat's own folder.
const PACK_DIR: &str = "history-pack";

/// A seal's scratch folder in chat pack store `store` (`pack_as_it_grows.rs`), named for this
/// process, `work-<pid>-<kind>-<uuid>`, as a move's scratch is (`transfer_out.rs` `scratch_dir`):
/// it holds the lines the seal encodes (a whole pack's are the whole log, 6 to 8 GB for a long
/// chat). Removed when its [`PackScratch`] drops; one a daemon left as it died is removed by the
/// next start's sweep ([`Hub::sweep_pack_work`]) or the chat's next seal ([`sweep_pack_work_in`]).
pub(in crate::hub) fn pack_work_dir(store: &pack::Store, kind: &str) -> PathBuf {
    let id = uuid::Uuid::now_v7().simple();
    store.root().join(format!("work-{}-{kind}-{id}", std::process::id()))
}

/// A scratch folder removed when dropped, on an error or a panic as on success.
pub(in crate::hub) struct PackScratch(pub PathBuf);

impl Drop for PackScratch {
    fn drop(&mut self) {
        let _ = crate::home_fs::remove_dir_all(&self.0);
    }
}

/// Removes the `work-*` scratch folders in chat pack store folder `dir` that no running daemon
/// owns (`transfer_out.rs` `dead_scratch`): a daemon's that died sealing, or one of a build that
/// named them without its pid and predates this daemon. The pack itself (`chunks/`, `sessions/`)
/// is the chat's history and is never touched. Returns the folders and bytes removed.
pub(in crate::hub) fn sweep_pack_work_in(dir: &Path) -> (u64, u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return (0, 0) };
    let (mut count, mut bytes) = (0, 0);
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(meta) = entry.metadata() else { continue };
        if !name.starts_with("work-") || !meta.is_dir() {
            continue;
        }
        if !super::transfer_out::dead_scratch(&name, meta.modified().ok()) {
            continue;
        }
        let size = tree_bytes(&entry.path());
        match crate::home_fs::remove_dir_all(entry.path()) {
            Ok(()) => {
                tracing::info!(dir = %dir.display(), "removed {name} ({size} bytes): a pack's scratch of a daemon that is gone");
                count += 1;
                bytes += size;
            }
            Err(error) => tracing::warn!(dir = %dir.display(), "{name} not removed: {error}"),
        }
    }
    (count, bytes)
}

/// The bytes of the files under `dir` (a scratch folder is one level of files).
fn tree_bytes(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    entries
        .flatten()
        .filter_map(|e| e.metadata().ok())
        .map(|m| if m.is_dir() { 0 } else { m.len() })
        .sum()
}

/// Whether a staged manifest's files are a history export's bundle, to be unpacked first.
pub(in crate::hub) fn is_packed(manifest: &Value) -> bool {
    manifest.get("packed").is_some_and(|p| !p.is_null())
}

/// `Hub::unpack_staged` unpacks a staged history bundle (`bundle/events/history.cspb`) into the
/// chat's pack store here and writes its lines to `bundle/events/000001.ndjson`, where `transfer_stage_finish` reads a
/// prefix's records. The bundle names every chunk by its hash, and a chunk that is not what its
/// name says is refused.
impl Hub {
    /// Chat `id`'s pack store, in its folder here (it goes when the chat does): its packed
    /// history, content-addressed, so a chat packed again keeps what it had and a chat that
    /// comes back is sent only what is new.
    pub(in crate::hub) fn pack_store(&self, id: &str) -> anyhow::Result<pack::Store> {
        let chat = self.store.session_dir(id);
        let dir = chat.ok_or_else(|| anyhow::anyhow!("this store keeps no packs"))?.join(PACK_DIR);
        // In the chat's folder, which the store made owner-only; made through the held home.
        crate::home_fs::create_dir_all(&dir, 0o700)?;
        Ok(pack::Store::new(dir))
    }

    /// Removes every chat's pack scratch a daemon before this one left
    /// ([`sweep_pack_work_in`]), on a thread of its own: listing a folder a chat is cheap, the
    /// removal of gigabytes is not, and nothing waits for it. Called once the store's index is
    /// read (`store_load.rs`), after [`super::transfer_out::note_started`].
    pub(in crate::hub) fn sweep_pack_work(&self) {
        let mut ids: Vec<String> = self.sessions().iter().map(|s| s.id.clone()).collect();
        ids.extend(self.evicted.rows().iter().map(|row| row.keys.id.clone()));
        let dirs: Vec<PathBuf> = ids
            .iter()
            .filter_map(|id| self.store.session_path(id))
            .map(|chat| chat.join(PACK_DIR))
            .filter(|dir| dir.is_dir())
            .collect();
        if dirs.is_empty() {
            return;
        }
        let spawned = std::thread::Builder::new().name("acpmux-pack-sweep".into()).spawn(move || {
            lower_this_thread();
            let (mut count, mut bytes) = (0, 0);
            for dir in dirs {
                let (c, b) = sweep_pack_work_in(&dir);
                count += c;
                bytes += b;
            }
            if count > 0 {
                tracing::info!("removed {count} chat pack scratch folders ({bytes} bytes) a daemon before this one left");
            }
        });
        if let Err(error) = spawned {
            tracing::warn!("chat pack scratch not swept: {error}");
        }
    }

    /// Unpacks chat `chat`'s staged history bundle (the module's step 5).
    pub(in crate::hub) fn unpack_staged(&self, bundle: &Path, chat: &str) -> anyhow::Result<()> {
        use std::io::Write as _;
        let file = inside(bundle, HISTORY_FILE).map_err(|e| anyhow::anyhow!("{}", e.message))?;
        let store = self.pack_store(chat)?;
        // It writes the chat's manifest, as a pack does.
        let _turn = PackTurn::take(chat);
        let mut input = std::io::BufReader::new(std::fs::File::open(&file)?);
        let manifest = pack::ship::unbundle(&store, &mut input, pack::ship::Lacking::Refuse)
            .map_err(pack_error)?
            .ok_or_else(|| anyhow::anyhow!("the history bundle names no session"))?;
        anyhow::ensure!(manifest.name == chat, "the history bundle is of another chat");
        let lines = file.with_file_name("000001.ndjson");
        let mut out = std::io::BufWriter::new(crate::home_fs::create_file(&lines)?);
        pack::Pack::with_manifest(&store, manifest).cat(&mut out).map_err(pack_error)?;
        out.flush()?;
        crate::home_fs::remove_file(&file)?;
        Ok(())
    }

    /// The last seq of the history a move leaves to follow when it keeps the chat's last
    /// `keep_turns` turns in its freeze: the seq before the first of them began (its
    /// `user_message`, or its `turn_started` when none came with it), and before the `queued`
    /// record of every prompt that still waits. Zero (nothing follows: the whole log moves in
    /// the freeze) for a chat with fewer turns.
    fn history_cut(&self, session: &Session, keep_turns: u64) -> anyhow::Result<u64> {
        let through = session.seq.load(Ordering::SeqCst);
        let waiting: std::collections::HashSet<String> = session
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .map(|q| q.prompt_id.clone())
            .collect();
        let keep = usize::try_from(keep_turns.max(1)).unwrap_or(usize::MAX);
        let mut starts = std::collections::VecDeque::<u64>::new();
        let (mut said, mut first_waiting) = (None::<u64>, None::<u64>);
        self.store.scan_kinds(
            &session.id,
            &["user_message", "turn_started", "queued"],
            &mut |rec| {
                if rec.seq > through {
                    return false;
                }
                match rec.kind.as_str() {
                    "queued" => {
                        let id = rec.msg.get("promptId").and_then(Value::as_str);
                        if first_waiting.is_none() && id.is_some_and(|id| waiting.contains(id)) {
                            first_waiting = Some(rec.seq);
                        }
                    }
                    "user_message" => {
                        said.get_or_insert(rec.seq);
                    }
                    _ => {
                        if starts.len() == keep {
                            starts.pop_front();
                        }
                        starts.push_back(said.take().unwrap_or(rec.seq));
                    }
                }
                true
            },
        )?;
        let kept = if starts.len() < keep { None } else { starts.front().copied() };
        let mut cut = kept.map_or(0, |start| start.saturating_sub(1));
        if let Some(queued) = first_waiting {
            cut = cut.min(queued.saturating_sub(1));
        }
        Ok(cut)
    }

    /// A `transfer_prepare` whose history follows the chat: the seq its history ends at, the
    /// digest of that record, and the log's stamp read before. No line is copied.
    pub(in crate::hub) fn later_prefix(
        &self,
        session: &Session,
        keep_turns: u64,
        events: &Path,
    ) -> Result<(u64, String, u64), RpcError> {
        let fail =
            |e: &dyn std::fmt::Display| RpcError::internal(format!("transfer: prepare: {e}"));
        let stamp = self.store.log_stamp(&session.id).map_err(|e| fail(&e))?;
        let cut = self.history_cut(session, keep_turns).map_err(|e| fail(&e))?;
        crate::home_fs::create_dirs(events).map_err(|e| fail(&e))?;
        let digest = self.digest_at(&session.id, cut)?.unwrap_or_default();
        Ok((cut, digest, stamp))
    }

    fn pending_note(&self, id: &str) -> Option<PathBuf> {
        Some(self.store.session_dir(id)?.join(PENDING_FILE))
    }

    /// At a finish: the chat's folder notes the history it awaits, when the receive's staged
    /// prefix was one whose history follows. A store with no folder notes nothing, and takes no
    /// history later.
    pub(in crate::hub) fn note_history_pending(&self, session: &Session, receive_dir: &Path) {
        let Some(staged) = read_json(&receive_dir.join("prefix.json")) else { return };
        let after = field(&staged, "afterSeq").as_u64().unwrap_or(0);
        if *field(&staged, "historyLater") != true || after == 0 {
            return;
        }
        let Some(note) = self.pending_note(&session.id) else { return };
        let awaited = json!({"afterSeq": after, "digest": token_digest(field(&staged, "token"))});
        if let Err(error) = crate::home_fs::write(&note, awaited.to_string()) {
            tracing::warn!(session = %session.id, "awaited history not noted: {error:#}");
        }
    }

    /// The history a chat here awaits: `(afterSeq, digest)`.
    fn history_awaited(&self, id: &str) -> Option<(u64, String)> {
        let note = read_json(&self.pending_note(id)?)?;
        let digest = field(&note, "digest").as_str().unwrap_or_default().to_owned();
        Some((field(&note, "afterSeq").as_u64()?, digest))
    }

    /// Refuses a move of a chat whose history has not arrived: its log here is its tail alone,
    /// and a move would carry that as the whole chat.
    pub(in crate::hub) fn refuse_while_history_awaited(
        &self,
        session: &Session,
    ) -> Result<(), RpcError> {
        match self.history_awaited(&session.id) {
            Some((after, _)) => Err(transfer_error(
                "history_pending",
                format!("its history through seq {after} has not arrived yet; move it after"),
            )),
            None => Ok(()),
        }
    }

    /// `_acpmux/transfer_history_have {sessionId}`: the pack chunks this daemon holds of the
    /// chat, for a source to leave out of its export.
    pub(in crate::hub) fn transfer_history_have(&self, params: &Value) -> Result<Value, RpcError> {
        let id = params.get("sessionId").and_then(Value::as_str).unwrap_or("");
        if !super::super::transfer::is_plain_id(id) {
            return Err(RpcError::invalid_params("transfer: history_have needs a sessionId"));
        }
        let held = || -> anyhow::Result<Vec<String>> {
            let store = self.pack_store(id)?;
            let Some(manifest) = pack::Manifest::load(&store, id).map_err(pack_error)? else {
                return Ok(Vec::new());
            };
            let ids = manifest.chunk_ids().map_err(pack_error)?;
            Ok(ids.iter().filter(|id| store.has(id)).map(pack::hex).collect())
        };
        // A store that cannot be read holds nothing: the export is then sent whole.
        Ok(json!({"sessionId": id, "have": held().unwrap_or_default()}))
    }

    /// `_acpmux/transfer_history_export {sessionId, throughSeq, have}`: the chat's lines
    /// through `throughSeq` as a session-pack bundle, without the chunks in `have`. Of a chat
    /// here or one that moved away (its copy keeps the log).
    pub(in crate::hub) fn transfer_history_export(
        &self,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let Some(through) = params.get("throughSeq").and_then(Value::as_u64).filter(|s| *s > 0)
        else {
            return Err(RpcError::invalid_params("transfer: history_export needs a throughSeq"));
        };
        let have: std::collections::HashSet<pack::Id> = field(params, "have")
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|id| pack::unhex(id.as_str()?).ok())
            .collect();
        self.sweep();
        // Named and swept as a prepare is: it is read the same way (`transfer_read`).
        let export_id = format!("pre-{}", uuid::Uuid::now_v7());
        let root = transfers_dir().join(&export_id);
        let made = self.pack_history(session, through, &have, &root, &export_id);
        made.map_err(|e| {
            let _ = crate::home_fs::remove_dir_all(&root);
            transfer_error("history", format!("{e:#}"))
        })
    }

    fn pack_history(
        &self,
        session: &Arc<Session>,
        through: u64,
        have: &std::collections::HashSet<pack::Id>,
        root: &Path,
        export_id: &str,
    ) -> anyhow::Result<Value> {
        use std::io::Write as _;
        let started = std::time::Instant::now();
        let chat = root.join(&session.id);
        crate::home_fs::create_dirs(chat.join("events"))?;
        let store = self.pack_store(&session.id)?;
        // The prepare's pack is waited for before the turn is taken (its thread holds the turn
        // while it packs); the turn then stands from the check of what it made to the bundle.
        let waited = Self::prepack_waited(&session.id, through);
        let _turn = PackTurn::take(&session.id);
        let prepacked = waited.and_then(|p| self.still_packed(session, through, &store, p));
        let (manifest, stats, digest, prepack_ms) = match prepacked {
            Some(p) => (p.manifest, p.stats, p.digest, Some(p.ms)),
            None => {
                let (manifest, stats, digest) =
                    self.pack_through(session, through, &store, root)?;
                (manifest, stats, digest, None)
            }
        };
        let bundle = chat.join(HISTORY_FILE);
        let mut out = std::io::BufWriter::new(crate::home_fs::create_file(&bundle)?);
        let shipped =
            pack::ship::bundle(&store, &session.id, have, &mut out).map_err(pack_error)?;
        out.flush()?;
        drop(out);
        let files: Vec<Value> = bundle_files(&chat)?
            .into_iter()
            .map(|(path, size)| json!({"path": path, "size": size}))
            .collect();
        super::super::transfer_watch::note_activity(root, None);
        let packed = json!({
            "schema": pack::SCHEMA,
            "rawBytes": stats.raw_bytes,
            "lines": manifest.lines,
            "packedBytes": stats.stored_bytes,
            "bundleBytes": shipped.bytes,
            "chunks": shipped.chunks,
            "sessionChunks": shipped.session_chunks,
            "keptSegments": stats.kept_segments,
            "ms": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            "prepackMs": prepack_ms,
        });
        Ok(json!({
            "schema": PREFIX_SCHEMA,
            "prepareId": export_id,
            "sessionId": session.id,
            "afterSeq": through,
            "token": format!("{export_id}:{through}:{digest}"),
            "packed": packed,
            "files": files,
        }))
    }

    /// Packs chat `session`'s log through seq `through` into `store` as the chat, from its lines
    /// as an export writes them (written in `work` and removed after). Returns the manifest,
    /// what the pack did, and the digest of the record at `through`.
    ///
    /// The pack's sealed segments through `through` that still hold the log are kept, and only
    /// the lines after them are written and encoded ([`Self::pack_kept_through`]): a compaction's
    /// outline or an export of a long chat costs about what changed since the last seal, not the
    /// whole log. Before, every one wrote the whole log to `work` first (an 8.6 GB chat's outline
    /// wrote 8 GB, and at each compaction again). A pack with nothing to keep packs whole.
    pub(in crate::hub) fn pack_through(
        &self,
        session: &Session,
        through: u64,
        store: &pack::Store,
        work: &Path,
    ) -> anyhow::Result<(pack::Manifest, pack::PackStats, String)> {
        crate::home_fs::create_dirs(work)?;
        if let Some(kept) = self.pack_kept_through(session, through, store, work)? {
            return Ok(kept);
        }
        let lines = work.join("history.ndjson");
        let packed = self.pack_whole_in_pieces(session, through, store, &lines);
        let _ = crate::home_fs::remove_file(&lines);
        packed
    }

    /// A whole pack of chat `session`'s log through `through`, in pieces of about
    /// [`WHOLE_PIECE`] of lines: each piece is written to `lines`, encoded, and its sealed
    /// segments saved in the manifest; the next piece starts after the last sealed segment
    /// ([`pack::pack_after`]), so the open tail a piece ends with is encoded again with the next.
    /// A segment seals at a fixed count of bytes from its start, so the pack is the one a single
    /// pass makes (`pack_as_it_grows.rs` extends a pack the same way).
    ///
    /// Before, the whole log was written to `lines` and then read into memory at once: an 8 GB
    /// chat's pack took 8 GB of scratch on disk and 8 GB of memory, and saved nothing until it
    /// ended. A daemon killed in it (a NIGHTLY's take-over) kept nothing, so the next daemon's
    /// first seal packed the whole log again: Leo's Mac held five of these folders of one chat,
    /// 3.4 to 7.8 GB each, from 11-26 to 11-27. Now the scratch and the memory are a piece's,
    /// and a pack cut short keeps every piece it finished: the next one checks and keeps them.
    fn pack_whole_in_pieces(
        &self,
        session: &Session,
        through: u64,
        store: &pack::Store,
        lines: &Path,
    ) -> anyhow::Result<(pack::Manifest, pack::PackStats, String)> {
        let params = pack::Params::default();
        let files = vec![lines.to_path_buf()];
        let (mut after_seq, mut after_line, mut piece) = (0u64, 0u64, WHOLE_PIECE);
        let mut total = pack::PackStats::default();
        let mut first = true;
        loop {
            let (last, digest, capped) =
                self.write_lines_capped(session, after_seq, through, lines, piece)?;
            if !capped {
                anyhow::ensure!(last == through, "the log here holds no record at seq {through}");
            }
            let (manifest, stats) = if after_line == 0 {
                pack::pack(store, &session.id, &files, &params, false).map_err(pack_error)?
            } else {
                pack::pack_after(store, &session.id, after_line, &files, &params)
                    .map_err(pack_error)?
                    .ok_or_else(|| anyhow::anyhow!("the pack changed under a whole pack"))?
            };
            if first {
                total.kept_segments = stats.kept_segments;
                first = false;
            }
            total.raw_bytes = stats.raw_bytes;
            total.stored_bytes = stats.stored_bytes;
            total.manifest_bytes = stats.manifest_bytes;
            total.encoded_bytes += stats.encoded_bytes;
            total.new_chunks += stats.new_chunks;
            total.new_bytes += stats.new_bytes;
            if !capped {
                return Ok((manifest, total, digest));
            }
            let end = manifest.segments.iter().take_while(|s| s.sealed).last();
            match end.and_then(|s| Some((s.line + s.lines, s.seq?.1))) {
                Some((line, seq)) if line > after_line => {
                    (after_line, after_seq, piece) = (line, seq, WHOLE_PIECE);
                }
                // No segment sealed in the piece (records larger than it): a larger one.
                Some(_) => piece = piece.saturating_mul(2),
                // Segments without seqs cannot be continued from: the rest in one piece.
                None => piece = u64::MAX,
            }
        }
    }

    /// [`Self::write_lines`] that stops after the line that takes it to `cap` bytes; also
    /// whether it stopped there (the records through `through` are then not all written).
    fn write_lines_capped(
        &self,
        session: &Session,
        after: u64,
        through: u64,
        lines: &Path,
        cap: u64,
    ) -> anyhow::Result<(u64, String, bool)> {
        use std::io::Write as _;
        let mut out = Counted(std::io::BufWriter::new(crate::home_fs::create_file(lines)?), 0);
        let (last, digest, capped) = self.emit_lines_capped(session, after, through, &mut out, cap)?;
        out.flush()?;
        Ok((last, digest, capped))
    }

    /// [`Self::pack_through`] from the pack's sealed segments that end by `through`: those the
    /// log still holds byte for byte are kept, the lines after them are written to `work` and
    /// encoded. The segments are trusted unchecked while the log's stamp is the one a pack that
    /// checked them recorded (`pack_checked`, as a seal trusts them, `pack_as_it_grows.rs`);
    /// otherwise each is checked by hashing the log's lines as they are made, never written
    /// ([`pack::SegmentCheck`]). `None` when no sealed segment is kept: the caller packs whole.
    fn pack_kept_through(
        &self,
        session: &Session,
        through: u64,
        store: &pack::Store,
        work: &Path,
    ) -> anyhow::Result<Option<(pack::Manifest, pack::PackStats, String)>> {
        let params = pack::Params::default();
        let Some(manifest) = pack::Manifest::load(store, &session.id).map_err(pack_error)? else {
            return Ok(None);
        };
        if manifest.params != params || manifest.turn_rule < pack::TURN_RULE {
            return Ok(None);
        }
        let stamp = self.store.log_stamp(&session.id)?;
        let candidates: Vec<&pack::Segment> = manifest
            .segments
            .iter()
            .take_while(|s| s.sealed && s.seq.is_some_and(|(_, hi)| hi <= through))
            .collect();
        let Some(last) = candidates.last().and_then(|s| s.seq) else { return Ok(None) };
        let trusted = self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).get(&session.id)
            == Some(&stamp);
        let keep = if trusted {
            candidates.len()
        } else {
            let mut check = pack::SegmentCheck::new(&candidates);
            let checked = {
                let mut out = std::io::BufWriter::with_capacity(1 << 20, &mut check);
                self.emit_lines(session, 0, last.1, &mut out).and_then(|_| {
                    use std::io::Write as _;
                    Ok(out.flush()?)
                })
            };
            match checked {
                Ok(_) => check.matched(),
                Err(_) if check.diverged() => check.matched(),
                Err(e) => return Err(e),
            }
        };
        let Some(after) = keep.checked_sub(1).and_then(|i| candidates.get(i)).and_then(|s| s.seq)
        else {
            return Ok(None);
        };
        let after = after.1;
        let lines = work.join("history.ndjson");
        let written = self.write_lines(session, after, through, &lines);
        let packed = written.and_then(|(last, digest)| {
            anyhow::ensure!(last == through, "the log here holds no record at seq {through}");
            let digest = match digest.is_empty() {
                // Nothing after the kept segments: the record at `through` ends the last of them.
                true => self
                    .digest_at(&session.id, through)
                    .map_err(|e| anyhow::anyhow!("{}", e.message))?
                    .ok_or_else(|| {
                        anyhow::anyhow!("the log here holds no record at seq {through}")
                    })?,
                false => digest,
            };
            let files = std::slice::from_ref(&lines);
            let packed = pack::pack_kept(store, &session.id, keep, files, &params);
            Ok(packed.map_err(pack_error)?.map(|(manifest, stats)| (manifest, stats, digest)))
        });
        let _ = crate::home_fs::remove_file(&lines);
        let packed = packed?;
        if packed.is_some() && self.store.log_stamp(&session.id)? == stamp {
            // Every sealed segment the pack names now was checked against the log at `stamp`
            // (kept ones by hash or by the same trust, the rest encoded from it here).
            self.pack_checked
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(session.id.clone(), stamp);
        }
        Ok(packed)
    }

    /// Writes chat `session`'s records after seq `after` through seq `through` to `lines`, one a
    /// line as an export writes them (after [`Hub::display_logged`]), so a chat packed again, or
    /// packed as it grows (`pack_as_it_grows.rs`), packs the same bytes. Returns the last seq
    /// written (`after` when none) and the digest of the record at `through` (empty when the log
    /// holds none there).
    fn write_lines(
        &self,
        session: &Session,
        after: u64,
        through: u64,
        lines: &Path,
    ) -> anyhow::Result<(u64, String)> {
        use std::io::Write as _;
        let mut out = std::io::BufWriter::new(crate::home_fs::create_file(lines)?);
        let written = self.emit_lines(session, after, through, &mut out)?;
        out.flush()?;
        Ok(written)
    }

    /// [`Self::write_lines`] into any writer: the same bytes, the same answer.
    fn emit_lines(
        &self,
        session: &Session,
        after: u64,
        through: u64,
        out: &mut dyn std::io::Write,
    ) -> anyhow::Result<(u64, String)> {
        let mut out = Counted(out, 0);
        let (last, digest, _) = self.emit_lines_capped(session, after, through, &mut out, u64::MAX)?;
        Ok((last, digest))
    }

    /// [`Self::emit_lines`] that stops after the line that takes `out` to `cap` bytes.
    fn emit_lines_capped<W: std::io::Write>(
        &self,
        session: &Session,
        after: u64,
        through: u64,
        out: &mut Counted<W>,
        cap: u64,
    ) -> anyhow::Result<(u64, String, bool)> {
        use std::io::Write as _;
        let (mut last, mut digest, mut failed) = (after, String::new(), None::<anyhow::Error>);
        let mut capped = false;
        // In passes of at most WRITE_LINES_PASS records, each a scan of its own: a scan holds the
        // store's fork-view lock (`store/fork_view.rs` `dropping`, one for every chat) shared for
        // its whole run, a cold archive commit waits for it exclusively, and every read of any
        // chat queues behind that waiting commit. A whole 30 MB log written in one scan, on the
        // pack worker's background-priority thread (`pack_as_it_grows.rs`) of a loaded host, held
        // it for minutes (the coordinator Mac, 2026-11-27: every acpmux delivery there timed out).
        loop {
            let (mut seen, mut ended) = (0usize, true);
            let from = last;
            self.store.scan(&session.id, from, &mut |mut e: EventRecord| {
                if e.seq > through {
                    return false;
                }
                let at_end = e.seq == through;
                let step = (|| -> anyhow::Result<()> {
                    if at_end {
                        digest = crate::sha256::sha256_hex(&serde_json::to_vec(&e)?);
                    }
                    last = e.seq;
                    self.display_logged(Some(session), &mut e);
                    serde_json::to_writer(&mut *out, &e)?;
                    out.write_all(b"\n")?;
                    Ok(())
                })();
                if let Err(e) = step {
                    failed = Some(e);
                }
                seen += 1;
                let more = failed.is_none() && !at_end;
                if more && out.1 >= cap {
                    capped = true;
                    return false;
                }
                if more && seen >= WRITE_LINES_PASS {
                    // This pass ends here; the next one starts after `last`.
                    ended = false;
                    return false;
                }
                more
            })?;
            if failed.is_some() || capped || ended || last == from {
                break;
            }
        }
        if let Some(e) = failed {
            return Err(e);
        }
        Ok((last, digest, capped))
    }

    /// At a history-later prepare through seq `through`: packs the chat's log through it into
    /// its pack store on a thread of its own, so the export after the move's commit only bundles.
    /// The freeze never waits for it; the export does ([`Self::prepacked`]).
    pub(in crate::hub) fn prepack_history(self: &Arc<Self>, session: &Arc<Session>, through: u64) {
        let slot = Arc::new(Prepack::default());
        PREPACKS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(session.id.clone(), (through, slot.clone()));
        let (hub, session, unstarted) = (self.clone(), session.clone(), slot.clone());
        let run = move || {
            // Set however the pack ends, so an export never waits on one that panicked.
            let mut done = PrepackDone { slot: &slot, packed: None };
            // One pack of a chat at a time; a prepare that a later one replaced while it waited
            // packs nothing (no export asks for it). One whose export already took its slot
            // still packs: that export waits for it.
            let _turn = PackTurn::take(&session.id);
            let newest = PREPACKS
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&session.id)
                .is_none_or(|(_, newest)| Arc::ptr_eq(newest, &slot));
            if !newest {
                return;
            }
            let started = std::time::Instant::now();
            let work = super::transfer_out::scratch_dir("prepack");
            let packed = hub.pack_store(&session.id).and_then(|store| {
                let stamp = hub.store.log_stamp(&session.id)?;
                let (manifest, stats, digest) =
                    hub.pack_through(&session, through, &store, &work)?;
                Ok(Prepacked { stamp, digest, manifest, stats, ms: 0 })
            });
            let _ = crate::home_fs::remove_dir_all(&work);
            match packed {
                Ok(mut p) => {
                    p.ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
                    done.packed = Some(p);
                }
                Err(error) => {
                    tracing::debug!(session = %session.id, "history not packed at prepare: {error:#}");
                }
            }
        };
        // Its own thread, at the lowest CPU priority: the pack encodes on every core (zstd 19)
        // for seconds, and a move's begin that runs meanwhile must not wait for a core.
        let spawned = std::thread::Builder::new().name("acpmux-prepack".into()).spawn(move || {
            lower_this_thread();
            run();
        });
        if let Err(error) = spawned {
            tracing::debug!("history not packed at prepare: {error}");
            // No thread ends the slot: ended here, as failed, so the export packs.
            drop(PrepackDone { slot: &unstarted, packed: None });
        }
    }

    /// The prepare's pack of chat `id`'s log through `through`, waited for: `None` when there
    /// is none through that seq or it failed.
    fn prepack_waited(id: &str, through: u64) -> Option<Prepacked> {
        // Taken: one export uses it, and a later one packs again (keeping its sealed segments).
        let mut all = PREPACKS.lock().unwrap_or_else(|e| e.into_inner());
        let slot = all.remove(id).filter(|(at, _)| *at == through);
        drop(all);
        let (_, slot) = slot?;
        let mut packed = slot.packed.lock().unwrap_or_else(|e| e.into_inner());
        while packed.is_none() {
            packed = slot.ready.wait(packed).unwrap_or_else(|e| e.into_inner());
        }
        packed.as_ref()?.clone()
    }

    /// The prepare's pack `p` of chat `session`'s log through `through`, when it is still what
    /// `store` holds of the chat and the log through `through` is as it was packed: the same
    /// log stamp (not rewritten) and the same record at `through`. Read under the chat's
    /// [`PackTurn`], so no pack changes the manifest after.
    fn still_packed(
        &self,
        session: &Session,
        through: u64,
        store: &pack::Store,
        p: Prepacked,
    ) -> Option<Prepacked> {
        let stamp = self.store.log_stamp(&session.id).ok();
        let digest = self.digest_at(&session.id, through).ok().flatten();
        let manifest = pack::Manifest::load(store, &session.id).ok().flatten()?;
        let same = stamp == Some(p.stamp)
            && digest.as_deref() == Some(p.digest.as_str())
            && manifest.lines == p.manifest.lines
            && manifest.raw_bytes == p.manifest.raw_bytes
            && manifest.segments.len() == p.manifest.segments.len();
        same.then_some(Prepacked { manifest, ..p })
    }

    /// `_acpmux/transfer_history {sessionId, stageId}`: the staged history becomes the live
    /// chat's segment `000000`. Answers `{sessionId, throughSeq, records}`.
    pub(in crate::hub) fn transfer_history(
        &self,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let stage_id = params.get("stageId").and_then(Value::as_str).unwrap_or("");
        let stage = inside(&transfers_dir(), &format!("in-{stage_id}"))?;
        let Some(staged) = read_json(&stage.join("staged.json")) else {
            return Err(RpcError::not_found(format!("transfer.unknown: no stage {stage_id:?}")));
        };
        if session.meta().moved_to.is_some() {
            return Err(transfer_error("history", "the chat moved away from here"));
        }
        let Some((after, digest)) = self.history_awaited(&session.id) else {
            return Err(transfer_error("history", "this chat awaits no history"));
        };
        let same = *field(&staged, "sessionId") == session.id.as_str()
            && field(&staged, "afterSeq").as_u64() == Some(after)
            && token_digest(field(&staged, "token")) == digest;
        if !same {
            return Err(transfer_error(
                "diverged",
                format!("the staged history is not the one this chat awaits (through seq {after})"),
            ));
        }
        let file = stage.join("store").join(&session.id).join("events").join("000000.ndjson");
        let records = self
            .adopt_history(&session.id, &file)
            .map_err(|e| transfer_error("history", format!("{e:#}")))?;
        if let Some(note) = self.pending_note(&session.id) {
            let _ = crate::home_fs::remove_file(&note);
        }
        let _ = crate::home_fs::remove_dir_all(&stage);
        self.append(
            session,
            "mux",
            "history_arrived",
            json!({"throughSeq": after, "records": records}),
        );
        Ok(json!({"sessionId": session.id, "throughSeq": after, "records": records}))
    }

    /// Writes the staged records as chat `id`'s segment `000000`, beside the log it appends to,
    /// in the order a fork's history is written (`store/fork_view.rs` `materialize`): the stamp
    /// goes up before the segment is there, so no read keeps a page made without it. And once
    /// more after: nothing here excludes readers as a fork's write does, so a read between the
    /// two could list the log without the segment under the first stamp.
    fn adopt_history(&self, id: &str, file: &Path) -> anyhow::Result<u64> {
        use std::io::BufRead as _;
        let mut writer = self
            .store
            .history_writer(id)?
            .ok_or_else(|| anyhow::anyhow!("this store takes no history after a move"))?;
        let mut records = 0u64;
        for line in std::io::BufReader::new(std::fs::File::open(file)?).lines() {
            let line = line?;
            if !line.trim().is_empty() {
                writer.write(&serde_json::from_str(&line)?)?;
                records = records.saturating_add(1);
            }
        }
        self.store.bump_log_stamp(id, 1)?;
        writer.commit()?;
        self.store.bump_log_stamp(id, 1)?;
        self.store.flush_session(id)?;
        Ok(records)
    }
}

#[cfg(test)]
#[path = "pack_through_kept_tests.rs"]
mod kept_tests;
#[cfg(test)]
#[path = "transfer_history_tests.rs"]
mod tests;
