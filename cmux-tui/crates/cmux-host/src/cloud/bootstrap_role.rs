//! Root role tickets fence late enrollment callbacks independently of HTTP.
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_link::root_bootstrap::{Host, StopReceipt, Ticket, WakeSet};

pub(super) struct RoleBridge {
    host: Arc<Host>,
    pending: Arc<Mutex<Option<Ticket>>>,
}

pub(super) struct WorkerBridge {
    host: Arc<Host>,
    ticket: Ticket,
    pending: Arc<Mutex<Option<Ticket>>>,
}

impl RoleBridge {
    pub(super) fn new(host: Arc<Host>) -> Self {
        Self { host, pending: Arc::new(Mutex::new(None)) }
    }
    pub(super) fn start(&mut self) -> io::Result<WorkerBridge> {
        // A detached old worker must never take a later incarnation's ticket.
        self.pending = Arc::new(Mutex::new(None));
        let ticket = self.host.new_ticket()?;
        Ok(WorkerBridge { host: self.host.clone(), ticket, pending: self.pending.clone() })
    }
    pub(super) fn resume(&self) -> io::Result<()> {
        let ticket = self.host.new_ticket()?;
        *self.pending.lock().map_err(|_| io::Error::other("bootstrap ticket unavailable"))? =
            Some(ticket);
        Ok(())
    }
    pub(super) fn stop(&self, deadline: Instant) -> io::Result<StopReceipt> {
        self.host.quiesce(deadline)
    }
}

impl WorkerBridge {
    pub(super) fn enrolled(&self) {
        self.host.offer(&self.ticket);
    }
    pub(super) fn resume(&mut self) {
        if let Ok(mut pending) = self.pending.lock()
            && let Some(ticket) = pending.take()
        {
            self.ticket = ticket;
        }
    }
    pub(super) fn wake_set(&self) -> Option<WakeSet> {
        self.host.wake_set().ok()
    }
    pub(super) fn drive(&self) {
        // The host retires failed endpoints. Optional transport failure
        // never stops Cloud status/activity or its live enrollment intent.
        let _ = self.host.drive();
    }
}
