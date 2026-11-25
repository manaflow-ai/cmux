//! The async side of [`Driver`] on tokio's clock, so a paused test clock moves it.

use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::{BoundedMachine, Driver};

impl<M: BoundedMachine> Driver<M, Instant> {
    /// Resolves when the current state's bound passes; never for a settled or person's state.
    /// Cancel-safe: `select!` it beside the machine's events and call [`Driver::expire_due`].
    pub async fn expired(&self) {
        match self.deadline() {
            Some(at) => tokio::time::sleep_until(at).await,
            None => std::future::pending().await,
        }
    }

    /// Feeds `events` and fires each bound's recovery edge on time, until the channel closes.
    pub async fn run(&mut self, events: &mut mpsc::Receiver<M::Event>) {
        loop {
            tokio::select! {
                event = events.recv() => match event {
                    Some(event) => {
                        self.feed(event);
                    }
                    None => return,
                },
                () = self.expired() => {
                    self.expire_due();
                }
            }
        }
    }
}
