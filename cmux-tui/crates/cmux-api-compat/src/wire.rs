//! Wire id rules: the ids, families, priorities and binary layouts the schema
//! files give the frame protocol must never change meaning under a peer.
//!
//! The schema files (`spec/sdk-schema.json` for the v12 commands and events,
//! `spec/resource-operations-v2.json` for the v2 operations) carry a
//! `families` table (name -> family byte) and, per command, operation or
//! event, a `method_id` / `event_id` (`family << 8 | ordinal`), a
//! `priority` and, for binary payloads, a `layout_version`.
//! `spec/api-compat.wire.json` keeps an append-only ledger of everything
//! ever given out ([`WireLedgers`]). It is a file of its own because the
//! daemon compiles `spec/api-compat.json` in and needs no ledger.
//! [`check`] compares a schema file with its ledger and refuses:
//!
//! - an id given to a second name (live or retired),
//! - a renumbered method, event or family,
//! - a removed name without a tombstone, and a tombstoned name coming back,
//! - a priority change without a new `priority_changed_reason`,
//! - a binary layout change without a `layout_version` bump.
//!
//! This is protobuf's field-number discipline (`reserved` numbers and names)
//! and Chromium's Mojo `[MinVersion]`/stable-ordinal rule for interfaces
//! (mojo/public/tools/mojom/check_stable_mojom_compatibility.py).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::CompatError;

/// The ledger file (`spec/api-compat.wire.json`): schema file name
/// ([`SDK_SCHEMA`], [`RESOURCE_OPERATIONS`]) -> its [`WireLedger`].
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WireLedgers {
    /// One ledger per schema file.
    pub files: BTreeMap<String, WireLedger>,
}

/// The append-only record of one schema file's wire ids. An id stays in it
/// forever: a removed family, method or event keeps its entry with a
/// `removed` reason (a tombstone), so its id is never given out again
/// (protobuf `reserved`; Chromium marks retired histogram enum values
/// obsolete instead of deleting them, tools/metrics/histograms/enums.xml).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireLedger {
    /// Family name -> its id byte (the high byte of every id in the family).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub families: BTreeMap<String, FamilyRecord>,
    /// Command or operation name -> its `method_id`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub methods: BTreeMap<String, IdRecord>,
    /// Event name -> its `event_id`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub events: BTreeMap<String, IdRecord>,
}

/// One family in a [`WireLedger`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FamilyRecord {
    /// The family byte.
    pub id: u8,
    /// Why the family was removed; its id and name stay retired.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<String>,
}

/// One method or event in a [`WireLedger`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IdRecord {
    /// `family << 8 | ordinal`.
    pub id: u16,
    /// The priority last recorded (`input`, `control`, `bulk`, `background`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    /// The `priority_changed_reason` of the last accepted priority change; a
    /// later change needs a different reason.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority_reason: Option<String>,
    /// The last binary layout this id used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<LayoutRecord>,
    /// Why the name was removed; its id and name stay retired.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<String>,
}

/// A binary payload layout: its version byte and a fingerprint of the
/// fields it encodes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutRecord {
    /// The layout version byte the schema declares.
    pub version: u8,
    /// FNV-1a 64 of the canonical JSON of the payload's types, in hex.
    pub fingerprint: String,
}

impl WireLedgers {
    /// Parses and validates a ledger file.
    pub fn from_json(bytes: &[u8]) -> Result<Self, CompatError> {
        let ledgers: Self =
            serde_json::from_slice(bytes).map_err(|e| CompatError::InvalidSchema(e.to_string()))?;
        ledgers.validate()?;
        Ok(ledgers)
    }

    /// No ledger gives one id to two names (tombstones included), and every
    /// tombstone says why.
    pub fn validate(&self) -> Result<(), CompatError> {
        for (file, ledger) in &self.files {
            ledger
                .validate()
                .map_err(|why| CompatError::InvalidSchema(format!("wire ledger {file}: {why}")))?;
        }
        Ok(())
    }
}

impl WireLedger {
    fn validate(&self) -> Result<(), String> {
        let families = self.families.iter().map(|(n, r)| (n, u16::from(r.id), r.removed.as_ref()));
        unique_ids("family", families)?;
        for (kind, records) in [("method", &self.methods), ("event", &self.events)] {
            unique_ids(kind, records.iter().map(|(n, r)| (n, r.id, r.removed.as_ref())))?;
        }
        Ok(())
    }
}

