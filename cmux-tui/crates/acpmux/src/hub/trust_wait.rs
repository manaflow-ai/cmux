//! Part of `Hub`; see `hub/mod.rs`. A sub-session in a folder nobody answered the trust
//! question for waits for the person instead of failing.
//!
//! `start_session` (`subsessions.rs`) asks [`Hub::ensure_folder_trusted`] before it starts
//! anything. A folder that reads as trusted (an answer, an agent's own level, or one of the
//! person's own folders, `trust_auto.rs`) passes at once, and so does a folder at or under the
//! starting session's own folder when that session runs in full access and a decision trusts its
//! folder ([`Hub::inherits_parent_trust`]). Any other folder raises a card on the
//! session that wants the sub-session: a choice question, **Trust** or **Not now**, through the
//! permission path every agent question uses, so the chat shows its card and the sidebar row its
//! "Needs your input" mark, and only the person answers it (never a policy, never a remote
//! browser). In a Web turn (`remote_floor.rs`) an auto-trust rule is no answer: the folder needs
//! a person's decision, as a Web client's own start does (`trust::web_session_level`). The start
//! waits on the card and goes on by itself when the folder becomes trusted, whether the card was
//! answered or the folder was trusted elsewhere (the pane's own question, `acp.trust.set`). Not
//! now refuses the start with `subsessions.trust_declined` and is remembered for
//! [`DECLINE_MEMORY`], so an agent that asks again is not met with the same card.
//!
//! While the card is up the session carries the tag [`TAG_PREFIX`]`<name>` (the folder), so the
//! sidebar can say *which* wait it is. The tag and the card go with the wait, whatever ends it;
//! a card withdrawn that way is logged as a cancelled decision and the session's status is
//! settled, as for any answered prompt, so the chat drops the card and stops asking for input.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};

use super::*;
use crate::trust::Level;

/// How long a start waits for an answer before it gives up.
pub(super) const WAIT: Duration = Duration::from_secs(30 * 60);
/// How long a Not now is remembered for the folder.
pub(super) const DECLINE_MEMORY: Duration = Duration::from_secs(10 * 60);
/// The session tag a waiting start sets: `trust.pending:<short name>` = the folder.
pub const TAG_PREFIX: &str = "trust.pending:";

/// What the hub remembers about trust waits.
#[derive(Default)]
pub(crate) struct Waits {
    /// Not now, by folder: refused again without a card until it expires.
    declined: StdMutex<HashMap<String, Instant>>,
    /// Fired when a folder's trust may have changed (`acp.trust.set`, a Trust on a card).
    changed: Notify,
    /// Starts waiting under each (session, tag): two starts with one name share the tag, which
    /// goes when the last of them ends.
    tagged: StdMutex<HashMap<(String, String), usize>>,
}

impl Waits {
    fn declined_recently(&self, key: &str) -> bool {
        let mut declined = self.declined.lock().unwrap_or_else(|e| e.into_inner());
        declined.retain(|_, at| at.elapsed() < DECLINE_MEMORY);
        declined.contains_key(key)
    }

    fn decline(&self, key: &str) {
        self.declined
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(key.to_owned(), Instant::now());
    }

    fn forget(&self, key: &str) {
        self.declined.lock().unwrap_or_else(|e| e.into_inner()).remove(key);
    }

    fn tag_held(&self, session: &str, tag: &str) {
        let mut tagged = self.tagged.lock().unwrap_or_else(|e| e.into_inner());
        *tagged.entry((session.to_owned(), tag.to_owned())).or_default() += 1;
    }

    /// Whether this was the last start holding the tag.
    fn tag_released(&self, session: &str, tag: &str) -> bool {
        let mut tagged = self.tagged.lock().unwrap_or_else(|e| e.into_inner());
        let key = (session.to_owned(), tag.to_owned());
        let left = tagged.get(&key).map_or(0, |n| n.saturating_sub(1));
        if left == 0 {
            tagged.remove(&key);
        } else {
            tagged.insert(key, left);
        }
        left == 0
    }
}

fn refused(reason: &str, message: String, cwd: &str) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason, "cwd": cwd}))
}

