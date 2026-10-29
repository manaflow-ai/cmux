//! The pairing records (`pairing.json`, 0600): tickets and paired devices.
//! Pure: every function takes the time it decides at, so tests drive it
//! without a clock. No secret is kept, only SHA-256 hashes, each compared
//! in constant time.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Role;
use crate::rpc::RpcError;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Store {
    #[serde(default)]
    pub tickets: Vec<TicketRecord>,
    #[serde(default)]
    pub devices: Vec<Device>,
}

/// One minted ticket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TicketRecord {
    pub id: String,
    /// SHA-256 (hex) of the ticket's secret.
    pub hash: String,
    pub role: Role,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub created_ms: u64,
    pub expires_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_ms: Option<u64>,
    /// The device the ticket made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub used_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TicketState {
    Open,
    Used,
    Revoked,
    Expired,
}

impl TicketState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Used => "used",
            Self::Revoked => "revoked",
            Self::Expired => "expired",
        }
    }
}

impl TicketRecord {
    pub fn state(&self, now_ms: u64) -> TicketState {
        if self.revoked_ms.is_some() {
            TicketState::Revoked
        } else if self.used_ms.is_some() {
            TicketState::Used
        } else if now_ms >= self.expires_ms {
            TicketState::Expired
        } else {
            TicketState::Open
        }
    }

    pub fn to_value(&self, now_ms: u64) -> Value {
        json!({
            "id": self.id,
            "role": self.role.as_str(),
            "label": self.label,
            "state": self.state(now_ms).as_str(),
            "created_at": crate::server::iso(self.created_ms),
            "expires_at": crate::server::iso(self.expires_ms),
            "used_at": self.used_ms.map(crate::server::iso),
            "used_by": self.used_by,
            "revoked_at": self.revoked_ms.map(crate::server::iso),
        })
    }
}

/// One paired machine and its credential.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub name: String,
    pub role: Role,
    /// SHA-256 (hex) of the device credential.
    pub token_hash: String,
    pub created_ms: u64,
    /// The ticket it redeemed; None for a credential issued without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticket: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_ms: Option<u64>,
    /// The person let this machine run chats in Full access (`super::full_access`).
    /// Off unless set: a record saved before the setting existed reads as off.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub full_access: bool,
}

impl Device {
    pub fn to_value(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "role": self.role.as_str(),
            "created_at": crate::server::iso(self.created_ms),
            "ticket_id": self.ticket,
            "revoked_at": self.revoked_ms.map(crate::server::iso),
            "full_access": self.full_access,
        })
    }

    /// Whether the setting covers this record now: a live `client` machine
    /// or `phone` with it on. A read-only or daemon-role record never drives
    /// chats here.
    pub fn grants_full_access(&self) -> bool {
        self.full_access && self.revoked_ms.is_none() && self.role.drives_chats()
    }
}

/// What a redeem made: the device and its credential (returned once, never kept).
#[derive(Debug, Clone)]
pub struct Redeemed {
    pub device: Device,
    pub token: String,
}

/// What a revoke changed; `bool` is whether it was already revoked.
#[derive(Debug, Clone)]
pub enum Revoked {
    Ticket(TicketRecord, bool),
    Device(Device, bool),
}

impl Revoked {
    pub fn to_value(&self, closed: usize) -> Value {
        let (kind, id, name, role, already, used_by) = match self {
            Self::Ticket(t, a) => ("ticket", &t.id, None, t.role, *a, t.used_by.as_ref()),
            Self::Device(d, a) => ("device", &d.id, Some(&d.name), d.role, *a, None),
        };
        // `used_by`: the machine a used ticket paired, which revoking the
        // ticket leaves paired.
        json!({
            "revoked": {"kind": kind, "id": id, "name": name, "role": role.as_str(), "already": already, "used_by": used_by},
            "closed_connections": closed,
        })
    }
}

/// A new record id: `prefix` and 12 random hex digits.
pub fn new_id(prefix: &str) -> Result<String, RpcError> {
    let mut bytes = [0u8; 6];
    getrandom::fill(&mut bytes)
        .map_err(|e| RpcError::internal(format!("the OS random generator: {e}")))?;
    Ok(format!("{prefix}_{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()))
}

fn hash(secret: &str) -> String {
    crate::sha256::sha256_hex(secret.as_bytes())
}

/// A live device already has that name; names are how `revoke` and the
/// peer list find a machine, so they stay unique.
fn name_taken(name: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "a machine named {name:?} is already paired here; choose another name, or revoke it first (`cmux host ticket revoke {name}`)"
    ))
    .with_data(json!({"reason": "name_taken"}))
}

