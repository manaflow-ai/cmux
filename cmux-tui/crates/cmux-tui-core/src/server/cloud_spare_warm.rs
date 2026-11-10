//! `cloud-spare-warm` (`cloud-spare-warm-v1`): the app's Cloud intent (it came to the front
//! signed in, the composer picked Cloud, a reserve or a claim named a machine) as one daemon
//! command. Leo, 2026-11-10, about the Swift warm that froze NIGHTLY's main thread in a pipe
//! write: "Why is this even in Swift anyways mang".
//!
//! The daemon decides the rest, in Rust, on a worker thread: whether to warm (the throttle and the
//! ledger of cmux-tui's `link/start_chat_cli/spare_warm.rs`), the warm or claim call, and the
//! headless Claude login copy onto the warmed or claimed machine (the gate, the remote switch, the
//! machine's reads, the Keychain read and the transfer). The answer is the ledger's, sent as soon
//! as it is written (a claim's at once, a warm's after the platform call); the copy runs after it
//! on its own thread, and reports its end to the same ledger, which a start's `wait-copy` reads.
//!
//! Only the verified app may send it: it carries the person's session and install tokens, which
//! the daemon uses for this one warm and never keeps.

use std::sync::{Arc, Mutex, PoisonError};

use serde::Deserialize;
use serde_json::Value;

use super::cloud_conversations::is_app_client;
use crate::Mux;
use crate::cloud_conversations::{CloudConversations, CloudError};

/// `identify` advertises it once the binary installed a [`SpareWarmService`].
pub const CAPABILITY: &str = "cloud-spare-warm-v1";

/// What the app knows and the daemon cannot read itself: the tokens it holds, and the settings it
/// keeps in its own defaults and cmux.json. Every rule over them is the daemon's.
#[derive(Deserialize, Clone, Default)]
#[serde(deny_unknown_fields)]
pub struct SpareWarmParams {
    /// The platform origin the warm calls (the app's artifacts API base URL).
    pub platform: String,
    /// The cmux API the copy's machine routes and the Release remote switch call (the app's
    /// owner API base URL).
    pub api: String,
    /// The person's Stack session token (the platform's and the machine routes' bearer).
    pub access_token: String,
    /// The install token, whose `team` claim is the backend team the spare is warmed in.
    pub install_token: String,
    /// The signed-in Stack user id.
    pub account: String,
    /// The machine a reserve's or a claim's answer named: no warm, the copy onto it.
    #[serde(default)]
    pub claimed: Option<String>,
    /// The selected Stack team (nil: personal), whose cached login is read first.
    #[serde(default)]
    pub team: Option<String>,
    /// The person's teams, whose cached logins are read after the selected team's; their personal
    /// login is always read last ([`SpareWarmParams::login_scopes`]).
    #[serde(default)]
    pub login_teams: Vec<String>,
    /// DEV and dogfood builds (`DevTools.isEnabled`).
    #[serde(default)]
    pub dogfood: bool,
    /// `cmux.cloud.passHarnessLogin` from the app's defaults, when set.
    #[serde(default)]
    pub setting: Option<bool>,
    /// The person's kept login choice (`pass`, `machine`, `none`), when they made one.
    #[serde(default)]
    pub stored_choice: Option<String>,
    /// The person's one-time Release consent from cmux.json, when asked.
    #[serde(default)]
    pub consent: Option<bool>,
}

impl SpareWarmParams {
    /// Every scope the person's cached login may sit under, in order: the selected team (None:
    /// personal), their other teams, then personal.
    pub fn login_scopes(&self) -> Vec<Option<String>> {
        let mut scopes = vec![self.team.clone()];
        for scope in self.login_teams.iter().cloned().map(Some).chain([None]) {
            if !scopes.contains(&scope) {
                scopes.push(scope);
            }
        }
        scopes
    }
}

impl std::fmt::Debug for SpareWarmParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SpareWarmParams")
            .field("platform", &self.platform)
            .field("api", &self.api)
            .field("access_token", &"[redacted]")
            .field("install_token", &"[redacted]")
            .field("account", &self.account)
            .field("claimed", &self.claimed)
            .field("dogfood", &self.dogfood)
            .finish_non_exhaustive()
    }
}

/// `cloud-start-chat-reservation` (`cloud-start-chat-reservation-v1`): the composer's reservation
/// (`cloud.reserve`, `cloud.releaseReservation`), which the App ran as a child process on every
/// compose. `request` is the page's object (`composeKey`, `environment`) with the app's `platform`.
#[derive(Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct ReservationParams {
    pub release: bool,
    pub request: Value,
    pub access_token: String,
    pub install_token: String,
}

impl std::fmt::Debug for ReservationParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReservationParams").field("release", &self.release).finish_non_exhaustive()
    }
}

/// `identify` advertises it with [`CAPABILITY`].
pub const RESERVATION_CAPABILITY: &str = "cloud-start-chat-reservation-v1";

/// `cloud-spare-warm-consent` (`cloud-spare-warm-v1`): the person's one-time Release consent, which
/// the app sends at once and again on every change, so a copy in flight reads it right before its
/// write and a change ends it.
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(deny_unknown_fields)]
pub struct ConsentParams {
    /// The consent in the person's cmux-next.json (null: never asked, or managed).
    #[serde(default)]
    pub consent: Option<bool>,
}

