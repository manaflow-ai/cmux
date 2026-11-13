//! A `session/prompt` its client cancelled with `$/cancel_request` (review F1 of #41361).
//!
//! The connection answers the request cancelled at once and drops the future that serves it
//! (`in_flight.rs`, `request_cancel.rs`). A prompt's future must not end there: dropped, its turn
//! never reached `Hub::finish_turn`, so the chat read "running" for good, every later prompt
//! queued behind it, and a resend of its prompt id waited on an outcome nobody would publish.
//!
//! So a cancelled prompt goes on in a task of its own ([`finish_on_cancel`]) and is stopped
//! the way the chat stops one prompt ([`PromptStop`]): taken out of the queue while it waits,
//! else exactly its turn stopped (`Hub::stop_cancelled_prompt`). Its turn then ends as every
//! turn does (`finish_turn`, the prompt's outcome to its waiters, its saved files settled), and
//! its answer, which nobody reads any more, is dropped.
//!
//! Its caller reads the reply no more either (review F2 of #41361): the reader it held
//! (`PromptOptions::reply_reader`, the lane report's `LaneReplyReader`) reads as gone from the
//! cancel on ([`ReaderGone`]), as for a caller whose connection ended, so the lane report of
//! its turn still goes to the lead and a question's reply goes back to its asker.

use crate::hub::{Hub, Session};
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use tokio::sync::watch;

type OnAccepted = Option<Box<dyn FnOnce(Value) + Send>>;

/// What a cancel of one `session/prompt` request stops: its prompt, once the chat took it
/// (`on_accepted` names its prompt id). A cancel before that stops it as it is taken.
pub(super) struct PromptStop {
    hub: Arc<Hub>,
    session: Arc<Session>,
    state: Mutex<State>,
    /// Its caller's reader of the reply, revoked by the cancel.
    reader: Option<ReaderGone>,
}

/// Whether a prompt's caller still reads its reply, read as a connection's `ended` is (true:
/// it reads no more): true once its connection ended or it cancelled the request.
pub(super) struct ReaderGone {
    tx: watch::Sender<bool>,
    rx: watch::Receiver<bool>,
}

impl ReaderGone {
    /// Gone with `ended`, the caller's connection's end, or with a cancel ([`PromptStop`]).
    pub(super) fn new(hub: &Arc<Hub>, mut ended: watch::Receiver<bool>) -> Self {
        let (tx, rx) = watch::channel(*ended.borrow());
        let gone = tx.clone();
        // Ends with the connection, or once nobody reads it any more.
        hub.scope.spawn_named("prompt-reader-gone", async move {
            loop {
                if *ended.borrow_and_update() {
                    break;
                }
                tokio::select! {
                    changed = ended.changed() => if changed.is_err() { break },
                    () = gone.closed() => return,
                }
            }
            gone.send_replace(true);
        });
        Self { tx, rx }
    }

    pub(super) fn subscribe(&self) -> watch::Receiver<bool> {
        self.rx.clone()
    }

    fn revoke(&self) {
        self.tx.send_replace(true);
    }
}

#[derive(Default)]
struct State {
    /// The prompt id the chat took it under.
    prompt: Option<String>,
    cancelled: bool,
    /// Its stop was started (once).
    stopping: bool,
}

impl PromptStop {
    pub(super) fn new(
        hub: &Arc<Hub>,
        session: &Arc<Session>,
        reader: Option<ReaderGone>,
    ) -> Arc<Self> {
        Arc::new(Self {
            hub: hub.clone(),
            session: session.clone(),
            state: Default::default(),
            reader,
        })
    }

    /// `on_accepted`, which first notes the prompt id the chat took it under.
    pub(super) fn watch(self: &Arc<Self>, on_accepted: OnAccepted) -> OnAccepted {
        let this = self.clone();
        Some(Box::new(move |v: Value| {
            if let Some(id) = v.get("promptId").and_then(Value::as_str) {
                this.state.lock().unwrap_or_else(|e| e.into_inner()).prompt = Some(id.to_owned());
                this.stop_if_due();
            }
            if let Some(f) = on_accepted {
                f(v);
            }
        }))
    }

    /// The request was cancelled: its caller reads the reply no more, and its prompt stops, now
    /// or once the chat takes it.
    fn cancel(&self) {
        if let Some(reader) = &self.reader {
            reader.revoke();
        }
        self.state.lock().unwrap_or_else(|e| e.into_inner()).cancelled = true;
        self.stop_if_due();
    }

    fn stop_if_due(&self) {
        let prompt = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if !state.cancelled || state.stopping {
                return;
            }
            let Some(prompt) = state.prompt.clone() else { return };
            state.stopping = true;
            prompt
        };
        let (hub, session) = (self.hub.clone(), self.session.clone());
        // Not under the accepting caller's locks, nor in a dropping future; the hub's own work,
        // which its close ends.
        self.hub.scope.spawn_until_cancelled("cancelled-prompt-stop", async move {
            hub.stop_cancelled_prompt(&session, &prompt).await;
        });
    }
}

/// `run` to its end, also when the request it serves is cancelled: then dropped while
/// [`crate::request_cancel::requested`] holds, it goes on in a task of its own and `stop`
/// stops its prompt. Dropped for any other reason, it is dropped as before.
pub(super) async fn finish_on_cancel<F>(run: F, stop: Arc<PromptStop>) -> F::Output
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    FinishOnCancel { run: Some(Box::pin(run)), stop }.await
}

struct FinishOnCancel<F: Future + Send + 'static>
where
    F::Output: Send + 'static,
{
    run: Option<Pin<Box<F>>>,
    stop: Arc<PromptStop>,
}

impl<F: Future + Send + 'static> Future for FinishOnCancel<F>
where
    F::Output: Send + 'static,
{
    type Output = F::Output;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<F::Output> {
        let Some(run) = self.run.as_mut() else {
            return Poll::Pending;
        };
        let out = std::task::ready!(run.as_mut().poll(cx));
        self.run = None;
        Poll::Ready(out)
    }
}

impl<F: Future + Send + 'static> Drop for FinishOnCancel<F>
where
    F::Output: Send + 'static,
{
    fn drop(&mut self) {
        let Some(run) = self.run.take() else { return };
        if !crate::request_cancel::requested() {
            return;
        }
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        self.stop.cancel();
        // The hub's work from here, as the turn is: the connection that asked for it is done.
        self.stop.hub.scope.spawn_named("cancelled-prompt-settle", async move {
            let _answer = run.await;
            tracing::debug!(
                target: crate::request_cancel::LOG_TARGET,
                "a cancelled prompt's turn settled; its answer went to nobody"
            );
        });
    }
}
