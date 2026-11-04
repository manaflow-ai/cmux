//! Asking the user's other devices for a Computer Use approval through the
//! hub (`docs/computer-use-approvals.md`, "Device hub approvals"). The hub
//! stores and forwards; this machine applies a decision only after checking it
//! itself, and fails closed otherwise.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use tokio::sync::{Mutex, broadcast, watch};
use tokio::time::Instant;

use crate::approval::{
    ApprovalRequest, ApprovalState, DecisionEvidence, Expectation, HubApproval, KnownDevice,
    PinnedApprover, VerifiedDecision, pin_of, verify_decision,
};
use crate::client::{HubClient, unix_millis};
use crate::error::HubError;
use crate::identity::Platform;
use crate::socket::{HubPush, SocketEvent, stop_requested};

/// Called with a decision that arrives after `wait_until_ms` but before
/// `answerable_until_ms`: the host grants it so the agent's retry runs.
pub type LateDecisionHandler = Arc<dyn Fn(VerifiedDecision) + Send + Sync>;

/// One question.
#[derive(Clone)]
pub struct ApprovalAsk {
    /// The worker's request, `digest` set.
    pub request: ApprovalRequest,
    /// This machine's `computerUse.phoneAlwaysAllow`.
    pub allow_always: bool,
    /// Gets a verified decision made after the call stopped waiting.
    pub on_late: Option<LateDecisionHandler>,
}

/// How a question ended. Everything but `Decided` leaves the call refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalOutcome {
    /// A verified once, session, always or deny.
    Decided(VerifiedDecision),
    /// No verified decision by `wait_until_ms` (or the hub expired it).
    Timeout,
    /// [`RemoteApprover::cancel`] ended it.
    Cancelled,
    /// No hub, signed out, unreachable, or no device that can approve.
    Unavailable(String),
    Error(String),
}

impl VerifiedDecision {
    /// The contract's `via` for this decision.
    pub fn via(&self) -> &'static str {
        match self.decider_platform {
            Platform::Ios => "phone",
            _ => "mac",
        }
    }
}

/// The host's way to ask a person on another device. No `RemoteApprover`
/// existed in `cmux-remote-host` when this crate was written; this is the
/// contract's shape (ask, cancel; late decisions through `on_late`).
#[async_trait]
pub trait RemoteApprover: Send + Sync {
    /// Asks and waits until `wait_until_ms`.
    async fn ask(&self, ask: ApprovalAsk) -> ApprovalOutcome;
    /// The agent session ended (`app_approval_cancel`): stop waiting and
    /// withdraw the question. `nonce` is the request's.
    async fn cancel(&self, nonce: &str);
}

/// No hub configured: every question is unavailable.
pub struct NoHubApprover;

#[async_trait]
impl RemoteApprover for NoHubApprover {
    async fn ask(&self, _ask: ApprovalAsk) -> ApprovalOutcome {
        ApprovalOutcome::Unavailable("the device hub is not configured".to_owned())
    }

    async fn cancel(&self, _nonce: &str) {}
}

struct AskEntry {
    token: u64,
    approval_id: Option<String>,
    cancel: watch::Sender<bool>,
}

struct DeviceCache {
    devices: Vec<KnownDevice>,
    stale: bool,
}

struct Inner {
    client: Arc<HubClient>,
    events: broadcast::Sender<SocketEvent>,
    devices: Mutex<DeviceCache>,
    /// The approvers this machine's owner pinned; the hub's list only supplies their keys.
    pinned: Vec<PinnedApprover>,
    asks: Mutex<HashMap<String, AskEntry>>,
    tokens: AtomicU64,
}

/// [`RemoteApprover`] over the device hub. `events` is the User DO socket's
/// ([`UserSocket::events`](crate::UserSocket::events)); `pinned` are the
/// approvers the machine's owner confirmed at setup. With none pinned every
/// question is unavailable: a device the hub lists, whatever its platform and
/// signature, never approves on its own.
#[derive(Clone)]
pub struct HubApprover {
    inner: Arc<Inner>,
}

enum WatchEnd {
    Decided(VerifiedDecision),
    Expired,
    Cancelled,
    Deadline,
}

impl HubApprover {
    pub fn new(
        client: Arc<HubClient>,
        events: broadcast::Sender<SocketEvent>,
        pinned: Vec<PinnedApprover>,
    ) -> HubApprover {
        HubApprover {
            inner: Arc::new(Inner {
                client,
                events,
                devices: Mutex::new(DeviceCache { devices: Vec::new(), stale: true }),
                pinned,
                asks: Mutex::new(HashMap::new()),
                tokens: AtomicU64::new(1),
            }),
        }
    }
}

impl Inner {
    async fn refresh_devices(&self) -> Result<Vec<KnownDevice>, HubError> {
        let devices: Vec<KnownDevice> =
            self.client.devices().await?.iter().map(|device| device.known()).collect();
        let mut cache = self.devices.lock().await;
        cache.devices = devices.clone();
        cache.stale = false;
        Ok(devices)
    }