fn unique_ids<'a>(
    kind: &str,
    records: impl Iterator<Item = (&'a String, u16, Option<&'a String>)>,
) -> Result<(), String> {
    let mut owners: BTreeMap<u16, &String> = BTreeMap::new();
    for (name, id, removed) in records {
        if removed.is_some_and(|why| why.trim().is_empty()) {
            return Err(format!("{kind} `{name}` has an empty `removed` reason"));
        }
        if let Some(owner) = owners.insert(id, name) {
            return Err(format!("{kind} id {id:#06x} belongs to both `{owner}` and `{name}`"));
        }
    }
    Ok(())
}

/// Ledger key of the v12 IR.
pub const SDK_SCHEMA: &str = "sdk-schema.json";
/// Ledger key of the v2 resource operations.
pub const RESOURCE_OPERATIONS: &str = "resource-operations-v2.json";

/// What one schema file assigns today.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WireIds {
    /// Family name -> family byte.
    pub families: BTreeMap<String, u8>,
    /// Command or operation name -> its wire attributes.
    pub methods: BTreeMap<String, WireEntry>,
    /// Event name -> its wire attributes.
    pub events: BTreeMap<String, WireEntry>,
}

/// The wire attributes of one command, operation or event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireEntry {
    /// `method_id` or `event_id`.
    pub id: u16,
    /// `priority`, when the schema states one.
    pub priority: Option<String>,
    /// `priority_changed_reason`, when the schema states one.
    pub priority_changed_reason: Option<String>,
    /// The binary layout, for `payload: binary`.
    pub layout: Option<LayoutRecord>,
}

/// A schema file the wire rules cannot read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadError {
    /// Where (`commands.send.method_id`, `families.tabs`, ...).
    pub at: String,
    /// What is wrong.
    pub why: String,
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.at, self.why)
    }
}

impl std::error::Error for ReadError {}

/// Reads the wire ids of `spec/sdk-schema.json`.
pub fn ids_from_sdk_schema(schema: &Value) -> Result<WireIds, ReadError> {
    let types = TypeTables::new(schema, &["types"]);
    let mut ids = WireIds { families: families(schema)?, ..WireIds::default() };
    read_entries(
        schema,
        "commands",
        "method_id",
        &["request", "result"],
        &types,
        &mut ids.methods,
    )?;
    read_entries(schema, "events", "event_id", &["payload"], &types, &mut ids.events)?;
    Ok(ids)
}

/// Reads the wire ids of `spec/resource-operations-v2.json` (transported and
/// local operations share one method id space).
pub fn ids_from_resource_operations(schema: &Value) -> Result<WireIds, ReadError> {
    let types = TypeTables::new(schema, &["types", "generics"]);
    let mut ids = WireIds { families: families(schema)?, ..WireIds::default() };
    for section in ["operations", "local_operations"] {
        read_entries(
            schema,
            section,
            "method_id",
            &["params", "result"],
            &types,
            &mut ids.methods,
        )?;
    }
    Ok(ids)
}

fn families(schema: &Value) -> Result<BTreeMap<String, u8>, ReadError> {
    let Some(table) = schema.get("families") else { return Ok(BTreeMap::new()) };
    let Some(table) = table.as_object() else {
        return Err(ReadError { at: "families".into(), why: "is not an object".into() });
    };
    table
        .iter()
        .map(|(name, family)| {
            let at = || format!("families.{name}");
            let raw = family.get("id").unwrap_or(family);
            let id =
                parse_id(raw).ok_or_else(|| ReadError { at: at(), why: "has no id".into() })?;
            let id = u8::try_from(id)
                .map_err(|_| ReadError { at: at(), why: format!("id {id} does not fit a byte") })?;
            Ok((name.clone(), id))
        })
        .collect()
}

fn read_entries(
    schema: &Value,
    section: &str,
    id_key: &str,
    body_keys: &[&str],
    types: &TypeTables<'_>,
    out: &mut BTreeMap<String, WireEntry>,
) -> Result<(), ReadError> {
    let Some(entries) = schema.get(section).and_then(Value::as_object) else { return Ok(()) };
    for (name, entry) in entries {
        let Some(raw) = entry.get(id_key) else { continue };
        let at = |key: &str| format!("{section}.{name}.{key}");
        let id = parse_id(raw)
            .and_then(|id| u16::try_from(id).ok())
            .ok_or_else(|| ReadError { at: at(id_key), why: format!("{raw} is not a u16") })?;
        let text = |key: &str| entry.get(key).and_then(Value::as_str).map(str::to_owned);
        let layout = match binary_layout_version(entry) {
            BinaryLayout::Json => None,
            BinaryLayout::Missing => {
                return Err(ReadError {
                    at: at("payload"),
                    why: "a binary payload needs a layout_version".into(),
                });
            }
            BinaryLayout::Version(version) => {
                let version = u8::try_from(version).map_err(|_| ReadError {
                    at: at("layout_version"),
                    why: format!("{version} does not fit a byte"),
                })?;
                Some(LayoutRecord { version, fingerprint: types.fingerprint(entry, body_keys) })
            }
        };
        out.insert(
            name.clone(),
            WireEntry {
                id,
                priority: text("priority"),
                priority_changed_reason: text("priority_changed_reason")
                    .filter(|reason| !reason.trim().is_empty()),
                layout,
            },
        );
    }
    Ok(())
}

