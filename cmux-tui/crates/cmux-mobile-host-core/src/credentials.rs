//! `MobileHostPhoneCredentials`: the paired phones' own acpmux credentials (`_acpmux/pair_issue`
//! role `phone`), as the approver sync keeps them on its proven connection.
//!
//! - Only [`Credentials::phones`] get one: the paired phones the account lists. Until the account's
//!   list is read, none does, and no record is revoked for being unlisted (a saved setting survives).
//! - Each new connection lists acpmux's phone records (`_acpmux/pair_list`) first, revokes every
//!   live one it must, then issues the missing ones.
//! - A phone that leaves, and an unlisted record, are [`Credentials::ending`]: the live record of
//!   that name is revoked, and no credential goes under that name until a list taken after its last
//!   issue and revoke shows no live record of it.
//! - A refusal is retried on a new connection ([`Credentials::refused`]).
//!
//! The state crosses the app's FFI whole: the app keeps it as JSON between events.

use crate::record_name::acpmux_record_name;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// One request for the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub id: i64,
    pub kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    List,
    Issue { phone: String },
    Revoke { record: String },
}

impl Request {
    pub fn method(&self) -> &'static str {
        match self.kind {
            Kind::List => "_acpmux/pair_list",
            Kind::Issue { .. } => "_acpmux/pair_issue",
            Kind::Revoke { .. } => "_acpmux/pair_revoke",
        }
    }

    pub fn params(&self) -> Value {
        match &self.kind {
            Kind::List => json!({}),
            Kind::Issue { phone } => json!({"name": acpmux_record_name(phone), "role": "phone"}),
            Kind::Revoke { record } => json!({"id": record}),
        }
    }

    /// The request as the app sends it: its id, method and params, and its kind's fields.
    pub fn to_json(&self) -> Value {
        let mut value = json!({"id": self.id, "method": self.method(), "params": self.params()});
        let Some(object) = value.as_object_mut() else { return value };
        match &self.kind {
            Kind::List => {
                object.insert("kind".to_owned(), json!("list"));
            }
            Kind::Issue { phone } => {
                object.insert("kind".to_owned(), json!("issue"));
                object.insert("phone".to_owned(), json!(phone));
            }
            Kind::Revoke { record } => {
                object.insert("kind".to_owned(), json!("revoke"));
                object.insert("record".to_owned(), json!(record));
            }
        }
        value
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Issued {
    pub record: String,
    pub token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Revoking {
    pub record: String,
    pub name: String,
}

/// The credentials' state; a fresh one is [`Credentials::default`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Credentials {
    /// The phones that get a credential (link ids); `None` until the account's list is read.
    pub phones: Option<BTreeSet<String>>,
    paired: BTreeSet<String>,
    /// Record names (`phone-<id>`) whose live records must end before any new credential under them.
    pub ending: BTreeSet<String>,
    issued: BTreeMap<String, Issued>,
    list_owed: bool,
    /// acpmux refused a request: a new connection retries it.
    pub refused: bool,
    connected: bool,
    reconciled: bool,
    #[serde(with = "by_id")]
    issuing: BTreeMap<i64, String>,
    #[serde(with = "by_id")]
    revoking: BTreeMap<i64, Revoking>,
    listing: Option<i64>,
}

impl Default for Credentials {
    fn default() -> Self {
        Self {
            phones: None,
            paired: BTreeSet::new(),
            ending: BTreeSet::new(),
            issued: BTreeMap::new(),
            list_owed: true,
            refused: false,
            connected: false,
            reconciled: false,
            issuing: BTreeMap::new(),
            revoking: BTreeMap::new(),
            listing: None,
        }
    }
}

fn name(phone: &str) -> String {
    acpmux_record_name(phone)
}

impl Credentials {
    /// Each phone's credential by phone device id, as hostd gets them.
    pub fn tokens(&self) -> BTreeMap<String, String> {
        self.issued.iter().map(|(phone, issued)| (phone.clone(), issued.token.clone())).collect()
    }

    /// Whether the sync must keep (or open) its connection for these credentials.
    pub fn needs_connection(&self) -> bool {
        !self.issued.is_empty()
            || !self.ending.is_empty()
            || self.refused
            || self.phones.as_ref().is_some_and(|phones| !phones.is_empty() || self.list_owed)
    }

    /// The paired phones and, once the account's list is read, those it lists.
    pub fn update(
        &mut self,
        paired: BTreeSet<String>,
        listed: Option<BTreeSet<String>>,
        ids: &mut i64,
    ) -> Vec<Request> {
        let wanted: Option<BTreeSet<String>> =
            listed.map(|listed| listed.intersection(&paired).cloned().collect());
        let mut left: BTreeSet<String> = self.paired.difference(&paired).cloned().collect();
        if let (Some(wanted), Some(phones)) = (&wanted, &self.phones) {
            left.extend(phones.difference(wanted).cloned());
        }
        if self.phones.is_none() && wanted.is_some() {
            self.list_owed = true;
        }
        self.paired = paired;
        self.phones = wanted;
        let names: BTreeSet<String> = left.iter().map(|phone| name(phone)).collect();
        self.ending.extend(names.iter().cloned());
        let mut requests = Vec::new();
        let phones: Vec<String> = self.issued.keys().cloned().collect();
        for phone in phones {
            if self.phones.as_ref().is_some_and(|wanted| wanted.contains(&phone)) {
                continue;
            }
            let Some(issued) = self.issued.remove(&phone) else { continue };
            let record_name = name(&phone);
            if !self.ending.contains(&record_name) {
                continue;
            }
            requests.extend(self.revoke(&issued.record, &record_name, ids));
        }
        // A removal with nothing under way for it: a list finds its record, if any.
        if names.iter().any(|name| !self.busy(name)) {
            self.list_owed = true;
        }
        requests.extend(self.list(ids));
        requests.extend(self.issue_missing(ids));
        requests
    }

    /// A new proven connection: the records are listed, then every phone gets a new credential.
    pub fn connected(&mut self, ids: &mut i64) -> Vec<Request> {
        self.connected = true;
        self.reconciled = false;
        self.issued.clear();
        self.list_owed = true;
        self.list(ids)
    }

    /// The connection ended: open requests end with it, and one whose outcome is unknown owes a list.
    pub fn disconnected(&mut self) {
        if !self.issuing.is_empty() || !self.revoking.is_empty() || self.listing.is_some() {
            self.list_owed = true;
        }
        self.connected = false;
        self.reconciled = false;
        self.issuing.clear();
        self.revoking.clear();
        self.listing = None;
    }

    /// The reply to request `id`; `None` when it is not one of these requests.
    pub fn reply(&mut self, id: i64, message: &Value, ids: &mut i64) -> Option<Vec<Request>> {
        let result = message.get("result").and_then(Value::as_object);
        if let Some(phone) = self.issuing.remove(&id) {
            let record_name = name(&phone);
            let issued = result.and_then(|result| {
                Some((
                    result.get("deviceId")?.as_str()?.to_owned(),
                    result.get("token")?.as_str()?.to_owned(),
                ))
            });
            let Some((record, token)) = issued else {
                self.refused = true;
                return Some(self.settle(&record_name, ids));
            };
            self.refused = false;
            if self.ending.contains(&record_name) {
                return Some(self.revoke(&record, &record_name, ids));
            }
            if self.phones.as_ref().is_some_and(|phones| phones.contains(&phone)) {
                self.issued.insert(phone, Issued { record, token });
            }
            return Some(Vec::new());
        }
        if let Some(revoked) = self.revoking.remove(&id) {
            let reason = message.pointer("/error/data/reason").and_then(Value::as_str);
            // Already gone counts as revoked.
            self.refused = result.is_none() && reason != Some("not_found");
            return Some(self.settle(&revoked.name, ids));
        }
        if self.listing != Some(id) {
            return None;
        }
        self.listing = None;
        let Some(result) = result else {
            self.refused = true;
            self.list_owed = true;
            return Some(Vec::new());
        };
        self.refused = false;
        self.reconciled = true;
        let owned: BTreeSet<String> = self
            .phones
            .iter()
            .flatten()
            .map(|phone| name(phone))
            .filter(|name| !self.ending.contains(name))
            .collect();
        let held: BTreeSet<String> =
            self.issued.values().map(|issued| issued.record.clone()).collect();
        let mut live = BTreeSet::new();
        let mut requests = Vec::new();
        let empty = Vec::new();
        let devices = result.get("devices").and_then(Value::as_array).unwrap_or(&empty);
        for device in
            devices.iter().filter_map(Value::as_object).filter(|device| is_live_phone(device))
        {
            let (Some(record), Some(device_name)) = (
                device.get("id").and_then(Value::as_str),
                device.get("name").and_then(Value::as_str),
            ) else {
                continue;
            };
            live.insert(device_name.to_owned());
            if !self.ending.contains(device_name) {
                // An unlisted record ends only once the account's list is read; a phone that left ends always.
                if self.phones.is_none() || owned.contains(device_name) || held.contains(record) {
                    continue;
                }
                self.ending.insert(device_name.to_owned());
            }
            requests.extend(self.revoke(record, device_name, ids));
        }
        let done: Vec<String> = self
            .ending
            .iter()
            .filter(|name| !live.contains(*name) && !self.busy(name))
            .cloned()
            .collect();
        for name in done {
            self.ending.remove(&name);
        }
        requests.extend(self.list(ids));
        requests.extend(self.issue_missing(ids));
        Some(requests)
    }

    fn busy(&self, record_name: &str) -> bool {
        self.issuing.values().any(|phone| name(phone) == record_name)
            || self.revoking.values().any(|revoking| revoking.name == record_name)
    }

    /// The last open request under an ending name ended: a new list shows whether its record is gone.
    fn settle(&mut self, record_name: &str, ids: &mut i64) -> Vec<Request> {
        if !self.ending.contains(record_name) || self.busy(record_name) {
            return Vec::new();
        }
        self.list_owed = true;
        self.list(ids)
    }

    fn list(&mut self, ids: &mut i64) -> Vec<Request> {
        if !self.connected || !self.list_owed || self.listing.is_some() {
            return Vec::new();
        }
        self.list_owed = false;
        *ids += 1;
        self.listing = Some(*ids);
        vec![Request { id: *ids, kind: Kind::List }]
    }

    /// Issues wait for the connection's first list and any list in flight, and never go under an ending name.
    fn issue_missing(&mut self, ids: &mut i64) -> Vec<Request> {
        if !self.connected || !self.reconciled || self.listing.is_some() {
            return Vec::new();
        }
        let Some(phones) = &self.phones else { return Vec::new() };
        let open: BTreeSet<&String> = self.issuing.values().collect();
        let missing: Vec<String> = phones
            .iter()
            .filter(|phone| {
                !self.ending.contains(&name(phone))
                    && !self.issued.contains_key(*phone)
                    && !open.contains(phone)
            })
            .cloned()
            .collect();
        missing
            .into_iter()
            .map(|phone| {
                *ids += 1;
                self.issuing.insert(*ids, phone.clone());
                Request { id: *ids, kind: Kind::Issue { phone } }
            })
            .collect()
    }

    fn revoke(&mut self, record: &str, record_name: &str, ids: &mut i64) -> Vec<Request> {
        if !self.connected || self.revoking.values().any(|revoking| revoking.record == record) {
            return Vec::new();
        }
        *ids += 1;
        self.revoking
            .insert(*ids, Revoking { record: record.to_owned(), name: record_name.to_owned() });
        vec![Request { id: *ids, kind: Kind::Revoke { record: record.to_owned() } }]
    }
}

/// A live phone record: role `phone` and `revoked_at` present and null (Swift's `is NSNull`).
fn is_live_phone(device: &Map<String, Value>) -> bool {
    device.get("role").and_then(Value::as_str) == Some("phone")
        && device.get("revoked_at") == Some(&Value::Null)
}

/// Open requests by id as `[[id, value], ...]`: JSON object keys are strings, and an `op`-tagged
/// request buffers its fields, which then no longer read a string key as an integer.
mod by_id {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::collections::BTreeMap;

    pub fn serialize<T: Serialize, S: Serializer>(
        map: &BTreeMap<i64, T>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(map.iter())
    }

    pub fn deserialize<'de, T: Deserialize<'de>, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<BTreeMap<i64, T>, D::Error> {
        Ok(Vec::<(i64, T)>::deserialize(deserializer)?.into_iter().collect())
    }
}