/// The card's request: `toolCall._meta.acpmux.trust` marks it for the daemon (only a person
/// answers; a Web client cannot), `question` (harness `acp`) is what the chat draws.
pub(super) fn card(cwd: &str, short: &str) -> Value {
    let name = if short.is_empty() { "A sub-session" } else { short };
    json!({
        "toolCall": {
            "toolCallId": format!("trust-{}", uuid::Uuid::now_v7()),
            "title": format!("Trust {cwd}?"),
            "kind": "other",
            "status": "pending",
            "_meta": {"acpmux": {
                "trust": {"cwd": cwd, "name": short},
                "question": {
                    "harness": "acp",
                    "agent": "cmux",
                    "items": [{
                        "id": "q0",
                        "header": "Folder trust",
                        "prompt": format!("{name} wants to work in {cwd}. Do you trust this folder?"),
                        "options": [
                            {
                                "id": "trust",
                                "label": "Trust folder",
                                "detail": "cmux stops asking about this folder. Your permission rules still apply.",
                            },
                            {
                                "id": "not_now",
                                "label": "Not now",
                                "detail": "The sub-session does not start, and the agent is told you declined.",
                            },
                        ],
                        "multiSelect": false,
                        "allowsOther": false,
                    }],
                },
            }},
        },
        "options": [
            {"optionId": "trust", "name": "Trust folder", "kind": "allow_once"},
            {"optionId": "not_now", "name": "Not now", "kind": "reject_once"},
        ],
    })
}

/// Takes this start's card and the tag away when the wait ends in any way, also when the start
/// itself is dropped (the agent's tool call went away). Only this start's card: another start
/// waiting on the same folder keeps its own.
struct Wait {
    hub: Arc<Hub>,
    session: Arc<Session>,
    /// The card's `toolCallId`, which names this start's card among the session's questions.
    call: String,
    tag: String,
    /// The task that raises the card and waits for its answer.
    task: Option<tokio::task::JoinHandle<Value>>,
}

impl Drop for Wait {
    fn drop(&mut self) {
        if self.hub.trust_waits.tag_released(&self.session.id, &self.tag) {
            self.hub.set_tags(&self.session, None, std::slice::from_ref(&self.tag), None);
        }
        // Aborted first, so the task never settles a card the cancel below settles too.
        let task = self.task.take();
        if let Some(task) = &task {
            task.abort();
        }
        self.hub.cancel_trust_card(&self.session, &self.call);
        let Some(task) = task else { return };
        // The task may raise the card after the cancel above: once it has ended, the card goes.
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let (hub, session, call) = (self.hub.clone(), self.session.clone(), self.call.clone());
            runtime.spawn(async move {
                let _ = task.await;
                hub.cancel_trust_card(&session, &call);
            });
        }
    }
}

impl Hub {
    /// Fires every wait on a folder's trust to look again (`acp.trust.set` calls this).
    pub fn trust_changed(&self) {
        self.trust_waits.changed.notify_waiters();
    }

    /// The family of the harness named `harness` (a profile, a family or `HEAD/MODEL`).
    async fn trust_family(&self, harness: &str) -> String {
        let cfg = self.config.read().await;
        cfg.resolve_harness(harness)
            .ok()
            .and_then(|resolved| {
                cfg.harnesses.get(&resolved).map(|p| crate::config::derive_family(&resolved, p))
            })
            .unwrap_or_else(|| harness.to_owned())
    }

    /// The folder's trust for an agent of `family`, read off the async runtime.
    async fn trust_level_of(
        &self,
        paths: &crate::trust::Paths,
        cwd: &str,
        family: &str,
    ) -> Result<crate::trust::SessionTrust, crate::trust::Failure> {
        let (paths, cwd, family) = (paths.clone(), cwd.to_owned(), family.to_owned());
        tokio::task::spawn_blocking(move || crate::trust::session_trust(&paths, &cwd, &family))
            .await
            .unwrap_or_else(|e| Err(crate::trust::Failure::Record(e.to_string())))
    }

