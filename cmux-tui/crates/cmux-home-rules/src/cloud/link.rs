//! The cloud link's lease state machine (`HomeCloudLink.swift`,
//! home-cloud-proxy.md section 2): which link the source acts on, when the
//! daemon's session lease is renewed, the retry backoff of a failed lease,
//! and the cooldown that spaces forced renewals.
//!
//! `step(state, event) -> (state, effects)`. Swift runs the effects in order:
//! it configures the source, starts lease work (`sync`, `renew`) and arms
//! the two timers; each one's outcome comes back as an event.

use serde::{Deserialize, Serialize};

/// The first wait before a failed lease is tried again; doubled per failure.
pub const FIRST_RETRY_MS: u64 = 1_000;
/// The longest retry wait, and the longest forced-renewal wait.
pub const MAX_RETRY_MS: u64 = 60_000;
/// How many replaced lease expiries are kept.
pub const REPLACED_EXPIRY_LIMIT: usize = 8;

/// The chat server (`HomeCloudServer`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Server {
    /// The build's cmux Cloud with the Stack account.
    #[default]
    Hosted,
    /// A self-hosted server at this URL.
    SelfHosted { url: String },
}

/// The daemon connection and the account it serves (`HomeCloudLink.Link`).
/// Two links are equal when all but `hasEndpoint` match.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    /// Whether the link has a cloud transport.
    #[serde(default)]
    pub has_endpoint: bool,
    /// The connection the endpoint talks over (any stable token).
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub user_id: Option<String>,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub server: Server,
}

impl PartialEq for Link {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
            && self.user_id == other.user_id
            && self.display_name == other.display_name
            && self.server == other.server
    }
}

/// The person a self-hosted server named (`CloudSelfHostInfo`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfHostInfo {
    pub user_id: String,
    #[serde(default)]
    pub login: String,
    #[serde(default)]
    pub display_name: Option<String>,
}

/// What lease work ended with (`HomeCloudLease.Outcome`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Outcome {
    #[serde(rename_all = "camelCase")]
    Leased {
        subject: String,
        expires_at: u64,
    },
    SelfHosted {
        info: SelfHostInfo,
    },
    SignedOut,
    Failed,
    Superseded,
}

/// The identity the source acts as (`CloudIdentity`): Swift adds the local
/// participant, and the Stack project unless `selfHosted`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub stack_user_id: String,
    pub display_name: String,
    pub self_hosted: bool,
}

/// Which commands `source.configure` gets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Commands {
    /// No transport (`commands: nil`).
    None,
    /// The endpoint of the link named in the effect.
    Endpoint,
}

/// The cooldown timer between forced renewals.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "phase", rename_all = "camelCase")]
pub enum Cooldown {
    #[default]
    Idle,
    /// Its first `FIRST_RETRY_MS`; `restMs` runs after it.
    #[serde(rename_all = "camelCase")]
    Floor { rest_ms: u64, proven: bool },
    /// The rest of it.
    Rest,
}

/// The link's state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    #[serde(default)]
    pub last: Option<Link>,
    /// Lease work started and not finished.
    #[serde(default)]
    pub leasing: u32,
    #[serde(default = "first_retry")]
    pub retry_delay_ms: u64,
    /// The reason the pending retry renews with; `None`: no retry pending.
    #[serde(default)]
    pub retry_reason: Option<String>,
    #[serde(default)]
    pub leased_expiry: Option<u64>,
    #[serde(default)]
    pub replaced_expiries: Vec<u64>,
    #[serde(default)]
    pub forced_wait_ms: u64,
    #[serde(default)]
    pub cooldown: Cooldown,
    #[serde(default)]
    pub pending_forced: Option<String>,
}

fn first_retry() -> u64 {
    FIRST_RETRY_MS
}

impl Default for State {
    fn default() -> Self {
        State {
            last: None,
            leasing: 0,
            retry_delay_ms: FIRST_RETRY_MS,
            retry_reason: None,
            leased_expiry: None,
            replaced_expiries: Vec::new(),
            forced_wait_ms: 0,
            cooldown: Cooldown::Idle,
            pending_forced: None,
        }
    }
}

