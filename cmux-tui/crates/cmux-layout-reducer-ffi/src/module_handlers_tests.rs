//! Every operation the crate's sources and test vectors name goes to one module in
//! `MODULE_HANDLERS`, so the table's order does not decide who answers, save the overlaps named
//! here.

use super::{MODULE_HANDLERS, module_for};
use std::collections::BTreeSet;
use std::path::Path;

/// Operations two modules handle, and the module that answers them (the first in the table).
/// `cloud_bootstrap` handles `cloud_machine_repo_*`, which `cloud_machine`'s prefix also covers.
const OVERLAPS: &[(&str, &str, &[&str])] =
    &[("cloud_machine_repo_", "cloud_bootstrap", &["cloud_bootstrap", "cloud_machine"])];

/// Every string literal shaped like an operation in `dir`'s Rust files, recursively.
fn literals(dir: &Path, into: &mut BTreeSet<String>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            literals(&path, into);
            continue;
        }
        if path.extension().is_none_or(|ext| ext != "rs") {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        for (index, quoted) in text.split('"').enumerate() {
            let shaped = !quoted.is_empty()
                && quoted.starts_with(|c: char| c.is_ascii_lowercase())
                && quoted.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
            if index % 2 == 1 && shaped {
                into.insert(quoted.to_owned());
            }
        }
    }
}

fn known_operations() -> BTreeSet<String> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut found = BTreeSet::new();
    literals(&root.join("src"), &mut found);
    literals(&root.join("tests"), &mut found);
    found
}

#[test]
fn table_is_sorted_by_module_name() {
    let names: Vec<&str> = MODULE_HANDLERS.iter().map(|(name, _, _)| *name).collect();
    let mut sorted = names.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(names, sorted, "MODULE_HANDLERS: one line per module, sorted by name");
}

#[test]
fn each_known_operation_is_claimed_by_exactly_one_module() {
    let operations = known_operations();
    let mut claimed_by_each = BTreeSet::new();
    for operation in &operations {
        let claimants: Vec<&str> = MODULE_HANDLERS
            .iter()
            .filter(|(_, handles, _)| handles(operation.as_bytes()))
            .map(|(name, _, _)| *name)
            .collect();
        claimed_by_each.extend(claimants.iter().copied());
        if claimants.len() <= 1 {
            continue;
        }
        let overlap = OVERLAPS.iter().find(|(prefix, _, _)| operation.starts_with(prefix));
        let Some((_, winner, sharers)) = overlap else {
            panic!("{operation} is claimed by {claimants:?}; give it to one module");
        };
        assert_eq!(&claimants, sharers, "{operation}");
        let answers = module_for(operation.as_bytes()).map(|(name, _, _)| *name);
        assert_eq!(answers, Some(*winner), "{operation}");
    }
    let unseen: Vec<&str> = MODULE_HANDLERS
        .iter()
        .map(|(name, _, _)| *name)
        .filter(|name| !claimed_by_each.contains(name))
        .collect();
    assert!(unseen.is_empty(), "no source or test vector names an operation of {unseen:?}");
}

#[test]
fn overlaps_are_still_shared() {
    let operations = known_operations();
    for (prefix, _, _) in OVERLAPS {
        assert!(
            operations.iter().any(|operation| operation.starts_with(prefix)),
            "no operation under {prefix} is left; drop it from OVERLAPS"
        );
    }
}