/// An integer, or a `0x` hex string.
fn parse_id(value: &Value) -> Option<u64> {
    match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => {
            let hex = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X"))?;
            u64::from_str_radix(hex, 16).ok()
        }
        _ => None,
    }
}

enum BinaryLayout {
    Json,
    Missing,
    Version(u64),
}

/// `payload: "binary"` with `layout_version` beside it, or
/// `payload: {"kind": "binary", "layout_version": n}`.
fn binary_layout_version(entry: &Value) -> BinaryLayout {
    let payload = entry.get("payload");
    let binary = match payload {
        Some(Value::String(kind)) => kind == "binary",
        Some(Value::Object(map)) => map.get("kind").and_then(Value::as_str) == Some("binary"),
        _ => false,
    };
    if !binary {
        return BinaryLayout::Json;
    }
    let version =
        entry.get("layout_version").or_else(|| payload.and_then(|p| p.get("layout_version")));
    version.and_then(Value::as_u64).map_or(BinaryLayout::Missing, BinaryLayout::Version)
}

/// The named type tables of a schema file, for layout fingerprints.
struct TypeTables<'a> {
    tables: Vec<&'a serde_json::Map<String, Value>>,
}

/// Keys that document a layout without changing its bytes.
const DOC_KEYS: [&str; 2] = ["description", "constraints"];

impl<'a> TypeTables<'a> {
    fn new(schema: &'a Value, keys: &[&str]) -> Self {
        Self { tables: keys.iter().filter_map(|k| schema.get(*k)?.as_object()).collect() }
    }

    fn lookup(&self, name: &str) -> Option<&'a Value> {
        self.tables.iter().find_map(|table| table.get(name))
    }

    /// FNV-1a 64 of the canonical bytes of the entry's bodies plus every
    /// named type they reach, so editing a referenced type changes it too.
    fn fingerprint(&self, entry: &Value, body_keys: &[&str]) -> String {
        let mut hash = Fnv::default();
        let mut reached = BTreeSet::new();
        let mut pending = Vec::new();
        for key in body_keys {
            hash.write(key.as_bytes());
            let body = entry.get(*key).unwrap_or(&Value::Null);
            canonical(body, &mut hash);
            referenced_names(body, &mut pending);
        }
        while let Some(name) = pending.pop() {
            if let Some(ty) = self.lookup(&name)
                && reached.insert(name)
            {
                referenced_names(ty, &mut pending);
            }
        }
        for name in &reached {
            hash.write(name.as_bytes());
            if let Some(ty) = self.lookup(name) {
                canonical(ty, &mut hash);
            }
        }
        format!("{:016x}", hash.0)
    }
}

fn referenced_names(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            let by_name = matches!(map.get("kind").and_then(Value::as_str), Some("ref" | "apply"));
            if by_name && let Some(name) = map.get("name").and_then(Value::as_str) {
                out.push(name.to_owned());
            }
            map.values().for_each(|v| referenced_names(v, out));
        }
        Value::Array(items) => items.iter().for_each(|v| referenced_names(v, out)),
        _ => {}
    }
}

/// Sorted-key JSON without documentation members, independent of
/// serde_json's map ordering features.
fn canonical(value: &Value, hash: &mut Fnv) {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<_> = map.keys().filter(|k| !DOC_KEYS.contains(&k.as_str())).collect();
            keys.sort();
            hash.write(b"{");
            for key in keys {
                hash.write(Value::String(key.clone()).to_string().as_bytes());
                hash.write(b":");
                canonical(&map[key], hash);
                hash.write(b",");
            }
            hash.write(b"}");
        }
        Value::Array(items) => {
            hash.write(b"[");
            for item in items {
                canonical(item, hash);
                hash.write(b",");
            }
            hash.write(b"]");
        }
        scalar => hash.write(scalar.to_string().as_bytes()),
    }
}

struct Fnv(u64);

impl Default for Fnv {
    fn default() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }
}

