//! Part of `Hub` (a child of `transfer_out.rs`). Pre-copy for a chat move: the
//! chat's history goes to the target before the move freezes it, so the freeze costs only what
//! changed since, not the whole log (cmuxterm-hq goals/super-highway.md: a 2.2 MB chat froze
//! 380-700 ms, a share of it per record of history).
//!
//! Daemons that serve it list `crate::capabilities::TRANSFER_PRECOPY`.
//!
//! 1. source `_acpmux/transfer_prepare {sessionId}`: no freeze. The log as of now goes into
//!    `transfers/pre-<id>/<chat>/events/000001.ndjson`; answers `{schema: PREFIX_SCHEMA,
//!    prepareId, sessionId, afterSeq, token, files}`, paged with `transfer_read` like a bundle.
//!    `afterSeq` is the last seq it holds; `token` names that prefix (its prepare, `afterSeq`,
//!    and a digest of the record at `afterSeq`).
//! 2. target `_acpmux/transfer_stage {manifest}` (that answer): a receive (`in-<id>`) that
//!    `transfer_write` fills; `_acpmux/transfer_stage_finish {stageId}` checks every record and
//!    writes them, as the store would, to one synced segment (`store/<chat>/events/000000.ndjson`,
//!    its kind index beside it). Nothing runs and
//!    nothing is listed: it is no chat yet. Swept like any receive.
//! 3. source `transfer_begin {..., prepareId, afterSeq}`: frozen as ever, but the bundle's log
//!    holds only the records past `afterSeq`; its answer names the prefix (`prefix: {prepareId,
//!    afterSeq, token}`). A log whose record at `afterSeq` is not the one prepared, or whose
//!    lines changed since (a compaction: `Store::log_stamp`), is refused `transfer.diverged`
//!    and given back at once, so the client moves it in full.
//! 4. target `transfer_receive {manifest, stageId}` takes the staged prefix into the receive
//!    (refused `transfer.unstaged` unless its token is the manifest's), and `transfer_finish`
//!    imports it: the prefix becomes the log's segment `000000` (linked in whole, as a fork's
//!    history is, `Store::history_writer`), then the tail is appended. Everything else about a
//!    finish is as it was: its queue, epochs, the `transferred_in` receipt, a replaced copy.
//!
//! A manifest with a `prefix` is never imported without its staged prefix: a delta alone would
//! lose the history.
//!
//! **A chat that comes back sends only what it did away.** Each chat folder notes its last move
//! in `transfer-base.json`: the source, at commit, that its copy is what move T shipped
//! (`shipped`); the target, at an unguarded finish, that its log through seq S is what move T
//! shipped, with the digest of its record at S (`received`). Before a prepare the client asks the
//! target `_acpmux/transfer_base {sessionId}`: a target that holds the chat's moved-away copy
//! answers `{base: {transferId}}`. A source whose note is the `received` of that move, whose log
//! still holds that record at S and was not rewritten since, prepares only the records past S and
//! names `base: {transferId, seq, digest}`. The target checks its own copy (its note is the
//! `shipped` of that move, unrewritten, and its record at S has that digest) or refuses the stage
//! `transfer.unbased`, and the client prepares again in full; its segment `000000` is its own
//! lines through S, as written, then the staged records.

use super::*;
use crate::hub::transfer_out::{MAX_FILES, bundle_files, inside, transfers_dir};

/// The schema of a prepare's answer (the stage's manifest).
pub const PREFIX_SCHEMA: &str = "acpmux.transfer.prefix.v1";

/// A prefix staged on the target, taken into a receive: the file the store adopts, and the last
/// seq it holds.
pub(in crate::hub) struct StagedPrefix {
    pub(in crate::hub) file: PathBuf,
    pub(in crate::hub) after_seq: u64,
    /// A prefix whose history follows the chat (`transfer_history.rs`).
    pub(in crate::hub) history_later: bool,
}

/// The prefix a begin checked on the source.
pub(in crate::hub) struct CheckedPrefix {
    pub(in crate::hub) prepare_id: String,
    pub(in crate::hub) after_seq: u64,
    pub(in crate::hub) token: String,
    /// What a history-later prepare folded of the prefix ([`FOLD_FILE`]), for the begin to fold
    /// only the records past it.
    pub(in crate::hub) folded: Option<PrefixFold>,
}

/// A history-later prepare's folds of its prefix, which the begin's freeze would otherwise read
/// from the whole log: the held prompts ([`super::super::queue::HeldFold`]), the
/// ownership epoch, and the prepare's native copies with what each holds.
pub(in crate::hub) struct PrefixFold {
    pub(in crate::hub) held: super::super::queue::HeldFold,
    pub(in crate::hub) epoch: u64,
    /// The prepare's copies of the agent's own files (`<prepare>/<chat>/native`).
    pub(in crate::hub) native_dir: PathBuf,
    /// Each copy's bundle path to `{length, sha256}`.
    pub(in crate::hub) native: Value,
}

/// A history-later prepare's [`PrefixFold`], beside its `prefix.json`.
const FOLD_FILE: &str = "fold.json";

