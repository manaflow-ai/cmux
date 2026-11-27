//! Explicit recovery of an ordinary chat's durable copy. A copy is not a lease: it
//! recovers as a new, idle chat, never as authority to replace a possibly live source.

use super::*;
use anyhow::Context as _;
use std::io::{BufRead as _, Read as _, Write as _};

const MAX_BYTES: u64 = 1 << 30;
const REPLICA_SCHEMA: &str = "acpmux.running-replica.v1";

impl Hub {
    /// Capture native/chat state before fixing the journal high-water mark. The journal
    /// is streamed through that mark, so a continually writing chat cannot extend the scan.
    /// The caller publishes only a successful bundle and owns its scratch destination.
    pub(crate) fn capture_running_replica(
        &self,
        session: &Arc<Session>,
        dest: &Path,
    ) -> Result<PathBuf> {
        let before = session.meta();
        anyhow::ensure!(before.auto_session.is_none(), "Auto chats use their fenced replica");
        let dir = dest.join(&before.id);
        anyhow::ensure!(!dir.exists(), "replica destination already exists");
        crate::home_fs::create_dirs(dir.join("events"))?;
        let mut bytes = 0;
        let files = capture_native(&before, &dir, &mut bytes)?;
        let (composers, mut images) = {
            let c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            (c.bundled(), c.image_ids().into_iter().collect::<std::collections::BTreeSet<_>>())
        };
        anyhow::ensure!(self.store_deferred(session), "replica could not flush tool output");
        let mut meta = session.meta();
        anyhow::ensure!(
            meta.agent_session_id == before.agent_session_id && meta.harness == before.harness,
            "agent changed while capturing replica; retry the capture"
        );
        let through = meta.last_seq;
        if let Some(reference) = meta.history_from.take() {
            meta.history_kept_through = Some(reference.through_seq);
        }
        let file = crate::home_fs::create_file(dir.join("events/000001.ndjson"))?;
        let mut out = std::io::BufWriter::new(file);
        let (mut count, mut last) = (0u64, 0u64);
        let mut failed = None;
        self.scan_off(&meta.id, 0, &mut |mut record: EventRecord| {
            if record.seq > through {
                return false;
            }
            self.display_logged(Some(session), &mut record);
            images.extend(super::prompt_images::ids_named_by(&record.kind, &record.msg));
            let write = write_record(&mut out, &record, &mut bytes);
            if let Err(error) = write {
                failed = Some(error);
                return false;
            }
            count += 1;
            last = record.seq;
            true
        })?;
        if let Some(error) = failed {
            return Err(error);
        }
        anyhow::ensure!(last == through, "replica journal ended before its high-water mark");
        out.flush()?;
        for id in &images {
            let source = super::prompt_images::image_path(id)
                .filter(|path| path.is_file())
                .context("replica is missing a referenced prompt image")?;
            copy_bounded(
                &source,
                &dir.join(super::prompt_images::BUNDLE_DIR).join(id),
                &mut bytes,
                false,
            )?;
        }
        crate::home_fs::write(dir.join(super::composers::BUNDLE_FILE), composers.to_string())?;
        crate::home_fs::write(dir.join("session.json"), serde_json::to_vec(&meta)?)?;
        let manifest = json!({
            "schema": "acpmux.bundle.v1", "id": meta.id, "eventCount": count,
            "lastSeq": through, "native": files.native, "harness": files.harness,
            "replica": {"schema": REPLICA_SCHEMA, "throughSeq": through}
        });
        crate::home_fs::write(dir.join("manifest.json"), serde_json::to_vec(&manifest)?)?;
        Ok(dir)
    }

