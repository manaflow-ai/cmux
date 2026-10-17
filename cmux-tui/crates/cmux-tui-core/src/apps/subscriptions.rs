//! Current stream authority and the fixed, verified-provider inventory invalidation carrier.

use cmux_app_host::ToHost;
use serde_json::{Value, json};

use super::grants::{Decision, ScopeTable};
use super::provider::{ProviderClaim, hosting_app_connection};
use super::supervisor::{ApiError, Host, HostKey, HostState, Inner, Out, Supervisor};

pub(crate) const AGENT_INVENTORY_INVALIDATION_CAPABILITY: &str = "agent-cli-app-invalidation-v1";
pub(super) const INVENTORY_STREAM: &str = "agent_cli.changed";

/// A sequence belongs to this supervisor boot and its current provider connection.
#[derive(Default)]
pub(super) struct InventoryDemand {
    provider: Option<u64>,
    enabled: bool,
    sequence: u64,
    exhausted: bool,
}

impl InventoryDemand {
    pub(super) fn snapshot(&self) -> Value {
        json!({"sequence":self.sequence,"enabled":self.enabled && !self.exhausted})
    }
}

impl Supervisor {
    /// A saved subscription cannot outlive current install, manifest, grant or host facts.
    pub(super) fn stream_readable(inner: &Inner, key: &HostKey, host: &Host, stream: &str) -> bool {
        if host.process.is_none()
            || !matches!(host.state, HostState::Starting | HostState::Running)
            || !inner.mirror.apps.get(&key.app).is_some_and(|r| r.installed && r.enabled)
        {
            return false;
        }
        let Some(family) = stream.strip_suffix(".changed").filter(|s| !s.is_empty()) else {
            return false;
        };
        let grant = Self::grant_for(inner, key);
        let table = ScopeTable::get();
        ["list", "get"].iter().any(|verb| {
            let op = format!("{family}.{verb}");
            matches!(table.check(&op, &Value::Null, &grant), Decision::Allow(_))
                && matches!(table.check(&op, &Value::Null, &host.grant), Decision::Allow(_))
        })
    }

    /// Recomputed at every emitted lifecycle boundary, including an otherwise empty output list.
    pub(super) fn inventory_demand_locked(inner: &mut Inner) -> Option<Out> {
        let provider =
            inner.providers.get("agent_cli").copied().filter(|id| inner.sinks.contains_key(id));
        let enabled = provider.is_some()
            && inner.hosts.iter().any(|(key, host)| {
                Self::stream_readable(inner, key, host, INVENTORY_STREAM)
                    && host.subs.values().any(|stream| stream == INVENTORY_STREAM)
            });
        let demand = &mut inner.inventory_demand;
        if demand.exhausted || (demand.provider == provider && demand.enabled == enabled) {
            return None;
        }
        let Some(sequence) = demand.sequence.checked_add(1) else {
            demand.exhausted = true;
            demand.enabled = false;
            return None;
        };
        demand.provider = provider;
        demand.enabled = enabled;
        demand.sequence = sequence;
        provider.map(|client| {
            Out::Client(
                client,
                json!({
                    "event":"apps-agent-inventory-demand", "sequence":sequence, "enabled":enabled,
                }),
            )
        })
    }

    /// Only the current verified non-agent provider can invalidate current readable subscribers.
    /// No event name, owner selector or payload is supplied by the provider.
    pub fn agent_inventory_changed(
        &self,
        client: u64,
        claim: ProviderClaim,
        sequence: u64,
    ) -> Result<Value, ApiError> {
        if !hosting_app_connection(&claim) {
            return Err(ApiError::new(
                "apps.provider.forbidden",
                "only the verified app provider invalidates inventory",
            ));
        }
        let (demand_event, result) = {
            let mut inner = self.inner.lock().unwrap();
            let event = Self::inventory_demand_locked(&mut inner);
            let demand = &inner.inventory_demand;
            let result = if inner.providers.get("agent_cli") != Some(&client)
                || demand.provider != Some(client)
            {
                Err(ApiError::new(
                    "apps.provider.unknown",
                    "this connection does not provide agent_cli",
                ))
            } else if demand.exhausted || !demand.enabled || demand.sequence != sequence {
                Err(ApiError::new(
                    "apps.provider.stale_demand",
                    "inventory demand is no longer current",
                ))
            } else {
                Self::publish_stream_locked(&inner, INVENTORY_STREAM, json!({}));
                Ok(json!({}))
            };
            (event, result)
        };
        self.emit(demand_event.into_iter().collect());
        result
    }

    /// Host sends only queue; holding the lock orders delivery with revocation and unsubscribe.
    pub(super) fn publish_stream_locked(inner: &Inner, stream: &str, body: Value) {
        for (key, host) in &inner.hosts {
            if !Self::stream_readable(inner, key, host, stream) {
                continue;
            }
            let Some(process) = &host.process else { continue };
            for (sub, _) in host.subs.iter().filter(|(_, s)| s.as_str() == stream) {
                process.send(&ToHost::Event { sub: *sub, body: body.clone() });
            }
        }
    }
}