/// The [`PrefixFold`] prepare `root` wrote of chat `chat` through `after_seq`, if whole.
fn read_prefix_fold(root: &Path, chat: &str, after_seq: u64) -> Option<PrefixFold> {
    let fold = read_json(&root.join(FOLD_FILE))?;
    if field(&fold, "afterSeq").as_u64() != Some(after_seq) {
        return None;
    }
    Some(PrefixFold {
        held: super::super::queue::HeldFold::from_json(field(&fold, "held"))?,
        epoch: field(&fold, "epoch").as_u64()?,
        native_dir: root.join(chat).join("native"),
        native: field(&fold, "native").clone(),
    })
}

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// The record's digest, as its line is written.
fn record_digest(record: &EventRecord) -> Result<String, RpcError> {
    let line = serde_json::to_vec(record).map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(crate::sha256::sha256_hex(&line))
}

/// The chat folder's note of its last move ([module docs](self)).
const BASE_FILE: &str = "transfer-base.json";

/// A base the source holds: the move it came by, the last seq it took, that record's digest.
struct Base {
    transfer_id: String,
    seq: u64,
    digest: String,
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// Whether a manifest names a staged prefix.
pub(in crate::hub) fn names_prefix(manifest: &Value) -> bool {
    manifest.get("prefix").is_some_and(|p| !p.is_null())
}

/// The prepare a finished move began from (`transfers/<move>/prepared`) goes with its move.
pub(in crate::hub) fn forget_prepared(move_dir: &Path) {
    let Ok(id) = std::fs::read_to_string(move_dir.join("prepared")) else { return };
    if let Ok(dir) = inside(&transfers_dir(), id.trim()) {
        let _ = crate::home_fs::remove_dir_all(dir);
    }
}

impl Hub {
    /// `_acpmux/transfer_prepare`: the chat's log as of now, for a later move to send only what
    /// follows it. The chat keeps running.
    pub(in crate::hub) fn transfer_prepare(
        self: &Arc<Self>,
        session: &Arc<Session>,
        base: Option<&Value>,
        keep_turns: Option<u64>,
    ) -> Result<Value, RpcError> {
        if let Some(to) = session.meta().moved_to {
            return Err(super::moved_error(&to));
        }
        self.refuse_while_history_awaited(session)?;
        if session.moving().is_some() {
            return Err(transfer_error("moving", "this chat is being moved"));
        }
        let mut steps = super::transfer_live::MoveSteps::new("prepare");
        self.sweep();
        steps.step("sweep");
        // The log's kind index made now, not under the freeze: the begin reads its held prompts
        // and its ownership epoch from it.
        let warmed = self.store.scan_kinds(&session.id, &["queued"], &mut |_| true);
        steps.step("kind_index");
        if let Err(error) = warmed {
            tracing::debug!(session = %session.id, "kind index not made before a move: {error:#}");
        }
        let base = base.and_then(|b| self.held_base(session, b));
        let prepare_id = format!("pre-{}", uuid::Uuid::now_v7());
        let root = transfers_dir().join(&prepare_id);
        let events = root.join(&session.id).join("events");
        // A move whose history follows the chat (`transfer_history.rs`) copies no line here. A
        // chat with fewer turns than it keeps has no history to follow: it is prepared whole.
        let later = match keep_turns {
            Some(keep) => {
                self.later_prefix(session, keep, &events).map(|l| Some(l).filter(|l| l.0 > 0))
            }
            None => Ok(None),
        };
        let made = later.and_then(|later| match later {
            Some(later) => Ok((later, true)),
            None => Ok((self.write_prefix(session, &events, base.as_ref())?, false)),
        });
        steps.step("prefix");
        let ((after_seq, digest, stamp), history_later) = match made {
            Ok(made) => made,
            Err(error) => {
                let _ = crate::home_fs::remove_dir_all(&root);
                return Err(error);
            }
        };
        let base = base.filter(|_| !history_later);
        // The agent's own transcript (a Claude chat's JSONL: 1.6 GB for a 7 GB chat) goes too,
        // at the path a bundle gives it: the freeze then pages only what it grew by
        // (`transfer_live.rs`). One that fails to copy goes whole inside the freeze, as before.
        let native_root = root.join(&session.id).join("native");
        let mut native = serde_json::Map::new();
        for (label, src) in crate::native::locate(&session.meta()) {
            match crate::native::copy_into(&src, &native_root, &label) {
                Ok(rel) if history_later => {
                    let copy = native_root.join(&rel);
                    let length = std::fs::metadata(&copy).map(|m| m.len()).unwrap_or(0);
                    if let Ok(Some(sha)) = super::transfer_live::prefix_digest(&copy, length) {
                        let at = format!("native/{rel}");
                        native.insert(at, json!({"length": length, "sha256": sha}));
                    }
                }
                Ok(_) => {}
                Err(error) => {
                    tracing::debug!(session = %session.id, "native file not pre-copied: {error:#}");
                }
            }
        }
        steps.step("native");
        if history_later {
            self.write_prefix_fold(session, &root, after_seq, Value::Object(native));
            self.prepack_history(session, after_seq);
        }
        let token = format!("{prepare_id}:{after_seq}:{digest}");
        let mut record = json!({"sessionId": session.id, "afterSeq": after_seq, "digest": digest,
                            "stamp": stamp, "token": token});
        if history_later {
            record.set("historyLater", json!(true));
        }
        let files = crate::home_fs::write(root.join("prefix.json"), record.to_string())
            .and_then(|()| bundle_files(&root.join(&session.id)))
            .map_err(|e| RpcError::internal(format!("transfer: prepare: {e}")))?;
        super::super::transfer_watch::note_activity(&root, None);
        // This prepare holds all an earlier one of the chat did (`transfer_live.rs`).
        super::transfer_live::drop_other_prepares(&session.id, &prepare_id);
        let files: Vec<Value> =
            files.into_iter().map(|(path, size)| json!({"path": path, "size": size})).collect();
        let mut answer = json!({"schema": PREFIX_SCHEMA, "prepareId": prepare_id,
                  "sessionId": session.id, "afterSeq": after_seq, "token": token, "files": files});
        if history_later {
            answer.set("historyLater", json!(true));
        }
        if let Some(b) = base {
            answer.set(
                "base",
                json!({"transferId": b.transfer_id, "seq": b.seq, "digest": b.digest}),
            );
        }
        Ok(answer)
    }

