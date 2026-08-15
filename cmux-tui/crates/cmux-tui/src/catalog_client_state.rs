//! Client-local order, selection, and attachment state for catalog sessions.
//!
//! Descriptors are process-wide. Selection and connection leases belong to a
//! stable frontend window. Pending switches and live leases are never durable.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::device_session_catalog::{
    CatalogSessionDescriptor, CatalogSessionKey, CatalogSourceId, ResourceAddress, SourceSnapshot,
};

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WindowId(String);

impl WindowId {
    pub fn parse(value: impl Into<String>) -> anyhow::Result<Self> {
        let value = value.into();
        anyhow::ensure!(!value.is_empty() && value.len() <= 256, "invalid catalog window id");
        Ok(Self(value))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SwitchIntentId(u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    Offline,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowSessionLease {
    pub key: CatalogSessionKey,
    pub lease_id: String,
    pub owner_generation: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedSessionView {
    pub workspace_id: Option<String>,
    pub projection: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingSwitch {
    pub target: CatalogSessionKey,
    pub intent: SwitchIntentId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowSelection {
    pub committed: Option<CatalogSessionKey>,
    pub pending: Option<PendingSwitch>,
    pub connection: WindowConnectionState,
    pub lease: Option<WindowSessionLease>,
    pub saved_views: BTreeMap<CatalogSessionKey, SavedSessionView>,
}

impl Default for WindowSelection {
    fn default() -> Self {
        Self {
            committed: None,
            pending: None,
            connection: WindowConnectionState::Disconnected,
            lease: None,
            saved_views: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SwitchStart {
    Noop,
    Pending(SwitchIntentId),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersistedWindowSelection {
    pub committed: Option<CatalogSessionKey>,
    pub saved_views: BTreeMap<CatalogSessionKey, SavedSessionView>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogRouteBinding {
    pub address: ResourceAddress,
    pub registry_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogClientPersistence {
    pub ordered_sessions: Vec<CatalogSessionKey>,
    pub cached_sessions: Vec<CatalogSessionDescriptor>,
    pub windows: BTreeMap<WindowId, PersistedWindowSelection>,
    pub route_bindings: BTreeMap<CatalogSessionKey, CatalogRouteBinding>,
    pub sessions_column_visible: bool,
}

#[derive(Debug, Default)]
pub struct CatalogClientState {
    rows: BTreeMap<CatalogSessionKey, CatalogSessionDescriptor>,
    order: Vec<CatalogSessionKey>,
    source_members: BTreeMap<CatalogSourceId, BTreeSet<CatalogSessionKey>>,
    windows: BTreeMap<WindowId, WindowSelection>,
    route_bindings: BTreeMap<CatalogSessionKey, CatalogRouteBinding>,
    next_intent: u64,
    sessions_column_visible: bool,
}

impl CatalogClientState {
    pub fn new() -> Self {
        Self { next_intent: 1, sessions_column_visible: true, ..Self::default() }
    }

    pub fn from_persistence(persisted: CatalogClientPersistence) -> anyhow::Result<Self> {
        let mut rows = BTreeMap::new();
        let mut source_members = BTreeMap::<CatalogSourceId, BTreeSet<CatalogSessionKey>>::new();
        for mut descriptor in persisted.cached_sessions {
            anyhow::ensure!(
                !rows.contains_key(&descriptor.key),
                "persisted catalog contains a duplicate session key"
            );
            descriptor.owner_state = crate::device_session_catalog::SessionOwnerState::Unavailable;
            source_members
                .entry(descriptor.key.device_id.source_id.clone())
                .or_default()
                .insert(descriptor.key.clone());
            rows.insert(descriptor.key.clone(), descriptor);
        }
        let order_set = persisted.ordered_sessions.iter().cloned().collect::<BTreeSet<_>>();
        anyhow::ensure!(
            order_set.len() == persisted.ordered_sessions.len(),
            "persisted catalog order contains a duplicate session key"
        );
        anyhow::ensure!(
            order_set.iter().all(|key| rows.contains_key(key)),
            "persisted catalog order contains an unknown session key"
        );
        let windows = persisted
            .windows
            .into_iter()
            .map(|(window, selection)| {
                (
                    window,
                    WindowSelection {
                        committed: selection.committed,
                        pending: None,
                        connection: WindowConnectionState::Disconnected,
                        lease: None,
                        saved_views: selection.saved_views,
                    },
                )
            })
            .collect();
        Ok(Self {
            rows,
            order: persisted.ordered_sessions,
            source_members,
            windows,
            route_bindings: persisted.route_bindings,
            next_intent: 1,
            sessions_column_visible: persisted.sessions_column_visible,
        })
    }

    pub fn reconcile_source(&mut self, snapshot: SourceSnapshot) -> anyhow::Result<()> {
        let source_id = snapshot.source_id;
        let previous = self.source_members.get(&source_id).cloned().unwrap_or_default();
        let mut present = BTreeSet::new();
        for descriptor in snapshot.sessions {
            let key = descriptor.key.clone();
            if descriptor.tombstoned {
                self.rows.remove(&key);
                self.order.retain(|candidate| candidate != &key);
                continue;
            }
            if let (Some(address), Some(registry_id)) =
                (&descriptor.resource_address, &descriptor.registry_id)
            {
                self.bind_verified_route(
                    key.clone(),
                    CatalogRouteBinding {
                        address: address.clone(),
                        registry_id: registry_id.clone(),
                    },
                )?;
            }
            if !self.rows.contains_key(&key) {
                self.order.push(key.clone());
            }
            present.insert(key.clone());
            self.rows.insert(key, descriptor);
        }
        for missing in previous.difference(&present) {
            if let Some(row) = self.rows.get_mut(missing) {
                row.owner_state = crate::device_session_catalog::SessionOwnerState::Unavailable;
            }
        }
        self.source_members.insert(source_id, present);
        Ok(())
    }

    pub fn bind_verified_route(
        &mut self,
        key: CatalogSessionKey,
        binding: CatalogRouteBinding,
    ) -> anyhow::Result<()> {
        if let Some(existing) = self.route_bindings.get(&key) {
            anyhow::ensure!(existing == &binding, "catalog route changed its verified identity");
            return Ok(());
        }
        self.route_bindings.insert(key, binding);
        Ok(())
    }

    pub fn route_binding(&self, key: &CatalogSessionKey) -> Option<&CatalogRouteBinding> {
        self.route_bindings.get(key)
    }

    pub fn rows_in_order(&self) -> Vec<&CatalogSessionDescriptor> {
        let mut seen_addresses = BTreeSet::new();
        self.order
            .iter()
            .filter_map(|key| {
                let row = self.rows.get(key)?;
                let address = self.route_bindings.get(key).map(|binding| &binding.address);
                if address.is_some_and(|address| !seen_addresses.insert(address.clone())) {
                    return None;
                }
                Some(row)
            })
            .collect()
    }

    pub fn reorder(
        &mut self,
        key: &CatalogSessionKey,
        before: Option<&CatalogSessionKey>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(self.rows.contains_key(key), "cannot reorder an unknown session");
        if before == Some(key) {
            return Ok(());
        }
        self.order.retain(|candidate| candidate != key);
        let index = before
            .and_then(|before| self.order.iter().position(|candidate| candidate == before))
            .unwrap_or(self.order.len());
        self.order.insert(index, key.clone());
        Ok(())
    }

    pub fn start_switch(
        &mut self,
        window: WindowId,
        target: CatalogSessionKey,
    ) -> anyhow::Result<SwitchStart> {
        anyhow::ensure!(self.rows.contains_key(&target), "cannot switch to an unknown session");
        let state = self.windows.entry(window).or_default();
        if state.committed.as_ref() == Some(&target) && state.pending.is_none() {
            return Ok(SwitchStart::Noop);
        }
        if let Some(pending) = &state.pending
            && pending.target == target
        {
            return Ok(SwitchStart::Pending(pending.intent));
        }
        let intent = SwitchIntentId(self.next_intent);
        self.next_intent = self.next_intent.checked_add(1).context("switch intent exhausted")?;
        state.pending = Some(PendingSwitch { target, intent });
        Ok(SwitchStart::Pending(intent))
    }

    pub fn commit_switch(
        &mut self,
        window: &WindowId,
        intent: SwitchIntentId,
        lease: WindowSessionLease,
    ) -> Option<WindowSessionLease> {
        let state = self.windows.get_mut(window)?;
        let pending = state.pending.as_ref()?;
        if pending.intent != intent || pending.target != lease.key {
            return None;
        }
        state.pending = None;
        state.committed = Some(lease.key.clone());
        state.connection = WindowConnectionState::Connected;
        state.lease.replace(lease)
    }

    pub fn fail_switch(&mut self, window: &WindowId, intent: SwitchIntentId) -> bool {
        let Some(state) = self.windows.get_mut(window) else { return false };
        if state.pending.as_ref().is_none_or(|pending| pending.intent != intent) {
            return false;
        }
        state.pending = None;
        state.connection = if state.lease.is_some() {
            WindowConnectionState::Connected
        } else {
            WindowConnectionState::Failed
        };
        true
    }

    pub fn mark_source_offline(&mut self, source_id: &CatalogSourceId) {
        let keys = self.source_members.get(source_id).cloned().unwrap_or_default();
        for key in &keys {
            if let Some(row) = self.rows.get_mut(key) {
                row.owner_state = crate::device_session_catalog::SessionOwnerState::Unavailable;
            }
        }
        for state in self.windows.values_mut() {
            if state.committed.as_ref().is_some_and(|key| keys.contains(key)) {
                state.connection = WindowConnectionState::Reconnecting;
            }
        }
    }

    pub fn save_view(&mut self, window: &WindowId, key: CatalogSessionKey, view: SavedSessionView) {
        self.windows.entry(window.clone()).or_default().saved_views.insert(key, view);
    }

    pub fn selection(&self, window: &WindowId) -> Option<&WindowSelection> {
        self.windows.get(window)
    }

    pub fn set_sessions_column_visible(&mut self, visible: bool) {
        self.sessions_column_visible = visible;
    }

    pub fn persistence(&self) -> CatalogClientPersistence {
        CatalogClientPersistence {
            ordered_sessions: self.order.clone(),
            cached_sessions: self
                .order
                .iter()
                .filter_map(|key| self.rows.get(key).cloned())
                .collect(),
            windows: self
                .windows
                .iter()
                .map(|(window, state)| {
                    (
                        window.clone(),
                        PersistedWindowSelection {
                            committed: state.committed.clone(),
                            saved_views: state.saved_views.clone(),
                        },
                    )
                })
                .collect(),
            route_bindings: self.route_bindings.clone(),
            sessions_column_visible: self.sessions_column_visible,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use cmux_tui_core::resource::{MachinePublicId, SessionPublicId};

    use super::*;
    use crate::device_session_catalog::{
        CatalogDeviceId, CatalogSessionId, CatalogSourceId, ResourceAddress, SessionOwnerState,
    };

    fn key(machine_digit: char, session_digit: char) -> CatalogSessionKey {
        let machine =
            MachinePublicId::parse(format!("machine_{}", machine_digit.to_string().repeat(32)))
                .unwrap();
        let session =
            SessionPublicId::parse(format!("session_{}", session_digit.to_string().repeat(32)))
                .unwrap();
        CatalogSessionKey {
            device_id: CatalogDeviceId::local(&machine),
            session_id: CatalogSessionId::Public(session),
        }
    }

    fn descriptor(key: CatalogSessionKey, order: u64) -> CatalogSessionDescriptor {
        let CatalogSessionId::Public(session_id) = &key.session_id else { unreachable!() };
        let machine_id = MachinePublicId::parse(key.device_id.route_id.clone()).unwrap();
        CatalogSessionDescriptor {
            key,
            resource_address: Some(ResourceAddress { machine_id, session_id: session_id.clone() }),
            registry_id: Some(format!("registry-{order}")),
            display_name: format!("Session {order}"),
            aliases: Vec::new(),
            owner_state: SessionOwnerState::Stopped,
            capabilities: BTreeSet::new(),
            source_order: order,
            last_seen_unix_ms: None,
            tombstoned: false,
        }
    }

    fn state_with(keys: &[CatalogSessionKey]) -> CatalogClientState {
        let source_id = keys[0].device_id.source_id.clone();
        let mut state = CatalogClientState::new();
        state
            .reconcile_source(SourceSnapshot {
                source_id,
                generation: "generation-1".to_string(),
                revision: 1,
                devices: Vec::new(),
                sessions: keys
                    .iter()
                    .enumerate()
                    .map(|(index, key)| descriptor(key.clone(), index as u64))
                    .collect(),
            })
            .unwrap();
        state
    }

    fn lease(key: CatalogSessionKey, id: &str) -> WindowSessionLease {
        WindowSessionLease {
            key,
            lease_id: id.to_string(),
            owner_generation: format!("generation-{id}"),
        }
    }

    #[test]
    fn two_windows_can_commit_different_sessions() {
        let first = key('1', 'a');
        let second = key('1', 'b');
        let mut state = state_with(&[first.clone(), second.clone()]);
        let left = WindowId::parse("left").unwrap();
        let right = WindowId::parse("right").unwrap();
        let SwitchStart::Pending(left_intent) =
            state.start_switch(left.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        let SwitchStart::Pending(right_intent) =
            state.start_switch(right.clone(), second.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };

        state.commit_switch(&left, left_intent, lease(first.clone(), "left"));
        state.commit_switch(&right, right_intent, lease(second.clone(), "right"));

        assert_eq!(state.selection(&left).unwrap().committed.as_ref(), Some(&first));
        assert_eq!(state.selection(&right).unwrap().committed.as_ref(), Some(&second));
    }

    #[test]
    fn stale_switch_completion_cannot_replace_a_newer_intent() {
        let first = key('2', 'a');
        let second = key('2', 'b');
        let mut state = state_with(&[first.clone(), second.clone()]);
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(old_intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        let SwitchStart::Pending(new_intent) =
            state.start_switch(window.clone(), second.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };

        assert_eq!(state.commit_switch(&window, old_intent, lease(first, "old")), None);
        state.commit_switch(&window, new_intent, lease(second.clone(), "new"));
        assert_eq!(state.selection(&window).unwrap().committed.as_ref(), Some(&second));
    }

    #[test]
    fn switch_failure_keeps_the_previous_window_session() {
        let first = key('3', 'a');
        let second = key('3', 'b');
        let mut state = state_with(&[first.clone(), second.clone()]);
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(first_intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        state.commit_switch(&window, first_intent, lease(first.clone(), "first"));
        let SwitchStart::Pending(second_intent) =
            state.start_switch(window.clone(), second).unwrap()
        else {
            panic!("expected pending switch")
        };

        assert!(state.fail_switch(&window, second_intent));
        let selection = state.selection(&window).unwrap();
        assert_eq!(selection.committed.as_ref(), Some(&first));
        assert_eq!(selection.lease.as_ref().unwrap().lease_id, "first");
    }

    #[test]
    fn switch_away_releases_only_the_window_attachment() {
        let first = key('4', 'a');
        let second = key('4', 'b');
        let mut state = state_with(&[first.clone(), second.clone()]);
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(first_intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        state.commit_switch(&window, first_intent, lease(first, "first"));
        let SwitchStart::Pending(second_intent) =
            state.start_switch(window.clone(), second.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };

        let released =
            state.commit_switch(&window, second_intent, lease(second, "second")).unwrap();
        assert_eq!(released.lease_id, "first");
        assert_eq!(state.rows_in_order().len(), 2);
    }

    #[test]
    fn hiding_sessions_column_keeps_the_active_lease() {
        let first = key('5', 'a');
        let mut state = state_with(std::slice::from_ref(&first));
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        state.commit_switch(&window, intent, lease(first, "lease"));

        state.set_sessions_column_visible(false);
        assert_eq!(state.selection(&window).unwrap().lease.as_ref().unwrap().lease_id, "lease");
    }

    #[test]
    fn persistence_omits_pending_switches_and_live_leases() {
        let first = key('6', 'a');
        let second = key('6', 'b');
        let mut state = state_with(&[first.clone(), second.clone()]);
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(first_intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        state.commit_switch(&window, first_intent, lease(first, "secret-lease"));
        state.start_switch(window, second).unwrap();

        let encoded = serde_json::to_string(&state.persistence()).unwrap();
        assert!(!encoded.contains("pending"));
        assert!(!encoded.contains("secret-lease"));
        assert!(!encoded.contains("owner_generation"));
    }

    #[test]
    fn client_restart_restores_window_selection_flat_order_and_offline_rows() {
        let first = key('a', 'a');
        let second = key('a', 'b');
        let mut state = state_with(&[first.clone(), second.clone()]);
        state.reorder(&second, Some(&first)).unwrap();
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        state.commit_switch(&window, intent, lease(first.clone(), "lease"));

        let restored = CatalogClientState::from_persistence(state.persistence()).unwrap();
        assert_eq!(
            restored.rows_in_order().into_iter().map(|row| row.key.clone()).collect::<Vec<_>>(),
            [second, first.clone()]
        );
        let selection = restored.selection(&window).unwrap();
        assert_eq!(selection.committed.as_ref(), Some(&first));
        assert_eq!(selection.connection, WindowConnectionState::Disconnected);
        assert!(selection.pending.is_none());
        assert!(selection.lease.is_none());
        assert!(
            restored
                .rows_in_order()
                .iter()
                .all(|row| row.owner_state == SessionOwnerState::Unavailable)
        );
    }

    #[test]
    fn provider_disconnect_keeps_last_known_rows_and_selection() {
        let first = key('7', 'a');
        let source = first.device_id.source_id.clone();
        let mut state = state_with(std::slice::from_ref(&first));
        let window = WindowId::parse("window").unwrap();
        let SwitchStart::Pending(intent) =
            state.start_switch(window.clone(), first.clone()).unwrap()
        else {
            panic!("expected pending switch")
        };
        state.commit_switch(&window, intent, lease(first.clone(), "lease"));

        state.mark_source_offline(&source);
        assert_eq!(state.rows_in_order().len(), 1);
        assert_eq!(state.selection(&window).unwrap().committed.as_ref(), Some(&first));
        assert_eq!(
            state.selection(&window).unwrap().connection,
            WindowConnectionState::Reconnecting
        );
    }

    #[test]
    fn flat_order_reconciles_new_and_offline_rows_by_catalog_key() {
        let first = key('8', 'a');
        let second = key('8', 'b');
        let third = key('8', 'c');
        let source_id: CatalogSourceId = first.device_id.source_id.clone();
        let mut state = state_with(&[first.clone(), second.clone()]);
        state.reorder(&second, Some(&first)).unwrap();
        state
            .reconcile_source(SourceSnapshot {
                source_id,
                generation: "generation-2".to_string(),
                revision: 2,
                devices: Vec::new(),
                sessions: vec![descriptor(first.clone(), 0), descriptor(third.clone(), 2)],
            })
            .unwrap();
        let keys = state.rows_in_order().into_iter().map(|row| row.key.clone()).collect::<Vec<_>>();
        assert_eq!(keys, [second, first, third]);
    }

    #[test]
    fn reconnect_rejects_a_changed_resource_identity_for_the_same_route() {
        let first = key('9', 'a');
        let mut state = state_with(std::slice::from_ref(&first));
        let changed = CatalogRouteBinding {
            address: ResourceAddress {
                machine_id: MachinePublicId::parse(format!("machine_{}", "9".repeat(32))).unwrap(),
                session_id: SessionPublicId::parse(format!("session_{}", "b".repeat(32))).unwrap(),
            },
            registry_id: "registry-0".to_string(),
        };

        let error = state.bind_verified_route(first, changed).unwrap_err();
        assert!(error.to_string().contains("changed its verified identity"));
    }

    #[test]
    fn verified_routes_with_same_resource_address_share_one_presented_row() {
        let local = key('b', 'a');
        let address = match &local.session_id {
            CatalogSessionId::Public(session_id) => ResourceAddress {
                machine_id: MachinePublicId::parse(local.device_id.route_id.clone()).unwrap(),
                session_id: session_id.clone(),
            },
            CatalogSessionId::ProviderV1Singleton => unreachable!(),
        };
        let provider_source = CatalogSourceId::provider_v1("test", "scope").unwrap();
        let provider = CatalogSessionKey::provider_v1(CatalogDeviceId::provider(
            provider_source.clone(),
            "machine-route",
        ));
        let mut provider_descriptor = descriptor(local.clone(), 0);
        provider_descriptor.key = provider.clone();
        provider_descriptor.resource_address = Some(address.clone());
        provider_descriptor.registry_id = Some("registry-0".to_string());
        let mut state = state_with(std::slice::from_ref(&local));

        state
            .reconcile_source(SourceSnapshot {
                source_id: provider_source,
                generation: "generation-provider".to_string(),
                revision: 1,
                devices: Vec::new(),
                sessions: vec![provider_descriptor],
            })
            .unwrap();

        assert_eq!(state.rows.len(), 2);
        assert_eq!(state.rows_in_order().len(), 1);
        assert_eq!(state.route_binding(&provider).unwrap().address, address);
    }
}
