//! Server-readable browser sync records: the profile list and the space and workspace bindings (RFD 0125 D8, first
//! row of the table). One record per `(kind, id)`; the newest write wins, ordered by `(updated_at_ms, device)`, and a
//! deletion is a tombstone record that wins the same way, so a profile deleted on one Mac is not brought back by
//! another that still holds it.
//!
//! [`sync_once`] is one round: diff the local list against the last merged view ([`SyncState::known`]), push what
//! changed, pull everything the server took since the cursor, and answer the [`Change`]s to apply locally. The
//! server (cmux-platform `POST /v1/sync/browser/records`) runs the same [`wins`] rule, so the two agree.

use std::collections::BTreeMap;

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// What a record is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// A browser profile: `{name, color, icon}`; id `default` or a lowercase UUID (stable, never reused, D3).
    Profile,
    /// A space's or workspace's default profile: id `space:<id>` or `workspace:<id>`, value `{profile}`.
    Binding,
}

/// One synced record. `value` is `None` on a tombstone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub kind: Kind,
    pub id: String,
    pub updated_at_ms: u64,
    pub device: String,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
}

impl Record {
    pub fn key(&self) -> (Kind, String) {
        (self.kind, self.id.clone())
    }
}

/// Last writer wins: does `incoming` replace `current`? Later `updated_at_ms` wins; a tie goes to the greater device
/// id, so every replica picks the same winner. An identical stamp never replaces (idempotent re-push).
pub fn wins(incoming: &Record, current: &Record) -> bool {
    (incoming.updated_at_ms, incoming.device.as_str())
        > (current.updated_at_ms, current.device.as_str())
}

/// The longest id the server takes.
pub const MAX_ID: usize = 160;
/// The most records one push carries.
pub const MAX_PUSH: usize = 500;

/// Checks a record's shape before it is sent (the server checks the same).
pub fn validate(record: &Record) -> anyhow::Result<()> {
    if record.id.is_empty() || record.id.len() > MAX_ID {
        bail!("bad record: id must be 1 to {MAX_ID} characters");
    }
    if record.device.is_empty() || record.device.len() > MAX_ID {
        bail!("bad record: device must be 1 to {MAX_ID} characters");
    }
    match (record.deleted, &record.value) {
        (true, None) => Ok(()),
        (true, Some(_)) => bail!("bad record: a tombstone carries no value"),
        (false, None) => bail!("bad record: a live record carries a value"),
        (false, Some(value)) => match record.kind {
            Kind::Profile => {
                let name = value.get("name").and_then(Value::as_str).unwrap_or_default();
                if name.trim().is_empty() || name.len() > 200 {
                    bail!("bad record: a profile needs a name of 1 to 200 characters");
                }
                for field in ["color", "icon"] {
                    match value.get(field) {
                        None | Some(Value::Null) | Some(Value::String(_)) => {}
                        Some(_) => bail!("bad record: profile {field} must be a string or null"),
                    }
                }
                Ok(())
            }
            Kind::Binding => {
                if !(record.id.starts_with("space:") || record.id.starts_with("workspace:")) {
                    bail!("bad record: a binding id is space:<id> or workspace:<id>");
                }
                if value.get("profile").and_then(Value::as_str).is_none_or(str::is_empty) {
                    bail!("bad record: a binding names its profile");
                }
                Ok(())
            }
        },
    }
}

/// A profile as the local store holds it, reduced to what syncs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalProfile {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
}

impl LocalProfile {
    pub fn value(&self) -> Value {
        json!({ "name": self.name, "color": self.color, "icon": self.icon })
    }

    pub fn from_record(record: &Record) -> Option<Self> {
        let value = record.value.as_ref()?;
        Some(Self {
            id: record.id.clone(),
            name: value.get("name")?.as_str()?.to_owned(),
            color: value.get("color").and_then(Value::as_str).map(str::to_owned),
            icon: value.get("icon").and_then(Value::as_str).map(str::to_owned),
        })
    }
}

/// The local side's current records: live ones only, keyed by `(kind, id)` with their value.
pub type LocalView = BTreeMap<(Kind, String), Value>;

/// Builds a [`LocalView`] from the local profile list and bindings (`space:<id>` or `workspace:<id>` to a profile).
pub fn local_view(profiles: &[LocalProfile], bindings: &[(String, String)]) -> LocalView {
    let mut view = LocalView::new();
    for profile in profiles {
        view.insert((Kind::Profile, profile.id.clone()), profile.value());
    }
    for (scope, profile) in bindings {
        view.insert((Kind::Binding, scope.clone()), json!({ "profile": profile }));
    }
    view
}

/// What a device keeps between rounds: the server cursor and the merged view it last saw.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    pub cursor: u64,
    #[serde(with = "known_as_list")]
    pub known: BTreeMap<(Kind, String), Record>,
}

mod known_as_list {
    use super::{Kind, Record};
    use serde::{Deserialize, Deserializer, Serializer};
    use std::collections::BTreeMap;