    /// At a history-later prepare: [`PrefixFold`] of the chat's records through `after_seq`,
    /// read from the log's kind index now, not under the begin's freeze. The check of the prefix
    /// under the freeze (`check_prefix`) holds those records unchanged. One that cannot be made
    /// is not written: the begin then reads the log as a prepare without it.
    fn write_prefix_fold(&self, session: &Session, root: &Path, after_seq: u64, native: Value) {
        let folded = self.held_fold_through(&session.id, after_seq).and_then(|held| {
            let epoch = self.ownership_epoch_after(&session.id, 0, 0)?;
            Ok((held, epoch))
        });
        let (held, epoch) = match folded {
            Ok(folded) => folded,
            Err(error) => {
                tracing::debug!(session = %session.id, "prefix not folded at prepare: {error:#}");
                return;
            }
        };
        let fold = json!({"afterSeq": after_seq, "held": held.into_json(), "epoch": epoch,
                          "native": native});
        if let Err(error) = crate::home_fs::write(root.join(FOLD_FILE), fold.to_string()) {
            tracing::debug!(session = %session.id, "prefix fold not written: {error}");
        }
    }

    /// The digest of chat `id`'s record at `seq`, read back from the records before `seq + 1`.
    pub(in crate::hub) fn digest_at(&self, id: &str, seq: u64) -> Result<Option<String>, RpcError> {
        if seq == 0 {
            return Ok(None);
        }
        let mut found = None;
        self.store
            .scan_back(id, seq - 1, seq + 1, &|_, _| false, &mut |rec| {
                found = Some(rec);
                false
            })
            .map_err(|e| RpcError::internal(e.to_string()))?;
        found.filter(|r| r.seq == seq).map(|r| record_digest(&r)).transpose()
    }

    fn base_note(&self, id: &str) -> Option<PathBuf> {
        // The path only: `session_dir` waits for the journal to sync the chat's metadata, which
        // under load took seconds of a finish's freeze.
        self.store.session_path(id).map(|dir| dir.join(BASE_FILE))
    }

    /// At a commit: this folder's copy of the chat is what move `transfer_id` shipped.
    pub(in crate::hub) fn note_shipped(&self, session: &Session, transfer_id: &str) {
        let Some(note) = self.base_note(&session.id) else { return };
        let Ok(stamp) = self.store.log_stamp(&session.id) else { return };
        let note_it = json!({"role": "shipped", "transferId": transfer_id, "stamp": stamp});
        if let Err(error) = crate::home_fs::write(note, note_it.to_string()) {
            tracing::debug!(session = %session.id, "move not noted for a later pre-copy: {error}");
        }
    }

    /// At an unguarded finish: the chat's log through `seq`, the bundle's last record (its meta's
    /// `last_seq`, taken under the source's freeze), is what move `transfer_id` shipped. A seq
    /// that is not is refused at a later stage by its digest: the source's record there differs.
    pub(in crate::hub) fn note_received(&self, session: &Session, transfer_id: &Value, seq: u64) {
        let Some(note) = self.base_note(&session.id) else { return };
        let (Some(transfer_id), Ok(stamp), Ok(Some(digest))) = (
            transfer_id.as_str(),
            self.store.log_stamp(&session.id),
            self.digest_at(&session.id, seq),
        ) else {
            let _ = crate::home_fs::remove_file(&note);
            return;
        };
        let note_it = json!({"role": "received", "transferId": transfer_id, "seq": seq,
                             "digest": digest, "stamp": stamp});
        if let Err(error) = crate::home_fs::write(note, note_it.to_string()) {
            tracing::debug!(session = %session.id, "move not noted for a later pre-copy: {error}");
        }
    }

    /// `_acpmux/transfer_base {sessionId}`: the move that took a chat away from here, when this
    /// daemon still holds the copy it shipped unrewritten; `{base: null}` otherwise.
    pub(in crate::hub) fn transfer_base(&self, params: &Value) -> Result<Value, RpcError> {
        let id = params.get("sessionId").and_then(Value::as_str).unwrap_or("");
        Ok(
            json!({"sessionId": id, "base": self.shipped_base(id).map(|t| json!({"transferId": t}))}),
        )
    }

    /// The move this daemon's moved-away copy of chat `id` was shipped by, while unrewritten.
    fn shipped_base(&self, id: &str) -> Option<String> {
        let session = self.session_get(id)?;
        if !self.moved_away(&session) {
            return None;
        }
        let note = read_json(&self.base_note(id)?)?;
        let stamp = self.store.log_stamp(id).ok()?;
        (*field(&note, "role") == "shipped" && field(&note, "stamp").as_u64() == Some(stamp))
            .then(|| field(&note, "transferId").as_str().map(str::to_owned))
            .flatten()
    }

