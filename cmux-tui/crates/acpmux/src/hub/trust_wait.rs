//! Part of `Hub`; see `hub/mod.rs`. A sub-session in a folder nobody answered the trust
//! question for waits for the person instead of failing.
//!
//! `start_session` (`subsessions.rs`) asks [`Hub::ensure_folder_trusted`] before it starts
//! anything. A folder that reads as trusted (an answer, an agent's own level, or one of the
//! person's own folders, `trust_auto.rs`) passes at once. Any other folder raises a card on the
//! session that wants the sub-session: a choice question, **Trust** or **Not now**, through the
//! permission path every agent question uses, so the chat shows its card and the sidebar row its
//! "Needs your input" mark, and only the person answers it (never a policy, never a remote
//! browser). The start waits on the card and goes on by itself when the folder becomes trusted,
//! whether the card was answered or the folder was trusted elsewhere (the pane's own question,
//! `acp.trust.set`). Not now refuses the start with `subsessions.trust_declined` and is
//! remembered for [`DECLINE_MEMORY`], so an agent that asks again is not met with the same card.
//!
//! While the card is up the session carries the tag [`TAG_PREFIX`]`<name>` (the folder), so the
//! sidebar can say *which* wait it is. The tag and the card go with the wait, whatever ends it.

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
}

impl Waits {
    fn declined_recently(&self, key: &str) -> bool {
        let mut declined = self.declined.lock().unwrap_or_else(|e| e.into_inner());
        declined.retain(|_, at| at.elapsed() < DECLINE_MEMORY);
        declined.contains_key(key)
    }

    fn decline(&self, key: &str) {
        self.declined.lock().unwrap_or_else(|e| e.into_inner()).insert(key.to_owned(), Instant::now());
    }

    fn forget(&self, key: &str) {
        self.declined.lock().unwrap_or_else(|e| e.into_inner()).remove(key);
    }
}

fn refused(reason: &str, message: String, cwd: &str) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason, "cwd": cwd}))
}

/// The card's request: `toolCall._meta.acpmux.trust` marks it for the daemon (only a person
/// answers; a Web client cannot), `question` (harness `acp`) is what the chat draws.
fn card(cwd: &str, short: &str) -> Value {
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

/// Takes the card and the tag away when the wait ends in any way, also when the start itself is
/// dropped (the agent's tool call went away).
struct Wait<'a> {
    hub: &'a Hub,
    session: &'a Session,
    key: String,
    tag: String,
}