    /// The account's devices, refetched when stale or when `want` is not among them.
    async fn devices_with(&self, want: &str) -> Vec<KnownDevice> {
        {
            let cache = self.devices.lock().await;
            if !cache.stale && cache.devices.iter().any(|device| device.id == want) {
                return cache.devices.clone();
            }
        }
        match self.refresh_devices().await {
            Ok(devices) => devices,
            // Fail closed: without a fresh list only a device already known counts,
            // and only when the list is not stale.
            Err(_) => {
                let cache = self.devices.lock().await;
                if cache.stale { Vec::new() } else { cache.devices.clone() }
            }
        }
    }

    async fn check(
        &self,
        evidence: &DecisionEvidence,
        approval_id: &str,
        request: &ApprovalRequest,
        allow_always: bool,
    ) -> Option<VerifiedDecision> {
        if evidence.approval_id != approval_id {
            return None;
        }
        let devices = self.devices_with(&evidence.decider_id).await;
        let expected = Expectation {
            approval_id,
            own_device_id: self.client.identity().id(),
            request_digest: &request.digest,
            allow_always,
            pinned: &self.pinned,
        };
        verify_decision(evidence, &expected, &devices).ok()
    }

    /// Applies what `GET /v1/approvals/:id` says, when it ends the question.
    async fn reread(
        &self,
        approval_id: &str,
        request: &ApprovalRequest,
        allow_always: bool,
    ) -> Option<WatchEnd> {
        let approval = self.client.approval(approval_id).await.ok()?;
        self.apply_record(&approval, approval_id, request, allow_always).await
    }

    async fn apply_record(
        &self,
        approval: &HubApproval,
        approval_id: &str,
        request: &ApprovalRequest,
        allow_always: bool,
    ) -> Option<WatchEnd> {
        match approval.state {
            ApprovalState::Decided => {
                let evidence = approval.evidence()?;
                self.check(&evidence, approval_id, request, allow_always)
                    .await
                    .map(WatchEnd::Decided)
            }
            ApprovalState::Expired => Some(WatchEnd::Expired),
            ApprovalState::Cancelled => Some(WatchEnd::Cancelled),
            ApprovalState::Pending | ApprovalState::Unknown => None,
        }
    }

    /// Waits for a verified decision on `approval_id` until `deadline`.
    async fn watch(
        &self,
        approval_id: &str,
        request: &ApprovalRequest,
        allow_always: bool,
        events: &mut broadcast::Receiver<SocketEvent>,
        cancel: &mut watch::Receiver<bool>,
        deadline: Instant,
    ) -> WatchEnd {
        let sleep = tokio::time::sleep_until(deadline);
        tokio::pin!(sleep);
        // wakeup-allow: each pass waits for a socket event, cancellation or the deadline.
        loop {
            let event = tokio::select! {
                () = &mut sleep => return WatchEnd::Deadline,
                () = stop_requested(cancel) => return WatchEnd::Cancelled,
                event = events.recv() => event,
            };
            let end = match event {
                Ok(SocketEvent::Push(HubPush::ApprovalDecided {
                    id,
                    decision,
                    digest,
                    decider_id,
                    sig,
                })) if id == approval_id => {
                    let evidence =
                        DecisionEvidence { approval_id: id, decision, digest, decider_id, sig };
                    self.check(&evidence, approval_id, request, allow_always)
                        .await
                        .map(WatchEnd::Decided)
                }
                Ok(SocketEvent::Push(HubPush::ApprovalClosed { id, state, .. }))
                    if id == approval_id =>
                {
                    match state.as_str() {
                        "expired" => Some(WatchEnd::Expired),
                        "cancelled" => Some(WatchEnd::Cancelled),
                        _ => self.reread(approval_id, request, allow_always).await,
                    }
                }
                Ok(SocketEvent::Push(HubPush::DevicesChanged)) => {
                    self.devices.lock().await.stale = true;
                    None
                }
                // Pushes have no backlog: after a (re)connect or a gap, read the outcome.
                Ok(SocketEvent::Connected) | Err(broadcast::error::RecvError::Lagged(_)) => {
                    self.reread(approval_id, request, allow_always).await
                }
                Ok(_) => None,
                Err(broadcast::error::RecvError::Closed) => {
                    // No socket any more: only the deadline or a cancel ends this.
                    tokio::select! {
                        () = &mut sleep => return WatchEnd::Deadline,
                        () = stop_requested(cancel) => return WatchEnd::Cancelled,
                    }
                }
            };
            if let Some(end) = end {
                return end;
            }
        }
    }

    async fn finish(&self, nonce: &str, token: u64) {
        let mut asks = self.asks.lock().await;
        if asks.get(nonce).is_some_and(|entry| entry.token == token) {
            asks.remove(nonce);
        }
    }
}

