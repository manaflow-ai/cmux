//! Part of the inbox (`inbox.rs` module docs, "Deadlines"): a held message's deadline survives a
//! daemon restart, and one that no turn can take expires and goes back to its sender.
//!
//! The wake timer lives in memory only, and a restart reads a chat's inbox lazily
//! (`Session::inbox`), with nothing to review it: an idle chat's held messages then waited for a
//! turn nothing would start. NOW counted 25 chats so on 2026-11-25, one with 219 messages past
//! their deadline (the soonest 46 hours past), one 10 days past. So:
//!
//! - a restored inbox that holds new messages is reviewed once, as an arrival would be
//!   ([`review_after_restore`]): its deadline wake is armed again, or what is due goes in now;
//! - a sweep ([`Hub::inbox_deadline_worker`]) reviews every chat's inbox after the daemon read
//!   every log, and every [`SWEEP_EVERY`] after that, so no chat depends on a request to read
//!   its inbox for its deadline to count;
//! - a new message still undelivered [`EXPIRE_AFTER_MS`] past its deadline in a chat with no
//!   running turn (a Stop's hold, a wake its agent keeps refusing, a first work that never
//!   starts) expires ([`Hub::inbox_expire`]): it leaves the inbox with an `inbox_removed` record
//!   (`reason: "expired"`, and why), a sender that waits is answered with that reason, and a
//!   sender chat on this machine gets one FYI per sender saying what did not arrive and why.
//!   A running turn takes its inbox at its end, so nothing expires under one.
//!
//! Stop condition: a review is what the timer does at its deadline, so a sweep adds no turn a
//! deadline would not have started. Cleanup: the sweep holds the hub weakly and ends with it.

use super::*;
use std::sync::Weak;

/// How long past its deadline a held message waits for a chat that takes no turn before it
/// expires and goes back to its sender.
pub(in crate::hub) const EXPIRE_AFTER_MS: u64 = 24 * 60 * 60 * 1000;
/// How often the sweep reviews every chat's inbox.
pub(in crate::hub) const SWEEP_EVERY: std::time::Duration = std::time::Duration::from_secs(10 * 60);
/// The thread an expiry notice goes to in the sender's inbox.
const BOUNCE_THREAD: &str = "acpmux:undelivered";

/// A restored inbox holds new messages: review it once, as an arrival would, so its deadline
/// wake is armed again with no new arrival (module docs). Runs on a task of its own: the
/// restore holds the inbox's load lock, and the review reads the inbox. Outside a runtime, or for
/// a chat the hub no longer holds, nothing runs.
pub(in crate::hub) fn review_after_restore(session: &Session) {
    if tokio::runtime::Handle::try_current().is_err() {
        return;
    }
    let Some(hub) = session.hub_ref.get().and_then(Weak::upgrade) else { return };
    let id = session.id.clone();
    let owner = hub.clone();
    // Owned by the hub's scope: its close ends a review still running (check-spawn-owner).
    owner.scope.spawn_named("inbox review after restore", async move {
        if let Some(session) = hub.session_get(&id) {
            hub.inbox_review(&session);
        }
    });
}

/// The new messages of `items` that expire at `now`: past their deadline by [`EXPIRE_AFTER_MS`].
/// A folded repeat has no deadline of its own, and a surge-held one waits for its triage.
pub(in crate::hub) fn expired_ids(items: &[Item], now: u64) -> Vec<String> {
    items
        .iter()
        .filter(|i| !i.noticed && !i.surge_held && !folded(i))
        .filter(|i| i.due().saturating_add(EXPIRE_AFTER_MS) < now)
        .map(|i| i.prompt_id.clone())
        .collect()
}

/// Why a chat with no running turn took no notice of a due message, for the expiry's record and
/// its sender.
/// Seen on 2026-11-25: a chat whose folder under /tmp was gone (every wake refused
/// `session.folder_missing`), and a chat whose first work waits for the person to pick a folder.
/// Called under the inbox's lock, as `inbox_review` reads the queue under it.
fn why_undelivered(session: &Session, inbox: &Inbox) -> &'static str {
    let meta = session.meta();
    if meta.status == SessionStatus::Closed {
        "the chat is closed"
    } else if session.stop_hold.load(std::sync::atomic::Ordering::SeqCst) != 0 {
        "the person's Stop holds other agents' messages and the person took no turn since"
    } else if !meta.cwd.as_os_str().is_empty() && !meta.cwd.exists() {
        "the chat's folder no longer exists, so no turn of it can start"
    } else if inbox.refused_at != 0 {
        "the chat's agent refused the turn that would have carried it"
    } else if inbox.first.is_some() || first_work_waits(session) {
        "the chat's first work never started"
    } else {
        "no turn of the chat took it"
    }
}

