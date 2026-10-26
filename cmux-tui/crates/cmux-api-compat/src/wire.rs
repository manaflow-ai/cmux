//! Wire id rules: the ids, families, priorities and binary layouts the schema
//! files give the frame protocol must never change meaning under a peer.
//!
//! The schema files (`spec/sdk-schema.json` for the v12 commands and events,
//! `spec/resource-operations-v2.json` for the v2 operations) carry a
//! `families` table (name -> `{id, description, next_ordinal}`) and, per
//! command, operation or event, a `method_id` / `event_id`
//! (`family << 8 | ordinal`), a `priority` and, for `payload: "binary"`, a
//! `layout_version` (transports.md, "Method ids"; the v2 attributes are
//! declared in `spec/resource-operations-v2.schema.json`).
//! `spec/api-compat.wire.json` ([`LEDGER_FILE`]) keeps an append-only ledger
//! of everything ever given out ([`WireLedgers`]). It is a file of its own
//! because the daemon compiles `spec/api-compat.json` in and needs no ledger.
//! [`check_all`] compares the schema files with the ledger and refuses:
//!
//! - an id given to a second name (live or retired), in the same file or in
//!   the other one: both files share the family byte and frame id spaces,
//! - a renumbered method, event or family,
//! - a removed name without a tombstone, and a tombstoned name coming back,
//! - a priority change without a new `priority_changed_reason`,
//! - a binary layout change without a `layout_version` bump,
//! - a family or id outside its file's range (v12 commands `0x01`-`0x5F`,
//!   v2 operations `0x60`-`0xBF`, v12 events `0xC0`-`0xFE`) or in a family the
//!   file does not declare.
//!
//! [`check_against_base`] starts from the ledger on the base branch instead,
//! so deleting or editing a ledger entry by hand cannot get a change past
//! these rules: the only hand edit it takes from the new ledger is a
//! `removed` reason.
//!
//! This is protobuf's field-number discipline (`reserved` numbers and names)
//! and Chromium's Mojo `[MinVersion]`/stable-ordinal rule for interfaces
//! (mojo/public/tools/mojom/check_stable_mojom_compatibility.py, which also
//! compares the new interface with the old one from the base revision).

mod base;
mod layout;
mod read;
mod space;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::CompatError;

pub use base::{check_against_base, ledger_from_base};
pub use read::{ReadError, ids_from_resource_operations, ids_from_sdk_schema};

/// The ledger file, in `spec/`.
pub const LEDGER_FILE: &str = "api-compat.wire.json";
/// Ledger key of the v12 IR.
pub const SDK_SCHEMA: &str = "sdk-schema.json";
/// Ledger key of the v2 resource operations.
pub const RESOURCE_OPERATIONS: &str = "resource-operations-v2.json";

/// The ledger file ([`LEDGER_FILE`]): schema file name ([`SDK_SCHEMA`],
/// [`RESOURCE_OPERATIONS`]) -> its [`WireLedger`].
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
    /// The priority last stated (`input`, `control`, `bulk`, `background`).
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

    /// No family byte or frame id belongs to two names, in one file or across
    /// files (tombstones included), and every tombstone says why.
    pub fn validate(&self) -> Result<(), CompatError> {
        for (file, ledger) in &self.files {
            ledger
                .validate()
                .map_err(|why| CompatError::InvalidSchema(format!("wire ledger {file}: {why}")))?;
        }
        match space::first_clash(self) {
            Some(why) => Err(CompatError::InvalidSchema(format!("wire ledger: {why}"))),
            None => Ok(()),
        }
    }
}

impl WireLedger {
    fn validate(&self) -> Result<(), String> {
        let families = self.families.iter().map(|(n, r)| (n, r.removed.as_ref()));
        let methods = self.methods.iter().map(|(n, r)| (n, r.removed.as_ref()));
        let events = self.events.iter().map(|(n, r)| (n, r.removed.as_ref()));
        for (name, removed) in families.chain(methods).chain(events) {
            if removed.is_some_and(|why| why.trim().is_empty()) {
                return Err(format!("`{name}` has an empty `removed` reason"));
            }
        }
        Ok(())
    }
}

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
    /// The binary layout, for `payload: "binary"`.
    pub layout: Option<LayoutRecord>,
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

/// The rules [`check_all`] and [`check_against_base`] enforce.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum WireRule {
    /// An id already belongs (or belonged) to another name, in this schema
    /// file or the other one.
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
    /// A family or id outside its file's range, or in an undeclared family.
    OutOfRange,
    /// A ledger entry of the base branch was dropped or edited by hand.
    LedgerEdited,
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

/// The result of [`check_all`] and [`check_against_base`].
#[derive(Clone, Debug, PartialEq)]
pub struct WireReport {
    /// Refused changes as `(schema file, problem)`.
    pub problems: Vec<(String, WireProblem)>,
    /// Base ledger entries the new ledger dropped or edited by hand
    /// ([`WireRule::LedgerEdited`]); `ledgers` has them back as they were.
    /// Always empty from [`check_all`].
    pub edits: Vec<(String, WireProblem)>,
    /// The ledgers with every accepted change recorded.
    pub ledgers: WireLedgers,
}

impl WireReport {
    /// True when `ledger` (the ledger file as it is) differs from what the
    /// rules record (`api-compat-check --write` writes it).
    pub fn is_stale(&self, ledger: &WireLedgers) -> bool {
        self.ledgers != *ledger
    }
}

/// Checks every schema file (ledger key -> what it assigns) against its
/// recorded ledger, and the shared id spaces across files. A ledger for a
/// file not passed in is kept as is.
pub fn check_all(recorded: &WireLedgers, files: &BTreeMap<String, WireIds>) -> WireReport {
    let mut report =
        WireReport { problems: Vec::new(), edits: Vec::new(), ledgers: recorded.clone() };
    for (file, ids) in files {
        let old = recorded.files.get(file).cloned().unwrap_or_default();
        let result = check(&old, ids);
        report.problems.extend(result.problems.into_iter().map(|p| (file.clone(), p)));
        report
            .problems
            .extend(space::out_of_range(file, ids).into_iter().map(|p| (file.clone(), p)));
        if result.ledger == WireLedger::default() {
            report.ledgers.files.remove(file);
        } else {
            report.ledgers.files.insert(file.clone(), result.ledger);
        }
    }
    report.problems.extend(space::reused_across_files(recorded, &report.ledgers));
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
        "removed without a tombstone; keep its ledger entry and add \"removed\": \"<why>\" to {kind} `{name}` in spec/{LEDGER_FILE}"
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
/// A schema that stops stating a priority (an event's is optional, and the
/// IR refuses a reason without one) keeps the recorded one, so stating a
/// different priority again still needs a reason.
fn check_priority(
    kind: &'static str,
    name: &str,
    record: &mut IdRecord,
    entry: &WireEntry,
    problems: &mut Vec<WireProblem>,
) {
    let Some(new) = &entry.priority else { return };
    let Some(old) = &record.priority else {
        record.priority = Some(new.clone());
        return;
    };
    if new == old {
        return;
    }
    match &entry.priority_changed_reason {
        Some(reason) if record.priority_reason.as_ref() != Some(reason) => {
            record.priority = Some(new.clone());
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
