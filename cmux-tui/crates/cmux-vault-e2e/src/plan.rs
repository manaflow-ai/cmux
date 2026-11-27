//! Which values a machine gets: for each name, the item of the most specific scope that covers the machine
//! (`machine:<vm>` over `repo:<its repo>` over `*`). A repo-scoped item reaches only a machine whose repo is known.

use std::collections::BTreeMap;

use crate::Scope;

/// An item's place, without its value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemMeta {
    pub id: String,
    pub name: String,
    pub scope: Scope,
    pub revision: u64,
}

/// A machine as the planner sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineMeta {
    pub id: String,
    /// `owner/name`, lowercased, when known.
    pub repo: Option<String>,
}

/// The items `machine` gets, by name: each name's most specific covering item.
pub fn for_machine<'a>(
    items: &'a [ItemMeta],
    machine: &MachineMeta,
) -> BTreeMap<&'a str, &'a ItemMeta> {
    let mut chosen: BTreeMap<&str, &ItemMeta> = BTreeMap::new();
    for item in items {
        let covers = match &item.scope {
            Scope::All => true,
            Scope::Repo(repo) => machine.repo.as_deref() == Some(repo.as_str()),
            Scope::Machine(vm) => vm == &machine.id,
        };
        if !covers {
            continue;
        }
        match chosen.get(item.name.as_str()) {
            Some(held) if held.scope.rank() >= item.scope.rank() => {}
            _ => {
                chosen.insert(item.name.as_str(), item);
            }
        }
    }
    chosen
}

/// Whether what the machine holds (`delivered`, name to revision) is exactly what it should get.
pub fn current(chosen: &BTreeMap<&str, &ItemMeta>, delivered: &BTreeMap<String, u64>) -> bool {
    chosen.len() == delivered.len()
        && chosen.iter().all(|(name, item)| delivered.get(*name) == Some(&item.revision))
}
