use std::collections::BTreeMap;
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

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
    /// Bumped by [`BrowserProviderRegistry::wake_waiters`]: a waiter that saw
    /// it change re-checks its cancel predicate.
    wakes: u64,
}

/// Connection-scoped CDP leases published by the native cmux-browser process.
///
/// This registry is intentionally not durable. A DevTools endpoint and target
/// id are capabilities for one live browser process; persisting either would
/// let a restarted daemon attach a journal tab to an unrelated future target.
#[derive(Default)]
pub(crate) struct BrowserProviderRegistry {
    state: Mutex<BrowserProviderState>,
    changed: Condvar,
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

        if state.registrations.get(&client) != Some(&registration) {
            state.registrations.insert(client, registration);
            state.revision = state.revision.wrapping_add(1).max(1);
            self.changed.notify_all();
        }
        Self::snapshot_locked(&state).ok_or_else(|| anyhow::anyhow!("browser provider vanished"))
    }

    pub(crate) fn unregister(&self, client: u64) -> bool {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.registrations.remove(&client).is_none() {
            return false;
        }
        state.revision = state.revision.wrapping_add(1).max(1);
        self.changed.notify_all();
        true
    }

    pub(crate) fn snapshot(&self) -> Option<BrowserProviderSnapshot> {
        Self::snapshot_locked(&self.state.lock().unwrap_or_else(PoisonError::into_inner))
    }

    pub(crate) fn target(&self, tab_id: &TabPublicId) -> Option<BrowserProviderTargetLease> {
        Self::target_locked(&self.state.lock().unwrap_or_else(PoisonError::into_inner), tab_id)
    }

    /// Blocks until a provider publishes `tab_id`'s target, or `canceled`
    /// turns true. It waits for an event only (Chromium's
    /// base/synchronization/waitable_event.h model, no timed re-check):
    /// whatever makes `canceled` true must call [`Self::wake_waiters`].
    pub(crate) fn wait_for_target(
        &self,
        tab_id: &TabPublicId,
        canceled: impl Fn() -> bool,
    ) -> Option<BrowserProviderTargetLease> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if let Some(lease) = Self::target_locked(&state, tab_id) {
                return Some(lease);
            }
            let seen = (state.revision, state.wakes);
            // Unlocked: the predicate can drop the last `Arc<Mux>`, and the
            // mux's drop wakes this registry.
            drop(state);
            if canceled() {
                return None;
            }
            state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            while (state.revision, state.wakes) == seen {
                state = self.changed.wait(state).unwrap_or_else(PoisonError::into_inner);
            }
        }
    }

    /// Wakes every [`Self::wait_for_target`] and
    /// [`Self::wait_for_revision_change`] to re-check its cancel predicate.
    /// Call it after making that predicate true (surface death, mux shutdown,
    /// mux drop).
    pub(crate) fn wake_waiters(&self) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.wakes = state.wakes.wrapping_add(1);
        self.changed.notify_all();
    }

    /// Waits up to `timeout` (a retry backoff) for the registrations to
    /// change. `false` only when `canceled`.
    pub(crate) fn wait_for_revision_change(
        &self,
        revision: u64,
        canceled: impl Fn() -> bool,
        timeout: Duration,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if state.revision != revision {
                return true;
            }
            let wakes = state.wakes;
            drop(state);
            if canceled() {
                return false;
            }
            state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            while state.revision == revision && state.wakes == wakes {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return true;
                }
                state = self
                    .changed
                    .wait_timeout(state, remaining)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            }
        }
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

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc::{RecvTimeoutError, channel};
    use std::thread;
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

    /// A tab waiting for a target no provider publishes checks its cancel
    /// predicate once, then sleeps until `wake_waiters`: the 250 ms re-check
    /// it had woke the daemon 4 times a second (idle_wakeups,
    /// cmux_next_daemon_idle_unprovided_browser_tab).
    #[test]
    fn wait_for_target_checks_cancel_only_when_woken() {
        let registry = Arc::new(BrowserProviderRegistry::default());
        let canceled = Arc::new(AtomicBool::new(false));
        let (checked_tx, checked) = channel();
        let waiter = {
            let registry = registry.clone();
            let canceled = canceled.clone();
            thread::spawn(move || {
                registry.wait_for_target(&tab(), || {
                    checked_tx.send(()).unwrap();
                    canceled.load(Ordering::Acquire)
                })
            })
        };
        checked.recv().unwrap();
        assert_eq!(
            checked.recv_timeout(Duration::from_millis(700)),
            Err(RecvTimeoutError::Timeout),
            "the wait re-checked its cancel predicate on a timer"
        );
        canceled.store(true, Ordering::Release);
        registry.wake_waiters();
        assert_eq!(waiter.join().unwrap(), None);
    }

    /// The predicate may drop the last `Arc<Mux>`, whose drop calls
    /// `wake_waiters`: that must neither deadlock nor be lost.
    #[test]
    fn wait_for_target_takes_a_wake_raised_by_its_own_cancel_check() {
        let registry = Arc::new(BrowserProviderRegistry::default());
        let checks = AtomicUsize::new(0);
        let lease = registry.wait_for_target(&tab(), || {
            if checks.fetch_add(1, Ordering::AcqRel) == 0 {
                registry.wake_waiters();
                false
            } else {
                true
            }
        });
        assert_eq!(lease, None);
        assert_eq!(checks.load(Ordering::Acquire), 2);
    }

    #[test]
    fn wait_for_target_returns_the_target_a_provider_publishes() {
        let registry = Arc::new(BrowserProviderRegistry::default());
        let (checked_tx, checked) = channel();
        let waiter = {
            let registry = registry.clone();
            thread::spawn(move || {
                registry.wait_for_target(&tab(), || {
                    let _ = checked_tx.send(());
                    false
                })
            })
        };
        checked.recv().unwrap();
        registry
            .register(1, registration(BTreeMap::from([(tab(), "target-7".to_string())])))
            .unwrap();
        let lease = waiter.join().unwrap().expect("the published target");
        assert_eq!(lease.target_id, "target-7");
    }

    #[test]
    fn wait_for_revision_change_returns_false_once_canceled_and_woken() {
        let registry = Arc::new(BrowserProviderRegistry::default());
        let canceled = Arc::new(AtomicBool::new(false));
        let (checked_tx, checked) = channel();
        let waiter = {
            let registry = registry.clone();
            let canceled = canceled.clone();
            thread::spawn(move || {
                registry.wait_for_revision_change(
                    0,
                    || {
                        let _ = checked_tx.send(());
                        canceled.load(Ordering::Acquire)
                    },
                    Duration::from_secs(60),
                )
            })
        };
        checked.recv().unwrap();
        canceled.store(true, Ordering::Release);
        registry.wake_waiters();
        assert!(!waiter.join().unwrap());
    }
}
