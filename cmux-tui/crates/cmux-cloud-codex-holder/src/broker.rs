//! One holder for one account scope. All login, access and refresh requests are serialized
//! through the private holder process, so no machine can race its rotating Codex auth cache.
//!
//! Shared state lives under one lock that is never held across an await, the way the Swift
//! actor's state was only consistent between suspension points: every check after an await
//! (scope, generation, pending revocation) is kept. Delivery and revocation: `broker_files.rs`;
//! renewal, catch-up, shutdown and quit: `broker_renewal.rs`.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures_util::FutureExt as _;
use futures_util::future::{BoxFuture, Shared};
use serde_json::Value;

use crate::cx::{Cx, Job};
use crate::error::{BrokerError, Error};
use crate::record::Record;
use crate::session::{Session, SessionError};
use crate::target::{PROTOCOL_VERSION, TargetRef};
use crate::types::{Grant, Prompt, Scope, now, valid_expiry};

/// The current scope, or none while signed out or fenced.
pub type CurrentScope = Arc<dyn Fn() -> Option<Scope> + Send + Sync>;
/// The Mac's own Codex access, when the person allowed it (`local_access`).
pub type LocalSignIn = Arc<dyn Fn() -> BoxFuture<'static, Option<Grant>> + Send + Sync>;

/// The local tools a holder runs.
#[derive(Clone, Debug)]
pub struct Launch {
    pub executable: PathBuf,
    pub prefix: Vec<String>,
    pub codex: PathBuf,
    pub environment: HashMap<String, String>,
    pub user_home: PathBuf,
}

/// One private broker request's hard bound.
const REQUEST_BOUND: Duration = Duration::from_secs(15);
pub const RENEWAL_RETRY_CAP: Duration = Duration::from_secs(300);

pub(crate) type RefreshResult = Shared<BoxFuture<'static, Result<Grant, Error>>>;

#[derive(Default)]
pub(crate) struct State {
    pub(crate) holder_id: Option<String>,
    /// When the scheduled renewal runs; a machine taken back whose access ends sooner renews at once.
    pub(crate) next_renewal_at: Option<f64>,
    pub(crate) session: Option<Arc<Session>>,
    pub(crate) stopped: bool,
    /// Set by `detach`: a quit or an update, after which delivered access stays where it is.
    pub(crate) detached: bool,
    pub(crate) cached: Option<Grant>,
    /// Whether `cached` came from the Mac's own Codex.
    pub(crate) cached_is_local: bool,
    pub(crate) previous_mode: HashMap<String, Option<Vec<u8>>>,
    pub(crate) loaded_previous_mode: HashSet<String>,
    pub(crate) installed: HashMap<String, Vec<u8>>,
    pub(crate) uncertain: HashMap<String, (Option<Vec<u8>>, Vec<u8>)>,
    pub(crate) pending_stage: HashMap<String, BTreeSet<String>>,
    pub(crate) removal_attempted: HashSet<String>,
    pub(crate) targets: HashMap<String, TargetRef>,
    pub(crate) generations: HashMap<String, u64>,
    pub(crate) pending_revocations: HashSet<String>,
    pub(crate) revocation_targets: HashMap<String, TargetRef>,
    pub(crate) refresh_task: Option<Job>,
    /// Machines taken back after a relaunch whose catch-up failed, each with its retry.
    pub(crate) catch_ups: HashMap<String, (u64, Job)>,
    pub(crate) next_token: u64,
    pub(crate) refresh_cycle: u64,
    pub(crate) refresh_in_flight: Option<(u64, RefreshResult, Cx)>,
    pub(crate) local_sign_in: Option<LocalSignIn>,
}

impl State {
    pub(crate) fn generation(&self, id: &str) -> u64 {
        self.generations.get(id).copied().unwrap_or(0)
    }

    pub(crate) fn bump(&mut self, id: &str) {
        let next = self.generation(id).saturating_add(1);
        self.generations.insert(id.to_owned(), next);
    }

    pub(crate) fn token(&mut self) -> u64 {
        self.next_token = self.next_token.saturating_add(1);
        self.next_token
    }
}