    pub fn serialize<S: Serializer>(
        map: &BTreeMap<(Kind, String), Record>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(map.values())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<BTreeMap<(Kind, String), Record>, D::Error> {
        let list = Vec::<Record>::deserialize(deserializer)?;
        Ok(list.into_iter().map(|record| (record.key(), record)).collect())
    }
}

/// The records this device must push: local values that differ from the merged view, stamped `now_ms`, and
/// tombstones for what the merged view holds live but the device no longer has.
pub fn outgoing(local: &LocalView, state: &SyncState, device: &str, now_ms: u64) -> Vec<Record> {
    let mut out = Vec::new();
    for ((kind, id), value) in local {
        let same = state
            .known
            .get(&(*kind, id.clone()))
            .is_some_and(|known| !known.deleted && known.value.as_ref() == Some(value));
        if !same {
            out.push(Record {
                kind: *kind,
                id: id.clone(),
                updated_at_ms: now_ms,
                device: device.to_owned(),
                deleted: false,
                value: Some(value.clone()),
            });
        }
    }
    for (key, known) in &state.known {
        if !known.deleted && !local.contains_key(key) {
            out.push(Record {
                kind: key.0,
                id: key.1.clone(),
                updated_at_ms: now_ms,
                device: device.to_owned(),
                deleted: true,
                value: None,
            });
        }
    }
    out
}

/// A change to make to the local store so it matches the merged view.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    /// Create or update the record (the caller knows which from its own store).
    Put { kind: Kind, id: String, value: Value },
    /// Delete the record.
    Delete { kind: Kind, id: String },
}

/// Folds `pulled` into `state` by [`wins`] and answers the changes that bring `local` to the merged view.
pub fn merge(local: &LocalView, state: &mut SyncState, pulled: Vec<Record>) -> Vec<Change> {
    for record in pulled {
        let key = record.key();
        let take = state
            .known
            .get(&key)
            .is_none_or(|current| wins(&record, current) || *current == record);
        if take {
            state.known.insert(key, record);
        }
    }
    let mut changes = Vec::new();
    for (key, known) in &state.known {
        let here = local.get(key);
        match (known.deleted, here) {
            (true, Some(_)) => changes.push(Change::Delete { kind: key.0, id: key.1.clone() }),
            (false, here) if here != known.value.as_ref() => {
                if let Some(value) = &known.value {
                    changes.push(Change::Put {
                        kind: key.0,
                        id: key.1.clone(),
                        value: value.clone(),
                    });
                }
            }
            _ => {}
        }
    }
    changes
}

/// The server's answer to a push: every record it took since the cursor (ours included, as merged) and the new
/// cursor.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullResult {
    pub cursor: u64,
    pub records: Vec<Record>,
}

/// One push and pull against the account store.
#[allow(async_fn_in_trait)]
pub trait Transport {
    async fn exchange(&self, since: u64, push: &[Record]) -> anyhow::Result<PullResult>;
}

/// The outcome of [`sync_once`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Round {
    pub pushed: usize,
    pub pulled: usize,
    pub changes: Vec<Change>,
}

/// One round: push the local differences, pull since the cursor, merge, and answer what to apply locally. `state`
/// is updated only when the server answered, so a failed round is retried whole.
pub async fn sync_once<T: Transport>(
    transport: &T,
    local: &LocalView,
    state: &mut SyncState,
    device: &str,
    now_ms: u64,
) -> anyhow::Result<Round> {
    let push = outgoing(local, state, device, now_ms);
    for record in &push {
        validate(record).with_context(|| format!("local {:?} {}", record.kind, record.id))?;
    }
    let mut pulled = PullResult { cursor: state.cursor, records: Vec::new() };
    // Chunked so a first sync of a large list never exceeds the server's per-push cap.
    let mut chunks: Vec<&[Record]> = push.chunks(MAX_PUSH).collect();
    if chunks.is_empty() {
        chunks.push(&[]);
    }
    for chunk in chunks {
        let answer = transport.exchange(pulled.cursor, chunk).await?;
        pulled.cursor = answer.cursor;
        pulled.records.extend(answer.records);
    }
    let pulled_count = pulled.records.len();
    let mut next = state.clone();
    next.cursor = pulled.cursor;
    let changes = merge(local, &mut next, pulled.records);
    *state = next;
    Ok(Round { pushed: push.len(), pulled: pulled_count, changes })
}

/// The account store over HTTPS: `POST {origin}/v1/sync/browser/records` with a person's cmux access token.
pub struct HttpTransport {
    origin: String,
    token: String,
    http: reqwest::Client,
}

impl HttpTransport {
    pub fn new(origin: &str, token: &str) -> anyhow::Result<Self> {
        let origin = origin.trim_end_matches('/');
        if !(origin.starts_with("https://") || origin.starts_with("http://127.0.0.1")) {
            bail!("browser sync origin must be https");
        }
        let http = cmux_egress::client_builder("cmux_browser_sync::records")
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux-browser-sync/", env!("CARGO_PKG_VERSION")))
            .timeout(std::time::Duration::from_secs(30))
            .build()?;
        Ok(Self { origin: origin.to_owned(), token: token.to_owned(), http })
    }
}

impl Transport for HttpTransport {
    async fn exchange(&self, since: u64, push: &[Record]) -> anyhow::Result<PullResult> {
        let url = format!("{}/v1/sync/browser/records", self.origin);
        let response = self
            .http
            .post(&url)
            .bearer_auth(&self.token)
            .json(&json!({ "since": since, "records": push }))
            .send()
            .await
            .map_err(|error| {
                anyhow::anyhow!("browser sync did not answer: {}", error.without_url())
            })?;
        let status = response.status();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            let code = body.get("code").and_then(Value::as_str).unwrap_or("");
            bail!("browser sync refused: {} {code}", status.as_u16());
        }
        serde_json::from_value(body).context("browser sync answer")
    }
}

#[cfg(test)]
#[path = "records_seeded_tests.rs"]
mod seeded_tests;