    /// Ok once `cwd` is trusted for an agent of `harness`: at once when it already is, else after
    /// the person answered the card this raises on `parent` (see the module docs). In a Web turn
    /// of `parent` an auto-trust rule is no answer. The Ok is whether a decision trusts the folder
    /// (a person's, an agent's own, or cmux's for a folder it made), not an auto-trust rule alone:
    /// only then is a worktree made from it recorded as trusted (`trust_made_worktree`).
    pub(super) async fn ensure_folder_trusted(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        cwd: &Path,
        harness: &str,
        short: &str,
    ) -> Result<bool, RpcError> {
        let Some(paths) = self.trust_gate() else { return Ok(false) };
        let family = self.trust_family(harness).await;
        let web = Self::web_turn(parent);
        let asked = cwd.to_string_lossy().into_owned();
        let key = match self.trust_level_of(&paths, &asked, &family).await {
            Ok(read) if passes(&read, web) => return Ok(!read.by_rule_only()),
            // No decision of its own, so nothing is recorded and a worktree made from it is not
            // recorded as trusted either.
            Ok(read) if self.inherits_parent_trust(&paths, parent, cwd, &read, web).await => {
                return Ok(false);
            }
            Ok(read) => read.cwd,
            Err(crate::trust::Failure::Invalid(message)) => {
                return Err(RpcError::invalid_params(message));
            }
            Err(crate::trust::Failure::Record(message)) => {
                // Without a readable record no answer can be kept: say so rather than ask.
                return Err(refused(
                    "subsessions.trust_unreadable",
                    format!(
                        "start_session refused: the folder trust record cannot be read ({message})"
                    ),
                    &asked,
                ));
            }
        };
        if self.trust_waits.declined_recently(&key) {
            return Err(declined(&key));
        }
        let request = card(&key, short);
        let call = card_call(&request).unwrap_or_default().to_owned();
        let tag = format!("{TAG_PREFIX}{short}");
        self.trust_waits.tag_held(&parent.id, &tag);
        self.set_tags(
            parent,
            Some(&serde_json::Map::from_iter([(tag.clone(), json!(key))])),
            &[],
            Some(WAIT.as_secs() + 60),
        );
        let (epoch, turn_id) = (
            parent.permission_epoch.load(std::sync::atomic::Ordering::SeqCst),
            parent.turn().map(|t| t.turn_id),
        );
        let task = {
            let (hub, parent) = (self.clone(), parent.clone());
            tokio::spawn(
                async move { hub.handle_permission(&parent, request, epoch, turn_id).await },
            )
        };
        let mut guard = Wait { hub: self.clone(), session: parent.clone(), call, tag, task: None };
        let answer = guard.task.insert(task);
        let deadline = tokio::time::sleep(WAIT);
        tokio::pin!(deadline);
        let outcome = loop {
            // Registered before the folder is read, so a change after the read is not missed.
            let changed = self.trust_waits.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if let Some(decided) = self.trusted_now(&paths, &key, &family, web).await {
                // Trusted elsewhere (the pane's question, another card): this card is moot, and
                // the guard takes it away.
                return Ok(decided);
            }
            tokio::select! {
                outcome = &mut *answer => {
                    break outcome.unwrap_or_else(|_| json!({"outcome": {"outcome": "cancelled"}}));
                }
                () = &mut changed => {}
                () = &mut deadline => {
                    return Err(refused(
                        "subsessions.trust_timed_out",
                        format!("start_session refused: nobody answered the trust question for {key} in {} minutes. Ask the user to trust it, then start the sub-session again.", WAIT.as_secs() / 60),
                        &key,
                    ));
                }
            }
        };
        // The task ended (it settled its card itself): nothing is left for the guard to await.
        guard.task = None;
        // A card withdrawn because another start trusted the folder still lets this one go on;
        // one withdrawn after Not now is declined too. A card the person answered goes by its
        // own answer: Trust on it wins over a Not now on another start's card.
        if let Some(decided) = self.trusted_now(&paths, &key, &family, web).await {
            return Ok(decided);
        }
        let answered = outcome.pointer("/outcome/optionId").and_then(Value::as_str).is_some();
        if !answered && self.trust_waits.declined_recently(&key) {
            return Err(declined(&key));
        }
        self.trust_card_answered(&paths, &key, &outcome).await?;
        // Trust wrote the person's decision.
        Ok(true)
    }

    /// Whether a start in `cwd` (resolved) takes the trust of `parent`'s own folder instead of a
    /// card (Leo, 2026-10-24, on a card a chat in full access raised: "why did this even happen in
    /// the first place? I thought we bypassed this"). Only all of these: `parent` runs in full
    /// access by cmux's own doing ([`full_access_by_cmux`]: a mode cmux set, never one the
    /// harness claimed), outside a Web turn, and is no chat a Web client started
    /// (`remote_origin`); `cwd` is the parent's own folder or under it, a folder recorded as it
    /// resolves (no link on the way); a decision trusts that folder for the parent's agent (a
    /// person's answer, the agent's own level, or a folder cmux made: never an auto-trust rule
    /// alone); and nobody marked `cwd` untrusted. Any other start keeps its card, and the folder
    /// walk after it (`subsession_folder_check`) still refuses a folder marked untrusted anywhere
    /// up to `/`.
    async fn inherits_parent_trust(
        &self,
        paths: &crate::trust::Paths,
        parent: &Session,
        cwd: &Path,
        read: &crate::trust::SessionTrust,
        web: bool,
    ) -> bool {
        if web || read.level == Level::Untrusted {
            return false;
        }
        let pm = parent.meta();
        // A Web client's chat stays one after a local turn: only the person's own chats lend trust.
        if pm.remote_origin || !full_access_by_cmux(&pm) {
            return false;
        }
        // Only a folder recorded as it resolves, or through links only root can change (`/tmp` on
        // macOS): through a link the agent could point elsewhere after it started, the folder it
        // runs in is not the one the link names now.
        let Ok(own) = std::fs::canonicalize(&pm.cwd) else { return false };
        if (own != pm.cwd && !only_root_links(&pm.cwd, 0)) || !cwd.starts_with(&own) {
            return false;
        }
        let family = self.trust_family(&pm.harness).await;
        let own = own.to_string_lossy();
        let decided = self
            .trust_level_of(paths, &own, &family)
            .await
            .is_ok_and(|read| read.decided == Level::Trusted);
        // The parent may have left full access (or its folder or harness) during the read.
        let now = parent.meta();
        decided
            && full_access_by_cmux(&now)
            && !now.remote_origin
            && now.cwd == pm.cwd
            && now.harness == pm.harness
    }

