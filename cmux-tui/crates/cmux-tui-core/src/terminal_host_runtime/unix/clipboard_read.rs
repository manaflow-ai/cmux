//! OSC 52 clipboard reads through the terminal host (decision
//! CLIPBOARD-READ-BROKER). Deny by default: the user grants each read.
//!
//! Negotiation: a host advertises `supports_clipboard_read` in its discovery
//! record, and only then does a current-protocol daemon ask the owner token
//! for `ADMIN | CLIPBOARD_READ`; an older host rejects the unknown right
//! bit, so it never sees it. The host enables deferred reads only while such
//! an owner connection is attached.
//!
//! Wire: `ClipboardReadRequest` (host to owner) carries `token:u64,
//! location:u8` (0 standard, 1 selection, 2 primary). `ClipboardReadReply`
//! (owner to host) carries `token:u64, outcome:u8` (0 refused, 1 granted)
//! and a text blob that a refusal ignores; longer than
//! [`MAX_CLIPBOARD_READ_BYTES`] is refused. Both use request id 0 and
//! sequence 0: the token names the read, and the request travels outside
//! both live sequences as a targeted frame, so the smart stream's cursor is
//! untouched.
//!
//! Host lifecycle: one open read per terminal; a read arriving while one is
//! open is refused at once. An open read is refused after
//! [`CLIPBOARD_READ_TIMEOUT`] on an injected clock, when its owner
//! disconnects, or when the terminal drains. Every answer is applied on the
//! parser thread, which flushes the OSC 52 reply to the PTY.

use super::*;
use ghostty_vt::{
    ClipboardLocation, ClipboardReadFn, ClipboardReadRequest, MAX_CLIPBOARD_READ_BYTES,
};
use std::sync::{MutexGuard, PoisonError};

/// A poisoned lock still guards consistent broker state (every critical
/// section leaves it whole), so the broker keeps working instead of
/// panicking on it.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How long the user has to answer one read.
pub(super) const CLIPBOARD_READ_TIMEOUT: Duration = Duration::from_secs(60);
const CLIPBOARD_READ_REFUSED: u8 = 0;
const CLIPBOARD_READ_GRANTED: u8 = 1;
const CLIPBOARD_READ_REQUEST_LEN: usize = size_of::<u64>() + 1;

/// The rights a daemon asks of a host for one owner connection.
pub(super) fn owner_rights_for(
    record: &TerminalHostRecord,
    protocol_version: u16,
) -> CapabilityRights {
    if protocol_version == PROTOCOL_VERSION && record.supports_clipboard_read {
        CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ
    } else {
        CapabilityRights::ADMIN
    }
}

/// Rights the owner token may grant: any non-empty part of `ADMIN` as
/// before, and `CLIPBOARD_READ` only together with all of `ADMIN`.
pub(super) fn owner_rights_allowed(requested: CapabilityRights) -> bool {
    if requested.contains(CapabilityRights::CLIPBOARD_READ) {
        requested == CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ
    } else {
        !requested.is_empty() && CapabilityRights::ADMIN.contains(requested)
    }
}

pub(super) fn encode_clipboard_read_request(request: ClipboardReadRequest) -> Vec<u8> {
    let mut payload = Vec::with_capacity(CLIPBOARD_READ_REQUEST_LEN);
    payload.extend_from_slice(&request.token.to_le_bytes());
    payload.push(match request.location {
        ClipboardLocation::Standard => 0,
        ClipboardLocation::Selection => 1,
        ClipboardLocation::Primary => 2,
    });
    payload
}

pub(super) fn decode_clipboard_read_request(
    payload: &[u8],
) -> anyhow::Result<ClipboardReadRequest> {
    let mut decoder = PayloadDecoder::new(payload);
    let token = decoder.u64()?;
    let location = match decoder.u8()? {
        0 => ClipboardLocation::Standard,
        1 => ClipboardLocation::Selection,
        2 => ClipboardLocation::Primary,
        _ => anyhow::bail!("unknown clipboard location"),
    };
    decoder.finish()?;
    anyhow::ensure!(token != 0, "clipboard read token is zero");
    Ok(ClipboardReadRequest { token, location })
}

