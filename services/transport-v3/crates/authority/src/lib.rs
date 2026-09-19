//! Server-side policy evaluation. Snapshots must be loaded from trusted storage after Stack
//! authentication; none of these records may be taken from a client's authorization request.

use std::{collections::BTreeMap, str::FromStr};

use cedar_policy::{
    Authorizer, Context, Decision, Entities, EntityUid, PolicySet, Request, Schema, ValidationMode,
    Validator,
};
use cmux_v3_grants::{Grant, LeasePolicy, OfflineAccess, Scope};
use libp2p_identity::PeerId;
use serde_json::json;
use thiserror::Error;

pub const DEFAULT_POLICY: &str = r#"
permit(principal, action in [Action::"connect", Action::"terminal_read", Action::"terminal_write"], resource)
when { principal.team == resource.team };
"#;

const SCHEMA: &str = r#"{
  "": {
    "entityTypes": {"Device": {"shape": {"type": "Record", "attributes": {
      "team": {"type": "String"}, "owner": {"type": "String"},
      "tags": {"type": "Set", "element": {"type": "String"}}
    }}}},
    "actions": {
      "connect": {"appliesTo": {"principalTypes": ["Device"], "resourceTypes": ["Device"]}},
      "terminal_read": {"appliesTo": {"principalTypes": ["Device"], "resourceTypes": ["Device"]}},
      "terminal_write": {"appliesTo": {"principalTypes": ["Device"], "resourceTypes": ["Device"]}},
      "offline_unlimited": {"appliesTo": {"principalTypes": ["Device"], "resourceTypes": ["Device"]}}
    }
  }
}"#;

/// One enrollment per team and key. Tags and leases are administrator-controlled.
pub struct Device {
    pub peer: PeerId,
    pub owner: String,
    pub tags: Vec<String>,
    pub active: bool,
    pub lease: LeasePolicy,
}

pub struct TeamPolicy {
    team: String,
    revision: u64,
    verified_at: u64,
    usable_until: u64,
    devices: BTreeMap<PeerId, Device>,
    policies: PolicySet,
    entities: Entities,
    schema: Schema,
}

impl TeamPolicy {
    /// Load one coherent revision of policy, device status, tags, and membership.
    /// `verified_at` is authoritative state freshness, not replica/cache fetch time.
    pub fn new(
        team: String,
        revision: u64,
        verified_at: u64,
        usable_until: u64,
        devices: Vec<Device>,
        source: &str,
    ) -> Result<Self, Error> {
        if team.is_empty()
            || team.len() > 256
            || usable_until <= verified_at
            || source.len() > 65536
            || devices.len() > 10000
        {
            return Err(Error::InvalidSnapshot);
        }
        let schema = Schema::from_json_value(
            serde_json::from_str(SCHEMA).map_err(|_| Error::InvalidPolicy)?,
        )
        .map_err(|_| Error::InvalidPolicy)?;
        let policies = PolicySet::from_str(source).map_err(|_| Error::InvalidPolicy)?;
        if !Validator::new(schema.clone())
            .validate(&policies, ValidationMode::Strict)
            .validation_passed()
        {
            return Err(Error::InvalidPolicy);
        }
        let mut records = BTreeMap::new();
        for device in devices {
            device.lease.validate()?;
            if device.owner.is_empty() || records.insert(device.peer, device).is_some() {
                return Err(Error::InvalidSnapshot);
            }
        }
        let entity_values: Vec<_> = records
            .values()
            .map(|device| {
                json!({
                    "uid": {"type": "Device", "id": device.peer.to_string()},
                    "attrs": {"team": team, "owner": device.owner, "tags": device.tags},
                    "parents": []
                })
            })
            .collect();
        let entities = Entities::from_json_value(json!(entity_values), Some(&schema))
            .map_err(|_| Error::InvalidSnapshot)?;
        Ok(Self {
            team,
            revision,
            verified_at,
            usable_until,
            devices: records,
            policies,
            entities,
            schema,
        })
    }

    /// The caller supplies a cryptographically authenticated peer, not a client-asserted device ID.
    pub fn authorize(
        &self,
        source: PeerId,
        destination: PeerId,
        action: &str,
        now: u64,
    ) -> Result<Grant, Error> {
        if now < self.verified_at || now >= self.usable_until {
            return Err(Error::StaleSnapshot);
        }
        let device = self.devices.get(&source).ok_or(Error::Denied)?;
        let target = self.devices.get(&destination).ok_or(Error::Denied)?;
        if !device.active || !target.active || action == "offline_unlimited" {
            return Err(Error::Denied);
        }
        self.check(source, destination, action)?;
        if matches!(device.lease.offline, OfflineAccess::UntilRevoked {}) {
            // Unlimited is a separate authority decision, never an unchecked request parameter.
            self.check(source, destination, "offline_unlimited")?;
        }
        Ok(Grant::new(
            Scope {
                team: &self.team,
                source,
                destination,
                action,
            },
            self.revision,
            device.lease,
            self.verified_at,
            now,
        )?)
    }

    fn check(&self, source: PeerId, destination: PeerId, action: &str) -> Result<(), Error> {
        let uid = |kind: &str, id: String| -> Result<EntityUid, Error> {
            Ok(EntityUid::from_type_name_and_id(
                kind.parse().map_err(|_| Error::Denied)?,
                cedar_policy::EntityId::new(id),
            ))
        };
        let request = Request::new(
            uid("Device", source.to_string())?,
            uid("Action", action.into())?,
            uid("Device", destination.to_string())?,
            Context::empty(),
            Some(&self.schema),
        )
        .map_err(|_| Error::Denied)?;
        let response = Authorizer::new().is_authorized(&request, &self.policies, &self.entities);
        // Cedar skips erroneous policies by default. A network authorization must fail closed.
        if response.decision() != Decision::Allow
            || response.diagnostics().errors().next().is_some()
        {
            return Err(Error::Denied);
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid team snapshot")]
    InvalidSnapshot,
    #[error("invalid ACL policy")]
    InvalidPolicy,
    #[error("team authorization state needs refresh")]
    StaleSnapshot,
    #[error("access denied")]
    Denied,
    #[error(transparent)]
    Grant(#[from] cmux_v3_grants::Error),
}
