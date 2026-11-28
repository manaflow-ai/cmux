//! Direct SuperGrok, GitHub Copilot and Kimi Code subscriptions. Only the daemon holds refresh
//! tokens. Sign-in attempts expose a browser challenge and a terminal status.

pub(crate) mod grok_hook;
mod oauth;
pub(crate) mod openrouter;
#[cfg(test)]
mod tests;

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex as AsyncMutex, watch};
use tokio::time::Instant;

use crate::routes::{self, RouteFile, RouteKind};

pub(crate) type Failure = &'static str;
const REFRESH_MARGIN: i64 = 300;
pub(crate) const LOCAL_KIMI_EXPIRY: &str = "ACPMUX_LOCAL_KIMI_EXPIRY";
pub(crate) const LOCAL_SUBSCRIPTION_ROUTE: &str = "ACPMUX_LOCAL_SUBSCRIPTION_ROUTE";
pub(crate) const KIMI_MODEL: &str = "kimi-for-coding";

pub(crate) fn migrate_all(home: &Path) {
    for provider in [Provider::Grok, Provider::Copilot, Provider::Kimi] {
        provider.store(home).migrate_all::<Record>();
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Provider {
    Grok,
    Copilot,
    Kimi,
}

impl Provider {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "grok" => Some(Self::Grok),
            "copilot" => Some(Self::Copilot),
            "kimi" => Some(Self::Kimi),
            _ => None,
        }
    }

    pub fn for_kind(kind: RouteKind) -> Option<Self> {
        match kind {
            RouteKind::GrokPlan => Some(Self::Grok),
            RouteKind::CopilotPlan => Some(Self::Copilot),
            RouteKind::KimiPlan => Some(Self::Kimi),
            _ => None,
        }
    }

    pub fn kind(self) -> RouteKind {
        match self {
            Self::Grok => RouteKind::GrokPlan,
            Self::Copilot => RouteKind::CopilotPlan,
            Self::Kimi => RouteKind::KimiPlan,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Grok => "grok",
            Self::Copilot => "copilot",
            Self::Kimi => "kimi",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Grok => "SuperGrok",
            Self::Copilot => "GitHub Copilot",
            Self::Kimi => "Kimi Code",
        }
    }

    pub fn family(self) -> &'static str {
        match self {
            Self::Grok => "grok",
            Self::Copilot => "github-copilot",
            Self::Kimi => "opencode",
        }
    }

    fn store(self, home: &Path) -> crate::subscription_store::Store<'_> {
        crate::subscription_store::Store::new(home, self.name())
    }

    #[cfg(test)]
    fn path(self, home: &Path, id: &str) -> Result<PathBuf, Failure> {
        self.store(home).path(id).map_err(|error| error.code())
    }

    fn read(self, home: &Path, id: &str) -> Result<Option<Record>, Failure> {
        self.store(home).read(id).map_err(|error| error.code())
    }

    fn write(self, home: &Path, id: &str, record: &Record) -> Result<(), Failure> {
        self.store(home).write(id, record).map_err(|error| error.code())
    }

    fn delete(self, home: &Path, id: &str) -> Result<(), Failure> {
        self.store(home).delete(id).map_err(|error| error.code())
    }

    #[cfg(unix)]
    pub(crate) fn copilot_access_matches(
        home: &Path,
        id: &str,
        token: &str,
    ) -> Result<bool, Failure> {
        Ok(Self::Copilot
            .read(home, id)?
            .is_some_and(|record| !record.access_token.is_empty() && record.access_token == token))
    }

    #[cfg(unix)]
    pub(crate) async fn forget_lapsed_copilot(
        home: PathBuf,
        id: String,
        token: String,
    ) -> Result<bool, Failure> {
        blocking(move || {
            let deleted = Self::Copilot
                .store(&home)
                .delete_if(&id, |record: Record| record.access_token == token)
                .map_err(|error| error.code())?;
            if deleted {
                crate::agent::copilot_auth::remove_route(&id);
            }
            Ok(deleted)
        })
        .await
    }

    pub(crate) fn available(
        self,
        home: &Path,
        id: &str,
    ) -> Result<bool, crate::subscription_store::Error> {
        self.store(home).available::<Record>(id)
    }

    pub(crate) fn login(self, home: &Path, id: &str) -> Option<String> {
        let metadata = self.store(home).metadata(id)?;
        metadata["login"].as_str().or_else(|| metadata["email"].as_str()).map(str::to_owned)
    }

    pub fn signed_in(self, home: &Path, id: &str) -> bool {
        self.store(home).metadata(id).is_some_and(|record| record["signed_in"] == true)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum KimiRegion {
    Global,
    China,
}

impl KimiRegion {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "kimiGlobal" => Some(Self::Global),
            "kimiChina" => Some(Self::China),
            _ => None,
        }
    }

    fn from_base_url(value: &str) -> Option<Self> {
        [Self::Global, Self::China].into_iter().find(|region| region.base_url() == value)
    }

    pub fn base_url(self) -> &'static str {
        match self {
            Self::Global => "https://api.kimi.ai/coding/v1",
            Self::China => "https://api.kimi.com/coding/v1",
        }
    }
}

