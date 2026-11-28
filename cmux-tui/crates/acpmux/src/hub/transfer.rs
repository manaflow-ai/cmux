//! Part of `Hub`; see `hub/mod.rs`.

use super::transfer_guard::plain_agent_session;
use super::*;
use cmux_json::JsonSet as _;
use std::sync::Mutex;

static HARNESS_STATE_LOCK: Mutex<()> = Mutex::new(());

/// Durable markers are made, rolled back and swept under one lock (`HARNESS_STATE_LOCK`), so a
/// sweep that read a marker finishes with it before its import's rollback or a retry runs.
pub(super) fn harness_state_lock() -> std::sync::MutexGuard<'static, ()> {
    HARNESS_STATE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

pub(super) use super::atomic_json::{is_plain_id, write_json_atomic};

/// Beside a move's bundle: what the first bytes of each agent file a history-later prepare had
/// copied hash to, `{"native/<label>/<path>": {length, sha256}}` (`export_grown`).
pub(super) const NATIVE_DIGESTS: &str = "native-digests.json";

/// [`Hub::import_into`]'s `(live, guarded, replace_durable, defer_finalize, staged)`.
pub(super) type ImportOptions<'a> = (
    Live,
    Option<super::transfer_guard::GuardedImport<'a>>,
    bool,
    bool,
    Option<&'a transfer_out::transfer_precopy::StagedPrefix>,
);

/// Whether the durable marker at `marker` stands for the chat `outer_id`.
fn marker_names(marker: &Path, outer_id: &str) -> bool {
    std::fs::read(marker)
        .ok()
        .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
        .is_some_and(|v| v.get("outerId").and_then(Value::as_str) == Some(outer_id))
}

/// Releases an import's claim on its session id however the import ends.
struct ImportReservation<'a> {
    hub: &'a Hub,
    id: String,
}

impl Drop for ImportReservation<'_> {
    fn drop(&mut self) {
        self.hub.importing.lock().unwrap().remove(&self.id);
    }
}

impl Hub {
    // ------------------------------------------------------------- export

    pub fn export(&self, session: &Arc<Session>, dest: &Path) -> Result<PathBuf> {
        self.export_after(session, dest, None)
    }

    /// `export`; `after` a staged prefix's last seq, its log holds only the records past it
    /// (`transfer_precopy.rs`).
    pub(super) fn export_after(
        &self,
        session: &Arc<Session>,
        dest: &Path,
        after: Option<u64>,
    ) -> Result<PathBuf> {
        self.export_grown(session, dest, after, None)
    }

    /// [`Self::export_after`]; `grown` a history-later prepare's copies of the agent's files and
    /// what each holds (`transfer_precopy.rs` `PrefixFold`): each that the file now only grew
    /// past moves into the bundle with that growth appended, and `dest`'s
    /// [`NATIVE_DIGESTS`] says what its first bytes hash to, so neither the copy nor the
    /// digest a move asks of them (`transfer_digest`) reads the whole file under the freeze.
    pub(super) fn export_grown(
        &self,
        session: &Arc<Session>,
        dest: &Path,
        after: Option<u64>,
        grown: Option<(&Path, &Value)>,
    ) -> Result<PathBuf> {
        // What the log holds back goes in first (`store/deferred.rs`).
        anyhow::ensure!(
            self.store_deferred(session),
            "could not store the chat's newest tool output"
        );
        let mut meta = session.meta();
        // A fork by reference names a chat the other machine does not have: the log below
        // holds that history itself (`store/fork_view.rs` scans through it), under its seqs.
        if let Some(r) = meta.history_from.take() {
            meta.history_kept_through = Some(r.through_seq);
        }
        let dir = dest.join(&meta.id);
        crate::home_fs::create_dirs(dir.join("events"))?;
        crate::home_fs::write(dir.join("session.json"), serde_json::to_string_pretty(&meta)?)?;
        use std::io::Write;
        // Stream the log into the bundle; a long session never sits in memory whole.
        let file = crate::home_fs::create_file(dir.join("events").join("000001.ndjson"))?;
        let mut out = std::io::BufWriter::new(file);
        let mut event_count = 0usize;
        let mut failed: Option<anyhow::Error> = None;
        let mut images = std::collections::BTreeSet::new();
        self.scan_off(&meta.id, after.unwrap_or(0), &mut |mut e: EventRecord| {
            // An ask carries the display line acpmux works out now, never a logged one.
            self.display_logged(Some(&**session), &mut e);
            images.extend(super::prompt_images::ids_named_by(&e.kind, &e.msg));
            let written = serde_json::to_string(&e).map_err(anyhow::Error::from).and_then(|line| {
                out.write_all(line.as_bytes())?;
                out.write_all(b"\n")?;
                Ok(())
            });
            match written {
                Ok(()) => {
                    event_count += 1;
                    true
                }
                Err(err) => {
                    failed = Some(err);
                    false
                }
            }
        })?;
        if let Some(e) = failed {
            return Err(e);
        }
        out.flush()?;
        // The draft's attachments go with its text (`draft_attachments.rs`).
        self.export_draft_attachments(session, &dir)?;
        // The images its prompts sent (`prompt_images.rs`), which the log names but does not hold,
        // the pre-copied prefix's prompts' too.
        if let Some(after) = after {
            super::prompt_images::prefix_ids(&*self.store, &meta.id, after, &mut images)?;
        }
        // Each surface's unsent draft and who sent the queued prompts (`composers.rs`), which
        // live in memory, not the log; the images the drafts hold go with the prompts' images.
        let composers = {
            let c = session.composers.lock().unwrap_or_else(|e| e.into_inner());
            images.extend(c.image_ids());
            c.bundled()
        };
        super::prompt_images::bundle_images(&images, &dir)?;
        crate::home_fs::write(dir.join(super::composers::BUNDLE_FILE), composers.to_string())?;
        // The agent's own files (`transfer_agent_files.rs`), which an Auto snapshot carries too.
        let files = self.export_agent_files(&meta, &dir, dest, grown)?;
        let mut manifest = json!({
            "schema": "acpmux.bundle.v1",
            "id": meta.id,
            "eventCount": event_count,
            "lastSeq": meta.last_seq,
            "native": files.native,
            "harness": files.harness,
        });
        if let Some(after) = after {
            manifest.set("afterSeq", json!(after));
        }
        crate::home_fs::write(dir.join("manifest.json"), serde_json::to_string_pretty(&manifest)?)?;
        Ok(dir)
    }