pub struct Broker {
    pub(crate) scope: Scope,
    pub(crate) current_scope: CurrentScope,
    pub(crate) launch: Launch,
    pub(crate) home: PathBuf,
    /// The machines this holder delivered to, on disk, so the next run renews or erases them.
    pub(crate) record: Record,
    pub(crate) renewal_retry_base: Duration,
    pub(crate) state: Mutex<State>,
    target_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl Drop for Broker {
    fn drop(&mut self) {
        let state = self.st();
        if let Some(job) = &state.refresh_task {
            job.cancel();
        }
        for (_, job) in state.catch_ups.values() {
            job.cancel();
        }
    }
}

impl Broker {
    pub fn new(
        scope: Scope,
        current_scope: CurrentScope,
        launch: Launch,
        home: PathBuf,
        renewal_retry_base: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            record: Record::new(&home),
            scope,
            current_scope,
            launch,
            home,
            renewal_retry_base,
            state: Mutex::new(State::default()),
            target_locks: Mutex::new(HashMap::new()),
        })
    }

    pub(crate) fn st(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub(crate) fn in_scope(&self) -> bool {
        (self.current_scope)().as_ref() == Some(&self.scope)
    }

    /// Where the Mac's own Codex access is read; asked before the private holder.
    pub fn set_local_sign_in(&self, source: Option<LocalSignIn>) {
        self.st().local_sign_in = source;
    }

    pub fn registered_machine_ids(&self) -> HashSet<String> {
        self.st().targets.keys().cloned().collect()
    }

    /// When the scheduled renewal runs (tests).
    pub fn scheduled_renewal(&self) -> Option<f64> {
        self.st().next_renewal_at
    }

    /// Starts the browser device-code flow. The caller shows this prompt in cmux and then
    /// calls `wait_for_login_and_transfer`, without opening a machine terminal.
    pub async fn login(
        &self,
        cx: &Cx,
        target: &TargetRef,
        confirmed: bool,
    ) -> Result<Prompt, Error> {
        self.validate(cx, target, confirmed).await?;
        self.ensure_scope(cx)?;
        let response = self.request(cx, "login", None, None).await?;
        self.ensure_scope(cx)?;
        let url = response.get("verificationUrl").and_then(Value::as_str).unwrap_or_default();
        let code = response.get("userCode").and_then(Value::as_str).unwrap_or_default();
        let https = url.strip_prefix("https://").is_some_and(|rest| !rest.is_empty());
        if !https || code.is_empty() || code.len() >= 64 {
            return Err(BrokerError::InvalidReply.into());
        }
        Ok(Prompt { verification_url: url.to_owned(), user_code: code.to_owned() })
    }

    /// Polls the local holder after the person completes the browser flow, then delivers
    /// access-only JSON to the machine. A failure erases what this left there.
    pub async fn wait_for_login_and_transfer(
        self: &Arc<Self>,
        cx: &Cx,
        target: &TargetRef,
        confirmed: bool,
        timeout: Duration,
    ) -> Result<Grant, Error> {
        let result = async {
            let id = target.machine_id();
            let generation = self.st().generation(id);
            self.validate(cx, target, confirmed).await?;
            let deadline = tokio::time::Instant::now() + timeout;
            while tokio::time::Instant::now() < deadline {
                {
                    let state = self.st();
                    if state.pending_revocations.contains(id) || state.generation(id) != generation
                    {
                        return Err(BrokerError::Cancelled.into());
                    }
                }
                match self.transfer(cx, target, confirmed, true).await {
                    Err(error) if error.is(BrokerError::NotAuthenticated) => {
                        // wakeup-allow: bounded device-login polling while the holder completes browser auth.
                        cx.sleep(Duration::from_secs(2)).await?;
                    }
                    other => return other,
                }
            }
            Err(BrokerError::Cancelled.into())
        }
        .await;
        if result.is_err() {
            // Cleanup must complete even when the initiating task was cancelled.
            let _ = self.revoke(&Cx::never(), target, false).await;
        }
        result
    }

    /// Reuses a cached short-lived grant when possible; otherwise asks the local holder to
    /// refresh and writes only the new access token.
    pub async fn transfer(
        self: &Arc<Self>,
        cx: &Cx,
        target: &TargetRef,
        confirmed: bool,
        force_refresh: bool,
    ) -> Result<Grant, Error> {
        let id = target.machine_id().to_owned();
        let generation = self.st().generation(&id);
        self.validate(cx, target, confirmed).await?;
        self.ensure_scope(cx)?;
        {
            let mut state = self.st();
            if state.pending_revocations.contains(&id) || state.generation(&id) != generation {
                return Err(BrokerError::Cancelled.into());
            }
            state.targets.insert(id.clone(), target.clone());
            state.generations.insert(id, generation);
        }
        if !force_refresh && self.cached_still_allowed().await {
            let cached = self.current_cache();
            if let Some(cached) = cached {
                self.deliver(cx, &cached, target, Some(generation)).await?;
                return Ok(cached);
            }
        }
        let grant = self.refresh_access(true).await?;
        self.deliver(cx, &grant, target, Some(generation)).await?;
        Ok(grant)
    }

    /// One refresh at a time: a second caller waits for the one in flight. Like the Swift
    /// holder's unstructured task, a caller's cancel does not end it; shutdown does.
    pub(crate) async fn refresh_access(self: &Arc<Self>, schedule: bool) -> Result<Grant, Error> {
        // The check and the claim are one step under the state lock, so two callers on different
        // workers never both start a refresh (each would rotate the Codex credential).
        let (shared, token) = {
            let mut state = self.st();
            if let Some((_, shared, _)) = state.refresh_in_flight.as_ref() {
                (shared.clone(), None)
            } else {
                let cx = Cx::new();
                let weak = Arc::downgrade(self);
                let task_cx = cx.clone();
                let handle = tokio::spawn(async move {
                    match weak.upgrade() {
                        Some(this) => this.perform_refresh(&task_cx).await,
                        None => Err(BrokerError::BrokerUnavailable.into()),
                    }
                });
                let shared = async move {
                    handle.await.unwrap_or(Err(BrokerError::BrokerUnavailable.into()))
                }
                .boxed()
                .shared();
                let token = state.token();
                state.refresh_in_flight = Some((token, shared.clone(), cx));
                (shared, Some(token))
            }
        };
        let Some(token) = token else { return shared.await };
        let result = shared.await;
        {
            let mut state = self.st();
            if state.refresh_in_flight.as_ref().is_some_and(|(t, _, _)| *t == token) {
                state.refresh_in_flight = None;
            }
        }
        let grant = result?;
        if schedule {
            self.schedule_refresh(&grant, 0);
        }
        Ok(grant)
    }

    /// Whether `cached` may still be delivered: a grant from the Mac's own Codex only while the
    /// person's yes stands and the Mac still holds that same token. Else it is dropped.
    pub(crate) async fn cached_still_allowed(&self) -> bool {
        let (is_local, source) = {
            let state = self.st();
            (state.cached_is_local, state.local_sign_in.clone())
        };
        if !is_local {
            return true;
        }
        if let Some(source) = source {
            let current = source().await;
            let cached = self.st().cached.clone();
            if current.is_some() && current == cached {
                return true;
            }
        }
        let mut state = self.st();
        state.cached = None;
        state.cached_is_local = false;
        false
    }

    /// The cached grant while it has more than 2 minutes left.
    pub(crate) fn current_cache(&self) -> Option<Grant> {
        self.st().cached.clone().filter(|c| c.expires_at > now() + 120.0)
    }

    async fn perform_refresh(&self, cx: &Cx) -> Result<Grant, Error> {
        // The Mac's own Codex keeps its token fresh; cmux only reads it, so no second refresher
        // ever rotates the Mac's refresh token. The same token again is no renewal: the holder
        // is asked, and a failed renewal tries the Mac again after its backoff.
        // A device-code grant keeps renewing through the holder when the Mac's own Codex is
        // signed in to another account: a yes given later (or a DEV build's, which needs no ask)
        // never swaps the account under chats that already run on it (#41072 review).
        let source = self.st().local_sign_in.clone();
        if let Some(source) = source
            && let Some(grant) = source().await
        {
            let (cached, cached_is_local) = {
                let state = self.st();
                (state.cached.clone(), state.cached_is_local)
            };
            let other_account = cached.as_ref().is_some_and(|c| c.account != grant.account);
            if cached.as_ref().map(|c| &c.access_token) != Some(&grant.access_token)
                && (cached_is_local || !other_account)
            {
                self.ensure_scope(cx)?;
                if other_account {
                    return Err(BrokerError::AccountChanged.into());
                }
                if grant.expires_at <= now() + 60.0 {
                    return Err(BrokerError::ExpiredAccess.into());
                }
                let mut state = self.st();
                state.cached = Some(grant.clone());
                state.cached_is_local = true;
                return Ok(grant);
            }
        }
        let previous = self.st().cached.as_ref().map(|c| c.account.clone());
        let response = self.request(cx, "access", Some(true), previous.as_deref()).await?;
        self.ensure_scope(cx)?;
        let text = |key: &str| {
            response.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_owned)
        };
        let (Some(token), Some(account), Some(expiry)) = (
            text("accessToken"),
            text("chatgptAccountId"),
            // A non-finite or far expiry is malformed: it never reaches a timer.
            response.get("expiresAt").and_then(Value::as_f64).filter(|e| valid_expiry(*e)),
        ) else {
            return Err(BrokerError::InvalidReply.into());
        };
        let grant = Grant { access_token: token, account, expires_at: expiry };
        if grant.expires_at <= now() + 60.0 {
            return Err(BrokerError::ExpiredAccess.into());
        }
        let mut state = self.st();
        state.cached = Some(grant.clone());
        state.cached_is_local = false;
        Ok(grant)
    }

    pub(crate) async fn validate(
        &self,
        cx: &Cx,
        target: &TargetRef,
        confirmed: bool,
    ) -> Result<(), Error> {
        {
            let state = self.st();
            if state.stopped {
                return Err(BrokerError::Cancelled.into());
            }
            if !confirmed {
                return Err(BrokerError::ConsentRequired.into());
            }
            if state.pending_revocations.contains(target.machine_id()) {
                return Err(BrokerError::Cancelled.into());
            }
        }
        if !self.in_scope() {
            return Err(BrokerError::ScopeChanged.into());
        }
        if !target.is_live().await? {
            return Err(BrokerError::TargetOffline.into());
        }
        let capability = cx.run(target.capability()).await?;
        if !capability.owner_vm {
            return Err(BrokerError::SharedMachine.into());
        }
        if capability.protocol_version != PROTOCOL_VERSION
            || !capability.codex_external_access_token
        {
            return Err(BrokerError::UnsupportedMachine.into());
        }
        Ok(())
    }

    pub(crate) fn ensure_scope(&self, cx: &Cx) -> Result<(), Error> {
        if self.st().stopped {
            return Err(BrokerError::Cancelled.into());
        }
        if !self.in_scope() {
            return Err(BrokerError::ScopeChanged.into());
        }
        if cx.is_cancelled() {
            return Err(BrokerError::Cancelled.into());
        }
        Ok(())
    }

    /// One request to the private holder, started on first use; a holder that failed is
    /// replaced on the next request.
    pub(crate) async fn request(
        &self,
        cx: &Cx,
        method: &str,
        force: Option<bool>,
        previous_account: Option<&str>,
    ) -> Result<Value, Error> {
        let session = {
            let mut state = self.st();
            if state.stopped && method != "logout" {
                return Err(BrokerError::Cancelled.into());
            }
            match &state.session {
                Some(session) => session.clone(),
                None => {
                    let launch = &self.launch;
                    let session = Session::spawn(
                        &launch.executable,
                        &launch.prefix,
                        &launch.codex,
                        &self.home,
                        &launch.environment,
                        &launch.user_home,
                    )
                    .map_err(|e| Error::Other(format!("cannot start the Codex holder: {e}")))?;
                    state.session = Some(session.clone());
                    session
                }
            }
        };
        let reply = tokio::time::timeout(
            REQUEST_BOUND,
            session.request(cx, method, force, previous_account),
        )
        .await;
        match reply {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(SessionError::NotAuthenticated)) => Err(BrokerError::NotAuthenticated.into()),
            Ok(Err(SessionError::AccountChanged)) => Err(BrokerError::AccountChanged.into()),
            Ok(Err(SessionError::Cancelled)) => {
                self.invalidate(&session).await;
                Err(BrokerError::Cancelled.into())
            }
            Ok(Err(SessionError::InvalidReply)) => {
                self.invalidate(&session).await;
                Err(BrokerError::InvalidReply.into())
            }
            Ok(Err(_)) | Err(_) => {
                self.invalidate(&session).await;
                Err(BrokerError::BrokerUnavailable.into())
            }
        }
    }

    pub(crate) async fn invalidate(&self, failed: &Arc<Session>) {
        {
            let mut state = self.st();
            if state.session.as_ref().is_some_and(|s| Arc::ptr_eq(s, failed)) {
                state.session = None;
            }
        }
        failed.shutdown().await;
    }

    /// Serializes delivery and revocation per machine (first come, first served).
    pub(crate) async fn lock_target(&self, id: &str) -> tokio::sync::OwnedMutexGuard<()> {
        let lock = self
            .target_locks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(id.to_owned())
            .or_default()
            .clone();
        lock.lock_owned().await
    }

    pub(crate) fn holder_id(&self) -> String {
        if let Some(id) = self.st().holder_id.clone() {
            return id;
        }
        let id = self.record.holder_id();
        self.st().holder_id = Some(id.clone());
        id
    }

    pub(crate) fn target_list(&self) -> Vec<TargetRef> {
        let state = self.st();
        let mut ids: Vec<&String> = state.targets.keys().collect();
        ids.sort();
        ids.into_iter().filter_map(|id| state.targets.get(id).cloned()).collect()
    }
}

#[cfg(test)]
#[path = "broker_tests.rs"]
mod tests;