    /// Recover an authenticated, decrypted replica directory as a new idle chat. Source
    /// automation is preserved as inert history; the next prompt is explicitly supplied.
    pub(crate) async fn recover_running_replica(
        self: &Arc<Self>,
        bundle: &Path,
        cwd: &Path,
        name: Option<&str>,
    ) -> Result<Value> {
        anyhow::ensure!(cwd.is_dir(), "recovery working directory does not exist");
        let scratch = tempfile::tempdir()?;
        let staged = scratch.path().join("bundle");
        crate::qos::off_worker(|| copy_tree(bundle, &staged, 0, &mut 0))?;
        let manifest: Value =
            serde_json::from_slice(&std::fs::read(staged.join("manifest.json"))?)?;
        anyhow::ensure!(
            manifest.pointer("/replica/schema").and_then(Value::as_str) == Some(REPLICA_SCHEMA),
            "not a running-chat replica"
        );
        let mut meta: SessionMeta =
            serde_json::from_slice(&std::fs::read(staged.join("session.json"))?)?;
        anyhow::ensure!(meta.auto_session.is_none(), "Auto recovery requires its fenced holder");
        require_native(
            &meta,
            manifest["native"].as_array().map(Vec::as_slice).unwrap_or(&[]),
            &manifest["harness"],
        )?;
        let source = meta.id.clone();
        meta.id = uuid::Uuid::now_v7().to_string();
        if let Some(agent) = &meta.agent_session_id {
            anyhow::ensure!(
                !self.auto_agent_session_taken(&meta.id, agent),
                "agent conversation already belongs to a local chat; recover on another machine"
            );
        }
        anyhow::ensure!(
            native_kind(&meta) != "opencode",
            "OpenCode replica is retained, but collision-safe database recovery is not supported"
        );
        meta.cwd = cwd.to_path_buf();
        meta.status = SessionStatus::Idle;
        // A recovery is neither an adopted process nor an automatically started fork/goal.
        meta.fork_start = None;
        meta.idle_launch = None;
        meta.watching = None;
        meta.goal = None;
        meta.auto_session = None;
        meta.subagent_retry_open = false;
        meta.subsession = None;
        meta.delegator = None;
        meta.handle = None;
        meta.roles.clear();
        meta.succeeds.clear();
        meta.former_names.clear();
        meta.lineage = None;
        meta.created_by = None;
        meta.fork_of_subagent = None;
        meta.retired_agent_session_ids.clear();
        let archived = crate::qos::off_worker(|| project_history(&staged, &mut meta))?;
        crate::home_fs::write(staged.join("session.json"), serde_json::to_vec(&meta)?)?;
        // Validate and place native state strictly. The generic import tolerates divergent
        // existing native files, which is inappropriate for a recovered durable copy.
        let plan = crate::native::guarded_plan(&staged, &meta).map_err(anyhow::Error::msg)?;
        let listed = manifest["native"].as_array().context("replica native manifest is invalid")?;
        anyhow::ensure!(plan.len() == listed.len(), "replica native files do not match manifest");
        for entry in listed {
            let path = entry["path"].as_str().context("replica native path is invalid")?;
            anyhow::ensure!(
                plan.iter().any(|(source, _)| source == &staged.join("native").join(path)),
                "replica is missing a declared native file"
            );
        }
        let native = staged.join("native");
        let kept = scratch.path().join("native");
        if native.exists() {
            std::fs::rename(&native, &kept)?;
        }
        let plan: Vec<_> = plan
            .into_iter()
            .map(|(src, dst)| {
                Ok((
                    kept.join(src.strip_prefix(&native).context("native plan escaped bundle")?),
                    dst,
                ))
            })
            .collect::<Result<_>>()?;
        // This refuses even an orphaned same-id file; no source's native store is overwritten.
        crate::qos::off_worker(|| crate::native::restore_guarded(&plan, false))?;
        let imported = self
            .import_into_held(
                &staged,
                name.map(str::to_owned),
                super::transfer::Live::No,
                None,
                false,
                false,
                None,
                true,
            )
            .await;
        let session = match imported {
            Ok(session) => session,
            Err(error) => {
                if let Some(home) = dirs::home_dir() {
                    for (_, path) in &plan {
                        let _ = crate::home_fs::remove_file(home.join(path));
                    }
                }
                return Err(anyhow::anyhow!("replica import: {error:?}"));
            }
        };
        if let Ok(raw) = std::fs::read(staged.join(super::composers::BUNDLE_FILE)) {
            if let Ok(value) = serde_json::from_slice::<Value>(&raw) {
                session.composers.lock().unwrap_or_else(|e| e.into_inner()).restore(&value);
            }
        }
        self.end_move(&session);
        self.save_meta(&session);
        Ok(json!({"sessionId": session.id, "sourceSessionId": source,
            "status": "idle", "automaticContinuation": false,
            "archivedControlRecords": archived, "queueRecovery": "history-only",
            "workingDirectoryRestored": false}))
    }
}

fn native_kind(meta: &SessionMeta) -> &str {
    if meta.harness == "cmux-harness" {
        return "cmux-harness";
    }
    [meta.family.as_deref(), Some(meta.harness.as_str())]
        .into_iter()
        .flatten()
        .find(|kind| ["claude", "codex", "pi", "opencode"].contains(kind))
        .unwrap_or(&meta.harness)
}