impl Fnv {
    fn write(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
    }
}

/// One refused wire change.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct WireProblem {
    /// `family`, `method` or `event`.
    pub kind: &'static str,
    /// The family, command, operation or event name.
    pub name: String,
    /// Which rule refused it.
    pub rule: WireRule,
    /// Details.
    pub why: String,
}

/// The rules [`check`] enforces.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum WireRule {
    /// An id already belongs (or belonged) to another name.
    ReusedId,
    /// A name kept its identity but got a new id.
    Renumbered,
    /// A name left the schema without a tombstone in the ledger.
    RemovedWithoutTombstone,
    /// A tombstoned name is back.
    Resurrected,
    /// A priority changed without a new `priority_changed_reason`.
    PriorityWithoutReason,
    /// A binary layout changed without a `layout_version` bump.
    LayoutWithoutVersionBump,
}

impl std::fmt::Display for WireProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} `{}`: {}", self.kind, self.name, self.why)
    }
}

/// The result of [`check`].
#[derive(Clone, Debug, PartialEq)]
pub struct WireCheck {
    /// Refused changes; empty when the schema is compatible.
    pub problems: Vec<WireProblem>,
    /// The ledger with every accepted new id, priority and layout recorded.
    /// Differs from the input ledger when the ledger must be rewritten.
    pub ledger: WireLedger,
}

/// The result of [`check_all`]: every schema file against its ledger.
#[derive(Clone, Debug, PartialEq)]
pub struct WireReport {
    /// Refused changes as `(schema file, problem)`.
    pub problems: Vec<(String, WireProblem)>,
    /// The ledgers with every accepted change recorded.
    pub ledgers: WireLedgers,
}

impl WireReport {
    /// True when a schema file added or changed something `recorded` does
    /// not hold yet (`api-compat-check --write` records it).
    pub fn is_stale(&self, recorded: &WireLedgers) -> bool {
        self.ledgers != *recorded
    }
}

/// Checks every schema file (ledger key -> what it assigns) against its
/// recorded ledger. A ledger for a file not passed in is kept as is.
pub fn check_all(recorded: &WireLedgers, files: &BTreeMap<String, WireIds>) -> WireReport {
    let mut report = WireReport { problems: Vec::new(), ledgers: recorded.clone() };
    for (file, ids) in files {
        let old = recorded.files.get(file).cloned().unwrap_or_default();
        let result = check(&old, ids);
        report.problems.extend(result.problems.into_iter().map(|p| (file.clone(), p)));
        if result.ledger == WireLedger::default() {
            report.ledgers.files.remove(file);
        } else {
            report.ledgers.files.insert(file.clone(), result.ledger);
        }
    }
    report
}

/// Compares what a schema file assigns against its ledger.
pub fn check(ledger: &WireLedger, ids: &WireIds) -> WireCheck {
    let mut problems = Vec::new();
    let mut next = ledger.clone();
    check_families(&mut next.families, &ids.families, &mut problems);
    check_ids("method", &mut next.methods, &ids.methods, &mut problems);
    check_ids("event", &mut next.events, &ids.events, &mut problems);
    problems.sort();
    WireCheck { problems, ledger: next }
}

fn problem(kind: &'static str, name: &str, rule: WireRule, why: String) -> WireProblem {
    WireProblem { kind, name: name.to_owned(), rule, why }
}

fn tombstone_hint(kind: &str, name: &str) -> String {
    format!(
        "removed without a tombstone; keep its ledger entry and add \"removed\": \"<why>\" to {kind} `{name}` in spec/api-compat.json"
    )
}

fn check_families(
    ledger: &mut BTreeMap<String, FamilyRecord>,
    schema: &BTreeMap<String, u8>,
    problems: &mut Vec<WireProblem>,
) {
    const KIND: &str = "family";
    // Only a name the ledger does not know can reuse a byte: a recorded
    // name keeps its own byte or is renumbered.
    let mut owners: BTreeMap<u8, String> = ledger.iter().map(|(n, r)| (r.id, n.clone())).collect();
    for (name, &id) in schema {
        match ledger.get(name) {
            Some(FamilyRecord { removed: Some(reason), .. }) => {
                let why = format!("was removed ({reason}); a removed family name stays retired");
                problems.push(problem(KIND, name, WireRule::Resurrected, why));
            }
            Some(record) if record.id != id => {
                let why = format!(
                    "renumbered from {:#04x} to {id:#04x}; families are append-only",
                    record.id
                );
                problems.push(problem(KIND, name, WireRule::Renumbered, why));
            }
            Some(_) => {}
            None => match owners.get(&id) {
                Some(owner) => {
                    let why = format!("family byte {id:#04x} belongs to `{owner}`");
                    problems.push(problem(KIND, name, WireRule::ReusedId, why));
                }
                None => {
                    owners.insert(id, name.clone());
                    ledger.insert(name.clone(), FamilyRecord { id, removed: None });
                }
            },
        }
    }
    for (name, record) in ledger.iter() {
        if record.removed.is_none() && !schema.contains_key(name) {
            let why = tombstone_hint(KIND, name);
            problems.push(problem(KIND, name, WireRule::RemovedWithoutTombstone, why));
        }
    }
}

