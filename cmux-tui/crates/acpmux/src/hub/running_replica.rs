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
        anyhow::ensure!(
            manifest["id"] == meta.id
                && manifest["lastSeq"].as_u64() == Some(meta.last_seq)
                && manifest["replica"]["throughSeq"].as_u64() == Some(meta.last_seq),
            "replica manifest and journal watermark disagree"
        );
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
    let mut direct = super::queue::unstarted_prompt::Unstarted::default();
    let mut open = None;
    let mut tools = std::collections::BTreeMap::<String, Value>::new();
    let mut settled_tools = std::collections::BTreeSet::new();
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
        if matches!(record.kind.trim_end_matches(".replay"), "tool_call" | "tool_call_update") {
            if let Some(update) = record.msg.pointer("/params/update") {
                if let Some(id) = update["toolCallId"].as_str() {
                    if matches!(update["status"].as_str(), Some("completed" | "failed")) {
                        tools.remove(id);
                        settled_tools.insert(id.to_owned());
                    } else if !settled_tools.contains(id) {
                        tools.insert(id.to_owned(), record.msg.clone());
                    }
                }
            }
        }
        write_record(&mut out, &record, &mut bytes)?;
    }
    anyhow::ensure!(last == meta.last_seq, "replica journal is incomplete");
    for (id, msg) in tools {
        last += 1;
        let msg = json!({"jsonrpc":"2.0", "method":"session/update", "params": {
            "sessionId": msg.pointer("/params/sessionId"), "update": {
                "sessionUpdate": "tool_call_update", "toolCallId": id, "status": "failed",
                "_meta": {"acpmux": {"outcomeUnknown": true}}
            }
        }});
        let event = EventRecord {
            seq: last,
            at: meta.updated_at,
            dir: "agent".into(),
            kind: "tool_call_update".into(),
            msg,
            host_seq: None,
        };
        write_record(&mut out, &event, &mut bytes)?;
    }
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

    fn meta(id: &str, cwd: &Path) -> SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "fake", "family": "claude", "cwd": cwd,
            "status": "running", "createdAt": 1, "updatedAt": 2
        }))
        .unwrap()
    }

    fn hub(root: &Path) -> Arc<Hub> {
        let cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["false"], "family": "claude"}},
            "defaultHarness": "fake", "store": {"mode": "local"}
        }))
        .unwrap();
        let store = crate::store::open(&cfg.store, root).unwrap();
        Hub::new(cfg, store)
    }

    fn native_path(cwd: &Path, id: &str) -> PathBuf {
        let project: String = cwd
            .to_string_lossy()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect();
        dirs::home_dir().unwrap().join(".claude/projects").join(project).join(format!("{id}.jsonl"))
    }

    // Only directories with a unique test-created working-directory name are removed.
    struct NativeFiles(Vec<PathBuf>);
    impl Drop for NativeFiles {
        fn drop(&mut self) {
            for path in &self.0 {
                let _ = std::fs::remove_file(path);
                if let Some(parent) = path.parent() {
                    let _ = std::fs::remove_dir(parent);
                }
            }
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn running_replica_long_silent_turn_recovers_idle_and_stays_inert_after_restart() {
        use cmux_session_cloud::{Cloud, replica, seal, store::FsStore};
        let tmp = tempfile::tempdir().unwrap();
        let source_cwd = tmp.path().join("source-cwd");
        let recovery_cwd = tmp.path().join("recovery-cwd");
        std::fs::create_dir_all(&source_cwd).unwrap();
        std::fs::create_dir_all(&recovery_cwd).unwrap();
        let source_store = tempfile::tempdir().unwrap();
        let source = hub(source_store.path());
        let source_id = uuid::Uuid::now_v7().to_string();
        let native_id = uuid::Uuid::now_v7().to_string();
        let mut metadata = meta(&source_id, &source_cwd);
        metadata.agent_session_id = Some(native_id.clone());
        source.store.save(&metadata).unwrap();
        let session = source.make_session(metadata);
        source.sessions.lock().unwrap().insert(source_id.clone(), session.clone());
        source.append(
            &session,
            "mux",
            "user_message",
            json!({
                "turnId":"t", "promptId":"p", "text":"long running task"
            }),
        );
        source.append(&session, "mux", "turn_started", json!({"turnId":"t", "promptId":"p"}));
        for i in 0..2048 {
            source.append(
                &session,
                "agent",
                "agent_message_chunk",
                json!({
                    "params": {"sessionId": native_id, "update": {
                        "sessionUpdate":"agent_message_chunk", "messageId":"m",
                        "content":{"type":"text", "text":format!("chunk {i}\n")}
                    }}
                }),
            );
        }
        source.append(
            &session,
            "agent",
            "tool_call",
            json!({"params": {
                "sessionId": native_id, "update": {"sessionUpdate":"tool_call",
                "toolCallId":"silent-tool", "status":"in_progress", "title":"write files"}
            }}),
        );
        source.append(
            &session,
            "mux",
            "queued",
            json!({
                "turnId":"queued-turn", "promptId":"queued-prompt", "text":"do not execute"
            }),
        );
        // An accepted direct prompt that never started must not re-enter the queue either.
        source.append(
            &session,
            "mux",
            "user_message",
            json!({
                "turnId":"accepted-turn", "promptId":"accepted-prompt", "text":"also inert"
            }),
        );
        source.save_meta(&session);
        let source_native = native_path(&source_cwd, &native_id);
        let recovered_native = native_path(&recovery_cwd, &native_id);
        let _cleanup = NativeFiles(vec![source_native.clone(), recovered_native.clone()]);
        crate::home_fs::create_dirs(source_native.parent().unwrap()).unwrap();
        crate::home_fs::write(&source_native, b"{\"type\":\"assistant\",\"text\":\"initial\"}\n")
            .unwrap();
        let first = source.capture_running_replica(&session, &tmp.path().join("first")).unwrap();
        let cloud = Cloud {
            store: Box::new(FsStore::new(tmp.path().join("cloud")).unwrap()),
            key: seal::Key::from_bytes([7; 32]),
            root_prefix: "m.running-test.".into(),
        };
        let before = replica::publish(&first, &source_id, &cloud).unwrap();
        let through = session.meta().last_seq;
        // Native progress changes without an ACP journal event: the long silent-turn case.
        let mut native = std::fs::OpenOptions::new().append(true).open(&source_native).unwrap();
        native.write_all(b"{\"type\":\"assistant\",\"text\":\"late silent progress\",\"permissionMode\":\"bypassPermissions\"}\n{\"partial\":").unwrap();
        drop(native);
        let second = source.capture_running_replica(&session, &tmp.path().join("second")).unwrap();
        assert_eq!(session.meta().last_seq, through);
        let after = replica::publish(&second, &source_id, &cloud).unwrap();
        assert_ne!(before.manifest, after.manifest);
        drop(session);
        drop(source);
        source_store.close().unwrap();
        std::fs::remove_file(&source_native).unwrap();
        std::fs::remove_dir_all(&first).unwrap();
        std::fs::remove_dir_all(&second).unwrap();
        let bundle = tmp.path().join("downloaded");
        replica::recover(&after.pair, &bundle, &cloud).unwrap();
        let destination = tmp.path().join("recovered-store");
        let recovered = hub(&destination);
        let result = recovered
            .recover_running_replica(&bundle, &recovery_cwd, Some("recovered"))
            .await
            .unwrap();
        let id = result["sessionId"].as_str().unwrap().to_owned();
        assert_ne!(id, source_id);
        assert_eq!(result["automaticContinuation"], false);
        let chat = recovered.resolve_here(&id).unwrap();
        assert_eq!(chat.meta().status, SessionStatus::Idle);
        let mut events = Vec::new();
        recovered
            .scan_off(&id, 0, &mut |event| {
                events.push(event);
                true
            })
            .unwrap();
        assert_eq!(events.iter().filter(|e| e.kind == "agent_message_chunk").count(), 2048);
        assert!(events.iter().any(|e| e.kind == "replica_history" && e.msg["kind"] == "queued"));
        assert_eq!(
            events
                .iter()
                .filter(|e| e.kind == "turn_result" && e.msg["detail"] == "outcome_unknown")
                .count(),
            2
        );
        assert!(events.iter().any(|e| e.kind == "tool_call_update"
            && e.msg.pointer("/params/update/_meta/acpmux/outcomeUnknown") == Some(&json!(true))));
        let restored = std::fs::read_to_string(&recovered_native).unwrap();
        assert!(restored.contains("late silent progress"));
        assert!(!restored.contains("bypassPermissions"));
        assert!(!restored.contains("partial"));
        recovered.restore_queue(&chat);
        assert!(chat.queue.lock().unwrap().is_empty());
        drop(chat);
        recovered.shutdown_all().await;
        recovered.close_owned_tasks().await;
        drop(recovered);
        let restarted = hub(&destination);
        let chat = restarted.resolve_here(&id).unwrap();
        restarted.restore_queue(&chat);
        assert!(chat.queue.lock().unwrap().is_empty());
        assert_eq!(chat.meta().status, SessionStatus::Idle);
    }

    #[test]
    fn running_replica_refuses_extra_journal_segments() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("events")).unwrap();
        std::fs::write(tmp.path().join("events/000001.ndjson"), "").unwrap();
        std::fs::write(tmp.path().join("events/000002.ndjson"), "").unwrap();
        assert!(project_history(tmp.path(), &mut meta("test", tmp.path())).is_err());
    }

    #[cfg(unix)]
    struct RunningTestTool {
        // Written by this test's stand-in agent after starting its own process group.
        pid_file: PathBuf,
        hub: Option<Arc<Hub>>,
    }

    #[cfg(unix)]
    impl Drop for RunningTestTool {
        fn drop(&mut self) {
            if let Some(pid) = std::fs::read_to_string(&self.pid_file)
                .ok()
                .and_then(|text| text.trim().parse::<i32>().ok())
                .filter(|pid| *pid > 1)
            {
                // SAFETY: fake_agent.py's auto-run starts this test's shell with
                // start_new_session=True. The private pid file identifies only that group.
                unsafe {
                    libc::killpg(pid, libc::SIGKILL);
                }
            }
            if let Some(hub) = self.hub.take() {
                tokio::spawn(async move {
                    hub.shutdown_all().await;
                });
            }
        }
    }

    /// A real ACP agent and shell are live at both capture and recovery. This complements
    /// the synthetic crash fixture above: no test appends journal events on this path.
    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn running_replica_live_agent_recovers_long_history_mid_silent_tool() {
        use cmux_session_cloud::{Cloud, replica, seal, store::FsStore};
        use std::time::{Duration, Instant};
        let tmp = tempfile::tempdir().unwrap();
        let cwd = tmp.path().join("source-cwd");
        let restored_cwd = tmp.path().join("restored-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::create_dir_all(&restored_cwd).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let sent_log = tmp.path().join("agent-responses.log");
        let cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake], "family": "claude",
                "env": {"FAKE_CLAUDE_STORE": "1", "FAKE_RESET_CANCEL_ON_PROMPT": "1",
                    "FAKE_SENT_LOG": sent_log}}},
            "defaultHarness": "fake", "store": {"mode": "local"},
            "titles": {"generate": false}
        }))
        .unwrap();
        let source = Hub::new(
            cfg.clone(),
            crate::store::open(&cfg.store, &tmp.path().join("source-store")).unwrap(),
        );
        let out = tmp.path().join("tool.log");
        let mut cleanup =
            RunningTestTool { pid_file: out.with_extension("log.pid"), hub: Some(source.clone()) };
        let session = source
            .new_session(NewRequest { cwd: Some(cwd.clone()), ..Default::default() })
            .await
            .unwrap();
        let native_id = session.meta().agent_session_id.unwrap();
        let source_native = native_path(&cwd, &native_id);
        let destination_native = native_path(&restored_cwd, &native_id);
        let _native_cleanup = NativeFiles(vec![source_native.clone(), destination_native.clone()]);
        let history_started = Instant::now();
        let history = tokio::time::timeout(
            Duration::from_secs(60),
            source.prompt(
                &session,
                vec![json!({"type":"text", "text":"delta-chunks: 12000 128"})],
                "test",
                false,
            ),
        )
        .await;
        if history.is_err() {
            let mut chunks = 0;
            let mut bytes = 0;
            let mut tail = std::collections::VecDeque::new();
            source
                .scan_off(&session.id, 0, &mut |event| {
                    if event.kind == "agent_message_chunk" {
                        chunks += 1;
                        bytes += event
                            .msg
                            .pointer("/params/update/content/text")
                            .and_then(Value::as_str)
                            .map_or(0, str::len);
                    }
                    if tail.len() == 12 {
                        tail.pop_front();
                    }
                    tail.push_back((event.seq, event.kind));
                    true
                })
                .unwrap();
            panic!(
                "history prompt timed out after {:?}: durable_chunks={chunks} durable_bytes={bytes} status={:?} turn_active={} agent_answered={} tail={tail:?}",
                history_started.elapsed(),
                session.meta().status,
                session.turn().is_some(),
                sent_log.exists()
            );
        }
        history.unwrap().unwrap();
        eprintln!("ordinary-running-replica: history_ms={}", history_started.elapsed().as_millis());
        let mut updates = source.subscribe();
        let source_for_turn = source.clone();
        let session_for_turn = session.clone();
        let prompt = format!("auto-run: {}", out.display());
        let live_prompt = prompt.clone();
        let live = tokio::spawn(async move {
            source_for_turn
                .prompt(
                    &session_for_turn,
                    vec![json!({"type":"text", "text":live_prompt})],
                    "test",
                    false,
                )
                .await
        });
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let event = updates.recv().await.unwrap();
                if event.session_id == session.id && event.record.kind == "tool_call" {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while std::fs::read_to_string(&out).unwrap_or_default() != "start\n"
            || !cleanup.pid_file.is_file()
        {
            assert!(Instant::now() < deadline, "live tool did not start");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(session.turn().is_some());
        assert!(!live.is_finished());
        let cloud = Cloud {
            store: Box::new(FsStore::new(tmp.path().join("cloud")).unwrap()),
            key: seal::Key::from_bytes([8; 32]),
            root_prefix: "m.live-running-test.".into(),
        };
        let snapshot =
            source.capture_running_replica(&session, &tmp.path().join("snapshot")).unwrap();
        let receipt = replica::publish(&snapshot, &session.id, &cloud).unwrap();
        let manifest: Value =
            serde_json::from_slice(&std::fs::read(snapshot.join("manifest.json")).unwrap())
                .unwrap();
        let through = manifest["lastSeq"].as_u64().unwrap();
        assert!(through > 256, "live chat spans multiple event pages");
        let mut source_log = Vec::new();
        source
            .scan_off(&session.id, 0, &mut |event| {
                source_log.push(event);
                true
            })
            .unwrap();
        let reply_bytes: usize = source_log
            .iter()
            .filter(|event| event.kind == "agent_message_chunk")
            .filter_map(|event| {
                event.msg.pointer("/params/update/content/text").and_then(Value::as_str)
            })
            .map(str::len)
            .sum();
        assert_eq!(reply_bytes, 12_000 * 128, "all streamed reply bytes reached the durable log");
        let native_before = std::fs::read_to_string(&source_native).unwrap();
        assert!(native_before.contains("delta-chunks: 12000 128"));
        assert!(native_before.contains(&prompt));
        std::fs::remove_dir_all(snapshot).unwrap();
        let download = tmp.path().join("download");
        replica::recover(&receipt.pair, &download, &cloud).unwrap();
        let dest_store = tmp.path().join("destination-store");
        let destination =
            Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dest_store).unwrap());
        let result = destination
            .recover_running_replica(&download, &restored_cwd, Some("recovered-live"))
            .await
            .unwrap();
        let id = result["sessionId"].as_str().unwrap();
        let recovered = destination.resolve_here(id).unwrap();
        assert_ne!(id, session.id);
        assert_eq!(recovered.meta().status, SessionStatus::Idle);
        assert!(recovered.turn().is_none());
        assert!(recovered.child.lock().await.is_none(), "recovery did not start an agent");
        let mut restored_log = Vec::new();
        destination
            .scan_off(id, 0, &mut |event| {
                restored_log.push(event);
                true
            })
            .unwrap();
        let transcript = |log: &[EventRecord]| {
            log.iter()
                .filter(|e| {
                    e.seq <= through && crate::store::HISTORY_KINDS.contains(&e.kind.as_str())
                })
                .map(|e| (e.seq, e.kind.clone(), e.msg.clone()))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            transcript(&restored_log),
            transcript(&source_log),
            "full live transcript recovered"
        );
        let native_records = |text: &str| {
            text.lines()
                .filter(|line| !line.trim().is_empty())
                .map(|line| serde_json::from_str::<Value>(line).unwrap())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            native_records(&std::fs::read_to_string(&destination_native).unwrap()),
            native_records(&native_before)
        );
        assert!(
            restored_log
                .iter()
                .any(|e| e.kind == "turn_result" && e.msg["detail"] == "outcome_unknown")
        );
        destination.restore_queue(&recovered);
        assert!(recovered.queue.lock().unwrap().is_empty());
        assert!(session.turn().is_some(), "source remains live during explicit recovery");
        assert!(!live.is_finished());
        assert_eq!(std::fs::read_to_string(&out).unwrap(), "start\n", "tool was not replayed");
        let recovered_id = id.to_owned();
        drop(recovered);
        destination.shutdown_all().await;
        destination.close_owned_tasks().await;
        drop(destination);
        let restarted = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dest_store).unwrap());
        let recovered = restarted.resolve_here(&recovered_id).unwrap();
        restarted.restore_queue(&recovered);
        assert!(recovered.queue.lock().unwrap().is_empty());
        assert!(recovered.turn().is_none());
        assert!(recovered.child.lock().await.is_none());
        assert_eq!(std::fs::read_to_string(&out).unwrap(), "start\n");
        eprintln!(
            "ordinary-running-replica: live_chunks=12000 live_bytes={reply_bytes} records={through} recovered_idle=true replayed_tools=0"
        );
        // Kill the test-owned shell group while its leader is still alive; cancel alone
        // would kill the shell but leave its detached sleep child until its time limit.
        cleanup.hub = None;
        drop(cleanup);
        source.cancel(&session).await.unwrap();
        let _ = tokio::time::timeout(Duration::from_secs(10), live).await.unwrap();
        source.shutdown_all().await;
        restarted.shutdown_all().await;
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