/// Copy exactly the observed prefix. A source growing during capture cannot extend this
/// read; an incomplete last JSONL line is excluded from native resumable state.
fn copy_bounded(source: &Path, target: &Path, total: &mut u64, lines: bool) -> Result<()> {
    anyhow::ensure!(
        std::fs::symlink_metadata(source)?.is_file(),
        "replica source is not a regular file"
    );
    let mut input = std::fs::File::open(source)?;
    let length = input.metadata()?.len();
    *total = total.checked_add(length).context("replica size overflow")?;
    anyhow::ensure!(*total <= MAX_BYTES, "running replica exceeds its byte limit");
    if let Some(parent) = target.parent() {
        crate::home_fs::create_dirs(parent)?;
    }
    let mut output = crate::home_fs::create_file(target)?;
    let mut remaining = length;
    let (mut copied, mut complete) = (0u64, 0u64);
    let mut buffer = [0u8; 64 << 10];
    while remaining > 0 {
        let limit = remaining.min(buffer.len() as u64) as usize;
        let n = input.read(&mut buffer[..limit])?;
        anyhow::ensure!(n != 0, "native session shrank during replica capture");
        if let Some(last) = buffer[..n].iter().rposition(|b| *b == b'\n') {
            complete = copied + last as u64 + 1;
        }
        output.write_all(&buffer[..n])?;
        copied += n as u64;
        remaining -= n as u64;
    }
    if lines {
        output.set_len(complete)?;
    }
    output.sync_all()?;
    Ok(())
}

fn capture_native(
    meta: &SessionMeta,
    dir: &Path,
    bytes: &mut u64,
) -> Result<super::transfer_agent_files::AgentFiles> {
    let mut native = Vec::new();
    if meta.agent_session_id.as_deref().is_some_and(|id| !id.is_empty()) {
        anyhow::ensure!(
            matches!(native_kind(meta), "claude" | "codex" | "pi"),
            "bounded native replica capture is unsupported for this harness"
        );
    }
    let home = dirs::home_dir().context("native replica needs a home directory")?;
    for (label, source) in crate::native::locate(meta) {
        let rel =
            source.strip_prefix(&home).context("native file is outside the home directory")?;
        let path = Path::new(&label).join(rel);
        copy_bounded(&source, &dir.join("native").join(&path), bytes, true)?;
        native.push(json!({"label": label, "path": path}));
    }
    require_native(meta, &native, &Value::Null)?;
    Ok(super::transfer_agent_files::AgentFiles { native, harness: Value::Null })
}

fn require_native(meta: &SessionMeta, native: &[Value], harness: &Value) -> Result<()> {
    if meta.agent_session_id.as_deref().is_none_or(str::is_empty) {
        return Ok(());
    }
    let label = match native_kind(meta) {
        "claude" => "claude-project",
        "codex" => "codex-rollout",
        "pi" => "pi-session",
        "opencode" => crate::native::OPENCODE_EXPORT,
        "cmux-harness" => {
            anyhow::ensure!(!harness.is_null(), "replica lacks the durable harness journal");
            return Ok(());
        }
        _ => anyhow::bail!("native replica capture is unsupported for this harness"),
    };
    anyhow::ensure!(
        native.iter().any(|entry| entry["label"] == label),
        "replica lacks required {label} native session state"
    );
    Ok(())
}

fn write_record(
    out: &mut impl std::io::Write,
    record: &EventRecord,
    bytes: &mut u64,
) -> Result<()> {
    let line = serde_json::to_vec(record)?;
    *bytes = bytes.saturating_add(line.len() as u64 + 1);
    anyhow::ensure!(*bytes <= MAX_BYTES, "running replica exceeds its byte limit");
    out.write_all(&line)?;
    out.write_all(b"\n")?;
    Ok(())
}

fn copy_tree(source: &Path, dest: &Path, depth: usize, bytes: &mut u64) -> Result<()> {
    anyhow::ensure!(depth <= 16, "replica directory nesting exceeds limit");
    crate::home_fs::create_dirs(dest)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let target = dest.join(entry.file_name());
        if kind.is_dir() {
            copy_tree(&entry.path(), &target, depth + 1, bytes)?;
        } else {
            anyhow::ensure!(kind.is_file(), "replica contains a non-regular file");
            copy_bounded(&entry.path(), &target, bytes, false)?;
        }
    }
    Ok(())
}

