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

use crate::hub::{Hub, Session};
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

type OnAccepted = Option<Box<dyn FnOnce(Value) + Send>>;

/// What a cancel of one `session/prompt` request stops: its prompt, once the chat took it
/// (`on_accepted` names its prompt id). A cancel before that stops it as it is taken.
pub(super) struct PromptStop {
    hub: Arc<Hub>,
    session: Arc<Session>,
    state: Mutex<State>,
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
    pub(super) fn new(hub: &Arc<Hub>, session: &Arc<Session>) -> Arc<Self> {
        Arc::new(Self { hub: hub.clone(), session: session.clone(), state: Default::default() })
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

    /// The request was cancelled: its prompt stops, now or once the chat takes it.
    fn cancel(&self) {
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
