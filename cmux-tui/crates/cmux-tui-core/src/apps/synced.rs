//! Synced app storage (`storage:synced`, cmuxterm-hq#12221): the cloud half
//! of the replica in `storage.rs`.
//!
//! - Writes: one flusher thread sends the replica's outbox through the
//!   daemon's cloud link (`appkv.set` / `appkv.delete` on `POST /v1/ops`),
//!   each op with its own idempotency key, again after a failure with the
//!   same key. Signed out it waits; the stream going live (a sign-in, a
//!   reconnect) or a new local write wakes it.
//! - Reads: the daemon subscribes once to the person's `appkv:<user>` stream
//!   (`Target::AppKv`, the inbox's path); its snapshot and events apply to
//!   the replicas of the apps that sync here, and each app hears
//!   `app.storage.changed {keys}` for the keys that changed.
//! - A different account on the stream drops the replicas and the queued
//!   writes of the previous one; writes made before any sign-in go to the
//!   first account.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError, Weak};
use std::time::Duration;

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::storage::{Changed, PendingOp, SYNCED_SCOPE};
use super::supervisor::{HostKey, Inner, Supervisor};
use crate::cloud_conversations::{CloudError, CloudEvent, Target};

/// The event an app hears when another device changed its synced keys.
pub(crate) const STORAGE_CHANGED: &str = "app.storage.changed";
/// The daemon's own subscriber id on the cloud link: no connection has it
/// (theirs count up from 1), so no disconnect ends the subscription.
const APPKV_CLIENT: u64 = u64::MAX - 1;
/// Outbox ops sent per pass.
const BATCH: usize = 32;
const RETRY_MIN: Duration = Duration::from_secs(2);
const RETRY_MAX: Duration = Duration::from_secs(300);
/// A quiet flusher still looks at the outbox this often (a lease that came
/// back without a stream event).
const IDLE_CHECK: Duration = Duration::from_secs(60);

/// Why one op did not reach the cloud.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SendError {
    /// Refused for good (`app.limit`, a bad request): dropped.
    Refused(String),
    /// Signed out, offline, 5xx: sent again later with the same key.
    Retry(String),
}

/// The cloud link synced storage uses (the daemon's `CloudConversations`;
/// a fake in tests).
pub(crate) trait AppKvCloud: Send + Sync {
    /// The signed-in account, `None` signed out.
    fn account(&self) -> Option<String>;
    /// Sends one op; the cloud's revision for it when the answer names one.
    fn send(&self, op: &PendingOp) -> Result<Option<u64>, SendError>;
    /// Subscribes to `appkv:<user>` (idempotent).
    fn subscribe(&self);
    /// Asks the stream for a snapshot (an app started syncing here).
    fn resync(&self);
}

/// The flusher's wake signal.
#[derive(Default)]
struct Signal {
    count: Mutex<u64>,
    wake: Condvar,
}

impl Signal {
    fn poke(&self) {
        *self.count.lock().unwrap_or_else(PoisonError::into_inner) += 1;
        self.wake.notify_all();
    }

    fn now(&self) -> u64 {
        *self.count.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Waits up to `timeout` for a poke after `seen`.
    fn wait(&self, seen: u64, timeout: Duration) {
        let guard = self.count.lock().unwrap_or_else(PoisonError::into_inner);
        let _unused = self.wake.wait_timeout_while(guard, timeout, |count| *count == seen);
    }
}

/// Synced storage's state on the supervisor.
#[derive(Default)]
pub(crate) struct SyncState {
    cloud: OnceLock<Arc<dyn AppKvCloud>>,
    signal: Arc<Signal>,
    started: AtomicBool,
}

impl SyncState {
    fn poke(&self) {
        self.signal.poke();
    }
}

/// What one flush pass did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Flush {
    /// Nothing to send, or nothing can be sent now (signed out).
    Idle,
    /// A full batch went: look again at once.
    More,
    /// The cloud did not answer: back off.
    Retry,
}