/// The refusal a ticket that cannot be redeemed gets. One message for every
/// cause, so a guesser learns nothing; `ticket ls` shows the minter why.
fn ticket_refused() -> RpcError {
    RpcError::invalid_params(
        "this ticket cannot be used: it is unknown, expired, revoked or already used. Mint a new one on the other machine (`cmux host ticket new`).",
    )
    .with_data(json!({"reason": "ticket_refused"}))
}

impl Store {
    pub fn mint(
        &mut self,
        secret: &str,
        role: Role,
        ttl_secs: u64,
        label: Option<String>,
        now_ms: u64,
    ) -> Result<TicketRecord, RpcError> {
        if ttl_secs == 0 || ttl_secs > super::MAX_TTL_SECS {
            return Err(RpcError::invalid_params(format!(
                "a ticket lives 1 to {} seconds",
                super::MAX_TTL_SECS
            )));
        }
        let record = TicketRecord {
            id: new_id("tk")?,
            hash: hash(secret),
            role,
            label: label.filter(|l| !l.trim().is_empty()),
            created_ms: now_ms,
            expires_ms: now_ms.saturating_add(ttl_secs * 1000),
            used_ms: None,
            used_by: None,
            revoked_ms: None,
        };
        // Spent tickets older than a day are dropped; the devices they made stay.
        let horizon = now_ms.saturating_sub(super::MAX_TTL_SECS * 1000);
        self.tickets.retain(|t| t.state(now_ms) == TicketState::Open || t.expires_ms > horizon);
        self.tickets.push(record.clone());
        Ok(record)
    }

    /// The open ticket whose secret is `secret`. Every record is compared, in
    /// constant time, whatever matches first.
    pub fn find_open(&self, secret: &str, now_ms: u64) -> Option<&TicketRecord> {
        let presented = hash(secret);
        let mut found = None;
        for t in &self.tickets {
            if cmux_local_auth::tokens_match(&presented, &t.hash) && found.is_none() {
                found = Some(t);
            }
        }
        found.filter(|t| t.state(now_ms) == TicketState::Open)
    }

    /// Redeem the ticket `secret` for a device `name` with credential `token`.
    /// `check` sees the ticket's role before anything changes; a refusal
    /// from it leaves the ticket open.
    pub fn redeem(
        &mut self,
        secret: &str,
        name: &str,
        token: &str,
        device_id: &str,
        now_ms: u64,
        check: impl FnOnce(Role) -> Result<(), RpcError>,
    ) -> Result<Redeemed, RpcError> {
        crate::session_name::validate(name).map_err(|e| {
            RpcError::invalid_params(format!("the machine name: {e}"))
                .with_data(json!({"reason": "bad_name"}))
        })?;
        let (id, role) = self
            .find_open(secret, now_ms)
            .map(|t| (t.id.clone(), t.role))
            .ok_or_else(ticket_refused)?;
        if self.devices.iter().any(|d| d.revoked_ms.is_none() && d.name == name) {
            return Err(name_taken(name));
        }
        check(role)?;
        let device = self.issue(name, role, token, device_id, Some(id.clone()), now_ms)?;
        if let Some(t) = self.tickets.iter_mut().find(|t| t.id == id) {
            t.used_ms = Some(now_ms);
            t.used_by = Some(device.id.clone());
        }
        Ok(Redeemed { device, token: token.to_owned() })
    }

    pub fn issue(
        &mut self,
        name: &str,
        role: Role,
        token: &str,
        id: &str,
        ticket: Option<String>,
        now_ms: u64,
    ) -> Result<Device, RpcError> {
        crate::session_name::validate(name)
            .map_err(|e| RpcError::invalid_params(format!("the machine name: {e}")))?;
        if self.devices.iter().any(|d| d.revoked_ms.is_none() && d.name == name) {
            return Err(name_taken(name));
        }
        let device = Device {
            id: id.to_owned(),
            name: name.to_owned(),
            role,
            token_hash: hash(token),
            created_ms: now_ms,
            ticket,
            revoked_ms: None,
            full_access: false,
        };
        self.devices.push(device.clone());
        Ok(device)
    }