impl Hub {
    /// Expires the new messages of `session` past their deadline by [`EXPIRE_AFTER_MS`] (module
    /// docs), when no turn runs there and no notice is in flight. Returns how many expired.
    pub(in crate::hub) fn inbox_expire(self: &Arc<Self>, session: &Arc<Session>) -> usize {
        if session.turn().is_some() {
            return 0;
        }
        let now = now_ms();
        let receiver = session.meta().name;
        let receiver = if receiver.is_empty() { session.id.clone() } else { receiver };
        let (expired, why) = {
            let mut inbox = session.inbox();
            if inbox.in_flight.is_some() {
                return 0;
            }
            let ids = expired_ids(&inbox.items, now);
            if ids.is_empty() {
                return 0;
            }
            let why = why_undelivered(session, &inbox);
            let mut expired = Vec::new();
            let mut kept = Vec::with_capacity(inbox.items.len());
            for item in std::mem::take(&mut inbox.items) {
                if ids.contains(&item.prompt_id) {
                    expired.push(item);
                } else {
                    kept.push(item);
                }
            }
            inbox.items = kept;
            for item in &expired {
                inbox.removed.insert(item.prompt_id.clone());
            }
            inbox.settled.notify_waiters();
            (expired, why)
        };
        for item in &expired {
            let record = json!({
                "promptId": item.prompt_id, "threadId": item.thread, "reason": "expired",
                "why": why, "dueAt": item.due(),
            });
            self.append(session, "mux", "inbox_removed", record);
        }
        let message = |item: &Item| {
            format!(
                "inbox.expired: {receiver} took no notice of this message within {} hours past its \
                 deadline ({why}). It was not delivered; it left {receiver}'s inbox.",
                (now.saturating_sub(item.due())) / 3_600_000
            )
        };
        let mut by_sender: std::collections::BTreeMap<String, Vec<&Item>> = Default::default();
        for item in &expired {
            if let Some(answer) = &item.answer {
                answer.send_replace(Some(Err(RpcError::new(-32000, message(item)))));
            }
            if let Some(from) = item.from_session.as_deref().filter(|f| *f != session.id) {
                by_sender.entry(from.to_owned()).or_default().push(item);
            }
        }
        tracing::warn!(session = %session.id, expired = expired.len(), why, "inbox messages expired past their deadline");
        for (from, items) in by_sender {
            self.inbox_bounce(&from, &receiver, why, &items);
        }
        expired.len()
    }

    /// Tells sender chat `from`, when it is on this machine and open, which of its messages to
    /// `receiver` expired and why: one FYI in its inbox (thread [`BOUNCE_THREAD`]). A bounce
    /// names no sender session, so it never bounces again.
    fn inbox_bounce(self: &Arc<Self>, from: &str, receiver: &str, why: &str, items: &[&Item]) {
        let Some(sender) = self.session_get(from) else { return };
        if sender.meta().status == SessionStatus::Closed {
            return;
        }
        let mut text = format!(
            "{} of your messages to {receiver} expired undelivered: {why}, for over {} hours past \
             their deadline. Send again if it still matters, or reach {receiver} another way.",
            items.len(),
            EXPIRE_AFTER_MS / 3_600_000
        );
        for item in items.iter().take(5) {
            let first = body(&item.text).lines().next().unwrap_or_default();
            let first: String = first.chars().take(PREVIEW_CHARS).collect();
            text.push_str(&format!("\n- {first}"));
        }
        if items.len() > 5 {
            text.push_str(&format!("\n- and {} more", items.len() - 5));
        }
        let prompt_id = format!("inbox-expired-{}", uuid::Uuid::now_v7());
        let class = PromptClass::Fyi;
        let sender_identity = crate::prompt_provenance::sender_record(None, None, None);
        {
            let mut inbox = sender.inbox();
            inbox.items.push(Item {
                surge_held: false,
                verdict: None,
                prompt_id: prompt_id.clone(),
                notice: None,
                answered: None,
                thread: BOUNCE_THREAD.to_owned(),
                from: CLIENT.to_owned(),
                from_session: None,
                asker: None,
                sender: sender_identity.clone(),
                class,
                report: false,
                waited: false,
                at: now_ms(),
                within: None,
                text: text.clone(),
                details: None,
                tool_notice: None,
                fire: false,
                noticed: false,
                read: false,
                answer: None,
                reader: None,
            });
            trim(&mut inbox);
        }
        let record = json!({
            "promptId": prompt_id, "threadId": BOUNCE_THREAD, "from": CLIENT, "class": class,
            "kind": kind_of(class), "client": CLIENT, "text": text, "sender": sender_identity,
        });
        self.append(&sender, "mux", "inbox", record);
        self.inbox_review(&sender);
    }

    /// One sweep of every open chat's inbox (module docs): review it, then expire what no turn
    /// can take. Returns how many messages expired.
    pub(in crate::hub) fn inbox_deadline_sweep(self: &Arc<Self>) -> usize {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let mut expired = 0;
        for session in sessions {
            if self.shutting_down() {
                break;
            }
            if session.meta().status == SessionStatus::Closed {
                continue;
            }
            self.inbox_review(&session);
            expired += self.inbox_expire(&session);
        }
        expired
    }

    /// The sweep (module docs): once every chat's log is read (`daemon.rs`), then every
    /// [`SWEEP_EVERY`], until the daemon shuts down.
    pub fn inbox_deadline_worker(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let hub = Arc::downgrade(self);
        crate::supervise::restarting("inbox-deadlines", &self.fatal, move || {
            let hub = hub.clone();
            async move {
                loop {
                    {
                        let Some(hub) = hub.upgrade() else { return };
                        if hub.shutting_down() {
                            return;
                        }
                        // Reads logs (a lazy inbox) and the journal: off the runtime's threads.
                        let pass = hub.clone();
                        let swept =
                            tokio::task::spawn_blocking(move || pass.inbox_deadline_sweep());
                        if let Err(e) = swept.await {
                            tracing::warn!("inbox deadline sweep: {e}");
                        }
                    }
                    tokio::time::sleep(SWEEP_EVERY).await;
                }
            }
        })
    }
}

#[cfg(test)]
#[path = "inbox_deadline_tests.rs"]
mod tests;