fn instant_at(unix_ms: i64) -> Instant {
    let remaining = unix_ms.saturating_sub(unix_millis()).max(0) as u64;
    Instant::now() + Duration::from_millis(remaining)
}

fn unavailable_or_error(error: HubError) -> ApprovalOutcome {
    if error.is_unavailable() {
        ApprovalOutcome::Unavailable(error.to_string())
    } else {
        ApprovalOutcome::Error(error.to_string())
    }
}

#[async_trait]
impl RemoteApprover for HubApprover {
    async fn ask(&self, ask: ApprovalAsk) -> ApprovalOutcome {
        let inner = &self.inner;
        let request = ask.request;
        if !request.digest_is_valid() {
            return ApprovalOutcome::Error(
                "the request digest does not match its fields".to_owned(),
            );
        }
        let nonce = request.nonce.clone();
        let token = inner.tokens.fetch_add(1, Ordering::Relaxed);
        let (cancel_tx, mut cancel) = watch::channel(false);
        {
            let mut asks = inner.asks.lock().await;
            if asks.contains_key(&nonce) {
                return ApprovalOutcome::Error("this request is already being asked".to_owned());
            }
            asks.insert(nonce.clone(), AskEntry { token, approval_id: None, cancel: cancel_tx });
        }
        // Subscribed before asking, so a decision pushed at once is not missed.
        let mut events = inner.events.subscribe();
        let outcome = async {
            if inner.pinned.is_empty() {
                return Err(ApprovalOutcome::Unavailable(
                    "no approver is pinned on this machine (cmux computer-use setup --approver)"
                        .to_owned(),
                ));
            }
            let own_id = inner.client.identity().id().to_owned();
            let devices = match inner.refresh_devices().await {
                Ok(devices) => devices,
                Err(error) => return Err(unavailable_or_error(error)),
            };
            let can_allow = |device: &KnownDevice| {
                !device.id.eq_ignore_ascii_case(&own_id)
                    && device.platform.is_approver()
                    && pin_of(device, &inner.pinned).is_ok()
            };
            if !devices.iter().any(can_allow) {
                return Err(ApprovalOutcome::Unavailable(
                    "no pinned Mac or iPhone is on this account with its pinned approval key"
                        .to_owned(),
                ));
            }
            let approval = inner
                .client
                .create_approval(&request, ask.allow_always)
                .await
                .map_err(unavailable_or_error)?;
            {
                let mut asks = inner.asks.lock().await;
                if let Some(entry) = asks.get_mut(&nonce).filter(|entry| entry.token == token) {
                    entry.approval_id = Some(approval.id.clone());
                }
            }
            if *cancel.borrow() {
                let _ = inner.client.cancel_approval(&approval.id).await;
                return Err(ApprovalOutcome::Cancelled);
            }
            Ok(approval)
        }
        .await;
        let approval = match outcome {
            Ok(approval) => approval,
            Err(outcome) => {
                inner.finish(&nonce, token).await;
                return outcome;
            }
        };
        let id = approval.id.clone();
        // A retry of the same nonce returns the stored approval, possibly decided.
        let first = match inner.apply_record(&approval, &id, &request, ask.allow_always).await {
            Some(end) => end,
            None => {
                inner
                    .watch(
                        &id,
                        &request,
                        ask.allow_always,
                        &mut events,
                        &mut cancel,
                        instant_at(request.wait_until_ms),
                    )
                    .await
            }
        };
        match first {
            WatchEnd::Decided(decision) => {
                inner.finish(&nonce, token).await;
                ApprovalOutcome::Decided(decision)
            }
            WatchEnd::Expired => {
                inner.finish(&nonce, token).await;
                ApprovalOutcome::Timeout
            }
            WatchEnd::Cancelled => {
                inner.finish(&nonce, token).await;
                ApprovalOutcome::Cancelled
            }
            WatchEnd::Deadline => {
                match ask.on_late {
                    Some(on_late) if request.answerable_until_ms > unix_millis() => {
                        let late = Arc::clone(&self.inner);
                        let allow_always = ask.allow_always;
                        tokio::spawn(async move {
                            let end = late
                                .watch(
                                    &id,
                                    &request,
                                    allow_always,
                                    &mut events,
                                    &mut cancel,
                                    instant_at(request.answerable_until_ms),
                                )
                                .await;
                            late.finish(&request.nonce, token).await;
                            if let WatchEnd::Decided(decision) = end {
                                on_late(decision);
                            }
                        });
                    }
                    _ => inner.finish(&nonce, token).await,
                }
                ApprovalOutcome::Timeout
            }
        }
    }

    async fn cancel(&self, nonce: &str) {
        let entry = self.inner.asks.lock().await.remove(nonce);
        let Some(entry) = entry else {
            return;
        };
        let _ = entry.cancel.send(true);
        if let Some(id) = entry.approval_id {
            let _ = self.inner.client.cancel_approval(&id).await;
        }
    }
}