/// What happened.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    /// `apply(link)`: one observed link.
    Apply { link: Link },
    /// The `sync` effect's lease work ended.
    Synced { link: Link, outcome: Outcome },
    /// `cloud-session-needed`.
    #[serde(rename_all = "camelCase")]
    SessionNeeded {
        reason: String,
        #[serde(default)]
        expires_at: Option<u64>,
    },
    /// The source refused an op or read for a missing lease.
    LeaseMissing,
    /// A reply or a live socket came through the current lease.
    LeaseProven,
    /// The `renew` effect's lease work ended.
    Renewed {
        reason: String,
        #[serde(default)]
        answering: Option<u64>,
        link: Link,
        outcome: Outcome,
    },
    /// The retry timer fired.
    RetryFired,
    /// The cooldown timer fired.
    CooldownFired,
}

/// What Swift does, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Effect {
    /// `source.rename(identity)`.
    Rename {
        identity: Identity,
    },
    /// `source.configure(commands:link:identity:leased:)`; `link` names
    /// the link whose endpoint and id to pass (`None`: id nil).
    Configure {
        commands: Commands,
        link: Option<Link>,
        identity: Option<Identity>,
        leased: bool,
    },
    /// `lease.sync(endpoint, expectedUserID:, server:)`, then `synced`.
    #[serde(rename_all = "camelCase")]
    Sync {
        link: Link,
        expected_user_id: Option<String>,
    },
    /// `lease.renew(endpoint, reason:, server:)`, then `renewed`.
    #[serde(rename_all = "camelCase")]
    Renew {
        reason: String,
        answering: Option<u64>,
        link: Link,
        force_refresh: bool,
    },
    /// `source.leaseRenewed(subject:)`.
    LeaseRenewed {
        subject: String,
    },
    #[serde(rename_all = "camelCase")]
    ScheduleRetry {
        after_ms: u64,
    },
    CancelRetry,
    #[serde(rename_all = "camelCase")]
    ScheduleCooldown {
        after_ms: u64,
    },
    CancelCooldown,
}

/// `missing` takes the current token; the others refresh it.
pub fn is_forced(reason: &str) -> bool {
    reason != "missing"
}

struct Machine {
    s: State,
    fx: Vec<Effect>,
}

impl Machine {
    fn set_leased_expiry(&mut self, value: Option<u64>) {
        let old = self.s.leased_expiry;
        self.s.leased_expiry = value;
        if let Some(old) = old
            && Some(old) != value
        {
            self.answered(old);
        }
    }

    fn answered(&mut self, expiry: u64) {
        let list = &mut self.s.replaced_expiries;
        list.retain(|e| *e != expiry);
        list.push(expiry);
        if list.len() > REPLACED_EXPIRY_LIMIT {
            list.remove(0);
        }
    }

    fn cancel_retry(&mut self) {
        self.s.retry_reason = None;
        self.fx.push(Effect::CancelRetry);
    }

    fn cancel_cooldown(&mut self) {
        self.s.cooldown = Cooldown::Idle;
        self.fx.push(Effect::CancelCooldown);
    }

    fn identity(user_id: Option<&str>, link: &Link) -> Option<Identity> {
        user_id.map(|id| Identity {
            stack_user_id: id.to_owned(),
            display_name: link.display_name.clone(),
            self_hosted: false,
        })
    }

