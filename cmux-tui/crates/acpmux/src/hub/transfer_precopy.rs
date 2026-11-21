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

use super::*;
use crate::hub::transfer_out::{MAX_FILES, bundle_files, inside, transfers_dir};

/// The schema of a prepare's answer (the stage's manifest).
pub const PREFIX_SCHEMA: &str = "acpmux.transfer.prefix.v1";

/// A prefix staged on the target, taken into a receive: the file the store adopts, and the last
/// seq it holds.
pub(in crate::hub) struct StagedPrefix {
    pub(in crate::hub) file: PathBuf,
    pub(in crate::hub) after_seq: u64,
}

/// The prefix a begin checked on the source.
pub(in crate::hub) struct CheckedPrefix {
    pub(in crate::hub) prepare_id: String,
    pub(in crate::hub) after_seq: u64,
    pub(in crate::hub) token: String,
}

fn transfer_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// The record's digest, as its line is written.
fn record_digest(record: &EventRecord) -> Result<String, RpcError> {
    let line = serde_json::to_vec(record).map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(crate::sha256::sha256_hex(&line))
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
        &self,
        session: &Arc<Session>,
    ) -> Result<Value, RpcError> {
        if let Some(to) = session.meta().moved_to {
            return Err(super::moved_error(&to));
        }
        if session.moving().is_some() {
            return Err(transfer_error("moving", "this chat is being moved"));
        }
        self.sweep();
        // The log's kind index made now, not under the freeze: the begin reads its held prompts
        // and its ownership epoch from it.
        let warmed = self.store.scan_kinds(&session.id, &["queued"], &mut |_| true);
        if let Err(error) = warmed {
            tracing::debug!(session = %session.id, "kind index not made before a move: {error:#}");
        }
        let prepare_id = format!("pre-{}", uuid::Uuid::now_v7());
        let root = transfers_dir().join(&prepare_id);
        let events = root.join(&session.id).join("events");
        let made = self.write_prefix(session, &events);
        let (after_seq, digest, stamp) = match made {
            Ok(made) => made,
            Err(error) => {
                let _ = crate::home_fs::remove_dir_all(&root);
                return Err(error);
            }
        };
        let token = format!("{prepare_id}:{after_seq}:{digest}");
        let record = json!({"sessionId": session.id, "afterSeq": after_seq, "digest": digest,
                            "stamp": stamp, "token": token});
        let files = crate::home_fs::write(root.join("prefix.json"), record.to_string())
            .and_then(|()| bundle_files(&root.join(&session.id)))
            .map_err(|e| RpcError::internal(format!("transfer: prepare: {e}")))?;
        super::super::transfer_watch::note_activity(&root, None);
        let files: Vec<Value> =
            files.into_iter().map(|(path, size)| json!({"path": path, "size": size})).collect();
        Ok(json!({"schema": PREFIX_SCHEMA, "prepareId": prepare_id, "sessionId": session.id,
                  "afterSeq": after_seq, "token": token, "files": files}))
    }

    /// Writes the log through its current last seq into `events/000001.ndjson`; returns that
    /// seq, the digest of its record, and the log's stamp read before.
    fn write_prefix(
        &self,
        session: &Arc<Session>,
        events: &Path,
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
        let (mut last, mut digest, mut failed) = (0, String::new(), None);
        self.store
            .scan(&session.id, 0, &mut |mut e: EventRecord| {
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
        if record["sessionId"] != session.id.as_str()
            || record["afterSeq"].as_u64() != Some(after_seq)
        {
            return Err(diverged("the prepare is of another chat or prefix"));
        }
        let stamp =
            self.store.log_stamp(&session.id).map_err(|e| RpcError::internal(e.to_string()))?;
        if record["stamp"].as_u64() != Some(stamp) {
            return Err(diverged("the chat's log was rewritten since its prepare"));
        }
        if after_seq > 0 {
            let mut at = None;
            self.store
                .scan(&session.id, after_seq - 1, &mut |e| {
                    at = Some(e);
                    false
                })
                .map_err(|e| RpcError::internal(e.to_string()))?;
            let same = match at.filter(|e| e.seq == after_seq) {
                Some(e) => record["digest"].as_str() == Some(record_digest(&e)?.as_str()),
                None => false,
            };
            if !same {
                return Err(diverged("the chat's log no longer holds the prepared prefix"));
            }
        }
        let token = record["token"].as_str().unwrap_or_default().to_owned();
        Ok(CheckedPrefix { prepare_id: prepare_id.to_owned(), after_seq, token })
    }

    /// `_acpmux/transfer_stage {manifest}`: a receive for a prepare's prefix, filled with
    /// `transfer_write`.
    pub(in crate::hub) fn transfer_stage(&self, params: &Value) -> Result<Value, RpcError> {
        let manifest = params.get("manifest").cloned().unwrap_or(Value::Null);
        if manifest["schema"] != PREFIX_SCHEMA {
            return Err(transfer_error("schema", format!("a stage takes {PREFIX_SCHEMA}")));
        }
        let id = manifest["sessionId"].as_str().unwrap_or("");
        if !super::super::transfer::is_plain_id(id) || manifest["afterSeq"].as_u64().is_none() {
            return Err(RpcError::invalid_params("transfer: a stage needs sessionId and afterSeq"));
        }
        let files = manifest["files"].as_array().cloned().unwrap_or_default();
        if files.len() > MAX_FILES {
            return Err(transfer_error("size", format!("{} files", files.len())));
        }
        for f in &files {
            let path = f["path"].as_str().unwrap_or("");
            inside(Path::new("/"), path)?;
            if !path.starts_with("events/") || f["size"].as_u64().is_none() {
                return Err(RpcError::invalid_params("transfer: a stage takes only events"));
            }
        }
        self.sweep();
        let stage_id = uuid::Uuid::now_v7().to_string();
        let dir = transfers_dir().join(format!("in-{stage_id}"));
        crate::home_fs::create_dirs(dir.join("bundle"))
            .and_then(|()| crate::home_fs::write(dir.join("manifest.json"), manifest.to_string()))
            .map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        super::super::transfer_watch::note_activity(&dir, None);
        Ok(json!({"receiveId": stage_id, "stageId": stage_id, "sessionId": id}))
    }

    /// `_acpmux/transfer_stage_finish {stageId}`: every record of the staged prefix read and
    /// written, as the store writes them, to a synced segment `000000`, and indexed. Answers `{stageId, afterSeq,
    /// records}`.
    pub(in crate::hub) fn transfer_stage_finish(&self, params: &Value) -> Result<Value, RpcError> {
        let stage_id = params.get("stageId").and_then(Value::as_str).unwrap_or("");
        let dir = inside(&transfers_dir(), &format!("in-{stage_id}"))?;
        let manifest = read_json(&dir.join("manifest.json"))
            .filter(|m| m["schema"] == PREFIX_SCHEMA)
            .ok_or_else(|| {
                RpcError::not_found(format!("transfer.unknown: no stage {stage_id:?}"))
            })?;
        let after_seq = manifest["afterSeq"].as_u64().unwrap_or(0);
        let bundle = dir.join("bundle");
        for f in manifest["files"].as_array().into_iter().flatten() {
            let (path, size) = (f["path"].as_str().unwrap_or(""), f["size"].as_u64());
            let have = std::fs::metadata(inside(&bundle, path)?).map_or(0, |m| m.len());
            if Some(have) != size {
                return Err(transfer_error("incomplete", format!("{path:?}: {have} of {size:?}")));
            }
        }
        let chat = manifest["sessionId"].as_str().unwrap_or_default();
        let staged = dir.join("store").join(chat);
        let segment = staged.join("events").join("000000.ndjson");
        let written = crate::home_fs::create_dirs(staged.join("events"))
            .map_err(anyhow::Error::from)
            .and_then(|()| write_staged(&bundle.join("events"), &segment));
        let (records, last) = written.map_err(|e| transfer_error("stage", format!("{e:#}")))?;
        if last != after_seq {
            let _ = crate::home_fs::remove_dir_all(dir.join("store"));
            return Err(transfer_error(
                "stage",
                format!("the prefix ends at {last}, not {after_seq}"),
            ));
        }
        index_staged(&dir.join("store"), chat);
        let staged = json!({"sessionId": manifest["sessionId"], "afterSeq": after_seq,
                            "token": manifest["token"]});
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
    ) -> Result<(), RpcError> {
        let stage = inside(&transfers_dir(), &format!("in-{stage_id}"))?;
        let staged = read_json(&stage.join("staged.json"));
        let prefix = &manifest["prefix"];
        let matches = staged.as_ref().is_some_and(|s| {
            s["sessionId"] == manifest["sessionId"]
                && s["afterSeq"] == prefix["afterSeq"]
                && s["token"].is_string()
                && s["token"] == prefix["token"]
        });
        if !matches {
            return Err(transfer_error("unstaged", "no staged prefix here matches this move")
                .with_data(json!({"stageId": stage_id})));
        }
        crate::home_fs::rename(stage.join("store"), dir.join("store"))
            .and_then(|()| {
                crate::home_fs::write(
                    dir.join("prefix.json"),
                    staged.unwrap_or_default().to_string(),
                )
            })
            .map_err(|e| RpcError::internal(format!("transfer: stage: {e}")))?;
        let _ = crate::home_fs::remove_dir_all(stage);
        Ok(())
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
        let Some(staged) =
            staged.filter(|s| s["token"] == manifest["prefix"]["token"] && file.is_file())
        else {
            return Err(transfer_error("unstaged", "the move's staged prefix is not here"));
        };
        Ok(Some(StagedPrefix { file, after_seq: staged["afterSeq"].as_u64().unwrap_or(0) }))
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
                self.store.append(id, &rec)?;
            }
        }
        Ok(last)
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
            if crate::home_fs::hard_link(file, &segment).is_err() {
                let tmp = events.join("000000.ndjson.history");
                crate::home_fs::copy(file, &tmp)?;
                std::fs::File::open(&tmp)?.sync_all()?;
                crate::home_fs::rename(&tmp, &segment)?;
            }
            adopt_index(file, &dir);
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

/// Reads every record of the prefix's `events/*.ndjson`, in order and each past the one before,
/// and writes them to `out` as the store writes a line, synced. Returns the count and last seq.
fn write_staged(events: &Path, out: &Path) -> anyhow::Result<(u64, u64)> {
    use std::io::{BufRead as _, Write as _};
    let mut files: Vec<PathBuf> = std::fs::read_dir(events)
        .map(|entries| entries.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    files.retain(|p| p.extension().is_some_and(|e| e == "ndjson"));
    files.sort();
    let tmp = out.with_extension("ndjson.tmp");
    let mut writer = std::io::BufWriter::new(crate::home_fs::create_file(&tmp)?);
    let (mut count, mut last) = (0u64, 0u64);
    for f in files {
        for (n, line) in std::io::BufReader::new(std::fs::File::open(&f)?).lines().enumerate() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let rec: EventRecord = serde_json::from_str(&line)
                .map_err(|e| anyhow::anyhow!("{} line {}: {e}", f.display(), n + 1))?;
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

/// Links the kind index made beside the staged segment `file` into the chat's folder `dir`.
fn adopt_index(file: &Path, dir: &Path) {
    let Some(staged) = file.parent().and_then(Path::parent) else { return };
    let index = crate::store::KIND_INDEX_DIR;
    let (copy, to) = (staged.join(index).join("000000.ndjson"), dir.join(index));
    if !copy.is_file() || crate::config::private_state_dir(&to).is_err() {
        return;
    }
    let target = to.join("000000.ndjson");
    let _ = crate::home_fs::remove_file(&target);
    let _ = crate::home_fs::hard_link(&copy, &target);
}
