//! Device hub approvals on Windows and Linux (docs/computer-use-approvals.md,
//! "Device hub approvals"): the host's [`RemoteApprover`] over the hub client's
//! [`HubApprover`], which asks the person's Mac or iPhone and applies a
//! decision only after this machine checked it: signed by an approver the box
//! owner pinned in the owner's config (`[[approvers]]`), with the key the
//! owner confirmed, never this machine. The hub's word alone never grants.

use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use cmux_device_hub_client as hub;
use serde_json::{Value, json};

use crate::approval::{ApprovalRequest, Decision};
use crate::approver::{ApproverDecision, RemoteApprover};
use crate::config::{ComputerUseConfig, DeviceHubConfig, PinnedApprover};

/// Why the host has no device hub collector, or that it has one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HubState {
    /// `[device_hub]` and at least one pinned approver: asking.
    Ready,
    /// Not set up; the reason is for status.
    Off(String),
}

impl HubState {
    /// Whether `config` sets up device hub approvals (fail closed: no pins, no collector).
    pub fn of(config: &Result<ComputerUseConfig, String>) -> HubState {
        match config {
            Err(error) => HubState::Off(format!("the Computer Use config is not valid: {error}")),
            Ok(config) => match (&config.device_hub, config.approvers.is_empty()) {
                (None, _) => HubState::Off("no device hub in the Computer Use config".into()),
                (Some(_), true) => HubState::Off(
                    "no approver is pinned: run `cmux computer-use setup --approver <device id>` on this machine".into(),
                ),
                (Some(_), false) => HubState::Ready,
            },
        }
    }

    pub fn status(&self, config: &Result<ComputerUseConfig, String>) -> Value {
        let approvers: Vec<Value> = config
            .as_ref()
            .map(|config| {
                config
                    .approvers
                    .iter()
                    .map(|pin| {
                        json!({"device_id": pin.device_id, "name": pin.name, "platform": pin.platform,
                               "fingerprint": hub::display_fingerprint(&pin.approval_key_fingerprint)})
                    })
                    .collect()
            })
            .unwrap_or_default();
        match self {
            HubState::Ready => json!({"state": "ready", "approvers": approvers}),
            HubState::Off(reason) => json!({"state": "off", "reason": reason, "approvers": approvers}),
        }
    }
}

/// The hub client's pins from the owner's config.
pub fn pins(approvers: &[PinnedApprover]) -> Vec<hub::PinnedApprover> {
    approvers
        .iter()
        .map(|pin| hub::PinnedApprover {
            device_id: pin.device_id.clone(),
            approval_key_fingerprint: pin.approval_key_fingerprint.clone(),
        })
        .collect()
}

/// Connects to the hub as this machine's device (registering it), opens the
/// User DO socket and returns the approver. Runs in the background at start.
pub async fn connect(
    hub_config: &DeviceHubConfig,
    approvers: &[PinnedApprover],
    machine: &str,
) -> Result<(HubRemote, hub::UserSocket), String> {
    let url = url::Url::parse(&hub_config.url).map_err(|error| format!("[device_hub] url: {error}"))?;
    let dir = hub::default_identity_dir().ok_or("no directory for this machine's device identity")?;
    let identity = tokio::task::spawn_blocking(move || hub::default_key_store(&dir).load_or_create())
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| error.to_string())?;
    let tokens = Arc::new(hub::CommandToken::new(hub_config.token_command.clone()));
    let client = Arc::new(hub::HubClient::new(hub::HubClientConfig::new(url, identity, tokens)).map_err(|error| error.to_string())?);
    client.register_device(machine).await.map_err(|error| format!("cannot register this machine on the device hub: {error}"))?;
    let socket = hub::UserSocket::spawn(Arc::clone(&client), hub::SocketOptions::default());
    let approver = hub::HubApprover::new(client, socket.events(), pins(approvers));
    let described = describe(approvers);
    Ok((HubRemote { approver: Arc::new(approver), allow_always: hub_config.allow_always, described }, socket))
}

fn describe(approvers: &[PinnedApprover]) -> Vec<String> {
    let mut names = Vec::new();
    for pin in approvers {
        let name = if pin.platform == "ios" { "phone" } else { "mac" };
        if !names.iter().any(|known| known == name) {
            names.push(name.to_owned());
        }
    }
    names
}

/// [`RemoteApprover`] over a hub client approver.
pub struct HubRemote {
    approver: Arc<dyn hub::RemoteApprover>,
    allow_always: bool,
    described: Vec<String>,
}

impl HubRemote {
    pub fn new(approver: Arc<dyn hub::RemoteApprover>, allow_always: bool, described: Vec<String>) -> Self {
        Self { approver, allow_always, described }
    }
}

/// Withdraws the hub question when the host stops waiting (another collector answered, or the worker cancelled).
struct Withdraw {
    approver: Option<Arc<dyn hub::RemoteApprover>>,
    nonce: String,
}

impl Drop for Withdraw {
    fn drop(&mut self) {
        if let Some(approver) = self.approver.take() {
            let nonce = std::mem::take(&mut self.nonce);
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move { approver.cancel(&nonce).await });
            }
        }
    }
}

fn decision_of(verified: &hub::VerifiedDecision) -> Option<ApproverDecision> {
    Some(ApproverDecision {
        decision: Decision::parse(verified.decision.as_str())?,
        digest: verified.digest.clone(),
        via: verified.via().to_owned(),
    })
}

