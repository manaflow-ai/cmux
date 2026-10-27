//! The id spaces every schema file shares: one family byte space and one u16
//! frame id space (`family << 8 | ordinal`, methods and events alike), split
//! into per-file ranges (transports.md, "Method ids";
//! `bindings/codegen/ipc_meta.py` checks the same ranges for the v12 IR).

use std::collections::BTreeMap;
use std::ops::RangeInclusive;

use super::{
    RESOURCE_OPERATIONS, SDK_SCHEMA, WireIds, WireLedger, WireLedgers, WireProblem, WireRule,
    problem,
};

const V12_COMMANDS: RangeInclusive<u8> = 0x01..=0x5F;
const V2_OPERATIONS: RangeInclusive<u8> = 0x60..=0xBF;
const V12_EVENTS: RangeInclusive<u8> = 0xC0..=0xFE;

/// The family bytes `file`'s methods or events may use; `None` when the file
/// has no entries of that kind (or is not a known schema file).
fn range(file: &str, kind: &str) -> Option<RangeInclusive<u8>> {
    match (file, kind) {
        (SDK_SCHEMA, "method") => Some(V12_COMMANDS),
        (SDK_SCHEMA, "event") => Some(V12_EVENTS),
        (RESOURCE_OPERATIONS, "method") => Some(V2_OPERATIONS),
        _ => None,
    }
}

fn describe(range: &RangeInclusive<u8>) -> String {
    format!("{:#04x}-{:#04x}", range.start(), range.end())
}

/// Families and ids of a known schema file outside its ranges, and ids in a
/// family the file does not declare.
pub(super) fn out_of_range(file: &str, ids: &WireIds) -> Vec<WireProblem> {
    let mut problems = Vec::new();
    let ranges: Vec<_> = ["method", "event"].iter().filter_map(|kind| range(file, kind)).collect();
    if ranges.is_empty() {
        return problems;
    }
    for (name, &id) in &ids.families {
        if !ranges.iter().any(|r| r.contains(&id)) {
            let allowed: Vec<_> = ranges.iter().map(describe).collect();
            let why = format!("family byte {id:#04x} is outside {}", allowed.join(" and "));
            problems.push(problem("family", name, WireRule::OutOfRange, why));
        }
    }
    for (kind, entries) in [("method", &ids.methods), ("event", &ids.events)] {
        for (name, entry) in entries {
            let [family, _] = entry.id.to_be_bytes();
            let why = match range(file, kind) {
                None => format!("{file} gives no {kind} ids"),
                Some(r) if !r.contains(&family) => {
                    format!("id {:#06x} is outside the {kind} families {}", entry.id, describe(&r))
                }
                Some(_) if !ids.families.values().any(|&f| f == family) => {
                    format!("family {family:#04x} of id {:#06x} is not in `families`", entry.id)
                }
                Some(_) => continue,
            };
            problems.push(problem(kind, name, WireRule::OutOfRange, why));
        }
    }
    problems
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum SharedId {
    Family(u8),
    Frame(u16),
}

impl std::fmt::Display for SharedId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Family(id) => write!(f, "family byte {id:#04x}"),
            Self::Frame(id) => write!(f, "id {id:#06x}"),
        }
    }
}

/// Every family, method and event of a ledger with its shared id.
fn entries(ledger: &WireLedger) -> impl Iterator<Item = (&'static str, &String, SharedId)> {
    let families = ledger.families.iter().map(|(n, r)| ("family", n, SharedId::Family(r.id)));
    let methods = ledger.methods.iter().map(|(n, r)| ("method", n, SharedId::Frame(r.id)));
    let events = ledger.events.iter().map(|(n, r)| ("event", n, SharedId::Frame(r.id)));
    families.chain(methods).chain(events)
}

/// Who holds each shared id: "kind `name` in file".
#[derive(Default)]
struct Owners(BTreeMap<SharedId, String>);

impl Owners {
    /// Takes `id` for the name, or returns who already holds it.
    fn claim(&mut self, file: &str, kind: &str, name: &str, id: SharedId) -> Option<&String> {
        if self.0.contains_key(&id) {
            return self.0.get(&id);
        }
        self.0.insert(id, format!("{kind} `{name}` in {file}"));
        None
    }
}

/// The first shared id two ledger entries hold (tombstones included).
pub(super) fn first_clash(ledgers: &WireLedgers) -> Option<String> {
    let mut owners = Owners::default();
    for (file, ledger) in &ledgers.files {
        for (kind, name, id) in entries(ledger) {
            if let Some(owner) = owners.claim(file, kind, name, id) {
                return Some(format!("{id} of {kind} `{name}` in {file} belongs to {owner}"));
            }
        }
    }
    None
}

/// New entries of `next` whose shared id an entry of another file (or kind)
/// holds, live or tombstoned. A same-file, same-kind reuse never reaches
/// `next`: [`super::check`] refuses it first.
pub(super) fn reused_across_files(
    recorded: &WireLedgers,
    next: &WireLedgers,
) -> Vec<(String, WireProblem)> {
    let mut owners = Owners::default();
    for (file, ledger) in &recorded.files {
        for (kind, name, id) in entries(ledger) {
            owners.claim(file, kind, name, id);
        }
    }
    let empty = WireLedger::default();
    let mut problems = Vec::new();
    for (file, ledger) in &next.files {
        let old = recorded.files.get(file).unwrap_or(&empty);
        let old: Vec<_> = entries(old).collect();
        for (kind, name, id) in entries(ledger) {
            if old.contains(&(kind, name, id)) {
                continue;
            }
            if let Some(owner) = owners.claim(file, kind, name, id) {
                let why = format!("{id} belongs to {owner}");
                problems.push((file.clone(), problem(kind, name, WireRule::ReusedId, why)));
            }
        }
    }
    problems
}