    /// The base a source may prepare from: its note is the `received` of the target's move, and
    /// its log still holds that record at that seq, unrewritten.
    fn held_base(&self, session: &Session, base: &Value) -> Option<Base> {
        let transfer_id = base.get("transferId").and_then(Value::as_str)?;
        let note = read_json(&self.base_note(&session.id)?)?;
        let seq = field(&note, "seq").as_u64().filter(|s| *s > 0)?;
        let digest = field(&note, "digest").as_str()?.to_owned();
        let stamp = self.store.log_stamp(&session.id).ok()?;
        let held = *field(&note, "role") == "received"
            && *field(&note, "transferId") == transfer_id
            && field(&note, "stamp").as_u64() == Some(stamp)
            && seq <= session.seq.load(Ordering::SeqCst)
            && self.digest_at(&session.id, seq).ok().flatten().as_deref() == Some(digest.as_str());
        held.then(|| Base { transfer_id: transfer_id.to_owned(), seq, digest })
    }

    /// At a stage of a prefix that names a base: this daemon's copy of the chat holds it.
    fn check_base(&self, id: &str, base: &Value) -> Result<u64, RpcError> {
        let unbased = |why: &str| {
            transfer_error("unbased", format!("{why}; prepare it in full"))
                .with_data(json!({"base": base}))
        };
        let seq = base.get("seq").and_then(Value::as_u64).filter(|s| *s > 0);
        let (Some(seq), Some(transfer_id)) = (seq, base.get("transferId").and_then(Value::as_str))
        else {
            return Err(RpcError::invalid_params("transfer: a base needs transferId and seq"));
        };
        if self.shipped_base(id).as_deref() != Some(transfer_id) {
            return Err(unbased("this daemon holds no copy that move shipped"));
        }
        if self.digest_at(id, seq)?.as_deref() != base.get("digest").and_then(Value::as_str) {
            return Err(unbased("this daemon's copy does not hold that record"));
        }
        Ok(seq)
    }

    /// Chat `id`'s own lines through `through`, as written, into `out`; returns how many.
    fn copy_own_lines(
        &self,
        id: &str,
        through: u64,
        out: &mut dyn std::io::Write,
    ) -> anyhow::Result<u64> {
        self.store.flush_session(id)?;
        let stamp = self.store.log_stamp(id)?;
        let filter = crate::store::LogFilter { through, kinds: None };
        let mut marks = crate::store::LogMarks::default();
        let (mut from, mut count, mut last) = (1, 0u64, 0u64);
        loop {
            let mut bytes = Vec::new();
            let chunk = self.store.read_log(id, from, filter, stamp, &mut marks, &mut bytes)?;
            out.write_all(&bytes)?;
            count += bytes.iter().filter(|b| **b == b'\n').count() as u64;
            if chunk.next > from {
                last = chunk.next - 1;
            }
            if chunk.at_end || chunk.next <= from || last >= through {
                break;
            }
            from = chunk.next;
        }
        anyhow::ensure!(self.store.log_stamp(id)? == stamp, "chat {id}'s log changed while read");
        anyhow::ensure!(last == through, "chat {id}'s own log ends at {last}, not {through}");
        Ok(count)
    }

    /// Writes the log through its current last seq into `events/000001.ndjson`; returns that
    /// seq, the digest of its record, and the log's stamp read before.
    fn write_prefix(
        &self,
        session: &Arc<Session>,
        events: &Path,
        base: Option<&Base>,
    ) -> Result<(u64, String, u64), RpcError> {
        use std::io::Write as _;
        let fail =
            |e: &dyn std::fmt::Display| RpcError::internal(format!("transfer: prepare: {e}"));
        let stamp = self.store.log_stamp(&session.id).map_err(|e| fail(&e))?;
        // Records appended while this reads stay for the move's delta.
        let through = session.seq.load(Ordering::SeqCst);
        crate::home_fs::create_dirs(events).map_err(|e| fail(&e))?;
        let file =
            crate::home_fs::create_file(events.join("000001.ndjson")).map_err(|e| fail(&e))?;
        let mut out = std::io::BufWriter::new(file);
        let (mut last, mut digest, mut failed) = match base {
            Some(b) => (b.seq, b.digest.clone(), None),
            None => (0, String::new(), None),
        };
        let after = base.map_or(0, |b| b.seq);
        self.store
            .scan(&session.id, after, &mut |mut e: EventRecord| {
                if e.seq > through {
                    return false;
                }
                let step = record_digest(&e).map_err(|e| e.message).and_then(|d| {
                    digest = d;
                    last = e.seq;
                    self.display_logged(Some(&**session), &mut e);
                    let line = serde_json::to_string(&e).map_err(|e| e.to_string())?;
                    out.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
                    out.write_all(b"\n").map_err(|e| e.to_string())
                });
                if let Err(e) = step {
                    failed = Some(e);
                }
                failed.is_none() && e.seq < through
            })
            .map_err(|e| fail(&e))?;
        if let Some(e) = failed {
            return Err(fail(&e));
        }
        out.flush().map_err(|e| fail(&e))?;
        Ok((last, digest, stamp))
    }