    fn self_hosted_identity(info: &SelfHostInfo) -> Identity {
        let name = info
            .display_name
            .clone()
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| info.login.clone());
        Identity { stack_user_id: info.user_id.clone(), display_name: name, self_hosted: true }
    }

    fn configure(&mut self, link: Option<&Link>, identity: Option<Identity>, leased: bool) {
        self.fx.push(Effect::Configure {
            commands: if link.is_some_and(|l| l.has_endpoint) {
                Commands::Endpoint
            } else {
                Commands::None
            },
            link: link.cloned(),
            identity,
            leased,
        });
    }

    fn apply(&mut self, link: Link) {
        if self.s.last.as_ref() == Some(&link) {
            return;
        }
        if let Some(prev) = &self.s.last
            && prev.id == link.id
            && prev.server == link.server
            && (prev.user_id == link.user_id || link.server != Server::Hosted)
        {
            let rename = (link.server == Server::Hosted)
                .then(|| Self::identity(link.user_id.as_deref(), &link))
                .flatten();
            self.s.last = Some(link);
            if let Some(identity) = rename {
                self.fx.push(Effect::Rename { identity });
            }
            return;
        }
        if let Some(prev) = self.s.last.clone()
            && (prev.server != link.server
                || (prev.user_id.is_some() && prev.user_id != link.user_id))
        {
            // Swift's default `leased: true`.
            self.configure(Some(&prev), None, true);
        }
        self.s.last = Some(link.clone());
        self.cancel_retry();
        self.s.retry_delay_ms = FIRST_RETRY_MS;
        self.cancel_cooldown();
        self.s.pending_forced = None;
        self.s.forced_wait_ms = 0;
        self.set_leased_expiry(None);
        self.s.replaced_expiries.clear();
        if !link.has_endpoint {
            let identity = Self::identity(link.user_id.as_deref(), &link);
            self.configure(None, identity, false);
            return;
        }
        self.s.leasing += 1;
        self.fx.push(Effect::Sync { expected_user_id: link.user_id.clone(), link });
    }

    fn synced(&mut self, link: Link, outcome: Outcome) {
        self.s.leasing = self.s.leasing.saturating_sub(1);
        match &outcome {
            Outcome::Leased { subject, expires_at } => {
                self.set_leased_expiry(Some(*expires_at));
                let identity = Self::identity(Some(subject), &link);
                self.configure(Some(&link), identity, true);
            }
            Outcome::SelfHosted { info } => {
                self.configure(Some(&link), Some(Self::self_hosted_identity(info)), true);
            }
            Outcome::SignedOut => self.configure(Some(&link), None, true),
            Outcome::Failed | Outcome::Superseded => {
                let pending = (link.server == Server::Hosted)
                    .then(|| Self::identity(link.user_id.as_deref(), &link))
                    .flatten();
                self.configure(Some(&link), pending, false);
            }
        }
        self.settled(&outcome, "missing");
    }

    fn session_needed(&mut self, reason: String, expires_at: Option<u64>) {
        if let Some(e) = expires_at
            && self.s.replaced_expiries.contains(&e)
        {
            return;
        }
        if self.s.leasing != 0 {
            return;
        }
        if is_forced(&reason) && self.s.cooldown != Cooldown::Idle {
            self.s.pending_forced = Some(reason);
            return;
        }
        self.renew(reason, expires_at);
    }

    fn lease_missing(&mut self) {
        if self.s.leasing != 0 {
            return;
        }
        self.cancel_retry();
        self.renew("missing".to_owned(), None);
    }

    fn lease_proven(&mut self) {
        self.s.forced_wait_ms = 0;
        if let Cooldown::Floor { proven, .. } = &mut self.s.cooldown {
            *proven = true;
            return;
        }
        self.cancel_cooldown();
        self.send_pending_forced();
    }

    fn send_pending_forced(&mut self) {
        if self.s.leasing != 0 || self.s.cooldown != Cooldown::Idle {
            return;
        }
        let Some(reason) = self.s.pending_forced.take() else {
            return;
        };
        self.renew(reason, None);
    }

    fn renew(&mut self, reason: String, answering: Option<u64>) {
        let Some(current) = self.s.last.clone().filter(|l| l.has_endpoint) else {
            return;
        };
        self.s.leasing += 1;
        self.fx.push(Effect::Renew {
            force_refresh: is_forced(&reason),
            reason,
            answering,
            link: current,
        });
    }

    fn renewed(&mut self, reason: String, answering: Option<u64>, link: Link, outcome: Outcome) {
        if let Outcome::Leased { subject, expires_at } = &outcome {
            if let Some(expiry) = answering
                && expiry != *expires_at
            {
                self.answered(expiry);
            }
            self.set_leased_expiry(Some(*expires_at));
            self.fx.push(Effect::LeaseRenewed { subject: subject.clone() });
        }
        if let Outcome::SelfHosted { info } = &outcome
            && let Some(last) = &self.s.last
            && last.id == link.id
            && last.server == link.server
        {
            let identity = Self::self_hosted_identity(info);
            self.configure(Some(&link), Some(identity), true);
        }
        self.s.leasing = self.s.leasing.saturating_sub(1);
        if matches!(outcome, Outcome::Leased { .. }) && is_forced(&reason) {
            self.start_cooldown();
        }
        self.settled(&outcome, &reason);
        self.send_pending_forced();
    }

    fn start_cooldown(&mut self) {
        self.s.forced_wait_ms = if self.s.forced_wait_ms == 0 {
            FIRST_RETRY_MS
        } else {
            (self.s.forced_wait_ms * 2).min(MAX_RETRY_MS)
        };
        let rest_ms = self.s.forced_wait_ms - FIRST_RETRY_MS;
        self.s.cooldown = Cooldown::Floor { rest_ms, proven: false };
        self.fx.push(Effect::ScheduleCooldown { after_ms: FIRST_RETRY_MS });
    }

    fn cooldown_fired(&mut self) {
        match std::mem::take(&mut self.s.cooldown) {
            Cooldown::Idle => {}
            Cooldown::Floor { rest_ms, proven } => {
                if proven || rest_ms == 0 {
                    self.send_pending_forced();
                } else {
                    self.s.cooldown = Cooldown::Rest;
                    self.fx.push(Effect::ScheduleCooldown { after_ms: rest_ms });
                }
            }
            Cooldown::Rest => self.send_pending_forced(),
        }
    }

    fn retry_fired(&mut self) {
        let Some(reason) = self.s.retry_reason.take() else {
            return;
        };
        if self.s.leasing != 0 {
            return;
        }
        self.renew(reason, None);
    }

    fn settled(&mut self, outcome: &Outcome, reason: &str) {
        match outcome {
            Outcome::Leased { .. } | Outcome::SelfHosted { .. } => {
                self.cancel_retry();
                self.s.retry_delay_ms = FIRST_RETRY_MS;
            }
            Outcome::Failed => {
                if self.s.retry_reason.is_some() {
                    return;
                }
                let delay = self.s.retry_delay_ms;
                self.s.retry_delay_ms = (delay * 2).min(MAX_RETRY_MS);
                self.s.retry_reason = Some(reason.to_owned());
                self.fx.push(Effect::ScheduleRetry { after_ms: delay });
            }
            Outcome::SignedOut | Outcome::Superseded => {}
        }
    }
}

/// One step of the link.
pub fn step(state: State, event: Event) -> (State, Vec<Effect>) {
    let mut m = Machine { s: state, fx: Vec::new() };
    match event {
        Event::Apply { link } => m.apply(link),
        Event::Synced { link, outcome } => m.synced(link, outcome),
        Event::SessionNeeded { reason, expires_at } => m.session_needed(reason, expires_at),
        Event::LeaseMissing => m.lease_missing(),
        Event::LeaseProven => m.lease_proven(),
        Event::Renewed { reason, answering, link, outcome } => {
            m.renewed(reason, answering, link, outcome);
        }
        Event::RetryFired => m.retry_fired(),
        Event::CooldownFired => m.cooldown_fired(),
    }
    (m.s, m.fx)
}

/// `cloud.link_step` request.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepRequest {
    #[serde(default)]
    pub state: State,
    pub event: Event,
}

/// `cloud.link_step` reply.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepReply {
    pub state: State,
    pub effects: Vec<Effect>,
}
