use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use crate::resource::TabPublicId;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum BrowserProviderAuthentication {
    None,
    Bearer(String),
}

impl BrowserProviderAuthentication {
    pub(crate) fn name(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Bearer(_) => "bearer",
        }
    }

    pub(crate) fn bearer_token(&self) -> Option<&str> {
        match self {
            Self::None => None,
            Self::Bearer(token) => Some(token),
        }
    }
}

/// Who presents a provider's pages (`browser-provider-native-hosting-v1`).
///
/// `Daemon` is the original contract: the daemon sizes each attached target
/// to its own viewer with `Emulation.setDeviceMetricsOverride` and mirrors it
/// with a screencast. `Native` means the provider shows each page in its own
/// native view at native geometry: the daemon never overrides the page's
/// metrics, never brings a target to the front, and screencasts a target only
/// while a frame viewer (an attached TUI or remote client) is attached.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum BrowserProviderHosting {
    #[default]
    Daemon,
    Native,
}

impl BrowserProviderHosting {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Daemon => "daemon",
            Self::Native => "native",
        }
    }

    pub(crate) fn is_native(self) -> bool {
        self == Self::Native
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserProviderRegistration {
    pub(crate) provider_id: String,
    pub(crate) endpoint: String,
    pub(crate) authentication: BrowserProviderAuthentication,
    pub(crate) hosting: BrowserProviderHosting,
    pub(crate) targets: BTreeMap<TabPublicId, String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserProviderTargetLease {
    pub(crate) provider_id: String,
    pub(crate) endpoint: String,
    pub(crate) authentication: BrowserProviderAuthentication,
    pub(crate) hosting: BrowserProviderHosting,
    pub(crate) tab_id: TabPublicId,
    pub(crate) target_id: String,
    pub(crate) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserProviderSnapshot {
    pub(crate) provider_id: String,
    pub(crate) endpoint: String,
    pub(crate) authentication: BrowserProviderAuthentication,
    pub(crate) hosting: BrowserProviderHosting,
    pub(crate) targets: BTreeMap<TabPublicId, String>,
    pub(crate) revision: u64,
    pub(crate) clients: usize,
}

#[derive(Default)]
struct BrowserProviderState {
    registrations: BTreeMap<u64, BrowserProviderRegistration>,
    revision: u64,
    /// Bumped by [`BrowserProviderRegistry::wake_waiters`]: a watcher that saw
    /// it change re-checks its cancel predicate.
    wakes: u64,
    /// Parked watchers by key, each called once at the next change or wake.
    watchers: BTreeMap<u64, ProviderWake>,
    next_watcher: u64,
}

type ProviderWake = Box<dyn FnOnce() + Send>;

/// What [`BrowserProviderRegistry::watch`] found.
#[derive(Debug)]
pub(crate) enum ProviderWatch {
    /// A provider publishes the tab's target.
    Target(BrowserProviderTargetLease),
    /// The registrations changed, or a wake came, since the caller's
    /// [`BrowserProviderRegistry::generation`]: it checks again.
    Moved,
    /// Nothing yet: the watcher is called at the next change or wake.
    Parked,
}

/// Connection-scoped CDP leases published by the native cmux-browser process.
///
/// This registry is intentionally not durable. A DevTools endpoint and target
/// id are capabilities for one live browser process; persisting either would
/// let a restarted daemon attach a journal tab to an unrelated future target.
///
/// A tab waiting for its target parks a watcher here instead of a thread: the
/// watcher (a wake of the bootstrap's lane) is called once at the next change,
/// as a Chromium sequence waits on a `base::WaitableEventWatcher`
/// (base/synchronization/waitable_event_watcher.h) rather than blocking.
#[derive(Default)]
pub(crate) struct BrowserProviderRegistry {
    state: Mutex<BrowserProviderState>,
}

impl BrowserProviderRegistry {
    pub(crate) fn register(
        &self,
        client: u64,
        registration: BrowserProviderRegistration,
    ) -> anyhow::Result<BrowserProviderSnapshot> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        for (other_client, existing) in &state.registrations {
            if *other_client == client {
                continue;
            }
            anyhow::ensure!(
                existing.provider_id == registration.provider_id,
                "another cmux-browser provider is already attached"
            );
            anyhow::ensure!(
                existing.endpoint == registration.endpoint
                    && existing.authentication == registration.authentication
                    && existing.hosting == registration.hosting,
                "cmux-browser provider clients disagree on the CDP endpoint, authentication or hosting"
            );
        }

        let mut woken = BTreeMap::new();
        if state.registrations.get(&client) != Some(&registration) {
            state.registrations.insert(client, registration);
            state.revision = state.revision.wrapping_add(1).max(1);
            woken = std::mem::take(&mut state.watchers);
        }
        let snapshot = Self::snapshot_locked(&state)
            .ok_or_else(|| anyhow::anyhow!("browser provider vanished"));
        drop(state);
        call_watchers(woken);
        snapshot
    }

    pub(crate) fn unregister(&self, client: u64) -> bool {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.registrations.remove(&client).is_none() {
            return false;
        }
        state.revision = state.revision.wrapping_add(1).max(1);
        let woken = std::mem::take(&mut state.watchers);
        drop(state);
        call_watchers(woken);
        true
    }

    pub(crate) fn snapshot(&self) -> Option<BrowserProviderSnapshot> {
        Self::snapshot_locked(&self.state.lock().unwrap_or_else(PoisonError::into_inner))
    }

    pub(crate) fn target(&self, tab_id: &TabPublicId) -> Option<BrowserProviderTargetLease> {
        Self::target_locked(&self.state.lock().unwrap_or_else(PoisonError::into_inner), tab_id)
    }

    /// The registrations' revision and the wake count, for [`Self::watch`]:
    /// read it before checking a cancel predicate, so a change or wake that
    /// lands between the check and the watch is never lost.
    pub(crate) fn generation(&self) -> (u64, u64) {
        let state = self.lock();
        (state.revision, state.wakes)
    }

    /// `tab_id`'s target when a provider publishes it; otherwise, unless the
    /// registrations or the wake count moved since `seen`, parks `wake` under
    /// `key` (replacing that key's earlier watcher) until the next change or
    /// wake. With no `tab_id` it only watches for a change.
    pub(crate) fn watch(
        &self,
        tab_id: Option<&TabPublicId>,
        seen: (u64, u64),
        key: u64,
        wake: impl FnOnce() + Send + 'static,
    ) -> ProviderWatch {
        let mut state = self.lock();
        if let Some(lease) = tab_id.and_then(|tab_id| Self::target_locked(&state, tab_id)) {
            return ProviderWatch::Target(lease);
        }
        if (state.revision, state.wakes) != seen {
            return ProviderWatch::Moved;
        }
        let replaced = state.watchers.insert(key, Box::new(wake));
        drop(state);
        drop(replaced);
        ProviderWatch::Parked
    }

    /// A key no other watcher of this registry has.
    pub(crate) fn watcher_key(&self) -> u64 {
        let mut state = self.lock();
        state.next_watcher += 1;
        state.next_watcher
    }

    /// Drops `key`'s parked watcher, if any.
    pub(crate) fn unwatch(&self, key: u64) {
        let removed = self.lock().watchers.remove(&key);
        drop(removed);
    }

    /// Calls every parked watcher so it re-checks its cancel predicate. Call
    /// it after making that predicate true (surface death, mux shutdown, mux
    /// drop).
    pub(crate) fn wake_waiters(&self) {
        let mut state = self.lock();
        state.wakes = state.wakes.wrapping_add(1);
        let woken = std::mem::take(&mut state.watchers);
        drop(state);
        call_watchers(woken);
    }

    /// Parked watchers.
    #[cfg(test)]
    pub(crate) fn watcher_count(&self) -> usize {
        self.lock().watchers.len()
    }

    fn lock(&self) -> MutexGuard<'_, BrowserProviderState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn target_locked(
        state: &BrowserProviderState,
        tab_id: &TabPublicId,
    ) -> Option<BrowserProviderTargetLease> {
        // A process can host multiple native windows. If two projections of
        // one tab are briefly alive, the oldest connected provider client is
        // the deterministic owner until it disconnects. Consumer clients may
        // all attach to that one target independently.
        let (_, registration) = state
            .registrations
            .iter()
            .find(|(_, registration)| registration.targets.contains_key(tab_id))?;
        Some(BrowserProviderTargetLease {
            provider_id: registration.provider_id.clone(),
            endpoint: registration.endpoint.clone(),
            authentication: registration.authentication.clone(),
            hosting: registration.hosting,
            tab_id: tab_id.clone(),
            target_id: registration.targets.get(tab_id)?.clone(),
            revision: state.revision,
        })
    }

    fn snapshot_locked(state: &BrowserProviderState) -> Option<BrowserProviderSnapshot> {
        let (_, first) = state.registrations.first_key_value()?;
        let mut targets = BTreeMap::new();
        for registration in state.registrations.values() {
            for (tab_id, target_id) in &registration.targets {
                targets.entry(tab_id.clone()).or_insert_with(|| target_id.clone());
            }
        }
        Some(BrowserProviderSnapshot {
            provider_id: first.provider_id.clone(),
            endpoint: first.endpoint.clone(),
            authentication: first.authentication.clone(),
            hosting: first.hosting,
            targets,
            revision: state.revision,
            clients: state.registrations.len(),
        })
    }
}

/// Calls watchers taken from the registry, after its lock is released: a
/// watcher wakes a lane, which takes the lane pool's lock.
fn call_watchers(watchers: BTreeMap<u64, ProviderWake>) {
    for wake in watchers.into_values() {
        wake();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{RecvTimeoutError, channel};
    use std::time::Duration;

    use super::*;

    fn tab() -> TabPublicId {
        TabPublicId::parse("tab_00000000000000000000000000000007".to_string()).unwrap()
    }

    fn registration(targets: BTreeMap<TabPublicId, String>) -> BrowserProviderRegistration {
        BrowserProviderRegistration {
            provider_id: "test-provider".to_string(),
            endpoint: "ws://127.0.0.1:9/devtools/browser/test".to_string(),
            authentication: BrowserProviderAuthentication::None,
            hosting: BrowserProviderHosting::Daemon,
            targets,
        }
    }

    fn watcher() -> (impl FnOnce() + Send + 'static, std::sync::mpsc::Receiver<()>) {
        let (tx, rx) = channel();
        (move || tx.send(()).unwrap(), rx)
    }

    /// A tab waiting for a target no provider publishes parks a watcher and
    /// takes no thread and no timer: nothing calls it until a wake (the
    /// 250 ms re-check it once had woke the daemon 4 times a second,
    /// cmux_next_daemon_idle_unprovided_browser_tab).
    #[test]
    fn a_watch_for_an_unpublished_target_parks_until_woken() {
        let registry = BrowserProviderRegistry::default();
        let (wake, woken) = watcher();
        let key = registry.watcher_key();
        let seen = registry.generation();
        assert!(matches!(registry.watch(Some(&tab()), seen, key, wake), ProviderWatch::Parked));
        assert_eq!(woken.recv_timeout(Duration::from_millis(300)), Err(RecvTimeoutError::Timeout));
        registry.wake_waiters();
        assert_eq!(woken.recv_timeout(Duration::from_secs(1)), Ok(()));
    }

    /// A wake raised between the caller's cancel check and its watch (the
    /// check can drop the last `Arc<Mux>`, whose drop wakes the registry) is
    /// not lost: the watch reports it instead of parking.
    #[test]
    fn a_wake_since_the_seen_generation_is_reported_not_parked() {
        let registry = BrowserProviderRegistry::default();
        let seen = registry.generation();
        registry.wake_waiters();
        let (wake, woken) = watcher();
        let key = registry.watcher_key();
        assert!(matches!(registry.watch(Some(&tab()), seen, key, wake), ProviderWatch::Moved));
        drop(woken);
        assert!(registry.lock().watchers.is_empty());
    }

    #[test]
    fn a_published_target_wakes_its_watcher_and_is_returned() {
        let registry = BrowserProviderRegistry::default();
        let (wake, woken) = watcher();
        let key = registry.watcher_key();
        let seen = registry.generation();
        assert!(matches!(registry.watch(Some(&tab()), seen, key, wake), ProviderWatch::Parked));
        registry
            .register(1, registration(BTreeMap::from([(tab(), "target-7".to_string())])))
            .unwrap();
        assert_eq!(woken.recv_timeout(Duration::from_secs(1)), Ok(()));
        let seen = registry.generation();
        let ProviderWatch::Target(lease) = registry.watch(Some(&tab()), seen, key, || {}) else {
            panic!("the published target");
        };
        assert_eq!(lease.target_id, "target-7");
    }

    /// A watcher parked again under its key replaces the earlier one, and
    /// unwatch drops it: a bootstrap that retries for hours keeps one.
    #[test]
    fn a_key_holds_one_watcher_and_unwatch_drops_it() {
        let registry = BrowserProviderRegistry::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let key = registry.watcher_key();
        for _ in 0..3 {
            let calls = calls.clone();
            let seen = registry.generation();
            registry.watch(None, seen, key, move || {
                calls.fetch_add(1, Ordering::AcqRel);
            });
        }
        registry.unregister(9);
        registry.wake_waiters();
        assert_eq!(calls.load(Ordering::Acquire), 1);
        let calls_after = calls.clone();
        let seen = registry.generation();
        registry.watch(None, seen, key, move || {
            calls_after.fetch_add(1, Ordering::AcqRel);
        });
        registry.unwatch(key);
        registry.wake_waiters();
        assert_eq!(calls.load(Ordering::Acquire), 1);
    }
}