// Deliberately no Debug representation.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
struct Record {
    access_token: String,
    refresh_token: String,
    expires_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    region: Option<KimiRegion>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sub: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    login: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    email: Option<String>,
}

pub(crate) fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

#[derive(Clone)]
pub(crate) enum Status {
    Pending,
    Done(String),
    Failed(Failure),
    Cancelled,
}

#[derive(Clone)]
pub(crate) struct Begun {
    pub attempt: String,
    pub url: String,
    pub user_code: String,
    pub expires_at: i64,
    pub interval: u64,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SignIn {
    Device(Provider),
    OpenRouter,
}

struct Attempt {
    sign_in: SignIn,
    request: Option<DeviceRequest>,
    started: Instant,
    cancel: watch::Sender<bool>,
    state: watch::Receiver<Status>,
}

struct DeviceRequest {
    home: PathBuf,
    replace: Option<String>,
    region: Option<KimiRegion>,
    begun: Begun,
}

type Account = (Provider, PathBuf, String);
type PendingWrites = Arc<Mutex<HashMap<Account, Arc<Record>>>>;

pub(crate) struct Service {
    oauth: oauth::OAuth,
    attempts: Mutex<HashMap<String, Arc<Attempt>>>,
    starting: AsyncMutex<()>,
    saving: Arc<AsyncMutex<()>>,
    accounts: Mutex<HashMap<String, std::sync::Weak<AsyncMutex<()>>>>,
    pending_writes: PendingWrites,
}

impl Default for Service {
    fn default() -> Self {
        Self::new(oauth::Endpoints::default())
    }
}

impl Service {
    fn new(endpoints: oauth::Endpoints) -> Self {
        Self {
            oauth: oauth::OAuth::new(endpoints),
            attempts: Mutex::default(),
            starting: AsyncMutex::default(),
            saving: Arc::default(),
            accounts: Mutex::default(),
            pending_writes: PendingWrites::default(),
        }
    }