    /// At begin, under the freeze: the prepared prefix is still the head of the log.
    pub(in crate::hub) fn check_prefix(
        &self,
        session: &Session,
        prepare_id: &str,
        after_seq: u64,
    ) -> Result<CheckedPrefix, RpcError> {
        let diverged = |why: &str| {
            transfer_error("diverged", format!("{why}; move it in full"))
                .with_data(json!({"prepareId": prepare_id, "afterSeq": after_seq}))
        };
        if !prepare_id.starts_with("pre-") {
            return Err(RpcError::invalid_params("transfer: prepareId names no prepare"));
        }
        let root = inside(&transfers_dir(), prepare_id)?;
        let Some(record) = read_json(&root.join("prefix.json")) else {
            return Err(diverged("no such prepare here"));
        };
        if *field(&record, "sessionId") != session.id.as_str()
            || field(&record, "afterSeq").as_u64() != Some(after_seq)
        {
            return Err(diverged("the prepare is of another chat or prefix"));
        }
        let stamp =
            self.store.log_stamp(&session.id).map_err(|e| RpcError::internal(e.to_string()))?;
        if field(&record, "stamp").as_u64() != Some(stamp) {
            return Err(diverged("the chat's log was rewritten since its prepare"));
        }
        // The record at the prefix's end, found by a seek: the cost is the same however long
        // the log is.
        if after_seq > 0 {
            let same = match self.digest_at(&session.id, after_seq)? {
                Some(digest) => field(&record, "digest").as_str() == Some(digest.as_str()),
                None => false,
            };
            if !same {
                return Err(diverged("the chat's log no longer holds the prepared prefix"));
            }
        }
        let token = field(&record, "token").as_str().unwrap_or_default().to_owned();
        let folded = (*field(&record, "historyLater") == true)
            .then(|| read_prefix_fold(&root, &session.id, after_seq))
            .flatten();
        Ok(CheckedPrefix { prepare_id: prepare_id.to_owned(), after_seq, token, folded })
    }

    /// `_acpmux/transfer_stage {manifest}`: a receive for a prepare's prefix, filled with
    /// `transfer_write`.
    pub(in crate::hub) fn transfer_stage(&self, params: &Value) -> Result<Value, RpcError> {
        let manifest = params.get("manifest").cloned().unwrap_or(Value::Null);
        if *field(&manifest, "schema") != PREFIX_SCHEMA {
            return Err(transfer_error("schema", format!("a stage takes {PREFIX_SCHEMA}")));
        }
        let id = field(&manifest, "sessionId").as_str().unwrap_or("");
        if !super::super::transfer::is_plain_id(id)
            || field(&manifest, "afterSeq").as_u64().is_none()
        {
            return Err(RpcError::invalid_params("transfer: a stage needs sessionId and afterSeq"));
        }
        let files = field(&manifest, "files").as_array().cloned().unwrap_or_default();
        if files.len() > MAX_FILES {
            return Err(transfer_error("size", format!("{} files", files.len())));
        }
        for f in &files {
            let path = f["path"].as_str().unwrap_or("");
            inside(Path::new("/"), path)?;
            let staged_kind = path.starts_with("events/") || path.starts_with("native/");
            if !staged_kind || f.get("size").and_then(Value::as_u64).is_none() {
                return Err(RpcError::invalid_params(
                    "transfer: a stage takes only events and native files",
                ));
            }
        }
        if let Some(base) = manifest.get("base").filter(|b| !b.is_null()) {
            self.check_base(id, base)?;
        }
        self.sweep();
        // A resumed stage takes up the chat's unfinished one, with this manifest, and says what
        // it holds (`transfer_live.rs`).
        if params.get("resume").and_then(Value::as_bool) == Some(true) {
            let base = manifest.get("base").cloned().unwrap_or(Value::Null);
            if let Some((stage_id, dir)) = super::transfer_live::resumable_stage(id, &base)
                && let Some(have) = super::transfer_live::stage_holds(&dir, &manifest)
            {
                crate::home_fs::write(dir.join("manifest.json"), manifest.to_string())
                    .map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
                super::super::transfer_watch::note_activity(&dir, None);
                let _ = crate::home_fs::write(dir.join("alive"), "0");
                return Ok(json!({"receiveId": stage_id, "stageId": stage_id, "sessionId": id,
                                 "resumed": true, "have": have}));
            }
        }
        // `control`: the guard a guarded receive will take this stage under (a cmux daemon's
        // `agent-transfer-stage`), so its records are rewritten for it as a hub move's are.
        let control = match params.get("control") {
            None | Some(Value::Null) => None,
            Some(control) => Some(
                ["peer", "web"]
                    .into_iter()
                    .find(|known| control.as_str() == Some(known))
                    .ok_or_else(|| RpcError::invalid_params("transfer: control is peer or web"))?,
            ),
        };
        let stage_id = uuid::Uuid::now_v7().to_string();
        let dir = transfers_dir().join(format!("in-{stage_id}"));
        crate::home_fs::create_dirs(dir.join("bundle"))
            .and_then(|()| crate::home_fs::write(dir.join("manifest.json"), manifest.to_string()))
            .and_then(|()| match control {
                Some(control) => crate::home_fs::write(
                    dir.join(super::super::transfer_hub_precopy::CONTROL_FILE),
                    control,
                ),
                None => Ok(()),
            })
            .map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        super::super::transfer_watch::note_activity(&dir, None);
        Ok(json!({"receiveId": stage_id, "stageId": stage_id, "sessionId": id}))
    }