    /// The live device whose credential is `token`; every record compared.
    pub fn device_for(&self, token: &str) -> Option<&Device> {
        if token.is_empty() {
            return None;
        }
        let presented = hash(token);
        let mut found = None;
        for d in &self.devices {
            if cmux_local_auth::tokens_match(&presented, &d.token_hash) && found.is_none() {
                found = Some(d);
            }
        }
        found.filter(|d| d.revoked_ms.is_none())
    }

    /// `Pairing::issue_phone`: a new `phone` record named `name`. It replaces
    /// the live phone record of that name (removed here, its id returned so
    /// its connections close) and takes its Full-access setting, so a phone
    /// the app issues a credential for at each launch keeps one record. A
    /// live record of another role keeps its name (`name_taken`).
    pub fn issue_phone(
        &mut self,
        name: &str,
        token: &str,
        id: &str,
        now_ms: u64,
    ) -> Result<(Device, Option<String>), RpcError> {
        let old = self
            .devices
            .iter()
            .position(|d| d.revoked_ms.is_none() && d.name == name && d.role == Role::Phone);
        // Names are unique among live records: set the old one aside for the issue's check.
        if let Some(device) = old.and_then(|at| self.devices.get_mut(at)) {
            device.revoked_ms = Some(now_ms);
        }
        let mut device = match self.issue(name, Role::Phone, token, id, None, now_ms) {
            Ok(device) => device,
            Err(e) => {
                if let Some(device) = old.and_then(|at| self.devices.get_mut(at)) {
                    device.revoked_ms = None;
                }
                return Err(e);
            }
        };
        let Some(at) = old else { return Ok((device, None)) };
        let previous = self.devices.remove(at);
        device.full_access = previous.full_access;
        if let Some(new) = self.devices.iter_mut().find(|d| d.id == id) {
            new.full_access = previous.full_access;
        }
        Ok((device, Some(previous.id)))
    }

    /// Turn the Full-access setting of the live device with id or name `key`
    /// on or off. Only a `client` machine or a `phone` drives chats here, so
    /// only one can have it on; turning it off is always accepted.
    pub fn set_full_access(&mut self, key: &str, on: bool) -> Result<Device, RpcError> {
        let at =
            self.devices.iter().position(|d| d.id == key && d.revoked_ms.is_none()).or_else(|| {
                self.devices.iter().position(|d| d.name == key && d.revoked_ms.is_none())
            });
        let d = at.and_then(|at| self.devices.get_mut(at)).ok_or_else(|| {
            RpcError::not_found(format!("no paired machine {key:?}; see `cmux host ticket ls`"))
                .with_data(json!({"reason": "not_found"}))
        })?;
        if on && !d.role.drives_chats() {
            return Err(RpcError::invalid_params(format!(
                "{} is paired {}: only a client machine or a phone drives chats here, so only one can run them in Full access",
                d.name,
                d.role.as_str()
            ))
            .with_data(json!({"reason": "full_access_role"})));
        }
        d.full_access = on;
        Ok(d.clone())
    }

    /// Revoke the ticket or device with id `key`, or the live device named
    /// `key`. Idempotent: revoking a revoked record reports `already`.
    pub fn revoke(&mut self, key: &str, now_ms: u64) -> Result<Revoked, RpcError> {
        if let Some(t) = self.tickets.iter_mut().find(|t| t.id == key) {
            let already = t.revoked_ms.is_some();
            t.revoked_ms.get_or_insert(now_ms);
            return Ok(Revoked::Ticket(t.clone(), already));
        }
        let at =
            self.devices.iter().position(|d| d.id == key).or_else(|| {
                self.devices.iter().position(|d| d.name == key && d.revoked_ms.is_none())
            });
        let d = at.and_then(|at| self.devices.get_mut(at)).ok_or_else(|| {
            RpcError::not_found(format!(
                "no ticket or paired machine {key:?}; see `cmux host ticket ls`"
            ))
            .with_data(json!({"reason": "not_found"}))
        })?;
        let already = d.revoked_ms.is_some();
        d.revoked_ms.get_or_insert(now_ms);
        Ok(Revoked::Device(d.clone(), already))
    }
}
