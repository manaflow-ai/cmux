//! Root role tickets fence late enrollment callbacks independently of HTTP.
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_link::root_bootstrap::{Host, NativeRequest, StopReceipt, Ticket, WakeSet};
use zeroize::Zeroizing;

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
    /// Capture the actual recipient before a protected/network read. A new
    /// daemon or role incarnation cannot consume this request's late result.
    pub(super) fn prepare_native(&self) -> Option<NativeRequest> {
        self.host.prepare_native(&self.ticket)
    }
    pub(super) fn publish_native(&self, request: NativeRequest, frame: Zeroizing<Vec<u8>>) -> bool {
        self.host.publish_native(request, frame)
    }

    /// Pin the role and actual daemon before touching protected identity or
    /// starting Cloud I/O. An obsolete read must never reach another recipient.
    pub(super) fn publish_original<H: super::client::Http>(
        &self,
        paths: &crate::config::Paths,
        instance: &str,
        client: &mut super::client::CloudClient<H>,
        wall_ms: u64,
    ) -> Result<bool, String> {
        let Some(request) = self.prepare_native() else { return Ok(false) };
        let frame = super::receiver_files::bootstrap(paths, instance, client, wall_ms)?.encode()?;
        if self.publish_native(request, frame) {
            Ok(true)
        } else {
            Err("Native receiving bootstrap recipient changed".into())
        }
    }
}