    /// `_acpmux/transfer_stage_finish {stageId}`: every record of the staged prefix read and
    /// written, as the store writes them, to a synced segment `000000`, and indexed. Answers `{stageId, afterSeq,
    /// records}`.
    pub(in crate::hub) fn transfer_stage_finish(&self, params: &Value) -> Result<Value, RpcError> {
        let mut steps = super::transfer_live::MoveSteps::new("stage_finish");
        let stage_id = params.get("stageId").and_then(Value::as_str).unwrap_or("");
        let dir = inside(&transfers_dir(), &format!("in-{stage_id}"))?;
        let manifest = read_json(&dir.join("manifest.json"))
            .filter(|m| m["schema"] == PREFIX_SCHEMA)
            .ok_or_else(|| {
                RpcError::not_found(format!("transfer.unknown: no stage {stage_id:?}"))
            })?;
        let after_seq = field(&manifest, "afterSeq").as_u64().unwrap_or(0);
        let bundle = dir.join("bundle");
        for f in field(&manifest, "files").as_array().into_iter().flatten() {
            let (path, size) = (f["path"].as_str().unwrap_or(""), f["size"].as_u64());
            let have = std::fs::metadata(inside(&bundle, path)?).map_or(0, |m| m.len());
            if Some(have) != size {
                return Err(transfer_error("incomplete", format!("{path:?}: {have} of {size:?}")));
            }
        }
        let chat = field(&manifest, "sessionId").as_str().unwrap_or_default();
        let staged = dir.join("store").join(chat);
        let segment = staged.join("events").join("000000.ndjson");
        let base = match manifest.get("base").filter(|b| !b.is_null()) {
            Some(base) => Some(self.check_base(chat, base)?),
            None => None,
        };
        // A prefix whose history follows the chat stages an empty segment; a history that
        // followed is unpacked first (`transfer_history.rs`).
        let history_later = *field(&manifest, "historyLater") == true;
        // A stage a hub move made (`transfer_hub_precopy.rs`) has its records rewritten for the
        // control it will run under, as a guarded import rewrites a bundle's.
        let control = super::super::transfer_hub_precopy::stage_control(&dir);
        if control.is_some() && base.is_some() {
            return Err(transfer_error("stage", "a guarded stage is of the whole prefix"));
        }
        let written = private_stage(&dir, &staged.join("events")).and_then(|()| {
            if history_later {
                crate::home_fs::write(&segment, "")?;
                return Ok((0, after_seq));
            }
            if super::transfer_history::is_packed(&manifest) {
                self.unpack_staged(&bundle, chat)?;
            }
            self.write_staged(&bundle.join("events"), &segment, chat, base, control)
        });
        let (records, last) = written.map_err(|e| transfer_error("stage", format!("{e:#}")))?;
        steps.step("write_staged");
        if last != after_seq {
            let _ = crate::home_fs::remove_dir_all(dir.join("store"));
            return Err(transfer_error(
                "stage",
                format!("the prefix ends at {last}, not {after_seq}"),
            ));
        }
        index_staged(&dir.join("store"), chat);
        steps.step("index");
        // The native files stay for the move's receive, with what each holds: the freeze pages
        // only what they grew by since (`transfer_live.rs`).
        let native = super::transfer_live::keep_staged_native(&dir);
        let mut staged = json!({"sessionId": field(&manifest, "sessionId"), "afterSeq": after_seq,
                                "token": field(&manifest, "token"), "native": native,
                                "historyLater": history_later});
        if let Some(control) = control {
            staged.set("control", json!(control.as_str()));
        }
        crate::home_fs::write(dir.join("staged.json"), staged.to_string())
            .map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        let _ = crate::home_fs::remove_dir_all(&bundle);
        super::super::transfer_watch::note_activity(&dir, None);
        Ok(json!({"stageId": stage_id, "afterSeq": after_seq, "records": records}))
    }

    /// A receive of a manifest that names a prefix takes the stage `stage_id` into `dir`: its
    /// prefix and its record, once their token is the manifest's. The stage is gone after.
    pub(in crate::hub) fn take_stage(
        &self,
        stage_id: &str,
        manifest: &Value,
        dir: &Path,
        control: Option<Control>,
    ) -> Result<Vec<Value>, RpcError> {
        let stage = inside(&transfers_dir(), &format!("in-{stage_id}"))?;
        let staged = read_json(&stage.join("staged.json"));
        let prefix = &manifest["prefix"];
        let matches = staged.as_ref().is_some_and(|s| {
            s["sessionId"] == manifest["sessionId"]
                && s["afterSeq"] == prefix["afterSeq"]
                && s["token"].is_string()
                && s["token"] == prefix["token"]
                // Rewritten for the control it is taken under, or for none.
                && s["control"].as_str() == control.map(Control::as_str)
        });
        if !matches {
            return Err(transfer_error("unstaged", "no staged prefix here matches this move")
                .with_data(json!({"stageId": stage_id})));
        }
        crate::home_fs::rename(stage.join("store"), dir.join("store"))
            .and_then(|()| {
                crate::home_fs::write(
                    dir.join("prefix.json"),
                    staged.clone().unwrap_or_default().to_string(),
                )
            })
            .map_err(|e| RpcError::internal(format!("transfer: stage: {e}")))?;
        let have = super::transfer_live::seed_native(&stage, dir, staged.as_ref());
        let _ = crate::home_fs::remove_dir_all(stage);
        Ok(have)
    }

