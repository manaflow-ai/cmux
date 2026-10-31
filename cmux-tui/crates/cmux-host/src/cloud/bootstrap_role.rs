//! Root role tickets fence late enrollment callbacks independently of HTTP.
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_cloud_wire::{
    CloudVmReceiverLifecycleParamsPhase as Phase, CloudVmReceiverLifecycleResultPhase as State,
};
use cmux_link::root_bootstrap::{Host, NativeRequest, NativeStatus, StopReceipt, Ticket, WakeSet};
use ring::rand::SecureRandom as _;
use zeroize::Zeroizing;

pub(super) struct RoleBridge {
    host: Arc<Host>,
    pending: Arc<Mutex<Option<Ticket>>>,
}

pub(super) struct WorkerBridge {
    host: Arc<Host>,
    ticket: Ticket,
    pending: Arc<Mutex<Option<Ticket>>>,
    generation: Option<String>,
    ready: bool,
}

impl RoleBridge {
    pub(super) fn new(host: Arc<Host>) -> Self {
        Self { host, pending: Arc::new(Mutex::new(None)) }
    }
    pub(super) fn start(&mut self) -> io::Result<WorkerBridge> {
        // A detached old worker must never take a later incarnation's ticket.
        self.pending = Arc::new(Mutex::new(None));
        let ticket = self.host.new_ticket()?;
        Ok(WorkerBridge {
            host: self.host.clone(),
            ticket,
            pending: self.pending.clone(),
            generation: None,
            ready: false,
        })
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
            self.ready = false;
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
    pub(super) fn is_ready(&self) -> bool {
        self.ready
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
        &mut self,
        paths: &crate::config::Paths,
        instance: &str,
        client: &mut super::client::CloudClient<H>,
        wall_ms: u64,
    ) -> Result<bool, String> {
        match self.host.native_status(&self.ticket) {
            Some(NativeStatus::Ready) => {
                if !self.ready
                    && let Some(generation) = self.generation.clone()
                {
                    if let Err(error) =
                        client.receiver_lifecycle(Phase::Ready, Some(generation), None, wall_ms)
                    {
                        self.host.retire_native(&self.ticket);
                        return Err(error);
                    }
                    if self.host.native_status(&self.ticket) != Some(NativeStatus::Ready) {
                        self.retire(client, wall_ms)?;
                        return Ok(false);
                    }
                    self.ready = true;
                    return Ok(true);
                }
                return Ok(false);
            }
            Some(NativeStatus::Ended) => {
                self.retire(client, wall_ms)?;
                if let Some(ticket) = self.host.advance_native(&self.ticket) {
                    self.ticket = ticket;
                    self.ready = false;
                    // A real child/source failure gets the worker's bounded
                    // backoff. Its private frame is never retried.
                    return Err("Native receiving attempt ended".into());
                }
                return Ok(false);
            }
            None => {
                self.retire(client, wall_ms)?;
                return Ok(false);
            }
            Some(NativeStatus::Pending) => {}
        }
        let Some(request) = self.prepare_native() else { return Ok(false) };
        let frame = match self.produce(&request, paths, instance, client, wall_ms) {
            Ok(frame) => frame,
            Err(error) => {
                self.host.retire_native(&self.ticket);
                return Err(error);
            }
        };
        if self.publish_native(request, frame) {
            Ok(true)
        } else {
            Err("Native receiving bootstrap recipient changed".into())
        }
    }

    fn current(&self, request: &NativeRequest) -> Result<(), String> {
        if self.host.native_request_current(request) {
            Ok(())
        } else {
            Err("Native receiving bootstrap recipient changed".into())
        }
    }

    fn produce<H: super::client::Http>(
        &mut self,
        request: &NativeRequest,
        paths: &crate::config::Paths,
        instance: &str,
        client: &mut super::client::CloudClient<H>,
        wall_ms: u64,
    ) -> Result<Zeroizing<Vec<u8>>, String> {
        self.current(request)?;
        let original = super::receiver_files::load(paths, instance)?;
        if &original.bound != client.bound()
            || original.install_public_jwk != client.install_public_jwk()
        {
            return Err("protected VM identity changed".into());
        }
        self.current(request)?;
        let mut observed = client.receiver_lifecycle(Phase::Read, None, None, wall_ms)?;
        self.current(request)?;
        // Recovery includes attempts whose begin reply or child READY was
        // never observed. The exact CAS witness cannot retire a later attempt.
        if matches!(&observed.phase, State::Starting | State::Ready) {
            observed =
                client.receiver_lifecycle(Phase::End, Some(observed.generation), None, wall_ms)?;
            self.current(request)?;
        }
        let mut random = [0; 16];
        ring::rand::SystemRandom::new()
            .fill(&mut random)
            .map_err(|_| "receiving attempt nonce unavailable")?;
        let attempt = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        self.current(request)?;
        let started = client.receiver_lifecycle(
            Phase::Begin,
            Some(observed.generation),
            Some(attempt),
            wall_ms,
        )?;
        self.generation = Some(started.generation.clone());
        self.ready = false;
        self.current(request)?;
        let bootstrap = super::receiver_files::bootstrap(paths, instance, client, wall_ms)?;
        self.current(request)?;
        if bootstrap.generation() != started.generation
            || original != super::receiver_files::load(paths, instance)?
        {
            return Err("protected VM receiving generation changed".into());
        }
        bootstrap.encode()
    }

    pub(super) fn retire<H: super::client::Http>(
        &mut self,
        client: &mut super::client::CloudClient<H>,
        wall_ms: u64,
    ) -> Result<(), String> {
        let Some(generation) = self.generation.clone() else { return Ok(()) };
        self.host
            .quiesce_native(&self.ticket, Instant::now() + std::time::Duration::from_secs(8))
            .map_err(|_| "Native receiving attempt did not drain")?;
        if client.receiver_lifecycle(Phase::End, Some(generation.clone()), None, wall_ms).is_err() {
            let current = client.receiver_lifecycle(Phase::Read, None, None, wall_ms)?;
            if current.generation == generation && current.phase != State::Stopped {
                return Err("original receiving attempt did not retire".into());
            }
        }
        self.generation = None;
        self.ready = false;
        Ok(())
    }
}
