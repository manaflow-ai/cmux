//! The ledger is append-only across commits too: the rules start from the
//! ledger on the base branch, so a pull request that deletes or edits ledger
//! entries by hand is checked as if it had not (Mojo's stable-interface
//! check compares with the base revision's mojom the same way,
//! mojo/public/tools/mojom/check_stable_mojom_compatibility.py).
//!
//! The one hand edit taken from the new ledger is a `removed` reason, on an
//! entry the base has live or on a new tombstoned entry (a reservation).

use std::collections::BTreeMap;

use super::{
    FamilyRecord, IdRecord, LEDGER_FILE, WireIds, WireLedger, WireLedgers, WireProblem, WireReport,
    WireRule, check_all, problem,
};
use crate::CompatError;

/// A ledger record that can carry a tombstone.
trait Retirable: Clone + PartialEq {
    fn removed(&self) -> Option<&String>;
    fn retire(&mut self, why: String);
}

impl Retirable for FamilyRecord {
    fn removed(&self) -> Option<&String> {
        self.removed.as_ref()
    }

    fn retire(&mut self, why: String) {
        self.removed = Some(why);
    }
}

impl Retirable for IdRecord {
    fn removed(&self) -> Option<&String> {
        self.removed.as_ref()
    }

    fn retire(&mut self, why: String) {
        self.removed = Some(why);
    }
}

/// The ledger the rules start from: `base` plus the tombstones `head` adds.
/// Everything else `head` changed is ignored here and reported by
/// [`check_against_base`].
pub fn ledger_from_base(base: &WireLedgers, head: &WireLedgers) -> WireLedgers {
    let mut merged = base.clone();
    for (file, ledger) in &head.files {
        let kept = merged.files.entry(file.clone()).or_default();
        take_tombstones(&mut kept.families, &ledger.families);
        take_tombstones(&mut kept.methods, &ledger.methods);
        take_tombstones(&mut kept.events, &ledger.events);
    }
    merged.files.retain(|_, ledger| *ledger != WireLedger::default());
    merged
}

fn take_tombstones<T: Retirable>(kept: &mut BTreeMap<String, T>, head: &BTreeMap<String, T>) {
    for (name, record) in head {
        let Some(why) = record.removed() else { continue };
        match kept.get_mut(name) {
            Some(base) if base.removed().is_none() => base.retire(why.clone()),
            Some(_) => {}
            None => {
                kept.insert(name.clone(), record.clone());
            }
        }
    }
}

/// [`check_all`] from the base branch's ledger ([`ledger_from_base`]), with
/// every base entry `head` dropped or changed other than the way the rules
/// record it in [`WireReport::edits`]. `head` is stale against the result
/// whenever it has an edit, so `--write` puts those entries back.
pub fn check_against_base(
    base: &WireLedgers,
    head: &WireLedgers,
    files: &BTreeMap<String, WireIds>,
) -> Result<WireReport, CompatError> {
    let recorded = ledger_from_base(base, head);
    recorded.validate()?;
    let mut report = check_all(&recorded, files);
    let empty = WireLedger::default();
    for (file, kept) in &base.files {
        let now = head.files.get(file).unwrap_or(&empty);
        let expected = report.ledgers.files.get(file).unwrap_or(&empty);
        let mut edits = Vec::new();
        hand_edits("family", &kept.families, &now.families, &expected.families, &mut edits);
        hand_edits("method", &kept.methods, &now.methods, &expected.methods, &mut edits);
        hand_edits("event", &kept.events, &now.events, &expected.events, &mut edits);
        report.edits.extend(edits.into_iter().map(|p| (file.clone(), p)));
    }
    Ok(report)
}

/// A base entry that `head` dropped, or changed to something the rules did
/// not record. An entry the rules changed but `head` has not caught up with
/// yet is only stale, not an edit.
fn hand_edits<T: Retirable>(
    kind: &'static str,
    base: &BTreeMap<String, T>,
    head: &BTreeMap<String, T>,
    expected: &BTreeMap<String, T>,
    out: &mut Vec<WireProblem>,
) {
    for (name, kept) in base {
        let why = match head.get(name) {
            None => format!(
                "dropped from spec/{LEDGER_FILE}; ledger entries stay forever (add \"removed\": \"<why>\" to retire one)"
            ),
            Some(now) if now != kept && expected.get(name) != Some(now) => format!(
                "edited by hand in spec/{LEDGER_FILE}; the only hand edit is adding a \"removed\" reason, and api-compat-check --write records the rest"
            ),
            Some(_) => continue,
        };
        out.push(problem(kind, name, WireRule::LedgerEdited, why));
    }
}