impl Supervisor {
    /// Installs the cloud link (once) and starts the outbox sender.
    pub(crate) fn set_appkv_cloud(&self, cloud: Arc<dyn AppKvCloud>) {
        if self.synced.cloud.set(cloud).is_err() || self.synced.started.swap(true, Ordering::SeqCst)
        {
            return;
        }
        let me = self.me.clone();
        let signal = self.synced.signal.clone();
        let spawned = std::thread::Builder::new()
            .name("cmux-app-synced".into())
            .spawn(move || flusher(&me, &signal));
        if let Err(error) = spawned {
            eprintln!("cmux-tui: synced app storage: no sender thread: {error}");
        }
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        self.appkv_refresh_locked(&inner);
    }

    /// Whether `app` keeps its storage in the synced replica here: installed
    /// with `storage:synced` granted (and still asked for by its manifest).
    pub(super) fn synced_locked(inner: &Inner, app: &str) -> bool {
        inner.mirror.apps.get(app).is_some_and(|record| record.installed)
            && Self::grant_for(inner, &HostKey { app: app.to_string(), preview: false })
                .scopes
                .contains(SYNCED_SCOPE)
    }

    /// After a change to the installed apps: the stream is subscribed while
    /// any app syncs, and an app syncing here for the first time asks for a
    /// snapshot (the rows other devices wrote before).
    pub(super) fn appkv_refresh_locked(&self, inner: &Inner) {
        let Some(cloud) = self.synced.cloud.get() else { return };
        let synced: Vec<&String> =
            inner.mirror.apps.keys().filter(|app| Self::synced_locked(inner, app)).collect();
        if synced.is_empty() {
            return;
        }
        cloud.subscribe();
        let fresh = self
            .storage()
            .as_ref()
            .is_some_and(|storage| synced.iter().any(|app| !storage.has_replica(app)));
        if fresh {
            cloud.resync();
        }
        self.synced.poke();
    }

    /// A synced write was made here: send it.
    pub(super) fn appkv_wrote(&self) {
        if let Some(cloud) = self.synced.cloud.get() {
            cloud.subscribe();
        }
        self.synced.poke();
    }

    /// One event of the `appkv:<user>` stream (routed here by the mux).
    pub(crate) fn on_appkv_event(&self, event: &CloudEvent) {
        if let CloudEvent::SubscriptionState { state, .. } = event {
            // Live after a sign-in or a reconnect: the outbox can go now.
            if *state == "live" {
                self.synced.poke();
            }
            return;
        }
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let storage = self.storage();
        let Some(storage) = storage.as_ref() else { return };
        let mut changed = Changed::new();
        if let Some(account) = event.account() {
            match storage.account() {
                Some(previous) if previous != account => {
                    changed = storage.reset_synced();
                    let _ = storage.set_account(account);
                }
                None => {
                    let _ = storage.set_account(account);
                }
                Some(_) => {}
            }
        }
        let synced = |app: &str| Self::synced_locked(&inner, app);
        let applied = match event {
            CloudEvent::AppKvReset { rows: Some(rows), .. } => storage.apply_snapshot(rows, synced),
            CloudEvent::AppKvChanged { writes, .. } => storage.apply_writes(writes, synced),
            _ => Ok(Changed::new()),
        };
        match applied {
            Ok(more) => {
                for (app, keys) in more {
                    changed.entry(app).or_default().extend(keys);
                }
            }
            Err(error) => eprintln!("cmux-tui: synced app storage: {}", error.message),
        }
        drop(storage);
        Self::publish_storage_changed_locked(&inner, &changed);
        if matches!(event, CloudEvent::AppKvReset { .. }) {
            self.synced.poke();
        }
    }

    /// `app.storage.changed {keys}` to each app's subscribed hosts.
    pub(super) fn publish_storage_changed_locked(inner: &Inner, changed: &Changed) {
        for (app, keys) in changed.iter().filter(|(_, keys)| !keys.is_empty()) {
            let body = json!({ "keys": keys });
            for (key, host) in inner.hosts.iter().filter(|(key, _)| &key.app == app) {
                if !Self::stream_readable(inner, key, host, STORAGE_CHANGED) {
                    continue;
                }
                let Some(process) = &host.process else { continue };
                for (sub, _) in host.subs.iter().filter(|(_, s)| s.as_str() == STORAGE_CHANGED) {
                    process.send(&ToHost::Event { sub: *sub, body: body.clone() });
                }
            }
        }
    }

