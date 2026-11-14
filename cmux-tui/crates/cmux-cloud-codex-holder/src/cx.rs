//! Cooperative cancellation, the way the holder's Swift actors had it: every task has one
//! [`Cx`], a cancel is seen at the next check, sleep or remote call, and work that must finish
//! even when its caller is cancelled (a cleanup, a reconcile, a quit erase) runs on
//! [`Cx::never`]. Futures are never dropped to cancel them, so each cleanup path still runs.

use std::future::Future;
use std::time::Duration;

use tokio_util::sync::CancellationToken;

use crate::error::Error;

/// One task's cancellation.
#[derive(Clone, Debug, Default)]
pub struct Cx(CancellationToken);

impl Cx {
    pub fn new() -> Self {
        Self(CancellationToken::new())
    }

    /// A task nothing cancels (Swift's unstructured `Task {}`, which inherits no cancel).
    pub fn never() -> Self {
        Self::new()
    }

    /// Cancelled with `self`, or on its own.
    pub fn child(&self) -> Self {
        Self(self.0.child_token())
    }

    pub fn cancel(&self) {
        self.0.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.is_cancelled()
    }

    pub async fn cancelled(&self) {
        self.0.cancelled().await;
    }

    /// Sleeps `duration`; a cancel ends it with [`Error::Interrupted`].
    pub async fn sleep(&self, duration: Duration) -> Result<(), Error> {
        if self.is_cancelled() {
            return Err(Error::Interrupted);
        }
        tokio::select! {
            biased;
            () = self.0.cancelled() => Err(Error::Interrupted),
            () = tokio::time::sleep(duration) => Ok(()),
        }
    }

    /// Runs one remote call; a cancel ends the wait with [`Error::Interrupted`] (the call's own
    /// child or request ends with it, as the app's transport did).
    pub async fn run<T>(&self, work: impl Future<Output = Result<T, Error>>) -> Result<T, Error> {
        if self.is_cancelled() {
            return Err(Error::Interrupted);
        }
        tokio::select! {
            biased;
            () = self.0.cancelled() => Err(Error::Interrupted),
            result = work => result,
        }
    }
}

/// A spawned task with its cancel and a way to wait for its end.
#[derive(Debug)]
pub struct Job {
    pub cx: Cx,
    done: tokio::sync::watch::Receiver<bool>,
}

impl Job {
    /// Spawns `work`, which gets the job's own [`Cx`].
    pub fn spawn<F>(work: impl FnOnce(Cx) -> F) -> Self
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let cx = Cx::new();
        let (sender, done) = tokio::sync::watch::channel(false);
        let future = work(cx.clone());
        tokio::spawn(async move {
            future.await;
            let _ = sender.send(true);
        });
        Self { cx, done }
    }

    pub fn cancel(&self) {
        self.cx.cancel();
    }

    /// A handle that waits for the end (tests).
    pub fn ended(&self) -> Ended {
        Ended(self.done.clone())
    }
}

/// Waits for a [`Job`]'s end.
#[derive(Clone, Debug)]
pub struct Ended(tokio::sync::watch::Receiver<bool>);

impl Ended {
    pub async fn wait(mut self) {
        let _ = self.0.wait_for(|done| *done).await;
    }
}