    /// Whether the folder reads as trusted for `family` now (`web`: a Web turn, where an auto-trust
    /// rule is no answer): None when not, else whether a decision trusts it, not a rule alone.
    async fn trusted_now(
        &self,
        paths: &crate::trust::Paths,
        key: &str,
        family: &str,
        web: bool,
    ) -> Option<bool> {
        let read = self.trust_level_of(paths, key, family).await.ok()?;
        passes(&read, web).then(|| !read.by_rule_only())
    }

    /// Records a worktree made from a folder a decision trusts (never an auto-trust rule alone,
    /// `ensure_folder_trusted`) as trusted, so opening its chat in the pane asks nothing. A Web
    /// client reads that record as a person's answer (`trust::web_session_level`). Best effort: a
    /// record that cannot be written leaves the pane's own question. A worktree its repository's
    /// decision already trusts (`via`) gets no record of its own, so Not now or Undo on the
    /// repository still reaches it.
    pub(super) async fn trust_made_worktree(&self, cwd: &Path) {
        let Some(paths) = self.trust_gate() else { return };
        let folder = cwd.to_string_lossy().into_owned();
        let _ = tokio::task::spawn_blocking(move || {
            let inherited = crate::trust::get(&paths, &folder).is_ok_and(|reply| {
                reply["level"] == "trusted" && reply["decided"] == true && reply["via"].is_string()
            });
            if inherited {
                Ok(serde_json::Value::Null)
            } else {
                crate::trust::set(&paths, &folder, "trusted")
            }
        })
        .await;
        self.trust_changed();
    }

    /// What the card's answer means: Trust writes the person's decision and lets the start go on.
    async fn trust_card_answered(
        &self,
        paths: &crate::trust::Paths,
        key: &str,
        outcome: &Value,
    ) -> Result<(), RpcError> {
        let option = outcome.pointer("/outcome/optionId").and_then(Value::as_str);
        match option {
            Some("trust") => {
                let (paths, folder) = (paths.clone(), key.to_owned());
                let set = tokio::task::spawn_blocking(move || {
                    crate::trust::set(&paths, &folder, "trusted")
                })
                .await;
                match set {
                    Ok(Ok(_)) => {
                        self.trust_waits.forget(key);
                        self.trust_changed();
                        Ok(())
                    }
                    Ok(Err(e)) => Err(refused(
                        "subsessions.trust_unreadable",
                        format!("start_session refused: the folder could not be trusted ({e:?})"),
                        key,
                    )),
                    Err(e) => Err(RpcError::internal(e.to_string())),
                }
            }
            Some("not_now") => {
                self.trust_waits.decline(key);
                Err(declined(key))
            }
            // Cancelled: the turn ended, the chat closed or the card was withdrawn.
            _ => Err(refused(
                "subsessions.trust_cancelled",
                format!(
                    "start_session refused: the trust question for {key} was withdrawn before it was answered. Start the sub-session again when the user is ready."
                ),
                key,
            )),
        }
    }

