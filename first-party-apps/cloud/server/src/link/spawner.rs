//! [`LinkSpawner`]: starts links. The real one is
//! [`super::CarrierSpawner`] (a local socket plus one `cmux link dial` per
//! stream); tests use fakes.
//!
//! The spawner reports event lines and the end through one channel that
//! the supervisor owns. Events are the only signal: no timer, no polling.

use super::argv::LinkCommand;
use std::sync::Arc;
use std::sync::mpsc::{SendError, Sender};

/// One link process: the machine and the supervisor's generation for it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LinkTag {
    pub machine: String,
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkProcessEvent {
    /// One stdout line (without the newline).
    Line { tag: LinkTag, line: String },
    /// The process ended (`None`: killed by a signal).
    Exited { tag: LinkTag, code: Option<i32> },
    /// The link's ready deadline passed (sent by the supervisor's clock).
    Deadline { tag: LinkTag },
}

/// Wakes the owner of the link state (the serve loop) after an event was
/// queued. Called on the thread that sent the event; it must not block.
pub type LinkWake = Arc<dyn Fn() + Send + Sync>;

/// Where a link process sends its events: the supervisor's queue, then a
/// wake for the serve loop, so a link change reaches the host at once.
#[derive(Clone)]
pub struct LinkEvents {
    sender: Sender<LinkProcessEvent>,
    wake: Option<LinkWake>,
}

impl LinkEvents {
    pub(crate) fn new(sender: Sender<LinkProcessEvent>, wake: Option<LinkWake>) -> Self {
        Self { sender, wake }
    }

    /// Queues `event` for the supervisor. `Err` when the supervisor is gone.
    pub fn send(&self, event: LinkProcessEvent) -> Result<(), SendError<LinkProcessEvent>> {
        self.sender.send(event)?;
        if let Some(wake) = &self.wake {
            wake();
        }
        Ok(())
    }
}

/// A running link process.
pub trait LinkProcess: Send {
    fn pid(&self) -> Option<u32>;
    /// Ends the process. Its `Exited` event still arrives.
    fn terminate(&mut self);
}

pub trait LinkSpawner: Send {
    fn spawn(
        &mut self,
        tag: LinkTag,
        command: &LinkCommand,
        events: LinkEvents,
    ) -> std::io::Result<Box<dyn LinkProcess>>;
}
