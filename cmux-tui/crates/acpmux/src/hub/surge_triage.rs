//! Part of `Hub`; see `hub/mod.rs`. The schedule, model call and delivery of surge triage
//! (`crate::surge_triage`, which says what the model may and may not decide).
//!
//! [`Hub::schedule_surge_triage`] runs one pass per chat at most [`DEBOUNCE`] after it is
//! called; a call while a pass runs asks for one more after it. The surge holder calls it after
//! each held message and after a restored inbox, so a pass resumes after a restart with no new
//! arrival. A pass:
//!
//! 1. reads the chat's `inbox`, `inbox_triaged` and `inbox_subscription` records;
//! 2. triages at most `MAX_BATCHES_PER_PASS` batches of the held messages no record decided,
//!    each through one `complete_own` call on the harness's small model (Claude: Haiku; Codex:
//!    its small model). A failed call decides every message of its batch `needs_this_session`;
//! 3. names the pass's digest before sending it (`digest_id`: a hash of its items) and journals
//!    each batch with that name (`persist_surge_triage`), so a crash after it leaves a record
//!    of a digest owed;
//! 4. sends every owed digest: the chat's own (its `needs_this_session` items only; none when
//!    there are none) and one per thread owner its subscriptions name (its `needs_its_owner`
//!    items). The prompt id is the digest's name, so a resend after a crash is the prompt
//!    ledger's duplicate, never a second digest. Then it journals the digest as delivered.
//!
//! A digest is the daemon's own prompt (provenance kind [`PROVENANCE_KIND`], no agent sender),
//! so no surge hold takes it back into an inbox.

use super::*;
use crate::surge_triage::{self as triage, Batch, Decision, Line, Owners};
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

/// How long a pass waits after its first call, so one pass takes a burst.
pub(crate) const DEBOUNCE: Duration = Duration::from_secs(30);
pub(crate) const PROVENANCE_KIND: &str = "surge_digest";
/// What answers instead of the small model (tests).
pub type SurgeTriager = Arc<dyn Fn(String) -> Option<String> + Send + Sync>;

/// What a chat's records say about surge triage.
#[derive(Default)]
pub(super) struct Journal {
    pub(super) held: Vec<triage::Held>,
    pub(super) triaged: BTreeSet<String>,
    pub(super) owners: Owners,
    /// Every decided item, by the digest that carries it.
    pub(super) by_digest: BTreeMap<String, Vec<Line>>,
    pub(super) delivered: BTreeSet<String>,
}

impl Journal {
    pub(super) fn read(&mut self, kind: &str, msg: &Value) {
        match kind {
            "inbox" => self.held.extend(triage::held_from_inbox(msg)),
            triage::SUBSCRIPTION_KIND => self.owners.apply(msg),
            triage::RECORD_KIND => {
                self.triaged.extend(triage::triaged_ids(msg));
                if let Some(d) = msg.get("digestDelivered").and_then(Value::as_str) {
                    self.delivered.insert(d.to_owned());
                }
                if let Some(d) = msg.get("digestPromptId").and_then(Value::as_str) {
                    let lines = triage::record_lines(msg);
                    self.by_digest.entry(d.to_owned()).or_default().extend(lines);
                }
            }
            _ => {}
        }
    }

    fn all_lines(&self) -> impl Iterator<Item = &Line> {
        self.by_digest.values().flatten()
    }
}

/// The owner digest's prompt id under the chat's digest `id`.
fn owner_digest_id(id: &str, owner: &str) -> String {
    let h = sha2::Sha256::digest(owner.as_bytes());
    format!("{id}-o{}", &format!("{h:x}")[..12])
}

use sha2::Digest as _;