    pub async fn import(
        self: &Arc<Self>,
        bundle: &Path,
        name: Option<String>,
    ) -> Result<Arc<Session>, RpcError> {
        self.import_into(bundle, name, Live::No, None, false, false, None).await
    }

    /// `import`; a `live` one (a chat moved here, `transfer_in.rs`) has its queue back before
    /// any client sees it, so no new prompt runs ahead of it. A `guard`ed one (`transfer_guard.rs`)
    /// queues under the guard's control and restores only its own agent file, without its mode.
    /// A `staged` prefix (`transfer_precopy.rs`) is the log's head; the bundle holds what follows.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn import_into(
        self: &Arc<Self>,
        bundle: &Path,
        name: Option<String>,
        live: Live,
        guarded: Option<super::transfer_guard::GuardedImport<'_>>,
        replace_durable: bool,
        defer_finalize: bool,
        staged: Option<&transfer_out::transfer_precopy::StagedPrefix>,
    ) -> Result<Arc<Session>, RpcError> {
        self.import_into_held(
            bundle,
            name,
            live,
            guarded,
            replace_durable,
            defer_finalize,
            staged,
            false,
        )
        .await
    }

    /// `import_into`; a `hold`ing one (Auto's, `auto_import.rs`) is published frozen by Auto and
    /// stays so with no gap: it does not end the freeze when it is done. Whoever asked frees it
    /// when the holder loop accepts the import (`auto_hold.rs` `auto_activate`).
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn import_into_held(
        self: &Arc<Self>,
        bundle: &Path,
        name: Option<String>,
        live: Live,
        guarded: Option<super::transfer_guard::GuardedImport<'_>>,
        replace_durable: bool,
        defer_finalize: bool,
        staged: Option<&transfer_out::transfer_precopy::StagedPrefix>,
        hold: bool,
    ) -> Result<Arc<Session>, RpcError> {
        let (the_chat, plain) = (false, (live, guarded, replace_durable, defer_finalize, staged));
        self.import_placing(bundle, name, plain, the_chat, hold).await
    }

    /// [`Self::import_into`] with its `(live, guarded, replace_durable, defer_finalize, staged)`.
    /// `the_chat`: the bundle is the chat itself (Auto mode's Cloud copy, `auto_import.rs`), so
    /// an agent file here that holds other bytes is replaced (`native::restore_replacing`).
    pub(super) async fn import_placing(
        self: &Arc<Self>,
        bundle: &Path,
        name: Option<String>,
        plain: ImportOptions<'_>,
        the_chat: bool,
        hold: bool,
    ) -> Result<Arc<Session>, RpcError> {
        let (live, guarded, replace_durable, defer_finalize, staged) = plain;
        let mut steps = transfer_out::transfer_live::MoveSteps::new("import");
        let meta_text = std::fs::read_to_string(bundle.join("session.json"))
            .map_err(|e| RpcError::invalid_params(format!("read session.json: {e}")))?;
        let mut meta: SessionMeta = serde_json::from_str(&meta_text)
            .map_err(|e| RpcError::invalid_params(format!("parse session.json: {e}")))?;
        // A bundle does not carry the source daemon's transcript authorization. Never import
        // historical native ids or parent links that could collide with local sessions.
        meta.previous_agent_session_ids.clear();
        meta.agent_session_family = None;
        meta.parent_id = None;
        meta.fork_seq = None;
        meta.fork_before = None;
        // Nor a fork's reference to a chat of the machine it came from: its log holds that
        // history (`export`).
        meta.history_from = None;
        meta.fork_requests.clear();
        meta.fork_parent_verified = Some(false);
        // A store comes from this machine's chat index, never from a bundle.
        meta.chat_store = None;
        // Nor the VM boundary: only a caller's peer link asks for it (`vm_boundary.rs`).
        meta.vm_boundary = false;
        // Nor a wait on its harness at every start (`SessionMeta::wait_start`): only a local
        // creator that is no agent's, lane's or remote connection gets that (`server/requests.rs`
        // `asks_to_wait_on_its_harness`); a bundle's own flag would hand it to any importer.
        meta.wait_start = false;
        // Nor is a mode cmux set here, which only this daemon records (`SessionMeta::mode_set_by_cmux`).
        meta.mode_set_by_cmux = None;
        // Nor what an agent of another daemon said at `initialize`, or the launch it started from:
        // an `asksBeforeTools` claim is believed only from an agent this daemon started
        // (`policy_mode.rs` `claim_distrust`). Its next start here records both again.
        meta.agent_capabilities = None;
        meta.launch_digest = None;
        super::bookmarks::capped(&mut meta.bookmarks);
        // The id becomes a directory name under the sessions root.
        if !is_plain_id(&meta.id) {
            return Err(RpcError::invalid_params(format!(
                "bundle session id {:?} is not a plain id",
                meta.id
            )));
        }
        // A chat that comes back (`replace_durable`: `transfer_in.rs` replaces its moved-away
        // copy here) is that copy: its name is the chat's own, not another's to step around.
        // Another chat with the name still holds it.
        let holds = |s: &Arc<Session>, n: &str| {
            s.read_meta(|m| m.name == n)
                && !(replace_durable && s.id == meta.id && self.moved_away(s))
        };
        if let Some(n) = &name {
            crate::session_name::validate(n).map_err(RpcError::invalid_params)?;
            if self.sessions.lock().unwrap().values().any(|s| holds(s, n)) {
                return Err(RpcError::invalid_params(format!("session name {n:?} is taken")));
            }
        }
        // Claim the id so a concurrent import of the same bundle fails, never writing twice.
        let _reservation = {
            let sessions = self.sessions.lock().unwrap();
            let mut importing = self.importing.lock().unwrap();
            let existing_moved =
                sessions.get(&meta.id).is_some_and(|session| self.moved_away(session));
            if (sessions.contains_key(&meta.id) && !(replace_durable && existing_moved))
                || !importing.insert(meta.id.clone())
            {
                return Err(RpcError::invalid_params(format!(
                    "session {} already exists here",
                    meta.id
                )));
            }
            ImportReservation { hub: self, id: meta.id.clone() }
        };
        // A name the import or move gives is someone's (`acpmux ls` lists it); without one the
        // chat keeps its bundle's name and whether that name was given.
        if let Some(n) = name {
            meta.name = n;
            meta.name_given = true;
        } else if self.sessions.lock().unwrap().values().any(|s| holds(s, &meta.name)) {
            meta.name = self.unique_name(&meta.name);
        }
        if !self.config.read().await.harnesses.contains_key(&meta.harness) {
            return Err(RpcError::invalid_params(format!(
                "agent {:?} is not configured on this host",
                meta.harness
            )));
        }
        if !meta.cwd.is_dir() {
            // `reason` and `cwd` let a client say it in its own words (`cli/errors.rs` `detail`).
            let e = RpcError::invalid_params(format!(
                "cwd {} does not exist here; pass a new cwd via fork or edit session.json",
                meta.cwd.display()
            ));
            return Err(e.with_data(json!({"reason": "cwd_missing", "cwd": meta.cwd})));
        }
        meta.status = SessionStatus::Idle;
        // It lives here now, whatever the daemon it came from had recorded.
        meta.moved_to = None;
        // The linked-worktree record (`worktree_care/revive.rs`) is read again from the folder
        // here. A chat moved from another machine's linked worktree into a fresh clone brought
        // that machine's root and git dir: they never match here, and `revive_folder` refused
        // every turn as `session.folder_missing` while its folder was there. A chat imported
        // into the same linked worktree reads the same record back, so its folder can still be
        // recreated if it goes. A read that is inconclusive keeps the bundle's record only for
        // the folder it names.
        let read = tokio::task::spawn_blocking({
            let cwd = meta.cwd.clone();
            move || {
                super::worktree_care::revive::origin_of(
                    &cwd,
                    &crate::git_state::GitState::read(&cwd),
                )
            }
        });
        // timeout: a slow git read is inconclusive; the bundle's record is kept.
        meta.worktree = match tokio::time::timeout(std::time::Duration::from_secs(2), read).await {
            Ok(Ok(Some(found))) => found,
            _ => meta.worktree.take().filter(|w| w.cwd == meta.cwd),
        };
        // An approve-all an older daemon or a vmHost machine gave asks here (`policy_source.rs`).
        super::policy_source::settle_imported_grant(&mut meta);
        meta.subsession = None;
        meta.lineage = None;
        meta.created_by = None;
        // Nor a race's authority or its resumption: its children stayed behind (`races.rs`).
        super::races::settle_imported(&mut meta.races);
        if let Live::Moved(credential) = &live {
            if let Some(binding) = credential.as_ref().and_then(|c| c.connection()) {
                if meta.credential_connection.as_deref().is_some_and(|old| old != binding) {
                    return Err(super::credentials::credential_needed());
                }
                meta.credential_connection = Some(binding.to_owned());
                meta.credential_model = None;
                meta.credential_withdrawn = false;
                meta.claude_token_recovery = None;
                meta.claude_login_restart_pending = None;
            } else if meta.credential_connection.is_some() || meta.credential_withdrawn {
                if credential.is_some() {
                    return Err(super::credentials::credential_needed());
                }
                self.prepare_claude_move_without_credential(&mut meta).await?;
            }
        }
        steps.step("meta");
        self.prepare_harness_state(&meta, replace_durable)
            .map_err(|e| RpcError::internal(e.to_string()))?;
        steps.step("harness_prepare");
        if let Err(e) = self.store.save(&meta) {
            let _ = self.abort_harness_state(&meta);
            return Err(RpcError::internal(e.to_string()));
        }
        // Copy events verbatim, preserving seq. A partial transcript is not
        // a valid import: any unreadable file or record rolls it back.
        let control = guarded.map(|g| g.guard.control);
        // A whole bundle's records are the chat's whole history: copied off the runtime's
        // workers, so the daemon's other chats answer meanwhile (`qos::off_worker`, cmux#54461).
        let copied =
            crate::qos::off_worker(|| self.copy_bundle_events(bundle, &meta.id, control, staged));
        let last = match copied {
            Ok(last) => last,
            Err(e) => {
                self.drop_failed_import(&meta);
                return Err(RpcError::invalid_params(format!("import events: {e}")));
            }
        };
        steps.step("events");
        if let Err(e) = self.restore_harness_state(bundle, &meta, replace_durable) {
            self.drop_failed_import(&meta);
            return Err(RpcError::invalid_params(format!("import durable journal: {e}")));
        }
        // The draft's attachments, with the draft's text in `session.json`.
        self.import_draft_attachments(bundle, &meta.id);
        let restored = match guarded {
            // A history-later move's receive bundle is read by nothing after its finish: its
            // transcript becomes the home folder's file by a link, not a copy under the freeze.
            // A move's receive bundle (`live`) is read by nothing after its finish either, which
            // removes it: its transcripts are linked too, not copied under the freeze (a Claude
            // chat's is 1.6 GB of a 7 GB chat; cmux#54461).
            None if staged.is_some_and(|s| s.history_later) => {
                crate::qos::off_worker(|| crate::native::restore_linked(bundle, &meta))
                    .unwrap_or_default()
            }
            // Auto mode's Cloud copy is the chat itself: its files replace the ones here.
            None if the_chat => {
                crate::qos::off_worker(|| crate::native::restore_replacing(bundle, &meta))
                    .unwrap_or_default()
            }
            None if matches!(live, Live::Moved(_)) => {
                crate::qos::off_worker(|| crate::native::restore_linked(bundle, &meta))
                    .unwrap_or_default()
            }
            None => {
                crate::qos::off_worker(|| crate::native::restore(bundle, &meta)).unwrap_or_default()
            }
            // A guarded chat keeps its agent session only with its file: a failed restore fails
            // the import, like its events.
            Some(g) => {
                let restored = crate::native::guarded_plan(bundle, &meta)
                    .map_err(anyhow::Error::msg)
                    .and_then(|plan| crate::native::restore_guarded(&plan, g.replace_native));
                match restored {
                    Ok(n) => n,
                    Err(e) => {
                        self.drop_failed_import(&meta);
                        return Err(RpcError::new(-32000, format!("transfer.native: {e:#}")));
                    }
                }
            }
        };
        steps.step("native");
        // Its images: a chat that shows none is no move (`prompt_images.rs`). One that cannot be
        // kept leaves the chat showing that image as missing, as a pruned one does.
        if let Err(e) = super::prompt_images::restore_images(bundle) {
            tracing::warn!(session = %meta.id, "moved images not kept: {e:#}");
        }
        // OpenCode's session is imported into its own database, in the chat's folder here. One
        // that fails leaves the chat to resume from its log, as a chat with no agent store does.
        if let Err(e) = crate::native::import_opencode(bundle, &meta) {
            tracing::warn!(session = %meta.id, "opencode session not imported: {e:#}");
        }
        steps.step("images");
        // Made once nothing can fail: a failed import leaves nothing in the child index.
        let session = self.make_session(meta.clone());
        steps.step("make_session");
        // Its copied log may hold the source's move: unknown until its own `imported` receipt
        // is logged (`transfer_authority.rs`), so a failed receipt never reads as local.
        *session.transfer_authority.lock().unwrap_or_else(|e| e.into_inner()) = None;
        session.seq.store(last, Ordering::SeqCst);
        {
            let mut meta = session.meta.lock().unwrap();
            meta.last_seq = last;
            // The copied log may end in transcript records: say it may have.
            meta.transcript_seq = last;
        }
        if let Live::Moved(credential) = live {
            // The login the move brought is the chat's before its queue runs (`end_move` below):
            // the turn it continues starts signed in. Held in memory only, as `session/new`'s.
            if let Some(credential) = credential {
                *session.credential.lock().unwrap_or_else(|e| e.into_inner()) = Some(credential);
            }
            self.restore_queue(&session);
            // A bundle from a daemon that wrote none moves the chat without them.
            if let Some(v) = std::fs::read(bundle.join(super::composers::BUNDLE_FILE))
                .ok()
                .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            {
                session.composers.lock().unwrap_or_else(|e| e.into_inner()).restore(&v);
            }
            // The source's subagent retries stayed there: their prompts do not wait here.
            self.drop_unsent_subagent_retries(&session);
            steps.step("queue");
        }
        // Published frozen: it is not this daemon's chat until its own receipt is logged (a
        // failed one removes it), so no prompt starts before that. Its log's `transfer_out` is
        // the source's move, not one of this daemon's.
        *session.moving.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(if hold { super::AUTO_AWAY } else { transfer_out::IMPORTING }.to_owned());
        // The source's subagent retries stayed there (`subagent_retry.rs`).
        self.settle_subagent_retries(&session);
        steps.step("subagent_retries");
        self.sessions.lock().unwrap().insert(meta.id.clone(), session.clone());
        self.update_live_session_index(&session);
        steps.step("publish");
        // A session that came may be another row's parent: every closed row is built again.
        self.session_came(&session);
        steps.step("session_came");
        // Indexed again once published: a lookup before that found no session and dropped it.
        self.child_tags.note(&session);
        self.offers.forget(&meta.id);
        let (_, logged) = self.append_at(
            &session,
            "mux",
            "imported",
            json!({"from": bundle, "nativeRestored": restored}),
            None,
            None,
        );
        // Without its own receipt the copied records would decide its transfer state after a
        // restart (`transfer_authority.rs`): the import fails and leaves no chat.
        if !logged {
            self.recover_staged_replacements();
            let _ = self.kill(&session, true).await;
            return Err(RpcError::internal("import: could not durably record imported"));
        }
        steps.step("imported_receipt");
        // Its queued prompts run now (`end_move` follows its policy, then wakes the queue).
        if !hold {
            self.end_move(&session);
        }
        steps.step("end_move");
        self.save_meta(&session);
        steps.step("save_meta");
        if !defer_finalize && let Err(error) = self.finalize_harness_state(&session.meta()) {
            self.recover_staged_replacements();
            let _ = self.kill(&session, true).await;
            return Err(RpcError::internal(error.to_string()));
        }
        Ok(session)
    }

    /// A Claude binding held by the source cannot launch here. Restore the destination's
    /// usual Claude launch only when its own configured route or login is ready.
    async fn prepare_claude_move_without_credential(
        &self,
        meta: &mut SessionMeta,
    ) -> Result<(), RpcError> {
        let unavailable = super::credentials::credential_needed;
        let (profile, defaults) = {
            let config = self.config.read().await;
            let profile = super::resolve::session_profile_checked(
                &config,
                &meta.harness,
                &meta.cwd,
                meta.remote_origin,
            )
            .map_err(|_| unavailable())?;
            (profile, config.defaults_for(&meta.harness))
        };
        if crate::config::derive_family(&meta.harness, &profile) != "claude" {
            return Err(unavailable());
        }
        meta.credential_connection = None;
        meta.credential_model = None;
        meta.credential_withdrawn = false;
        meta.claude_token_recovery = None;
        meta.claude_login_restart_pending = None;
        let launch = self
            .spawn_profile_with(meta, &profile, &defaults.env, None)
            .await
            .map_err(|_| unavailable())?;
        let env = crate::agent::resolved_profile_env(&launch).map_err(|_| unavailable())?;
        if ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]
            .iter()
            .any(|key| env.get(*key).is_some_and(|value| !value.trim().is_empty()))
        {
            return Ok(());
        }
        if !crate::claude_cloud_auth::launches_claude_itself(&launch.argv) {
            return Err(unavailable());
        }
        let cli = crate::agent_login::Cli { program: launch.argv[0].clone(), globals: vec![], env };
        let machine = crate::agent_login::Machine {
            root: self.vm_marker_root(),
            home: dirs::home_dir().unwrap_or_default(),
        };
        let status =
            crate::agent_login::claude_status(&machine, &cli).await.map_err(|_| unavailable())?;
        if status["signedIn"] == true || status["apiKey"] == true {
            Ok(())
        } else {
            Err(unavailable())
        }
    }

    fn harness_pi_session_optional(
        root: &Path,
        agent_id: &str,
    ) -> Result<Option<(PathBuf, Vec<u8>)>> {
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let mut found = None;
        for entry in std::fs::read_dir(root)? {
            let entry = entry?;
            let path = entry.path();
            let file_type = std::fs::symlink_metadata(&path)?.file_type();
            if !file_type.is_file() || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let bytes = std::fs::read(&path)?;
            let first = bytes.splitn(2, |b| *b == b'\n').next().unwrap_or_default();
            let Ok(header) = serde_json::from_slice::<Value>(first) else { continue };
            let id = header.get("id").and_then(Value::as_str);
            let valid = header.get("type").and_then(Value::as_str) == Some("session")
                && header.get("cwd").and_then(Value::as_str).is_some();
            if valid && id == Some(agent_id) {
                if found.is_some() {
                    return Err(anyhow::anyhow!("multiple Pi sessions match ACP session id"));
                }
                found = Some((path, bytes));
            }
        }
        Ok(found)
    }

    fn harness_pi_session(root: &Path, agent_id: &str) -> Result<(PathBuf, Vec<u8>)> {
        Self::harness_pi_session_optional(root, agent_id)?
            .ok_or_else(|| anyhow::anyhow!("Pi session file for ACP session id is missing"))
    }

    fn rebind_harness_pi_session(bytes: &[u8], agent_id: &str, cwd: &Path) -> Result<Vec<u8>> {
        let Some(split) = bytes.iter().position(|b| *b == b'\n') else {
            return Err(anyhow::anyhow!("Pi session file has no header"));
        };
        let mut header: Value = serde_json::from_slice(bytes.get(..split).unwrap_or_default())?;
        let id = header.get("id").and_then(Value::as_str);
        if header.get("type").and_then(Value::as_str) != Some("session")
            || header.get("cwd").and_then(Value::as_str).is_none()
            || id != Some(agent_id)
        {
            return Err(anyhow::anyhow!(
                "Pi session header is not a valid session for this ACP id"
            ));
        }
        header.set("cwd", Value::String(cwd.to_string_lossy().into_owned()));
        let mut out = serde_json::to_vec(&header)?;
        out.push(b'\n');
        out.extend_from_slice(bytes.get(split + 1..).unwrap_or_default());
        Ok(out)
    }

    pub(super) fn prepare_harness_state(
        &self,
        meta: &SessionMeta,
        replace_durable: bool,
    ) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return Ok(()) };
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return Ok(()) };
        let Some(root) = session_dir.parent() else { return Ok(()) };
        let marker = root.join(format!(".{agent_id}.durable-transfer-state"));
        let _state_lock = harness_state_lock();
        if std::fs::symlink_metadata(&marker).is_ok() {
            return Err(anyhow::anyhow!("durable transfer recovery marker is already present"));
        }
        let prepared = write_json_atomic(
            &marker,
            &json!({
                "outerId": meta.id,
                "agentId": agent_id,
                "replaceDurable": replace_durable,
                "phase": "prepared",
            }),
        );
        if prepared.is_err() && marker_names(&marker, &meta.id) {
            // Renamed into place before a later step failed: no marker was here before, so it is
            // this import's, and the failed preparation must not leave it.
            let _ = crate::home_fs::remove_file(&marker);
        }
        prepared
    }

    /// Undo a failed import's prepared durable state as a restart would (`recover_durable_marker`),
    /// so a retry on this daemon finds no marker of it. Before its store goes: that names the
    /// owner. A staged one (files installed, backups taken) is left whole for the next start's
    /// sweep, which rolls it back before any chat loads. Returns whether the failed import's store
    /// must stay for that sweep to prove the marker's owner: not for a replacement, whose owner is
    /// the store the receive moved aside and puts back (`transfer_in.rs`).
    #[must_use]
    fn abort_harness_state(&self, meta: &SessionMeta) -> bool {
        if meta.harness != "cmux-harness" {
            return false;
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return false };
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return false };
        let Some(root) = session_dir.parent() else { return false };
        let marker = root.join(format!(".{agent_id}.durable-transfer-state"));
        let _state_lock = harness_state_lock();
        let Some(value) =
            std::fs::read(&marker).ok().and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
        else {
            return false;
        };
        if value.get("outerId").and_then(Value::as_str) != Some(meta.id.as_str()) {
            return false;
        }
        if value.get("phase").and_then(Value::as_str) == Some("prepared") {
            self.recover_durable_marker(root, &marker, agent_id);
            return false;
        }
        value.get("replaceDurable").and_then(Value::as_bool) != Some(true)
    }

    /// A failed import's store goes once its durable state is rolled back (`abort_harness_state`).
    fn drop_failed_import(&self, meta: &SessionMeta) {
        if self.abort_harness_state(meta) {
            // The store stays; its log writer goes, as `delete` drops it: a sweep may remove the
            // store before a retry writes it again.
            self.store.close_log(&meta.id);
            tracing::warn!(session = %meta.id, "a failed import's staged durable state waits for the next start to roll it back");
        } else {
            self.remove_cached_closed_summary(&meta.id);
            // The book tee (`book_tee.rs`) needs no `forget` here, as a purge does: it holds no
            // actor for this chat. Its hook runs in `write_record_locked`, which an import's
            // lines never pass (`copy_bundle_events` appends to the store), and its drain and
            // pass act only on chats in `sessions`, which an import joins after its last
            // rollback.
            let _ = self.store.delete(&meta.id);
        }
    }

    pub(super) fn export_harness_state(&self, meta: &SessionMeta, dir: &Path) -> Result<Value> {
        if meta.harness != "cmux-harness" {
            return Ok(Value::Null);
        }
        let agent_id = meta.agent_session_id.as_deref().ok_or_else(|| {
            anyhow::anyhow!("cmux-harness durable state requires an ACP session id")
        })?;
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let Some(session_dir) = self.store.session_dir(&meta.id) else {
            return Err(anyhow::anyhow!(
                "cmux-harness durable state requires a local session store"
            ));
        };
        let root =
            session_dir.parent().ok_or_else(|| anyhow::anyhow!("invalid session store root"))?;
        let legacy_root = dirs::home_dir()
            .map(|home| home.join(".cmux-harness").join("sessions"))
            .filter(|legacy| legacy != root);
        let current_state_present = std::fs::symlink_metadata(root.join(agent_id)).is_ok()
            || std::fs::read_dir(root).into_iter().flatten().flatten().any(|entry| {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                    return false;
                }
                let Ok(bytes) = std::fs::read(path) else { return false };
                let first = bytes.splitn(2, |b| *b == b'\n').next().unwrap_or_default();
                serde_json::from_slice::<Value>(first).ok().and_then(|header| {
                    header
                        .get("id")
                        .or_else(|| header.get("sessionId"))
                        .and_then(Value::as_str)
                        .map(|id| id == agent_id)
                }) == Some(true)
            });
        let (journal_root, pi_session_path, session_bytes) =
            match Self::harness_pi_session_optional(root, agent_id)? {
                Some((path, bytes)) => (root.to_path_buf(), path, bytes),
                None if !current_state_present => {
                    let legacy = legacy_root.ok_or_else(|| {
                        anyhow::anyhow!("Pi session file for ACP session id is missing")
                    })?;
                    let durable = legacy
                        .parent()
                        .map(|parent| parent.join("durable"))
                        .ok_or_else(|| anyhow::anyhow!("invalid legacy harness root"))?;
                    let (path, bytes) = Self::harness_pi_session(&legacy, agent_id)?;
                    (durable, path, bytes)
                }
                None => {
                    return Err(anyhow::anyhow!(
                        "current cmux-harness state is present but its Pi session is invalid"
                    ));
                }
            };
        let journal = journal_root.join(agent_id).join("journal.ndjson");
        let pi_filename = pi_session_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow::anyhow!("Pi session filename is not valid UTF-8"))?;
        if pi_filename.is_empty()
            || pi_filename.len() > 256
            || !pi_filename.ends_with(".jsonl")
            || Path::new(pi_filename).components().count() != 1
        {
            return Err(anyhow::anyhow!("Pi session filename is unsafe"));
        }
        let read_private = |path: &Path, label: &str| -> Result<Vec<u8>> {
            let meta = std::fs::symlink_metadata(path)?;
            if !meta.file_type().is_file() {
                return Err(anyhow::anyhow!("{label} is not a regular file"));
            }
            std::fs::read(path).map_err(|e| anyhow::anyhow!("read {label}: {e}"))
        };
        let journal_bytes = read_private(&journal, "durable journal")?;
        let target = dir.join("harness");
        crate::home_fs::create_dirs(&target)?;
        crate::home_fs::write(target.join("journal.ndjson"), &journal_bytes)?;
        crate::home_fs::write(target.join("session.jsonl"), &session_bytes)?;
        Ok(json!({
            "sessionId": agent_id,
            "journal": {"path": "harness/journal.ndjson", "size": journal_bytes.len(), "sha256": crate::sha256::sha256_hex(&journal_bytes)},
            "session": {"path": "harness/session.jsonl", "filename": pi_filename, "size": session_bytes.len(), "sha256": crate::sha256::sha256_hex(&session_bytes)},
        }))
    }

    fn restore_harness_state(
        &self,
        bundle: &Path,
        meta: &SessionMeta,
        replace_durable: bool,
    ) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let agent_id = meta.agent_session_id.as_deref().ok_or_else(|| {
            anyhow::anyhow!("cmux-harness durable transfer requires an ACP session id")
        })?;
        if !plain_agent_session(agent_id) {
            return Err(anyhow::anyhow!("invalid cmux-harness ACP session id"));
        }
        let manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(bundle.join("manifest.json"))?)?;
        let spec = manifest
            .get("harness")
            .filter(|v| !v.is_null())
            .ok_or_else(|| anyhow::anyhow!("missing cmux-harness durable manifest"))?;
        if spec.get("sessionId").and_then(Value::as_str) != Some(agent_id) {
            return Err(anyhow::anyhow!("cmux-harness ACP session id mismatch"));
        }
        let checked = |key: &str, path: &str| -> Result<Vec<u8>> {
            let item = spec
                .get(key)
                .ok_or_else(|| anyhow::anyhow!("missing cmux-harness {key} manifest"))?;
            if item.get("path").and_then(Value::as_str) != Some(path) {
                return Err(anyhow::anyhow!("invalid cmux-harness durable path"));
            }
            let bytes = std::fs::read(bundle.join(path))?;
            if item.get("size").and_then(Value::as_u64) != Some(bytes.len() as u64)
                || item.get("sha256").and_then(Value::as_str)
                    != Some(crate::sha256::sha256_hex(&bytes).as_str())
            {
                return Err(anyhow::anyhow!("cmux-harness durable digest mismatch"));
            }
            Ok(bytes)
        };
        let journal_bytes = checked("journal", "harness/journal.ndjson")?;
        let session_bytes = checked("session", "harness/session.jsonl")?;
        let pi_filename_owned;
        let mut pi_filename = spec
            .get("session")
            .and_then(|v| v.get("filename"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if pi_filename.is_empty() {
            pi_filename_owned = format!("{agent_id}.jsonl");
            pi_filename = &pi_filename_owned;
        }
        if pi_filename.is_empty()
            || pi_filename.len() > 256
            || !pi_filename.ends_with(".jsonl")
            || Path::new(pi_filename).components().count() != 1
        {
            return Err(anyhow::anyhow!("Pi session filename is unsafe"));
        }
        let session_bytes = Self::rebind_harness_pi_session(&session_bytes, agent_id, &meta.cwd)?;
        let _state_lock = HARNESS_STATE_LOCK
            .lock()
            .map_err(|_| anyhow::anyhow!("durable transfer lock poisoned"))?;
        let session_dir = self
            .store
            .session_dir(&meta.id)
            .ok_or_else(|| anyhow::anyhow!("target has no local session store"))?;
        let root = session_dir
            .parent()
            .ok_or_else(|| anyhow::anyhow!("invalid target session store root"))?;
        let journal_dir = root.join(agent_id);
        let journal_dir_was_present = std::fs::symlink_metadata(&journal_dir).is_ok();
        if let Ok(meta) = std::fs::symlink_metadata(&journal_dir)
            && (meta.file_type().is_symlink() || !meta.file_type().is_dir())
        {
            return Err(anyhow::anyhow!("target durable session is not a real directory"));
        }
        if std::fs::symlink_metadata(&journal_dir).is_ok() && !replace_durable {
            return Err(anyhow::anyhow!("target durable session is already occupied"));
        }
        if let Ok(owner) = std::fs::symlink_metadata(journal_dir.join("owner.sqlite"))
            && owner.file_type().is_symlink()
        {
            return Err(anyhow::anyhow!("target durable owner lock is symlinked"));
        }
        if !replace_durable && Self::harness_pi_session_optional(root, agent_id)?.is_some() {
            return Err(anyhow::anyhow!("target already has a Pi session for this ACP id"));
        }
        let existing_pi =
            if replace_durable { Self::harness_pi_session_optional(root, agent_id)? } else { None };
        let pi_target = existing_pi
            .as_ref()
            .map(|(path, _)| path.clone())
            .unwrap_or_else(|| root.join(pi_filename));
        if let Ok(meta) = std::fs::symlink_metadata(&pi_target) {
            if meta.file_type().is_symlink() || !meta.file_type().is_file() {
                return Err(anyhow::anyhow!("target Pi session is not a real file"));
            }
            if existing_pi.is_none() {
                return Err(anyhow::anyhow!("target Pi session filename is already occupied"));
            }
        }
        let journal = journal_dir.join("journal.ndjson");
        let journal_tmp = journal_dir.join("journal.ndjson.importing");
        let journal_backup = journal_dir.join("journal.ndjson.transfer-backup");
        let target_filename = pi_target
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow::anyhow!("Pi session target filename is invalid"))?;
        let session_tmp = root.join(format!("{target_filename}.importing"));
        let session_backup = root.join(format!("{target_filename}.transfer-backup"));
        for path in [&journal_tmp, &session_tmp, &journal_backup, &session_backup] {
            if std::fs::symlink_metadata(path).is_ok() {
                return Err(anyhow::anyhow!("durable transfer temporary path is occupied"));
            }
        }
        let durable_state = root.join(format!(".{agent_id}.durable-transfer-state"));
        if let Ok(raw) = std::fs::read(&durable_state) {
            let prepared: Value = serde_json::from_slice(&raw)?;
            if prepared.get("outerId").and_then(Value::as_str) != Some(meta.id.as_str()) {
                return Err(anyhow::anyhow!(
                    "durable transfer recovery marker belongs to another session"
                ));
            }
        }
        write_json_atomic(
            &durable_state,
            &json!({
                "agentId": agent_id,
                "outerId": meta.id,
                "replaceDurable": replace_durable,
                "phase": "staged",
                "transferId": manifest["transferId"],
                "piFilename": target_filename,
                "journalDirWasPresent": journal_dir_was_present,
                "hadJournal": std::fs::symlink_metadata(&journal).is_ok(),
                "hadPi": std::fs::symlink_metadata(&pi_target).is_ok(),
            }),
        )?;
        crate::home_fs::create_dirs(&journal_dir)?;
        let mut installed_journal = false;
        let mut installed_pi = false;
        let mut backed_journal = false;
        let mut backed_pi = false;
        let install = (|| -> Result<()> {
            use std::io::Write;
            let mut file = crate::home_fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&journal_tmp)?;
            file.write_all(&journal_bytes)?;
            file.sync_all()?;
            let mut file = crate::home_fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&session_tmp)?;
            file.write_all(&session_bytes)?;
            file.sync_all()?;
            if replace_durable {
                if std::fs::symlink_metadata(&journal).is_ok() {
                    crate::home_fs::rename(&journal, &journal_backup)?;
                    backed_journal = true;
                }
                if std::fs::symlink_metadata(&pi_target).is_ok() {
                    if let Err(e) = crate::home_fs::rename(&pi_target, &session_backup) {
                        let _ = crate::home_fs::rename(&journal_backup, &journal);
                        backed_journal = false;
                        return Err(e.into());
                    }
                    backed_pi = true;
                }
            }
            crate::home_fs::rename(&journal_tmp, &journal)?;
            installed_journal = true;
            crate::home_fs::rename(&session_tmp, &pi_target)?;
            installed_pi = true;
            std::fs::File::open(&journal_dir)?.sync_all()?;
            std::fs::File::open(root)?.sync_all()?;
            Ok(())
        })();
        if let Err(e) = install {
            let _ = crate::home_fs::remove_file(&journal_tmp);
            let _ = crate::home_fs::remove_file(&session_tmp);
            if installed_journal {
                let _ = crate::home_fs::remove_file(&journal);
            }
            if installed_pi {
                let _ = crate::home_fs::remove_file(&pi_target);
            }
            let mut restored = true;
            if backed_journal {
                restored &= crate::home_fs::rename(&journal_backup, &journal).is_ok();
            }
            if backed_pi {
                restored &= crate::home_fs::rename(&session_backup, &pi_target).is_ok();
            }
            if !journal_dir_was_present {
                let _ = crate::home_fs::remove_dir(&journal_dir);
            }
            // A backup that could not go back keeps the marker, staged: the next start's sweep
            // puts it back (`recover_durable_marker`) instead of it being lost.
            if restored {
                let _ = crate::home_fs::remove_file(&durable_state);
            }
            return Err(e);
        }
        Ok(())
    }

    pub(super) fn mark_harness_state_committed(&self, meta: &SessionMeta) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return Ok(()) };
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return Ok(()) };
        let Some(root) = session_dir.parent() else { return Ok(()) };
        let state = root.join(format!(".{agent_id}.durable-transfer-state"));
        let mut marker = serde_json::from_slice::<Value>(&std::fs::read(&state)?)?;
        marker.set("phase", json!("committed"));
        write_json_atomic(&state, &marker)
    }

    pub(super) fn finalize_harness_state(&self, meta: &SessionMeta) -> Result<()> {
        if meta.harness != "cmux-harness" {
            return Ok(());
        }
        let Some(agent_id) = meta.agent_session_id.as_deref() else { return Ok(()) };
        let Some(session_dir) = self.store.session_dir(&meta.id) else { return Ok(()) };
        let Some(root) = session_dir.parent() else { return Ok(()) };
        let state = root.join(format!(".{agent_id}.durable-transfer-state"));
        let mut marker = serde_json::from_slice::<Value>(&std::fs::read(&state)?)?;
        marker.set("phase", json!("committed"));
        write_json_atomic(&state, &marker)?;
        let filename = marker.get("piFilename").and_then(Value::as_str).unwrap_or("");
        if !filename.is_empty() {
            crate::home_fs::remove_file(root.join(format!("{filename}.transfer-backup"))).or_else(
                |e| {
                    if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }
                },
            )?;
        }
        crate::home_fs::remove_file(root.join(agent_id).join("journal.ndjson.transfer-backup"))
            .or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })?;
        crate::home_fs::remove_file(&state)
            .or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })?;
        std::fs::File::open(root)?.sync_all()?;
        Ok(())
    }
}

/// Whether an import is a chat moved here (`transfer_in.rs`), which keeps its queue, composers
/// and the owner's login its move brought (`agent_credentials.rs`), or a plain import.
pub(super) enum Live {
    No,
    Moved(Option<crate::agent_credentials::AgentCredential>),
}

#[cfg(test)]
#[path = "fork_reference_export_tests.rs"]
mod fork_reference_export_tests;
#[cfg(test)]
#[path = "import_publish_tests.rs"]
mod import_publish_tests;

#[cfg(test)]
#[path = "transfer_tests.rs"]
mod tests;