    fn account(&self, id: &str) -> Arc<AsyncMutex<()>> {
        let mut locks = self.accounts.lock().unwrap_or_else(|poison| poison.into_inner());
        locks.retain(|_, weak| weak.strong_count() > 0);
        if let Some(lock) = locks.get(id).and_then(std::sync::Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(AsyncMutex::new(()));
        locks.insert(id.to_owned(), Arc::downgrade(&lock));
        lock
    }

    fn previous_pending(&self, sign_in: SignIn) -> Option<Arc<Attempt>> {
        let mut attempts = self.attempts.lock().unwrap_or_else(|poison| poison.into_inner());
        attempts.retain(|_, attempt| {
            matches!(*attempt.state.borrow(), Status::Pending)
                || attempt.started.elapsed() < Duration::from_secs(3600)
        });
        attempts
            .values()
            .find(|attempt| {
                attempt.sign_in == sign_in && matches!(*attempt.state.borrow(), Status::Pending)
            })
            .cloned()
    }

    pub async fn begin(
        self: &Arc<Self>,
        provider: Provider,
        places: crate::chatgpt::Places,
        replace: Option<String>,
        region: Option<KimiRegion>,
        on_finish: impl FnOnce() + Send + 'static,
    ) -> Result<Begun, Failure> {
        let _starting = self.starting.lock().await;
        let prior_region = if let Some(id) = replace.clone() {
            let dir = places.routes.clone();
            blocking(move || {
                let route = check_route(provider, dir.as_deref(), &id)?;
                Ok(route.file.openai_base_url.as_deref().and_then(KimiRegion::from_base_url))
            })
            .await?
        } else {
            None
        };
        let region = if provider == Provider::Kimi {
            if prior_region.zip(region).is_some_and(|(saved, selected)| saved != selected) {
                return Err("bad_region");
            }
            Some(prior_region.or(region).unwrap_or(KimiRegion::Global))
        } else {
            None
        };
        let sign_in = SignIn::Device(provider);
        let joined =
            self.attempts.lock().unwrap_or_else(|p| p.into_inner()).values().find_map(|attempt| {
                let request = attempt.request.as_ref()?;
                (attempt.sign_in == sign_in
                    && matches!(*attempt.state.borrow(), Status::Pending)
                    && request.home == places.home
                    && request.replace == replace
                    && request.region == region
                    && request.begun.expires_at > now())
                .then(|| request.begun.clone())
            });
        if let Some(begun) = joined {
            return Ok(begun);
        }
        let challenge = self.oauth.begin(provider, region).await?;
        let begun = Begun {
            attempt: uuid::Uuid::new_v4().to_string(),
            url: challenge.url.clone(),
            user_code: challenge.code.clone(),
            expires_at: challenge.expires_at,
            interval: challenge.interval.as_secs(),
        };
        let (cancel, mut cancelled) = watch::channel(false);
        let (state, receiver) = watch::channel(Status::Pending);
        let expires_at = begun.expires_at;
        let request = DeviceRequest {
            home: places.home.clone(),
            replace: replace.clone(),
            region,
            begun: begun.clone(),
        };
        let attempt = Arc::new(Attempt {
            sign_in,
            request: Some(request),
            started: Instant::now(),
            cancel,
            state: receiver,
        });
        self.attempts
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .insert(begun.attempt.clone(), attempt);
        let service = self.clone();
        static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
        SCOPE.get_or_init(|| cmux_scope::Scope::new("subscription sign-in"))
            .spawn_named("subscription approval", async move {
                let id = replace.clone().unwrap_or_else(|| format!("{}-{}", provider.name(), uuid::Uuid::new_v4()));
                let deadline = challenge.deadline;
                let approval = async {
                    let record = service.oauth.poll(provider, challenge).await?;
                    let save_guard = service.saving.clone().lock_owned().await;
                    let guard = service.account(&id).lock_owned().await;
                    Ok::<_, Failure>((record, save_guard, guard))
                };
                let status = tokio::select! {
                    biased;
                    // Drop the watch guard before the arm runs: it is not `Send`.
                    _ = async { let _ = cancelled.wait_for(|yes| *yes).await; } => Status::Cancelled,
                    outcome = tokio::time::timeout_at(deadline, approval) => match outcome {
                        Err(_) => Status::Failed("expired_token"),
                        Ok(Err(code)) => Status::Failed(code),
                        Ok(Ok((record, save_guard, guard))) => {
                            let pending = service.pending_writes.clone();
                            match blocking(move || {
                                let (_save, _guard) = (save_guard, guard);
                                if now() >= expires_at { return Err("expired_token"); }
                                save(provider, &places, &id, replace.is_some(), &record)?;
                                pending.lock().unwrap_or_else(|p| p.into_inner())
                                    .remove(&(provider, places.home, id.clone()));
                                Ok(id)
                            }).await {
                                Ok(id) => Status::Done(id),
                                Err(code) => Status::Failed(code),
                            }
                        }
                    }
                };
                if matches!(status, Status::Done(_)) { on_finish(); }
                state.send_replace(status);
            });
        Ok(begun)
    }

    fn attempt(&self, id: &str) -> Result<Arc<Attempt>, Failure> {
        self.attempts
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get(id)
            .cloned()
            .ok_or("unknown_attempt")
    }

    pub async fn wait(&self, id: &str, timeout: Duration) -> Result<Status, Failure> {
        let mut state = self.attempt(id)?.state.clone();
        let _ = tokio::time::timeout(
            timeout,
            state.wait_for(|value| !matches!(value, Status::Pending)),
        )
        .await;
        let result = state.borrow().clone();
        Ok(result)
    }

    async fn stop(attempt: &Attempt) -> Status {
        attempt.cancel.send_replace(true);
        let mut state = attempt.state.clone();
        let _ = state.wait_for(|status| !matches!(status, Status::Pending)).await;
        let result = state.borrow().clone();
        result
    }

    pub async fn cancel(&self, id: &str) -> Result<Status, Failure> {
        Ok(Self::stop(self.attempt(id)?.as_ref()).await)
    }

    pub async fn token(
        &self,
        provider: Provider,
        home: &Path,
        id: &str,
        margin: i64,
    ) -> Result<(String, i64), Failure> {
        self.grant(provider, home, id, margin).await.map(|(value, expiry, _)| (value, expiry))
    }

    pub async fn grant(
        &self,
        provider: Provider,
        home: &Path,
        id: &str,
        margin: i64,
    ) -> Result<(String, i64, Option<KimiRegion>), Failure> {
        let guard = self.account(id).lock_owned().await;
        let (home, id) = (home.to_owned(), id.to_owned());
        let key = (provider, home.clone(), id.clone());
        let pending =
            self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).get(&key).cloned();
        let mut needs_write = pending.is_some();
        let mut record = match pending {
            Some(record) => record,
            None => {
                let (h, i) = (home.clone(), id.clone());
                Arc::new(blocking(move || provider.read(&h, &i)).await?.ok_or("signed_out")?)
            }
        };
        if provider == Provider::Copilot {
            return Ok((record.access_token.clone(), 0, None));
        }
        if record.refresh_token.is_empty() {
            return Err("reauth_required");
        }
        let mut refresh_failure = None;
        if record.expires_at.saturating_sub(now()) <= margin {
            match self.oauth.refresh(provider, &record).await {
                Ok(fresh) => {
                    record = Arc::new(fresh);
                    // Rotation invalidates the on-disk refresh token even if this write fails.
                    self.pending_writes
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .insert(key.clone(), record.clone());
                    needs_write = true;
                }
                Err("reauth_required") => {
                    let pending = self.pending_writes.clone();
                    blocking(move || {
                        let _guard = guard;
                        if provider == Provider::Kimi {
                            // Keep the identity needed to check the next approval.
                            let mut cleared = Arc::unwrap_or_clone(record);
                            cleared.access_token.clear();
                            cleared.refresh_token.clear();
                            cleared.expires_at = 0;
                            provider.write(&home, &id, &cleared)?;
                        } else {
                            provider.delete(&home, &id)?;
                        }
                        pending.lock().unwrap_or_else(|p| p.into_inner()).remove(&key);
                        Ok(())
                    })
                    .await?;
                    return Err("reauth_required");
                }
                Err(code) => refresh_failure = Some(code),
            }
        }
        let answer = (record.access_token.clone(), record.expires_at, record.region);
        if needs_write {
            let pending = self.pending_writes.clone();
            let _ = blocking(move || {
                let _guard = guard;
                provider.write(&home, &id, &record)?;
                pending.lock().unwrap_or_else(|p| p.into_inner()).remove(&key);
                Ok(())
            })
            .await;
        }
        match refresh_failure {
            Some(code) if answer.1 <= now() => Err(code),
            _ => Ok(answer),
        }
    }