impl Hub {
    /// Triage `session`'s held messages once, [`DEBOUNCE`] from now (module doc).
    pub(crate) fn schedule_surge_triage(self: &Arc<Self>, session: &Arc<Session>) {
        {
            let mut due = self.surge_triage_due.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(again) = due.get_mut(&session.id) {
                *again = true;
                return;
            }
            due.insert(session.id.clone(), false);
        }
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(hub.surge_triage_debounce()).await;
                let more = match hub.surge_triage_pass(&session).await {
                    Ok(more) => more,
                    Err(e) => {
                        tracing::warn!(session = %session.id, "surge triage: {}", e.message);
                        false
                    }
                };
                let mut due = hub.surge_triage_due.lock().unwrap_or_else(|e| e.into_inner());
                let again = due.get(&session.id).copied().unwrap_or(false);
                if !(more || again) || super::queue::closing(&session) {
                    due.remove(&session.id);
                    return;
                }
                due.insert(session.id.clone(), false);
            }
        });
    }

    fn surge_triage_debounce(&self) -> Duration {
        if self.surge_triager.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
            Duration::from_millis(1)
        } else {
            DEBOUNCE
        }
    }

    pub(crate) fn set_surge_triager(&self, triager: Option<SurgeTriager>) {
        *self.surge_triager.lock().unwrap_or_else(|e| e.into_inner()) = triager;
    }

    pub(super) fn surge_journal(&self, session: &Session) -> Result<Journal, RpcError> {
        let mut journal = Journal::default();
        let kinds = ["inbox", triage::RECORD_KIND, triage::SUBSCRIPTION_KIND];
        self.scan_for_rebuild(session, &kinds, &mut |e: EventRecord| {
            journal.read(&e.kind, &e.msg);
            true
        })
        .map_err(|e| RpcError::internal(format!("read surge records: {e}")))?;
        Ok(journal)
    }

    /// One pass (module doc). True when held messages are left for another pass.
    pub(super) async fn surge_triage_pass(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<bool, RpcError> {
        let mut journal = self.surge_journal(session)?;
        let pending = triage::pending(std::mem::take(&mut journal.held), &journal.triaged);
        let batches = triage::batches(&session.id, pending.clone());
        let taken: usize = batches.iter().map(|b| b.messages.len()).sum();
        let harness = session.meta().harness;
        let mut decided: Vec<(Batch, Vec<Decision>)> = Vec::with_capacity(batches.len());
        for batch in batches {
            let d = self.surge_triage_batch(Some(&harness), &batch, &journal.owners).await;
            decided.push((batch, d));
        }
        // The pass's digest is named by every item it carries, before any is journaled.
        let lines: Vec<Line> = decided
            .iter()
            .flat_map(|(b, d)| triage::record_lines(&triage::triaged_record(b, d, None)))
            .collect();
        if !lines.is_empty() {
            let id = triage::digest_id(&session.id, &lines);
            for (batch, d) in &decided {
                let record = triage::triaged_record(batch, d, Some(&id));
                journal.read(triage::RECORD_KIND, &record);
                let open = self.surge_open_topics(session, &journal);
                self.persist_surge_triage(session, record, open)?;
            }
        }
        for (id, lines) in &journal.by_digest {
            if !journal.delivered.contains(id) {
                self.deliver_surge_digests(session, id, lines).await?;
                let open = self.surge_open_topics(session, &journal);
                let marker = json!({"digestDelivered": id, "items": []});
                self.persist_surge_triage(session, marker, open)?;
            }
        }
        Ok(pending.len() > taken)
    }

    /// Distinct threads with a `needs_this_session` item the chat has not read.
    fn surge_open_topics(&self, session: &Session, journal: &Journal) -> u64 {
        let read: BTreeSet<String> = {
            let inbox = session.inbox();
            inbox.items.iter().filter(|i| i.read).map(|i| i.prompt_id.clone()).collect()
        };
        let open: Vec<Line> =
            journal.all_lines().filter(|l| !read.contains(&l.prompt_id)).cloned().collect();
        triage::actionable_topics(&open)
    }

    /// Sends the digests named `id`: the chat's own and each owner's. Each is sent once: a
    /// resend is its prompt id's duplicate.
    async fn deliver_surge_digests(
        self: &Arc<Self>,
        session: &Arc<Session>,
        id: &str,
        lines: &[Line],
    ) -> Result<(), RpcError> {
        if let Some(text) = triage::digest(&session.id, lines) {
            self.send_surge_digest(session, id, text, lines).await?;
        }
        let owners: BTreeSet<&str> = lines.iter().filter_map(|l| l.owner.as_deref()).collect();
        for owner in owners {
            let Some(text) = triage::owner_digest(&session.id, owner, lines) else { continue };
            // An owner gone since its subscription: its items stay in this chat's archive.
            let Ok(to) = self.resolve(owner) else {
                tracing::info!(session = %session.id, owner, "surge triage: owner gone");
                continue;
            };
            self.send_surge_digest(&to, &owner_digest_id(id, owner), text, lines).await?;
        }
        Ok(())
    }

    /// One digest prompt, accepted (queued, steered or a duplicate) before this returns.
    async fn send_surge_digest(
        self: &Arc<Self>,
        to: &Arc<Session>,
        id: &str,
        text: String,
        lines: &[Line],
    ) -> Result<(), RpcError> {
        let ids: Vec<&str> = lines.iter().map(|l| l.prompt_id.as_str()).collect();
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let opts = PromptOptions {
            prompt_id: Some(id.to_owned()),
            provenance: Some(json!({"kind": PROVENANCE_KIND, "digestId": id, "promptIds": ids})),
            on_accepted: Some(Box::new(move |accepted: Value| {
                let _ = tx.send(accepted);
            })),
            ..PromptOptions::default()
        };
        let (hub, chat) = (self.clone(), to.clone());
        // Runs on past the accept: a queued prompt's run lasts until its turn ends.
        let run = tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            hub.prompt_with(&chat, blocks, "acpmux", false, opts).await
        });
        match rx.await {
            Ok(_) => Ok(()),
            Err(_) => match run.await {
                Ok(Err(e)) => Err(e),
                _ => Err(RpcError::internal("surge digest was not accepted")),
            },
        }
    }

    /// The decisions of `batch`, through `harness` (None: the default harness).
    pub(crate) async fn surge_triage_batch(
        self: &Arc<Self>,
        harness: Option<&str>,
        batch: &Batch,
        owners: &Owners,
    ) -> Vec<Decision> {
        if batch.messages.is_empty() {
            return Vec::new();
        }
        let prompt = triage::prompt(batch);
        let triager = self.surge_triager.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let answer = match triager {
            Some(triage_with) => triage_with(prompt),
            None => {
                let timeout = Duration::from_millis(triage::TIMEOUT_MS);
                match self.complete_own(harness, prompt, triage::MAX_TOKENS, timeout).await {
                    Ok(text) => Some(text),
                    Err(e) => {
                        tracing::info!(
                            recipient = %batch.recipient,
                            batch = %batch.batch_id,
                            reason = e.reason(),
                            "surge triage: no model answer; every message reaches the chat"
                        );
                        None
                    }
                }
            }
        };
        triage::decide(batch, answer.as_deref(), owners)
    }
}

#[cfg(test)]
#[path = "surge_triage_tests.rs"]
mod tests;