impl Drop for Wait<'_> {
    fn drop(&mut self) {
        self.hub.cancel_trust_cards(self.session, &self.key);
        self.hub.set_tags(self.session, None, std::slice::from_ref(&self.tag), None);
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

    /// The folder's key and level for an agent of `family`, read off the async runtime.
    async fn trust_level_of(
        &self,
        paths: &crate::trust::Paths,
        cwd: &str,
        family: &str,
    ) -> Result<(String, Level), crate::trust::Failure> {
        let (paths, cwd, family) = (paths.clone(), cwd.to_owned(), family.to_owned());
        tokio::task::spawn_blocking(move || crate::trust::session_level(&paths, &cwd, &family))
            .await
            .unwrap_or_else(|e| Err(crate::trust::Failure::Record(e.to_string())))
    }

    /// Ok once `cwd` is trusted for an agent of `harness`: at once when it already is, else after
    /// the person answered the card this raises on `parent` (see the module docs).
    pub(super) async fn ensure_folder_trusted(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        cwd: &Path,
        harness: &str,
        short: &str,
    ) -> Result<(), RpcError> {
        let Some(paths) = self.trust_gate() else { return Ok(()) };
        let family = self.trust_family(harness).await;
        let asked = cwd.to_string_lossy().into_owned();
        let (key, level) = match self.trust_level_of(&paths, &asked, &family).await {
            Ok(read) => read,
            Err(crate::trust::Failure::Invalid(message)) => {
                return Err(RpcError::invalid_params(message));
            }
            Err(crate::trust::Failure::Record(message)) => {
                // Without a readable record no answer can be kept: say so rather than ask.
                return Err(refused(
                    "subsessions.trust_unreadable",
                    format!("start_session refused: the folder trust record cannot be read ({message})"),
                    &asked,
                ));
            }
        };
        if level == Level::Trusted {
            return Ok(());
        }
        if self.trust_waits.declined_recently(&key) {
            return Err(declined(&key));
        }
        let guard = Wait {
            hub: self,
            session: parent,
            key: key.clone(),
            tag: format!("{TAG_PREFIX}{short}"),
        };
        let tag = serde_json::Map::from_iter([(guard.tag.clone(), json!(key))]);
        self.set_tags(parent, Some(&tag), &[], Some(WAIT.as_secs() + 60));
        let (epoch, turn_id) = (
            parent.permission_epoch.load(std::sync::atomic::Ordering::SeqCst),
            parent.turn().map(|t| t.turn_id),
        );
        let mut answer = {
            let (hub, parent, request, turn) =
                (self.clone(), parent.clone(), card(&key, short), turn_id);
            tokio::spawn(async move {
                hub.handle_permission(&parent, request, epoch, turn).await
            })
        };
        let deadline = tokio::time::sleep(WAIT);
        tokio::pin!(deadline);
        loop {
            // Registered before the folder is read, so a change after the read is not missed.
            let changed = self.trust_waits.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if self.trusted_now(&paths, &key, &family).await {
                // Trusted elsewhere (the pane's question, another card): this card is moot.
                self.cancel_trust_cards(parent, &key);
                return Ok(());
            }
            tokio::select! {
                outcome = &mut answer => {
                    let outcome = outcome.unwrap_or_else(|_| json!({"outcome": {"outcome": "cancelled"}}));
                    // A card withdrawn because another start trusted the folder still lets this
                    // one go on; one withdrawn after Not now is declined too.
                    if self.trusted_now(&paths, &key, &family).await {
                        return Ok(());
                    }
                    if self.trust_waits.declined_recently(&key) {
                        return Err(declined(&key));
                    }
                    return self.trust_card_answered(&paths, &key, &outcome).await;
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
        }
    }

    /// Whether the folder reads as trusted for `family` now.
    async fn trusted_now(&self, paths: &crate::trust::Paths, key: &str, family: &str) -> bool {
        matches!(self.trust_level_of(paths, key, family).await, Ok((_, Level::Trusted)))
    }

    /// Records a worktree made from a trusted folder as trusted, so opening its chat in the pane
    /// asks nothing. Best effort: a record that cannot be written leaves the pane's own question.
    pub(super) async fn trust_made_worktree(&self, cwd: &Path) {
        let Some(paths) = self.trust_gate() else { return };
        let folder = cwd.to_string_lossy().into_owned();
        let _ = tokio::task::spawn_blocking(move || crate::trust::set(&paths, &folder, "trusted"))
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
                format!("start_session refused: the trust question for {key} was withdrawn before it was answered. Start the sub-session again when the user is ready."),
                key,
            )),
        }
    }

    /// Withdraws the trust cards `session` shows for `key`; their waits see a cancel.
    pub(super) fn cancel_trust_cards(&self, session: &Session, key: &str) {
        let drained: Vec<_> = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let ids: Vec<String> = state
                .pending
                .iter()
                .filter(|(_, p)| super::questions::trust_cwd(&p.request) == Some(key))
                .map(|(id, _)| id.clone())
                .collect();
            ids.into_iter().filter_map(|id| state.pending.remove(&id).map(|p| (id, p))).collect()
        };
        for (_, pending) in drained {
            let _ = pending.reply.send(json!({"outcome": "cancelled"}));
        }
    }
}

fn declined(key: &str) -> RpcError {
    refused(
        "subsessions.trust_declined",
        format!("start_session refused: the user chose not to trust {key} for now. Do not ask again; continue without a sub-session there, or use a folder the user already trusts."),
        key,
    )
}
