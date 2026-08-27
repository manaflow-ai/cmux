use std::collections::BTreeMap;
use std::sync::{Condvar, Mutex};
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserProviderRegistration {
    pub(crate) provider_id: String,
    pub(crate) endpoint: String,
    pub(crate) authentication: BrowserProviderAuthentication,
    pub(crate) targets: BTreeMap<TabPublicId, String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserProviderTargetLease {
    pub(crate) provider_id: String,
    pub(crate) endpoint: String,
    pub(crate) authentication: BrowserProviderAuthentication,
    pub(crate) tab_id: TabPublicId,
    pub(crate) target_id: String,
    pub(crate) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BrowserProviderSnapshot {
    pub(crate) provider_id: String,
    pub(crate) endpoint: String,
    pub(crate) authentication: BrowserProviderAuthentication,
    pub(crate) targets: BTreeMap<TabPublicId, String>,
    pub(crate) revision: u64,
    pub(crate) clients: usize,
}

#[derive(Default)]
struct BrowserProviderState {
    registrations: BTreeMap<u64, BrowserProviderRegistration>,
    revision: u64,
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
        let mut state = self.state.lock().unwrap();
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
                    && existing.authentication == registration.authentication,
                "cmux-browser provider clients disagree on the CDP endpoint or authentication"
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
        let mut state = self.state.lock().unwrap();
        if state.registrations.remove(&client).is_none() {
            return false;
        }
        state.revision = state.revision.wrapping_add(1).max(1);
        self.changed.notify_all();
        true
    }

    pub(crate) fn snapshot(&self) -> Option<BrowserProviderSnapshot> {
        Self::snapshot_locked(&self.state.lock().unwrap())
    }

    pub(crate) fn target(&self, tab_id: &TabPublicId) -> Option<BrowserProviderTargetLease> {
        Self::target_locked(&self.state.lock().unwrap(), tab_id)
    }

    pub(crate) fn wait_for_target(
        &self,
        tab_id: &TabPublicId,
        canceled: impl Fn() -> bool,
    ) -> Option<BrowserProviderTargetLease> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(lease) = Self::target_locked(&state, tab_id) {
                return Some(lease);
            }
            if canceled() {
                return None;
            }
            let (next, _) = self.changed.wait_timeout(state, Duration::from_millis(250)).unwrap();
            state = next;
        }
    }

    pub(crate) fn wait_for_revision_change(
        &self,
        revision: u64,
        canceled: impl Fn() -> bool,
        timeout: Duration,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().unwrap();
        loop {
            if state.revision != revision {
                return true;
            }
            if canceled() {
                return false;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return true;
            }
            let (next, wait) = self.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if wait.timed_out() {
                return true;
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
            targets,
            revision: state.revision,
            clients: state.registrations.len(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(index: u8) -> TabPublicId {
        TabPublicId::parse(format!("tab_{index:032x}")).unwrap()
    }

    fn registration(provider_id: &str, targets: &[(u8, &str)]) -> BrowserProviderRegistration {
        BrowserProviderRegistration {
            provider_id: provider_id.into(),
            endpoint: "ws://127.0.0.1:9222/devtools/browser/test".into(),
            authentication: BrowserProviderAuthentication::None,
            targets: targets
                .iter()
                .map(|(tab_id, target_id)| (tab(*tab_id), (*target_id).to_string()))
                .collect(),
        }
    }

    #[test]
    fn same_process_clients_union_targets_and_oldest_projection_wins() {
        let providers = BrowserProviderRegistry::default();
        providers.register(7, registration("browser-a", &[(1, "target-a")])).unwrap();
        let snapshot = providers
            .register(9, registration("browser-a", &[(1, "target-b"), (2, "target-c")]))
            .unwrap();
        assert_eq!(snapshot.clients, 2);
        assert_eq!(snapshot.targets.get(&tab(1)).map(String::as_str), Some("target-a"));
        assert_eq!(snapshot.targets.get(&tab(2)).map(String::as_str), Some("target-c"));

        assert!(providers.unregister(7));
        let snapshot = providers.snapshot().unwrap();
        assert_eq!(snapshot.targets.get(&tab(1)).map(String::as_str), Some("target-b"));
    }

    #[test]
    fn competing_process_or_endpoint_is_rejected_without_replacing_the_owner() {
        let providers = BrowserProviderRegistry::default();
        providers.register(1, registration("browser-a", &[(1, "target-a")])).unwrap();
        assert!(
            providers
                .register(2, registration("browser-b", &[(2, "target-b")]))
                .unwrap_err()
                .to_string()
                .contains("already attached")
        );
        let mut mismatched = registration("browser-a", &[(2, "target-b")]);
        mismatched.endpoint = "ws://127.0.0.1:9333/devtools/browser/other".into();
        assert!(providers.register(2, mismatched).is_err());
        assert_eq!(providers.snapshot().unwrap().clients, 1);
    }

    #[test]
    fn replacing_one_clients_full_target_set_releases_stale_targets() {
        let providers = BrowserProviderRegistry::default();
        providers
            .register(1, registration("browser-a", &[(1, "target-a"), (2, "target-b")]))
            .unwrap();
        providers.register(1, registration("browser-a", &[(2, "target-b")])).unwrap();
        let snapshot = providers.snapshot().unwrap();
        assert!(!snapshot.targets.contains_key(&tab(1)));
        assert_eq!(snapshot.targets.get(&tab(2)).map(String::as_str), Some("target-b"));
    }
}