/// `None`, or text over the cap, is a refusal.
pub(super) fn encode_clipboard_read_reply(token: u64, text: Option<&[u8]>) -> Vec<u8> {
    let text = text.filter(|text| text.len() <= MAX_CLIPBOARD_READ_BYTES);
    let body = text.unwrap_or_default();
    let mut payload = Vec::with_capacity(13 + body.len());
    payload.extend_from_slice(&token.to_le_bytes());
    payload.push(if text.is_some() { CLIPBOARD_READ_GRANTED } else { CLIPBOARD_READ_REFUSED });
    payload.extend_from_slice(&(body.len() as u32).to_le_bytes());
    payload.extend_from_slice(body);
    payload
}

fn decode_clipboard_read_reply(payload: &[u8]) -> anyhow::Result<(u64, Option<Vec<u8>>)> {
    let mut decoder = PayloadDecoder::new(payload);
    let token = decoder.u64()?;
    let outcome = decoder.u8()?;
    let text = decoder.blob()?;
    decoder.finish()?;
    let text = match outcome {
        CLIPBOARD_READ_REFUSED => None,
        CLIPBOARD_READ_GRANTED if text.len() <= MAX_CLIPBOARD_READ_BYTES => Some(text.to_vec()),
        CLIPBOARD_READ_GRANTED => None,
        _ => anyhow::bail!("unknown clipboard read outcome"),
    };
    Ok((token, text))
}

/// The host's time source for the read timeout. Tests inject a fake.
pub(super) trait ClipboardClock: Send + Sync {
    fn now(&self) -> Instant;

    /// Waits on `changed` until it is notified or `timeout` passes on this
    /// clock.
    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, ClipboardReadState>,
        timeout: Duration,
    ) -> MutexGuard<'a, ClipboardReadState>;
}

pub(super) struct SystemClock;

impl ClipboardClock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn wait_timeout<'a>(
        &self,
        changed: &Condvar,
        state: MutexGuard<'a, ClipboardReadState>,
        timeout: Duration,
    ) -> MutexGuard<'a, ClipboardReadState> {
        changed.wait_timeout(state, timeout).unwrap_or_else(PoisonError::into_inner).0
    }
}

struct ClipboardOwner {
    client: u64,
    tap: HostTap,
}

struct OpenClipboardRead {
    token: u64,
    client: u64,
    deadline: Instant,
}

#[derive(Default)]
pub(super) struct ClipboardReadState {
    /// Attached `CLIPBOARD_READ` connections; the newest one is asked. A
    /// transient owner connection therefore cannot strand the long-lived
    /// one when it leaves.
    owners: Vec<ClipboardOwner>,
    open: Option<OpenClipboardRead>,
    ended: bool,
}

struct ClipboardReadsShared {
    state: Mutex<ClipboardReadState>,
    changed: Condvar,
    clock: Arc<dyn ClipboardClock>,
}

/// Host-side broker. Lock order: terminal, then this state, then the
/// host's broadcast lock.
pub(super) struct ClipboardReads {
    shared: Arc<ClipboardReadsShared>,
    /// Reads the terminal reported during the current `vt_write`.
    queued: Arc<Mutex<Vec<ClipboardReadRequest>>>,
}