#[async_trait]
impl RemoteApprover for HubRemote {
    async fn ask(&self, request: &ApprovalRequest) -> Option<ApproverDecision> {
        let request: hub::ApprovalRequest = serde_json::from_value(request.to_value()).ok()?;
        if !request.digest_is_valid() {
            return None;
        }
        // A decision after the call stopped waiting still counts until answerable_until_ms.
        let (late_tx, late_rx) = tokio::sync::oneshot::channel();
        let late_tx = Mutex::new(Some(late_tx));
        let on_late: hub::LateDecisionHandler = Arc::new(move |decision| {
            if let Some(sender) = late_tx.lock().unwrap_or_else(PoisonError::into_inner).take() {
                let _ = sender.send(decision);
            }
        });
        let mut withdraw = Withdraw { approver: Some(Arc::clone(&self.approver)), nonce: request.nonce.clone() };
        let asked = hub::ApprovalAsk { request, allow_always: self.allow_always, on_late: Some(on_late) };
        let answer = match self.approver.ask(asked).await {
            hub::ApprovalOutcome::Decided(decision) => decision_of(&decision),
            // The late watch (if any) holds the sender; it is dropped when that watch ends undecided.
            hub::ApprovalOutcome::Timeout => late_rx.await.ok().as_ref().and_then(decision_of),
            hub::ApprovalOutcome::Cancelled | hub::ApprovalOutcome::Unavailable(_) | hub::ApprovalOutcome::Error(_) => None,
        };
        withdraw.approver = None;
        answer
    }

    fn describe(&self) -> Vec<String> {
        if self.described.is_empty() { vec!["device-hub".into()] } else { self.described.clone() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::approval::{Question, Target};

    fn request() -> ApprovalRequest {
        ApprovalRequest::new(
            Question {
                client: "c".into(),
                machine: "m".into(),
                session: "s".into(),
                agent: "a".into(),
                workspace: "w".into(),
                target: Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() },
                tool: "click".into(),
                risk: "R1".into(),
            },
            crate::approval::now_ms(),
        )
        .unwrap()
    }

    /// The host's request is the hub's request, byte for byte (the same digest).
    #[test]
    fn the_hosts_request_is_the_hubs_request() {
        let request = request();
        let converted: hub::ApprovalRequest = serde_json::from_value(request.to_value()).unwrap();
        assert!(converted.digest_is_valid());
        assert_eq!(converted.digest, request.digest);
    }

    struct Answers(Mutex<Vec<String>>, hub::ApprovalOutcome);

    #[async_trait]
    impl hub::RemoteApprover for Answers {
        async fn ask(&self, ask: hub::ApprovalAsk) -> hub::ApprovalOutcome {
            if let (hub::ApprovalOutcome::Timeout, Some(on_late)) = (&self.1, ask.on_late) {
                on_late(hub::VerifiedDecision {
                    approval_id: "a".into(),
                    decision: hub::Decision::Once,
                    digest: ask.request.digest.clone(),
                    decider_id: "phone".into(),
                    decider_platform: hub::Platform::Ios,
                });
            }
            self.1.clone()
        }
        async fn cancel(&self, nonce: &str) {
            self.0.lock().unwrap().push(nonce.to_owned());
        }
    }

    #[tokio::test]
    async fn a_late_decision_answers() {
        let request = request();
        let late = Arc::new(Answers(Mutex::new(Vec::new()), hub::ApprovalOutcome::Timeout));
        let remote = HubRemote::new(late.clone(), false, vec![]);
        let answer = remote.ask(&request).await.unwrap();
        assert_eq!((answer.decision, answer.via.as_str(), answer.digest), (Decision::Once, "phone", request.digest));
        assert!(late.0.lock().unwrap().is_empty(), "an answered question is not withdrawn");
    }

    /// Another collector answered first: the host drops the future and the hub question is withdrawn.
    #[tokio::test]
    async fn a_dropped_ask_withdraws_the_hub_question() {
        struct Never(Arc<Mutex<Vec<String>>>);
        #[async_trait]
        impl hub::RemoteApprover for Never {
            async fn ask(&self, _ask: hub::ApprovalAsk) -> hub::ApprovalOutcome {
                std::future::pending().await
            }
            async fn cancel(&self, nonce: &str) {
                self.0.lock().unwrap().push(nonce.to_owned());
            }
        }
        let request = request();
        let cancels = Arc::new(Mutex::new(Vec::new()));
        let remote = HubRemote::new(Arc::new(Never(Arc::clone(&cancels))), false, vec![]);
        let _ = tokio::time::timeout(std::time::Duration::from_millis(10), remote.ask(&request)).await;
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(*cancels.lock().unwrap(), vec![request.nonce.clone()]);
    }

    /// Fail closed: no hub or no pinned approver is no collector, and status says why.
    #[test]
    fn no_pins_no_collector() {
        assert!(matches!(HubState::of(&Ok(ComputerUseConfig::default())), HubState::Off(_)));
        let mut config = ComputerUseConfig {
            device_hub: Some(DeviceHubConfig {
                url: "https://hub.example".into(),
                token_command: "/usr/bin/t".into(),
                allow_always: false,
            }),
            ..ComputerUseConfig::default()
        };
        let off = HubState::of(&Ok(config.clone()));
        assert!(matches!(&off, HubState::Off(reason) if reason.contains("--approver")), "{off:?}");
        config.approvers.push(PinnedApprover {
            device_id: "d".into(),
            approval_key_fingerprint: "a".repeat(64),
            name: "iPhone".into(),
            platform: "ios".into(),
        });
        assert_eq!(HubState::of(&Ok(config.clone())), HubState::Ready);
        assert_eq!(describe(&config.approvers), vec!["phone".to_owned()]);
        assert_eq!(HubState::Ready.status(&Ok(config))["approvers"][0]["fingerprint"].as_str().map(str::len), Some(39));
    }
}