/// Apply the same transcript allowlist as a local fork. All other records retain their
/// original payload under a non-executable kind, including queues, inboxes and retry timers.
fn inert(record: &mut EventRecord) -> bool {
    if crate::store::HISTORY_KINDS
        .contains(&record.kind.strip_suffix(".replay").unwrap_or(&record.kind))
    {
        return false;
    }
    record.msg = json!({"kind": record.kind, "dir": record.dir, "record": record.msg});
    record.kind = "replica_history".into();
    record.dir = "mux".into();
    record.host_seq = None;
    true
}

fn project_history(bundle: &Path, meta: &mut SessionMeta) -> Result<u64> {
    for entry in std::fs::read_dir(bundle.join("events"))? {
        anyhow::ensure!(
            entry?.file_name() == "000001.ndjson",
            "replica contains an unexpected journal file"
        );
    }
    let path = bundle.join("events/000001.ndjson");
    let input = std::io::BufReader::new(std::fs::File::open(&path)?);
    let projected = bundle.join("events/projected.part");
    let mut out = std::io::BufWriter::new(crate::home_fs::create_file(&projected)?);
    let (mut last, mut bytes, mut archived) = (0u64, 0u64, 0u64);
    let mut direct = super::unstarted_prompt::Unstarted::default();
    let mut open = None;
    for line in input.lines() {
        let mut record: EventRecord = serde_json::from_str(&line?)?;
        anyhow::ensure!(
            record.seq > last && record.seq <= meta.last_seq,
            "replica journal sequence is invalid"
        );
        last = record.seq;
        archived += u64::from(inert(&mut record));
        direct.read(&record);
        match record.kind.as_str() {
            "turn_started" => open = Some(record.clone()),
            "turn_result" => open = None,
            _ => {}
        }
        write_record(&mut out, &record, &mut bytes)?;
    }
    anyhow::ensure!(last == meta.last_seq, "replica journal is incomplete");
    // Settle in the staged bundle, before import publishes anything. Even a crash during
    // import cannot turn an accepted but unstarted prompt into a recovered automatic run.
    for started in direct.finish().into_iter().chain(open) {
        last += 1;
        let result = json!({"status": "failed", "detail": "outcome_unknown",
            "turnId": started.msg.get("turnId"), "promptId": started.msg.get("promptId"),
            "turnSeq": started.seq, "errorText": "Recovered from a saved copy. The source may still be running; check tool effects before continuing. Pending prompts remain in recovery history."});
        let record = EventRecord {
            seq: last,
            at: started.at,
            dir: "mux".into(),
            kind: "turn_result".into(),
            msg: result.clone(),
            host_seq: None,
        };
        write_record(&mut out, &record, &mut bytes)?;
        meta.last_turn = Some(result);
    }
    out.flush().context("flush recovered history")?;
    drop(out);
    crate::home_fs::rename(projected, path)?;
    meta.last_seq = last;
    meta.transcript_seq = last;
    Ok(archived)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(kind: &str, seq: u64) -> EventRecord {
        EventRecord {
            seq,
            at: seq,
            dir: "mux".into(),
            kind: kind.into(),
            msg: json!({"turnId": "t", "promptId": "p", "text": "preserved"}),
            host_seq: None,
        }
    }

    #[test]
    fn running_replica_control_history_cannot_restart_queues_or_timers() {
        for kind in [
            "queued",
            "queue_updated",
            "inbox_received",
            "auto_resume_scheduled",
            "agent_pair_held",
            "unknown_future_control",
        ] {
            let mut event = record(kind, 1);
            assert!(inert(&mut event));
            assert_eq!(event.kind, "replica_history");
            assert_eq!(event.msg["kind"], kind);
            assert_eq!(event.msg["record"]["text"], "preserved");
            assert!(!Hub::QUEUE_KINDS.contains(&event.kind.as_str()));
        }
        let mut message = record("user_message", 1);
        assert!(!inert(&mut message));
    }

    #[test]
    fn running_replica_stream_refuses_growth_past_byte_limit() {
        let mut bytes = MAX_BYTES;
        let mut output = Vec::new();
        assert!(write_record(&mut output, &record("user_message", 1), &mut bytes).is_err());
        assert!(output.is_empty());
    }
}