impl ClipboardReads {
    pub(super) fn new(clock: Arc<dyn ClipboardClock>) -> Self {
        Self {
            shared: Arc::new(ClipboardReadsShared {
                state: Mutex::new(ClipboardReadState::default()),
                changed: Condvar::new(),
                clock,
            }),
            queued: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// The terminal callback: it runs inside `vt_write`, so it only queues.
    pub(super) fn callback(&self) -> ClipboardReadFn {
        let queued = self.queued.clone();
        Box::new(move |request| lock(&queued).push(request))
    }

    /// Starts the timeout worker. It blocks until the earliest deadline or a
    /// state change and exits when the terminal drains.
    pub(super) fn start_timer(
        &self,
        parser_commands: SyncSender<ParserCommand>,
    ) -> std::io::Result<()> {
        let shared = self.shared.clone();
        thread::Builder::new()
            .name("terminal-host-clipboard".into())
            .spawn(move || shared.run_timer(&parser_commands))
            .map(drop)
    }

    #[cfg(test)]
    pub(super) fn notify_timer(&self) {
        let _state = lock(&self.shared.state);
        self.shared.changed.notify_all();
    }

    /// Parser thread, terminal locked, right after `vt_write`: asks the
    /// newest owner about the first read, refuses the rest.
    pub(super) fn dispatch(&self, term: &mut Terminal, broadcast_lock: &Mutex<()>) {
        let requests = std::mem::take(&mut *lock(&self.queued));
        for request in requests {
            if !self.open(request, broadcast_lock) {
                term.complete_clipboard_read(request.token, None);
            }
        }
    }

    fn open(&self, request: ClipboardReadRequest, broadcast_lock: &Mutex<()>) -> bool {
        let mut state = lock(&self.shared.state);
        if state.ended || state.open.is_some() {
            return false;
        }
        let Some(owner) = state.owners.last() else { return false };
        let frame =
            Frame::new(MessageKind::ClipboardReadRequest, encode_clipboard_read_request(request));
        let client = owner.client;
        // Same serialization as other targeted frames: never between a
        // legacy Output/Resized and its Colors.
        if !{
            let _broadcast = lock(broadcast_lock);
            owner.tap.try_send(frame)
        } {
            return false;
        }
        let deadline = self.shared.clock.now() + CLIPBOARD_READ_TIMEOUT;
        state.open = Some(OpenClipboardRead { token: request.token, client, deadline });
        self.shared.changed.notify_all();
        true
    }

    /// A connection granted `CLIPBOARD_READ` joined: reads are deferred
    /// from now on and asked of it.
    pub(super) fn register_owner(&self, term: &Mutex<Terminal>, client: u64, tap: HostTap) {
        let mut term = lock(term);
        let mut state = lock(&self.shared.state);
        if state.ended {
            return;
        }
        state.owners.push(ClipboardOwner { client, tap });
        term.set_clipboard_reads_deferred(true);
    }

    /// Any connection left. Returns the open read it owned, which the
    /// caller refuses on the parser thread. The last owner turns deferral
    /// off, so reads are ignored again.
    fn unregister_owner(&self, term: &Mutex<Terminal>, client: u64) -> Option<u64> {
        if !lock(&self.shared.state).owners.iter().any(|owner| owner.client == client) {
            return None;
        }
        let mut term = lock(term);
        let mut state = lock(&self.shared.state);
        state.owners.retain(|owner| owner.client != client);
        if state.owners.is_empty() {
            term.set_clipboard_reads_deferred(false);
        }
        let open = state.open.take_if(|open| open.client == client)?;
        self.shared.changed.notify_all();
        Some(open.token)
    }

    fn take_open(&self, client: u64, token: u64) -> bool {
        let mut state = lock(&self.shared.state);
        let taken = state.open.take_if(|open| open.client == client && open.token == token);
        self.shared.changed.notify_all();
        taken.is_some()
    }

    /// Parser thread, at the terminal's end: refuses every open and queued
    /// read and stops the timer.
    pub(super) fn end(&self, term: &mut Terminal) {
        let mut tokens: Vec<u64> =
            std::mem::take(&mut *lock(&self.queued)).iter().map(|r| r.token).collect();
        {
            let mut state = lock(&self.shared.state);
            state.ended = true;
            state.owners.clear();
            tokens.extend(state.open.take().map(|open| open.token));
            self.shared.changed.notify_all();
        }
        term.set_clipboard_reads_deferred(false);
        for token in tokens {
            term.complete_clipboard_read(token, None);
        }
    }
}

impl ClipboardReadsShared {
    fn run_timer(&self, parser_commands: &SyncSender<ParserCommand>) {
        let mut state = lock(&self.state);
        loop {
            if state.ended {
                return;
            }
            let Some(deadline) = state.open.as_ref().map(|open| open.deadline) else {
                state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
                continue;
            };
            let now = self.clock.now();
            if now < deadline {
                state = self.clock.wait_timeout(&self.changed, state, deadline - now);
                continue;
            }
            let token = state.open.take().map(|open| open.token);
            drop(state);
            if let Some(token) = token {
                let _ = parser_commands
                    .send(ParserCommand::ClipboardReadComplete { token, text: None });
            }
            state = lock(&self.state);
        }
    }
}

impl HostShared {
    /// Refuses the open read of a connection that left (see `remove_client`).
    pub(super) fn release_clipboard_owner(&self, client: u64) {
        if let Some(token) = self.clipboard.unregister_owner(&self.term, client) {
            let _ = self
                .parser_commands
                .send(ParserCommand::ClipboardReadComplete { token, text: None });
        }
    }

    /// One `ClipboardReadReply` from `client`. False closes the connection:
    /// it lacks the right or sent a malformed reply. Stale or unknown tokens
    /// are ignored.
    pub(super) fn apply_clipboard_read_reply(
        &self,
        client: u64,
        granted_rights: CapabilityRights,
        frame: &Frame,
    ) -> bool {
        if !granted_rights.contains(CapabilityRights::CLIPBOARD_READ) || frame.request_id != 0 {
            return false;
        }
        let Ok((token, text)) = decode_clipboard_read_reply(&frame.payload) else {
            return false;
        };
        if self.clipboard.take_open(client, token) {
            let _ = self.parser_commands.send(ParserCommand::ClipboardReadComplete { token, text });
        }
        true
    }
}

/// Daemon side, one per owner connection: whether the connection negotiated
/// `CLIPBOARD_READ`, and the host's open read. A newer request replaces an
/// older one, which the host has already refused by its timeout.
#[derive(Default)]
pub(crate) struct ClipboardReadInbox {
    negotiated: AtomicBool,
    pending: Mutex<Option<ClipboardReadRequest>>,
}

impl ControlResponses {
    pub(super) fn with_clipboard_reads(negotiated: bool) -> Self {
        let responses = Self::new();
        responses.clipboard_reads.negotiated.store(negotiated, Ordering::Release);
        responses
    }

    #[cfg(test)]
    pub(crate) fn negotiate_clipboard_reads_for_test(&self) {
        self.clipboard_reads.negotiated.store(true, Ordering::Release);
    }

    pub(crate) fn clipboard_reads_negotiated(&self) -> bool {
        self.clipboard_reads.negotiated.load(Ordering::Acquire)
    }

    /// The connection's frame reader got a `ClipboardReadRequest`. False
    /// ends the connection: unnegotiated, or a malformed envelope or payload.
    pub(crate) fn accept_clipboard_read_request(
        &self,
        frame: &Frame,
        protocol_version: u16,
    ) -> bool {
        if !self.clipboard_reads_negotiated()
            || frame.version != protocol_version
            || frame.flags != 0
            || frame.request_id != 0
            || frame.sequence != 0
        {
            return false;
        }
        let Ok(request) = decode_clipboard_read_request(&frame.payload) else {
            return false;
        };
        *lock(&self.clipboard_reads.pending) = Some(request);
        true
    }

    pub(crate) fn pending_clipboard_read(&self) -> Option<ClipboardReadRequest> {
        *lock(&self.clipboard_reads.pending)
    }

    fn take_clipboard_read(&self, token: u64) -> bool {
        self.clipboard_reads
            .pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take_if(|pending| pending.token == token)
            .is_some()
    }
}

impl HostAttachment {
    pub(crate) fn clipboard_reads_negotiated(&self) -> bool {
        self.control_responses.clipboard_reads_negotiated()
    }

    #[cfg(test)]
    pub(crate) fn negotiate_clipboard_reads_for_test(&self) {
        self.control_responses.negotiate_clipboard_reads_for_test();
    }

    pub(crate) fn pending_clipboard_read(&self) -> Option<ClipboardReadRequest> {
        self.control_responses.pending_clipboard_read()
    }

    /// Answers the pending read `token`: `Some(text)` grants, `None`
    /// refuses. False, with nothing sent, when `token` is not pending.
    pub(crate) fn complete_clipboard_read(
        &self,
        token: u64,
        text: Option<&[u8]>,
    ) -> std::io::Result<bool> {
        if !self.control_responses.take_clipboard_read(token) {
            return Ok(false);
        }
        self.send(MessageKind::ClipboardReadReply, &encode_clipboard_read_reply(token, text))?;
        Ok(true)
    }
}