    /// At finish: the staged prefix a receive took, when its manifest names one.
    pub(in crate::hub) fn staged_prefix(
        dir: &Path,
        manifest: &Value,
    ) -> Result<Option<StagedPrefix>, RpcError> {
        if manifest["schema"] == PREFIX_SCHEMA {
            return Err(transfer_error("schema", "a stage is finished with transfer_stage_finish"));
        }
        if !names_prefix(manifest) {
            return Ok(None);
        }
        let chat = manifest["sessionId"].as_str().unwrap_or_default();
        let file = dir.join("store").join(chat).join("events").join("000000.ndjson");
        let staged = read_json(&dir.join("prefix.json"));
        let Some(staged) = staged.filter(|s| {
            *field(s, "token") == *field(field(manifest, "prefix"), "token") && file.is_file()
        }) else {
            return Err(transfer_error("unstaged", "the move's staged prefix is not here"));
        };
        Ok(Some(StagedPrefix {
            file,
            after_seq: field(&staged, "afterSeq").as_u64().unwrap_or(0),
            history_later: *field(&staged, "historyLater") == true,
        }))
    }

    /// Append every record of a bundle's `events/*.ndjson` to the store, in file order, after the
    /// staged prefix when there is one (adopted whole as segment `000000`). Returns the highest
    /// sequence copied. Under a guard's `control`, the records of prompts still to run carry it
    /// (`transfer_guard.rs` `guarded_record`).
    pub(in crate::hub) fn copy_bundle_events(
        &self,
        bundle: &Path,
        id: &str,
        control: Option<Control>,
        staged: Option<&StagedPrefix>,
    ) -> anyhow::Result<u64> {
        let mut last = 0;
        if let Some(staged) = staged {
            self.adopt_prefix(id, &staged.file)?;
            last = staged.after_seq;
        }
        let events_path = bundle.join("events");
        if !events_path.exists() {
            return Ok(last);
        }
        let mut files: Vec<PathBuf> = Vec::new();
        for entry in std::fs::read_dir(&events_path)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) == Some("ndjson") {
                files.push(path);
            }
        }
        files.sort();
        // A whole move into a chat with no log here yet: its records go in as segment `000000`,
        // one buffered write synced and renamed once, as a staged prefix's do, not one locked
        // write each (a 1 GB chat's history was a million of them under the freeze, cmux#54461).
        let mut whole = match staged {
            None => self.whole_history_writer(id)?,
            Some(_) => None,
        };
        for f in files {
            use std::io::BufRead as _;
            let file = std::fs::File::open(&f)
                .map_err(|e| anyhow::anyhow!("read {}: {e}", f.display()))?;
            // Bound memory to one record, including for multi-gigabyte event logs.
            for (n, line) in std::io::BufReader::new(file).lines().enumerate() {
                let line = line.map_err(|e| anyhow::anyhow!("read {}: {e}", f.display()))?;
                if line.trim().is_empty() {
                    continue;
                }
                let mut rec: EventRecord = serde_json::from_str(&line)
                    .map_err(|e| anyhow::anyhow!("{} line {}: {e}", f.display(), n + 1))?;
                if let Some(control) = control {
                    super::super::transfer_guard::guarded_record(&mut rec, control);
                }
                // The tail follows the prefix: a record at or below it would come twice.
                anyhow::ensure!(
                    staged.is_none_or(|s| rec.seq > s.after_seq),
                    "{} line {}: seq {} is in the staged prefix",
                    f.display(),
                    n + 1,
                    rec.seq
                );
                last = last.max(rec.seq);
                match whole.as_mut() {
                    Some(writer) => writer.write(&rec)?,
                    None => self.store.append(id, &rec)?,
                }
            }
        }
        if let Some(writer) = whole {
            writer.commit()?;
            // Its kind index, in one pass from the page cache: the finish's queue and inbox reads
            // take it, not a parse of the whole log under the freeze (`index_staged`).
            if let Err(error) = self.store.scan_kinds(id, &["queued"], &mut |_| true) {
                tracing::debug!(session = %id, "moved history not indexed: {error:#}");
            }
        }
        Ok(last)
    }

    /// The store's writer of chat `id`'s segment `000000`, when the store writes one into a folder
    /// and the chat has no segment there yet (a failed import's retry may have some: it appends).
    fn whole_history_writer(
        &self,
        id: &str,
    ) -> anyhow::Result<Option<Box<dyn crate::store::HistoryWriter + '_>>> {
        if !self.store.writes_history() {
            return Ok(None);
        }
        let Some(dir) = self.store.session_dir(id) else { return Ok(None) };
        let has_segment = std::fs::read_dir(dir.join("events")).is_ok_and(|entries| {
            entries.flatten().any(|e| e.path().extension().is_some_and(|x| x == "ndjson"))
        });
        if has_segment {
            return Ok(None);
        }
        self.store.history_writer(id)
    }

    /// The staged prefix as chat `id`'s segment `000000`, which the store never appends to and
    /// reads as any other (`Store::history_writer`): linked in whole and synced. A store with no
    /// folder of its own takes it record by record through its history writer.
    fn adopt_prefix(&self, id: &str, file: &Path) -> anyhow::Result<()> {
        if std::fs::metadata(file)?.len() == 0 {
            return Ok(());
        }
        if self.store.writes_history()
            && let Some(dir) = self.store.session_dir(id)
        {
            let events = dir.join("events");
            crate::config::private_state_dir(&dir)?;
            crate::config::private_state_dir(&events)?;
            let segment = events.join("000000.ndjson");
            anyhow::ensure!(!segment.exists(), "chat {id} has a segment 000000 already");
            // The receive keeps its own name for the file until it goes: a finish tried again
            // after a failed import finds it.
            let linked = crate::home_fs::hard_link(file, &segment).is_ok();
            if !linked {
                let tmp = events.join("000000.ndjson.history");
                crate::home_fs::copy(file, &tmp)?;
                std::fs::File::open(&tmp)?.sync_all()?;
                crate::home_fs::rename(&tmp, &segment)?;
            }
            adopt_index(file, &dir, &segment, linked);
            for synced in [&events, &dir] {
                crate::home_fs::sync_dir(synced)?;
            }
            if let Some(root) = dir.parent() {
                crate::home_fs::sync_dir(root)?;
            }
            return Ok(());
        }
        use std::io::BufRead as _;
        let mut writer = self
            .store
            .history_writer(id)?
            .ok_or_else(|| anyhow::anyhow!("this store takes no staged prefix"))?;
        for line in std::io::BufReader::new(std::fs::File::open(file)?).lines() {
            let line = line?;
            if !line.trim().is_empty() {
                writer.write(&serde_json::from_str(&line)?)?;
            }
        }
        writer.commit()
    }
}