    /// Sends what the outbox holds, one op at a time, off every lock.
    fn flush_once(&self) -> Flush {
        let Some(cloud) = self.synced.cloud.get().cloned() else { return Flush::Idle };
        let Some(account) = cloud.account() else { return Flush::Idle };
        let ops = {
            let storage = self.storage();
            let Some(storage) = storage.as_ref() else { return Flush::Idle };
            match storage.account() {
                // Another account's writes never go to this one; its stream
                // resets the replica first.
                Some(previous) if previous != account => return Flush::Idle,
                Some(_) => {}
                None => {
                    let _ = storage.set_account(&account);
                }
            }
            storage.pending(BATCH)
        };
        let full = ops.len() == BATCH;
        for op in ops {
            let sent = cloud.send(&op);
            let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let changed = {
                let storage = self.storage();
                let Some(storage) = storage.as_ref() else { return Flush::Idle };
                match &sent {
                    Ok(revision) => storage.acked(&op, *revision),
                    Err(SendError::Refused(reason)) => {
                        eprintln!(
                            "cmux-tui: synced app storage: the cloud refused {} {}: {reason}",
                            op.app, op.key
                        );
                        storage.refused(&op)
                    }
                    Err(SendError::Retry(_)) => return Flush::Retry,
                }
            };
            Self::publish_storage_changed_locked(&inner, &changed);
            drop(inner);
            if matches!(sent, Err(SendError::Refused(_))) {
                cloud.resync();
            }
        }
        if full { Flush::More } else { Flush::Idle }
    }
}

fn flusher(me: &Weak<Supervisor>, signal: &Signal) {
    let mut backoff = RETRY_MIN;
    loop {
        let seen = signal.now();
        let flushed = {
            let Some(supervisor) = me.upgrade() else { return };
            supervisor.flush_once()
        };
        let wait = match flushed {
            Flush::More => Duration::ZERO,
            Flush::Idle => IDLE_CHECK,
            Flush::Retry => {
                let wait = backoff;
                backoff = (backoff * 2).min(RETRY_MAX);
                wait
            }
        };
        if flushed != Flush::Retry {
            backoff = RETRY_MIN;
        }
        if !wait.is_zero() {
            signal.wait(seen, wait);
        }
    }
}

/// The daemon's cloud link as synced storage's [`AppKvCloud`].
pub(crate) struct MuxCloud {
    mux: Weak<crate::Mux>,
}

impl MuxCloud {
    pub(crate) fn new(mux: &Arc<crate::Mux>) -> Self {
        Self { mux: Arc::downgrade(mux) }
    }

    fn with<T>(
        &self,
        f: impl FnOnce(&crate::cloud_conversations::CloudConversations) -> T,
    ) -> Option<T> {
        let mux = self.mux.upgrade()?;
        mux.cloud_conversations().map(f)
    }
}

/// The revision the cloud gave a write: `value.revision` (or the row's).
fn revision_of(data: &Value) -> Option<u64> {
    let value = data.get("value")?;
    value.get("revision").or_else(|| value.pointer("/row/revision")).and_then(Value::as_u64)
}

impl AppKvCloud for MuxCloud {
    fn account(&self) -> Option<String> {
        self.with(|service| service.lease_account()).flatten()
    }

    fn send(&self, op: &PendingOp) -> Result<Option<u64>, SendError> {
        let sent = self
            .with(|service| {
                service.appkv_op(&op.app, &op.key, op.value.as_ref(), &op.idempotency_key)
            })
            .ok_or_else(|| SendError::Retry("no cloud link".into()))?;
        match sent {
            Ok(data) => Ok(revision_of(&data)),
            Err(CloudError::Rejected { code, retryable: false, .. }) => {
                Err(SendError::Refused(code))
            }
            Err(CloudError::BadRequest(message)) => Err(SendError::Refused(message)),
            Err(error) => Err(SendError::Retry(error.to_string())),
        }
    }

    fn subscribe(&self) {
        self.with(|service| {
            let _ = service.subscribe(APPKV_CLIENT, Target::AppKv);
        });
    }

    fn resync(&self) {
        self.with(|service| service.resync(&Target::AppKv));
    }
}