    /// Withdraws the trust card `session` shows with the tool call `call`; its wait sees a cancel.
    /// Each card withdrawn is settled here (`settle_permission`: the cancelled decision logged,
    /// the session's status back), since the task that raised it is aborted and settles nothing.
    pub(super) fn cancel_trust_card(&self, session: &Session, call: &str) {
        let drained: Vec<_> = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let ids: Vec<String> = state
                .pending
                .iter()
                .filter(|(_, p)| {
                    super::questions::trust_cwd(&p.request).is_some()
                        && card_call(&p.request) == Some(call)
                })
                .map(|(id, _)| id.clone())
                .collect();
            let cancelled = json!({"outcome": "cancelled"});
            let drained: Vec<_> = ids
                .into_iter()
                .filter_map(|id| state.pending.remove(&id).map(|p| (id, p)))
                .collect();
            // Told to a later answer at once (`permission_settled.rs`), before the settle below.
            for (id, _) in &drained {
                state.settled.remember(id, None, &cancelled);
            }
            drained
        };
        for (id, pending) in drained {
            let outcome = json!({"outcome": "cancelled"});
            let _ = pending.reply.send(outcome.clone());
            self.settle_permission(session, &id, outcome, None, pending.prev_status);
        }
    }
}

/// Whether chat `m` runs in full access by cmux's own doing: its mode is a full-access mode cmux set
/// itself (`SessionMeta::mode_set_by_cmux`). A mode the harness reported on its own
/// (`current_mode_update`) is not enough, since the agent controls that, and neither is a launch
/// command that skips the checks, which a fallback to another profile leaves behind in the record.
pub(super) fn full_access_by_cmux(m: &SessionMeta) -> bool {
    let set = m.mode_set_by_cmux.as_deref();
    set.is_some_and(|mode| super::start_mode::FULL_ACCESS_MODES.contains(&mode))
        && crate::web_modes::mode_of(m).as_deref() == set
}

/// Whether `read` lets a start go on: with the auto-trust rules, or in a Web turn (`web`)
/// without them.
/// Whether every link on the way to the absolute `path` (and in its targets) is root's, in a
/// folder root owns that others cannot write: an agent running as the person cannot point it
/// elsewhere.
#[cfg(unix)]
fn only_root_links(path: &Path, depth: u8) -> bool {
    use std::os::unix::fs::MetadataExt;
    use std::path::Component;
    if depth > 8 || !path.is_absolute() {
        return false;
    }
    let mut at = std::path::PathBuf::new();
    for part in path.components() {
        if matches!(part, Component::CurDir | Component::ParentDir) {
            return false;
        }
        at.push(part);
        let Ok(meta) = std::fs::symlink_metadata(&at) else { return false };
        if !meta.file_type().is_symlink() {
            continue;
        }
        let Some(folder) = at.parent().map(Path::to_path_buf) else { return false };
        let Ok(held) = std::fs::metadata(&folder) else { return false };
        let Ok(target) = std::fs::read_link(&at) else { return false };
        if meta.uid() != 0 || held.uid() != 0 || held.mode() & 0o022 != 0 {
            return false;
        }
        if !only_root_links(&folder.join(target), depth + 1) {
            return false;
        }
        let Ok(resolved) = std::fs::canonicalize(&at) else { return false };
        at = resolved;
    }
    true
}

#[cfg(not(unix))]
fn only_root_links(_path: &Path, _depth: u8) -> bool {
    false
}

fn passes(read: &crate::trust::SessionTrust, web: bool) -> bool {
    (if web { read.decided } else { read.level }) == Level::Trusted
}

/// The `toolCallId` of a card's request.
fn card_call(request: &Value) -> Option<&str> {
    request.pointer("/toolCall/toolCallId").and_then(Value::as_str)
}

fn declined(key: &str) -> RpcError {
    refused(
        "subsessions.trust_declined",
        format!(
            "start_session refused: the user chose not to trust {key} for now. Do not ask again; continue without a sub-session there, or use a folder the user already trusts."
        ),
        key,
    )
}

#[cfg(all(test, unix))]
mod tests {
    use super::only_root_links;
    use std::path::Path;

    #[test]
    fn a_link_the_person_owns_can_be_pointed_elsewhere() {
        let root = std::env::temp_dir().join(format!("acpmux-root-links-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(root.join("target")).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        std::os::unix::fs::symlink(root.join("target"), root.join("link")).unwrap();
        assert!(!only_root_links(&root.join("link"), 0));
        assert!(!only_root_links(&root.join("link/sub"), 0));
        assert!(only_root_links(&root.join("target"), 0));
        assert!(!only_root_links(Path::new("relative"), 0));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_system_link_only_root_can_change_is_taken() {
        // macOS's /tmp -> private/tmp; on a system without it there is nothing to check.
        let tmp = Path::new("/tmp");
        if std::fs::symlink_metadata(tmp).is_ok_and(|m| m.file_type().is_symlink()) {
            assert!(only_root_links(tmp, 0));
        }
    }
}