impl Hub {
    /// Reads every record of the prefix's `events/*.ndjson`, in order and each past the one before,
    /// and writes them to `out` as the store writes a line, synced, after this daemon's own lines of
    /// chat `chat` through `base` when the prefix follows them. Returns the count and last seq.
    fn write_staged(
        &self,
        events: &Path,
        out: &Path,
        chat: &str,
        base: Option<u64>,
        control: Option<Control>,
    ) -> anyhow::Result<(u64, u64)> {
        use std::io::{BufRead as _, Write as _};
        let mut files: Vec<PathBuf> = std::fs::read_dir(events)
            .map(|entries| entries.flatten().map(|e| e.path()).collect())
            .unwrap_or_default();
        files.retain(|p| p.extension().is_some_and(|e| e == "ndjson"));
        files.sort();
        let tmp = out.with_extension("ndjson.tmp");
        let mut writer = std::io::BufWriter::new(crate::home_fs::create_file(&tmp)?);
        let (mut count, mut last) = (0u64, 0u64);
        if let Some(base) = base {
            count = self.copy_own_lines(chat, base, &mut writer)?;
            last = base;
        }
        for f in files {
            for (n, line) in std::io::BufReader::new(std::fs::File::open(&f)?).lines().enumerate() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                let mut rec: EventRecord = serde_json::from_str(&line)
                    .map_err(|e| anyhow::anyhow!("{} line {}: {e}", f.display(), n + 1))?;
                if let Some(control) = control {
                    super::super::transfer_guard::guarded_record(&mut rec, control);
                }
                anyhow::ensure!(rec.seq > last || count == 0, "seq {} follows {last}", rec.seq);
                serde_json::to_writer(&mut writer, &rec)?;
                writer.write_all(b"\n")?;
                (count, last) = (count + 1, rec.seq);
            }
        }
        let file = writer.into_inner().map_err(|e| anyhow::anyhow!("{e}"))?;
        file.sync_all()?;
        crate::home_fs::rename(&tmp, out)?;
        Ok((count, last))
    }
}

/// The staged segment's kind index (`store/kind_index.rs`), made by a store of the stage's own
/// (`<stage>/store/<chat>/events-index/`): a log load's queue and transfer reads of the chat
/// read it, not the segment. A copy names its segment's file by device and inode, which the
/// adopted link keeps. One that is not made is made by the first scan, as for any segment.
fn index_staged(root: &Path, chat: &str) {
    let indexed = crate::store::LocalStore::new(root.to_path_buf(), 1 << 30).and_then(|store| {
        crate::store::Store::scan_kinds(&store, chat, &["queued"], &mut |_| true)
    });
    if let Err(error) = indexed {
        tracing::debug!(session = %chat, "staged prefix not indexed: {error:#}");
    }
}

/// Makes the staged chat's `events` folder, owner-only down from `transfers/`: a store refuses a
/// folder under a group-writable one (umask 002), and with it the staged segment's kind index,
/// so the finish's queue and inbox reads parsed the whole log inside the freeze.
fn private_stage(stage: &Path, events: &Path) -> anyhow::Result<()> {
    #[cfg(unix)]
    for dir in [transfers_dir(), stage.to_path_buf()] {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::symlink_metadata(&dir)?.permissions().mode();
        if mode & 0o077 != 0 {
            crate::home_fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    if let Err(error) = crate::config::private_state_dir(events) {
        tracing::debug!("staged prefix kept unindexed: {error:#}");
        crate::home_fs::create_dirs(events)?;
    }
    Ok(())
}

/// Links the kind index made beside the staged segment `file` into the chat's folder `dir`, as
/// the copy of `segment` (the chat's segment `000000`). A segment that was copied, not linked
/// (the stage on another file system than the store), is another file: the index is written
/// again for it (`store/kind_index.rs` `carry_copy`), or the first scan reads the whole log
/// inside the freeze.
fn adopt_index(file: &Path, dir: &Path, segment: &Path, linked: bool) {
    let Some(staged) = file.parent().and_then(Path::parent) else { return };
    let index = crate::store::KIND_INDEX_DIR;
    let (copy, to) = (staged.join(index).join("000000.ndjson"), dir.join(index));
    if !copy.is_file() || crate::config::private_state_dir(&to).is_err() {
        return;
    }
    let target = to.join("000000.ndjson");
    let _ = crate::home_fs::remove_file(&target);
    if linked && crate::home_fs::hard_link(&copy, &target).is_ok() {
        return;
    }
    if let Err(error) = crate::store::carry_kind_index(&copy, segment, &target) {
        tracing::debug!(segment = %segment.display(), "staged kind index not carried: {error:#}");
    }
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}