fn check_ids(
    kind: &'static str,
    ledger: &mut BTreeMap<String, IdRecord>,
    schema: &BTreeMap<String, WireEntry>,
    problems: &mut Vec<WireProblem>,
) {
    let mut owners: BTreeMap<u16, String> = ledger.iter().map(|(n, r)| (r.id, n.clone())).collect();
    for (name, entry) in schema {
        let Some(record) = ledger.get_mut(name) else {
            match owners.get(&entry.id) {
                Some(owner) => {
                    let why = format!("id {:#06x} belongs to `{owner}`", entry.id);
                    problems.push(problem(kind, name, WireRule::ReusedId, why));
                }
                None => {
                    owners.insert(entry.id, name.clone());
                    ledger.insert(
                        name.clone(),
                        IdRecord {
                            id: entry.id,
                            priority: entry.priority.clone(),
                            priority_reason: entry.priority_changed_reason.clone(),
                            layout: entry.layout.clone(),
                            removed: None,
                        },
                    );
                }
            }
            continue;
        };
        if let Some(reason) = &record.removed {
            let why = format!("was removed ({reason}); a removed name stays retired");
            problems.push(problem(kind, name, WireRule::Resurrected, why));
            continue;
        }
        if record.id != entry.id {
            let why = format!("renumbered from {:#06x} to {:#06x}", record.id, entry.id);
            problems.push(problem(kind, name, WireRule::Renumbered, why));
            continue;
        }
        check_priority(kind, name, record, entry, problems);
        check_layout(kind, name, record, entry, problems);
    }
    for (name, record) in ledger.iter() {
        if record.removed.is_none() && !schema.contains_key(name) {
            let why = tombstone_hint(kind, name);
            problems.push(problem(kind, name, WireRule::RemovedWithoutTombstone, why));
        }
    }
}

/// The first priority is recorded as given; every later change needs a
/// `priority_changed_reason` that differs from the one the last change used.
fn check_priority(
    kind: &'static str,
    name: &str,
    record: &mut IdRecord,
    entry: &WireEntry,
    problems: &mut Vec<WireProblem>,
) {
    let Some(old) = &record.priority else {
        record.priority.clone_from(&entry.priority);
        return;
    };
    if entry.priority.as_ref() == Some(old) {
        return;
    }
    let new = entry.priority.as_deref().unwrap_or("(none)");
    match &entry.priority_changed_reason {
        Some(reason) if record.priority_reason.as_ref() != Some(reason) => {
            record.priority.clone_from(&entry.priority);
            record.priority_reason = Some(reason.clone());
        }
        Some(_) => {
            let why = format!(
                "priority {old} -> {new} reuses the priority_changed_reason of the previous change; write why this change is safe"
            );
            problems.push(problem(kind, name, WireRule::PriorityWithoutReason, why));
        }
        None => {
            let why = format!("priority {old} -> {new} without a priority_changed_reason");
            problems.push(problem(kind, name, WireRule::PriorityWithoutReason, why));
        }
    }
}

/// A binary layout may change only with a higher `layout_version`. The last
/// binary layout stays recorded when a payload goes back to JSON, so a later
/// binary layout still has to pass it.
fn check_layout(
    kind: &'static str,
    name: &str,
    record: &mut IdRecord,
    entry: &WireEntry,
    problems: &mut Vec<WireProblem>,
) {
    let Some(new) = &entry.layout else { return };
    let Some(old) = &record.layout else {
        record.layout = Some(new.clone());
        return;
    };
    if new == old {
        return;
    }
    if new.version > old.version {
        record.layout = Some(new.clone());
        return;
    }
    let why = if new.fingerprint == old.fingerprint {
        format!("layout_version went from {} to {}; versions only go up", old.version, new.version)
    } else {
        format!(
            "binary layout changed without a layout_version bump (recorded {}, schema {})",
            old.version, new.version
        )
    };
    problems.push(problem(kind, name, WireRule::LayoutWithoutVersionBump, why));
}