    pub async fn remove(
        &self,
        provider: Provider,
        places: crate::chatgpt::Places,
        id: String,
        instance: String,
    ) -> Result<(), Failure> {
        let guard = self.account(&id).lock_owned().await;
        let (read_places, read_id, read_instance) = (places.clone(), id.clone(), instance.clone());
        let grants = blocking(move || {
            let check_instance = || {
                let route = check_route(provider, read_places.routes.as_deref(), &read_id)?;
                if route.file.credential_instance.as_deref() != Some(read_instance.as_str()) {
                    return Err("not_found");
                }
                Ok(())
            };
            check_instance()?;
            let grants = provider
                .store(&read_places.home)
                .grants::<Record>(&read_id)
                .map_err(|error| error.code())?;
            check_instance()?;
            Ok(grants)
        })
        .await?;
        let key = (provider, places.home.clone(), id.clone());
        // GitHub requires the OAuth application's secret to revoke its grant.
        if provider == Provider::Grok {
            let fresh =
                self.pending_writes.lock().unwrap_or_else(|p| p.into_inner()).get(&key).cloned();
            let mut attempted = std::collections::HashSet::new();
            let records = fresh
                .iter()
                .map(Arc::as_ref)
                .chain(grants.active.iter())
                .chain(grants.retired.iter().map(|(_, record)| record));
            for record in records {
                if !record.refresh_token.is_empty()
                    && attempted.insert(record.refresh_token.as_str())
                {
                    self.oauth.revoke_grok(record).await;
                }
            }
        }
        let pending = self.pending_writes.clone();
        blocking(move || {
            let _guard = guard;
            routes::remove_with(
                places.routes.as_deref(),
                &places.home,
                &id,
                Some(&instance),
                |route| {
                    if route.file.kind != provider.kind() {
                        return Err("not_found");
                    }
                    provider
                        .store(&places.home)
                        .delete_grants(&id, &grants)
                        .map_err(|error| error.code())?;
                    pending.lock().unwrap_or_else(|p| p.into_inner()).remove(&key);
                    #[cfg(unix)]
                    if provider == Provider::Copilot {
                        crate::agent::copilot_auth::remove_route(&id);
                    }
                    Ok(())
                },
                |_| "storage",
            )
            .map(|_| ())
        })
        .await
    }
}

pub(crate) const LOCAL_MARGIN: i64 = REFRESH_MARGIN;

/// A standalone harness check has no live Hub. Take its Copilot grant from the same
/// connection store and apply the same owner marker as a daemon launch.
#[cfg(unix)]
pub(crate) async fn standalone_copilot_env(
    config: &crate::config::Config,
    env: &mut std::collections::BTreeMap<String, String>,
) -> Result<(), Failure> {
    let (dir, home) = routes::places(config);
    let id = routes::automatic_connection(
        dir.as_deref(),
        &routes::bindings(&home),
        Provider::Copilot.family(),
    )
    .ok_or("not_found")?;
    let (store_home, route_id) = (home.clone(), id.clone());
    let record = blocking(move || Provider::Copilot.read(&store_home, &route_id))
        .await?
        .ok_or("not_found")?;
    env.insert(crate::agent_credentials::COPILOT_TOKEN.into(), record.access_token);
    env.insert(crate::agent::copilot_auth::ROUTE_ENV.into(), id);
    env.insert(
        crate::agent::copilot_auth::ROUTE_HOME_ENV.into(),
        home.to_string_lossy().into_owned(),
    );
    Ok(())
}

fn check_route(provider: Provider, dir: Option<&Path>, id: &str) -> Result<routes::Route, Failure> {
    routes::find(dir, id).ok().filter(|route| route.file.kind == provider.kind()).ok_or("not_found")
}

fn save(
    provider: Provider,
    places: &crate::chatgpt::Places,
    id: &str,
    replace: bool,
    record: &Record,
) -> Result<(), Failure> {
    let dir = places.routes.as_deref();
    let store = provider.store(&places.home);
    if provider == Provider::Kimi {
        let subject =
            record.sub.as_deref().filter(|subject| !subject.is_empty()).ok_or("bad_reply")?;
        if replace && !store.metadata(id).is_some_and(|prior| prior["sub"] == subject) {
            return Err("different_account");
        }
    }
    if let Some(sub) = &record.sub {
        for route in routes::load(dir).0 {
            if route.file.kind != provider.kind() {
                continue;
            }
            let Some(metadata) = store.metadata(&route.id) else { continue };
            let prior = metadata["sub"].as_str();
            if route.id == id && replace && prior.is_some_and(|prior| prior != sub) {
                return Err("different_account");
            }
            if route.id != id
                && metadata["signed_in"] == true
                && prior == Some(sub.as_str())
                && (provider != Provider::Kimi
                    || metadata["region"] == serde_json::json!(record.region))
            {
                return Err("already_signed_in");
            }
        }
    }
    let login = record.login.as_ref().or(record.email.as_ref());
    if replace {
        let mut route = check_route(provider, dir, id)?.file;
        if let Some(login) = login {
            route.name = Some(format!("{} ({login})", provider.label()));
        }
        provider.write(&places.home, id, record)?;
        #[cfg(unix)]
        if provider == Provider::Copilot {
            crate::agent::copilot_auth::remove_route(id);
        }
        if login.is_some() {
            routes::add(dir, id, &route, true).map_err(|_| "storage")?;
        }
        return Ok(());
    }
    let file = RouteFile {
        credential_instance: None,
        name: Some(login.map_or_else(
            || provider.label().to_owned(),
            |login| format!("{} ({login})", provider.label()),
        )),
        kind: provider.kind(),
        families: vec![provider.family().into()],
        provider: Some(provider.name().into()),
        anthropic_base_url: None,
        openai_base_url: record.region.map(|region| region.base_url().into()),
        auth: None,
        secret: None,
        claude_token_expires_at: None,
        cloud_enabled: None,
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
    };
    provider.write(&places.home, id, record)?;
    if routes::add(dir, id, &file, false).is_err() {
        provider.delete(&places.home, id)?;
        return Err("storage");
    }
    Ok(())
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, Failure> + Send + 'static,
) -> Result<T, Failure> {
    tokio::task::spawn_blocking(work).await.map_err(|_| "storage")?
}