/// What every copy in flight reads again: the app's latest consent, and an epoch a change of it moves.
#[derive(Default)]
pub(crate) struct SpareWarmControl {
    state: Mutex<ControlState>,
}

#[derive(Default, Clone, Copy)]
struct ControlState {
    epoch: u64,
    /// None until the app first sent it (a daemon that just started).
    consent: Option<Option<bool>>,
}

impl SpareWarmControl {
    fn now(&self) -> ControlState {
        *self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The app's consent now; a changed one ends every copy begun before it.
    pub(crate) fn set_consent(&self, consent: Option<bool>) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.consent.is_some_and(|old| old != consent) {
            state.epoch += 1;
        }
        state.consent = Some(consent);
    }
}

/// What a login copy in flight asks before it reads anything and again right before its write.
pub trait CopyGuard: Send + Sync {
    /// Whether `account` is still the leased person and nothing since (a sign-out, a switch of
    /// account, a change of consent) ended the copy: false ends it as abandoned.
    fn still(&self, account: &str) -> bool;
    /// The person's consent now: the app's latest, else the one its warm carried.
    fn consent(&self) -> Option<bool>;
}

/// The daemon's guard: the lease and the control as they were when the warm came.
struct LiveGuard {
    account: String,
    /// The lease and its person epoch then; no conversations service: no person, so no copy.
    lease: Option<(CloudConversations, u64)>,
    control: Arc<SpareWarmControl>,
    epoch: u64,
    consent: Option<bool>,
}

impl LiveGuard {
    fn new(
        lease: Option<CloudConversations>,
        control: Arc<SpareWarmControl>,
        params: &SpareWarmParams,
    ) -> Self {
        let lease = lease.map(|lease| {
            let epoch = lease.lease_person_epoch();
            (lease, epoch)
        });
        let epoch = control.now().epoch;
        Self { account: params.account.clone(), lease, control, epoch, consent: params.consent }
    }
}

impl CopyGuard for LiveGuard {
    fn still(&self, copy_account: &str) -> bool {
        if copy_account != self.account || self.control.now().epoch != self.epoch {
            return false;
        }
        // Fails closed: only the account the daemon leases now, under the same person epoch as when
        // the warm came, goes on. No lease (never sent, cleared, an agent's or a tailnet's) is no
        // person, so a warm that reached the daemon after a sign-out copies nothing.
        self.lease.as_ref().is_some_and(|(lease, epoch)| {
            lease.lease_person_epoch() == *epoch
                && lease.lease_person().is_some_and(|(sub, _)| sub == copy_account)
        })
    }

    fn consent(&self) -> Option<bool> {
        self.control.now().consent.unwrap_or(self.consent)
    }
}

/// The warm and the reservation, which the binary that has the Cloud transport and the ledger installs.
pub trait SpareWarmService: Send + Sync {
    /// The platform's answer to a reservation or its release, as `cmux link start-chat reserve|release` prints it.
    fn reservation(&self, params: ReservationParams) -> Value;

    /// Answers the ledger's answer once it is written, and starts the login copy it hands out (if
    /// any) on its own thread. `guard` says whether the copy may go on ([`CopyGuard`]): false ends
    /// it as abandoned, so the next warm answers it again.
    fn warm(&self, params: SpareWarmParams, guard: Arc<dyn CopyGuard>) -> Value;
}

/// The command, on a cloud request worker thread (`cloud_conversations::is_network`).
pub(super) fn handle(mux: &Mux, client: u64, params: SpareWarmParams) -> anyhow::Result<Value> {
    if !is_app_client(mux, client) {
        return Err(forbidden().into());
    }
    let Some(service) = mux.spare_warm() else {
        return Err(CloudError::Unavailable("this daemon has no Cloud spare warm".into()).into());
    };
    let guard =
        LiveGuard::new(mux.cloud_conversations().cloned(), mux.spare_warm_control(), &params);
    Ok(service.warm(params, Arc::new(guard)))
}

/// `cloud-spare-warm-consent`, on the request loop: records the app's consent.
pub(super) fn consent(mux: &Mux, client: u64, params: ConsentParams) -> anyhow::Result<Value> {
    if !is_app_client(mux, client) {
        return Err(forbidden().into());
    }
    mux.spare_warm_control().set_consent(params.consent);
    Ok(serde_json::json!({"ok": true}))
}

/// `cloud-start-chat-reservation`, on a cloud request worker thread.
pub(super) fn reservation(
    mux: &Mux,
    client: u64,
    params: ReservationParams,
) -> anyhow::Result<Value> {
    if !is_app_client(mux, client) {
        return Err(forbidden().into());
    }
    let Some(service) = mux.spare_warm() else {
        return Err(CloudError::Unavailable("this daemon has no Cloud reservation".into()).into());
    };
    Ok(service.reservation(params))
}

/// The refusal for a connection that is not the verified app.
pub(super) fn forbidden() -> CloudError {
    CloudError::Rejected {
        code: "forbidden".into(),
        message: "cloud-spare-warm, cloud-spare-warm-consent and cloud-start-chat-reservation require the verified cmux app connection".into(),
        retryable: false,
    }
}

#[cfg(test)]
#[path = "cloud_spare_warm_tests.rs"]
mod tests;
