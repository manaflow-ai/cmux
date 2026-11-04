//! The worker's side of the approval question (docs/computer-use-approvals.md):
//! one question per session x app at a time (parallel calls join it), the call
//! waits until `wait_until_ms`, the question stays answerable until
//! `answerable_until_ms` (a late Allow still grows the session or the saved
//! list, so the agent's retry runs), an answer counts once and only with the
//! request's digest, and a session that ends cancels its questions.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, watch};

use crate::approval::{ApprovalRequest, Decision, Pending, Question, Target, now_ms};

/// How a call's question ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Decided(Decision),
    /// No answer before `wait_until_ms` (`approval_timeout`).
    Timeout,
    /// No collector, cancelled, or the host link is gone (`approval_unavailable`).
    Unavailable,
}

/// Applies an Allow to the session (and the saved list), on time or late.
pub trait GrantSink: Send + Sync {
    fn grant(&self, session: &str, target: &Target, decision: Decision);
}

struct Asked {
    pending: Pending,
    key: (String, String),
    /// `None` until answered.
    outcome: watch::Sender<Option<Outcome>>,
}

pub struct Broker {
    next_id: AtomicU64,
    to_host: mpsc::UnboundedSender<Value>,
    sink: Arc<dyn GrantSink>,
    asked: Mutex<HashMap<u64, Asked>>,
    by_key: Mutex<HashMap<(String, String), u64>>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Broker {
    pub fn new(to_host: mpsc::UnboundedSender<Value>, sink: Arc<dyn GrantSink>) -> Arc<Self> {
        Arc::new(Self {
            next_id: AtomicU64::new(1),
            to_host,
            sink,
            asked: Mutex::new(HashMap::new()),
            by_key: Mutex::new(HashMap::new()),
        })
    }

    /// Asks (or joins the open question for this session x app) and waits until
    /// the call's deadline.
    pub async fn ask(self: &Arc<Self>, question: Question) -> Outcome {
        let key = (question.session.clone(), question.target.key());
        let mut failed_send = None;
        let (mut receiver, wait_until) = {
            let mut by_key = lock(&self.by_key);
            let joined = by_key.get(&key).and_then(|id| {
                lock(&self.asked).get(id).filter(|asked| asked.pending.answered().is_none()).map(|asked| {
                    (asked.outcome.subscribe(), asked.pending.request.wait_until_ms)
                })
            });
            match joined {
                Some(found) => found,
                None => {
                    let request = match ApprovalRequest::new(question, now_ms()) {
                        Ok(request) => request,
                        Err(_) => return Outcome::Unavailable,
                    };
                    let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                    let (sender, receiver) = watch::channel(None);
                    let wait_until = request.wait_until_ms;
                    let answerable_until = request.answerable_until_ms;
                    let line = json!({"type": "app_approval", "id": id, "request": request.to_value()});
                    lock(&self.asked).insert(id, Asked { pending: Pending::new(request), key: key.clone(), outcome: sender });
                    by_key.insert(key, id);
                    if self.to_host.send(line).is_err() {
                        failed_send = Some(id);
                    }
                    // The question is forgotten once nobody can answer it any more.
                    let broker = Arc::downgrade(self);
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(answerable_until.saturating_sub(now_ms()))).await;
                        if let Some(broker) = broker.upgrade() {
                            broker.forget(id);
                        }
                    });
                    (receiver, wait_until)
                }
            }
        };
        if let Some(id) = failed_send {
            self.finish(id, Outcome::Unavailable);
        }
        let deadline = Duration::from_millis(wait_until.saturating_sub(now_ms()));
        let waited = tokio::time::timeout(deadline, receiver.wait_for(Option::is_some)).await;
        match waited {
            Ok(Ok(outcome)) => outcome.unwrap_or(Outcome::Unavailable),
            Ok(Err(_)) => Outcome::Unavailable,
            Err(_) => Outcome::Timeout,
        }
    }

    /// The host's answer line: `{"type":"app_approval","id","ok",decision,digest,via}`.
    /// An answer with another digest, a second answer or a late one is ignored.
    pub fn answer(&self, message: &Value) {
        let Some(id) = message.get("id").and_then(Value::as_u64) else { return };
        if message.get("ok").and_then(Value::as_bool) != Some(true) {
            self.finish(id, Outcome::Unavailable);
            return;
        }
        let Some(decision) = message.get("decision").and_then(Value::as_str).and_then(Decision::parse) else { return };
        let digest = message.get("digest").and_then(Value::as_str).unwrap_or_default();
        let accepted = {
            let mut asked = lock(&self.asked);
            let Some(entry) = asked.get_mut(&id) else { return };
            match entry.pending.accept(decision, digest, now_ms()) {
                Ok(decision) => Some((entry.pending.request.session.clone(), entry.pending.request.target.clone(), decision)),
                Err(_) => None,
            }
        };
        let Some((session, target, decision)) = accepted else { return };
        if matches!(decision, Decision::Session | Decision::Always) {
            self.sink.grant(&session, &target, decision);
        }
        self.finish(id, Outcome::Decided(decision));
    }

    /// The session ended: its open questions are withdrawn.
    pub fn cancel_session(&self, session: &str) {
        let ids: Vec<u64> = lock(&self.asked)
            .iter()
            .filter(|(_, asked)| asked.pending.request.session == session)
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            let _ = self.to_host.send(json!({"type": "app_approval_cancel", "id": id}));
            self.forget(id);
        }
    }

    /// The open questions, for status.
    pub fn open(&self) -> usize {
        lock(&self.asked).values().filter(|asked| asked.pending.answered().is_none()).count()
    }

    fn finish(&self, id: u64, outcome: Outcome) {
        let asked = lock(&self.asked);
        if let Some(entry) = asked.get(&id) {
            entry.outcome.send_replace(Some(outcome));
            let key = entry.key.clone();
            drop(asked);
            let mut by_key = lock(&self.by_key);
            if by_key.get(&key) == Some(&id) {
                by_key.remove(&key);
            }
        }
    }

    fn forget(&self, id: u64) {
        let removed = lock(&self.asked).remove(&id);
        if let Some(entry) = removed {
            // Read first: the borrow's guard must be gone before the write.
            let current = *entry.outcome.borrow();
            entry.outcome.send_replace(current.or(Some(Outcome::Unavailable)));
            let mut by_key = lock(&self.by_key);
            if by_key.get(&entry.key) == Some(&id) {
                by_key.remove(&entry.key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder(Mutex<Vec<(String, String, Decision)>>);

    impl GrantSink for Recorder {
        fn grant(&self, session: &str, target: &Target, decision: Decision) {
            lock(&self.0).push((session.to_owned(), target.key(), decision));
        }
    }

    fn question(session: &str) -> Question {
        Question {
            client: "c".into(),
            machine: "m".into(),
            session: session.into(),
            agent: "Claude".into(),
            workspace: "w".into(),
            target: Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() },
            tool: "click".into(),
            risk: "R1".into(),
        }
    }

    #[tokio::test]
    async fn parallel_calls_join_one_question_and_an_allow_grants_the_session() {
        let (sender, mut lines) = mpsc::unbounded_channel();
        let sink = Arc::new(Recorder::default());
        let broker = Broker::new(sender, sink.clone());
        let first = tokio::spawn({
            let broker = Arc::clone(&broker);
            async move { broker.ask(question("s1")).await }
        });
        let asked = lines.recv().await.unwrap();
        let second = tokio::spawn({
            let broker = Arc::clone(&broker);
            async move { broker.ask(question("s1")).await }
        });
        tokio::task::yield_now().await;
        assert!(lines.try_recv().is_err(), "the second call joins the open question");
        let digest = asked["request"]["digest"].as_str().unwrap();
        // A wrong digest is ignored; the right one decides once.
        broker.answer(&json!({"type": "app_approval", "id": asked["id"], "ok": true, "decision": "always", "digest": "00"}));
        broker.answer(&json!({"type": "app_approval", "id": asked["id"], "ok": true, "decision": "session", "digest": digest}));
        broker.answer(&json!({"type": "app_approval", "id": asked["id"], "ok": true, "decision": "deny", "digest": digest}));
        assert_eq!(first.await.unwrap(), Outcome::Decided(Decision::Session));
        assert_eq!(second.await.unwrap(), Outcome::Decided(Decision::Session));
        assert_eq!(lock(&sink.0).as_slice(), &[("s1".to_owned(), "exe:/usr/bin/gedit".to_owned(), Decision::Session)]);
    }

    #[tokio::test(start_paused = true)]
    async fn no_answer_times_out_and_a_late_allow_still_grants() {
        let (sender, mut lines) = mpsc::unbounded_channel();
        let sink = Arc::new(Recorder::default());
        let broker = Broker::new(sender, sink.clone());
        let call = tokio::spawn({
            let broker = Arc::clone(&broker);
            async move { broker.ask(question("s1")).await }
        });
        let asked = lines.recv().await.unwrap();
        assert_eq!(call.await.unwrap(), Outcome::Timeout);
        let digest = asked["request"]["digest"].as_str().unwrap();
        broker.answer(&json!({"type": "app_approval", "id": asked["id"], "ok": true, "decision": "always", "digest": digest}));
        assert_eq!(lock(&sink.0).len(), 1);
    }

    #[tokio::test]
    async fn no_collector_fails_closed_and_an_ended_session_cancels() {
        let (sender, mut lines) = mpsc::unbounded_channel();
        let broker = Broker::new(sender, Arc::new(Recorder::default()));
        let call = tokio::spawn({
            let broker = Arc::clone(&broker);
            async move { broker.ask(question("s1")).await }
        });
        let asked = lines.recv().await.unwrap();
        broker.answer(&json!({"type": "app_approval", "id": asked["id"], "ok": false}));
        assert_eq!(call.await.unwrap(), Outcome::Unavailable);

        let call = tokio::spawn({
            let broker = Arc::clone(&broker);
            async move { broker.ask(question("s2")).await }
        });
        let asked = lines.recv().await.unwrap();
        broker.cancel_session("s2");
        assert_eq!(lines.recv().await.unwrap(), json!({"type": "app_approval_cancel", "id": asked["id"]}));
        assert_eq!(call.await.unwrap(), Outcome::Unavailable);
    }
}
