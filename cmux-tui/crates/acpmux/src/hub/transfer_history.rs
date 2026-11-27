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
struct PackTurn(String);

impl PackTurn {
    /// Waits for chat `id`'s turn.
    fn take(id: &str) -> Self {
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

/// The most records one scan of [`Hub::write_lines`] writes before it lets the store's
/// fork-view lock go and scans on from the last one. Three in tests, so every export and pack
/// test writes its lines in several passes and checks they are the bytes one pass wrote.
const WRITE_LINES_PASS: usize = if cfg!(test) { 3 } else { 2_000 };

/// The calling thread at the lowest CPU priority, and the threads it starts after: nice 19 on
/// Linux (a thread's own, inherited by the threads it starts), the background band on macOS.
/// Best effort: a refusal leaves it as it was.
fn lower_this_thread() {
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

fn pack_error(e: pack::Error) -> anyhow::Error {
    anyhow::anyhow!("session pack: {e}")
}

/// The folder of a chat's pack store, in the chat's own folder.
const PACK_DIR: &str = "history-pack";

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
    fn pack_store(&self, id: &str) -> anyhow::Result<pack::Store> {
        let chat = self.store.session_dir(id);
        let dir = chat.ok_or_else(|| anyhow::anyhow!("this store keeps no packs"))?.join(PACK_DIR);
        // In the chat's folder, which the store made owner-only; made through the held home.
        crate::home_fs::create_dir_all(&dir, 0o700)?;
        Ok(pack::Store::new(dir))
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
    fn pack_through(
        &self,
        session: &Session,
        through: u64,
        store: &pack::Store,
        work: &Path,
    ) -> anyhow::Result<(pack::Manifest, pack::PackStats, String)> {
        crate::home_fs::create_dirs(work)?;
        let lines = work.join("history.ndjson");
        let written = self.write_lines(session, 0, through, &lines);
        let packed = written.and_then(|(last, digest)| {
            anyhow::ensure!(last == through, "the log here holds no record at seq {through}");
            let params = pack::Params::default();
            let packed =
                pack::pack(store, &session.id, std::slice::from_ref(&lines), &params, false);
            Ok((packed.map_err(pack_error)?, digest))
        });
        let _ = crate::home_fs::remove_file(&lines);
        let ((manifest, stats), digest) = packed?;
        Ok((manifest, stats, digest))
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
        let (mut last, mut digest, mut failed) = (after, String::new(), None::<anyhow::Error>);
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
                    serde_json::to_writer(&mut out, &e)?;
                    out.write_all(b"\n")?;
                    Ok(())
                })();
                if let Err(e) = step {
                    failed = Some(e);
                }
                seen += 1;
                let more = failed.is_none() && !at_end;
                if more && seen >= WRITE_LINES_PASS {
                    // This pass ends here; the next one starts after `last`.
                    ended = false;
                    return false;
                }
                more
            })?;
            if failed.is_some() || ended || last == from {
                break;
            }
        }
        if let Some(e) = failed {
            return Err(e);
        }
        out.flush()?;
        Ok((last, digest))
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
            let work = transfers_dir().join(format!("pre-{}", uuid::Uuid::now_v7()));
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
mod tests {
    use super::*;

    #[test]
    fn a_chats_second_pack_waits_for_its_first_and_another_chats_does_not() {
        let first = PackTurn::take("turn-chat-a");
        let _other = PackTurn::take("turn-chat-b");
        let (sent, got) = std::sync::mpsc::channel();
        let second = std::thread::spawn(move || {
            let _turn = PackTurn::take("turn-chat-a");
            sent.send(()).unwrap();
        });
        assert!(
            got.recv_timeout(std::time::Duration::from_millis(200)).is_err(),
            "the second pack ran beside the first"
        );
        drop(first);
        got.recv_timeout(std::time::Duration::from_secs(10)).expect("the second pack never ran");
        second.join().unwrap();
        assert!(!PACKING.0.lock().unwrap().contains("turn-chat-a"));
    }

    #[test]
    fn a_prepack_that_ended_without_a_pack_does_not_hold_its_export() {
        let slot = Arc::new(Prepack::default());
        PREPACKS.lock().unwrap().insert("ended-chat".into(), (7, slot.clone()));
        // What a thread that never started leaves: the slot ended as failed.
        drop(PrepackDone { slot: &slot, packed: None });
        assert!(Hub::prepack_waited("ended-chat", 7).is_none());
        assert!(!PREPACKS.lock().unwrap().contains_key("ended-chat"));
    }
}
