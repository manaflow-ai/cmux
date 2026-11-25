//! Edits of `machines.hosts` (`cmux hosts add|rename|set-endpoints|remove`):
//! one host added, renamed, given new endpoints or removed, the whole list
//! then held to [`crate::hosts::accepts`], the same rule `settings.set`
//! applies to the key. The file is changed like the settings owner changes
//! it: under the owner's advisory lock, only the `machines.hosts` value
//! rewritten (comments and every other key stay byte for byte), published
//! atomically. A missing file starts from the classic seed, as the owner's
//! first write does.

use std::path::Path;

use serde_json::{Map, Value};

use crate::fsio::{publish, read_source};
use crate::hosts::{self, HostDecl, PATH};
use crate::store::FileRead;

/// One change to the host list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostEdit {
    Add { label: String, endpoints: Vec<String>, icon: Option<String> },
    Rename { from: String, to: String },
    SetEndpoints { label: String, endpoints: Vec<String> },
    Remove { label: String },
}

/// `items` (the file's `machines.hosts` list) with `edit` applied, or why
/// not. Items the edit does not name are kept as they are, unknown members
/// included.
pub fn apply(items: &[Value], edit: &HostEdit) -> Result<Vec<Value>, String> {
    let mut items = items.to_vec();
    match edit {
        HostEdit::Add { label, endpoints, icon } => {
            check_label(label)?;
            check_endpoints(endpoints)?;
            if index_of(&items, label).is_some() {
                return Err(format!(
                    "a host is already called {:?} (cmux hosts list)",
                    label.trim()
                ));
            }
            let mut host = Map::new();
            host.insert("label".into(), Value::String(label.trim().to_owned()));
            host.insert("endpoints".into(), endpoint_list(endpoints));
            if let Some(icon) = icon {
                host.insert("icon".into(), Value::String(icon.clone()));
            }
            items.push(Value::Object(host));
        }
        HostEdit::Rename { from, to } => {
            check_label(to)?;
            let at = find(&items, from)?;
            if index_of(&items, to).is_some_and(|other| other != at) {
                return Err(format!("a host is already called {:?} (cmux hosts list)", to.trim()));
            }
            member_map(items.get_mut(at))?
                .insert("label".into(), Value::String(to.trim().to_owned()));
        }
        HostEdit::SetEndpoints { label, endpoints } => {
            check_endpoints(endpoints)?;
            let at = find(&items, label)?;
            let host = member_map(items.get_mut(at))?;
            host.remove("endpoint");
            host.insert("endpoints".into(), endpoint_list(endpoints));
        }
        HostEdit::Remove { label } => {
            let at = find(&items, label)?;
            items.remove(at);
        }
    }
    let list = Value::Array(items.clone());
    if !hosts::accepts(&list) {
        let (_, problems) = hosts::parse(&list);
        let first = problems.into_iter().next().unwrap_or_else(|| "not a host list".to_owned());
        return Err(format!("{first}; fix it in cmux-next.json first"));
    }
    Ok(items)
}

/// Applies `edit` to the file at `config_path` and returns the hosts it now
/// declares. `seed_path` is read while `config_path` does not exist
/// ([`crate::location::seed_path`]).
pub fn edit_file(
    config_path: &Path,
    seed_path: Option<&Path>,
    edit: &HostEdit,
) -> Result<Vec<HostDecl>, String> {
    let _lock = crate::owner::lock_config(config_path);
    let missing = std::fs::symlink_metadata(config_path)
        .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound);
    let read_from = match seed_path {
        Some(seed) if missing => seed,
        _ => config_path,
    };
    let source = match read_source(read_from) {
        FileRead::Text(text) => text,
        FileRead::Unreadable(problem) => return Err(problem),
    };
    let root = if source.trim().is_empty() {
        Value::Object(Map::new())
    } else {
        crate::jsonc::parse(&source)
            .map_err(|error| format!("{}: {error}; fix the file first", read_from.display()))?
    };
    let path: Vec<String> = PATH.iter().map(|part| (*part).to_owned()).collect();
    let items = match crate::value::value_at(&root, &path) {
        None => Vec::new(),
        Some(Value::Array(items)) => items.clone(),
        Some(_) => {
            return Err("machines.hosts is not a list; fix it in cmux-next.json first".into());
        }
    };
    let next = apply(&items, edit)?;
    let base = if source.trim().is_empty() { "{}\n".to_owned() } else { source };
    let text = crate::jsonc::set(&base, &path, &Value::Array(next.clone()))
        .map_err(|error| format!("{}: {error}", config_path.display()))?;
    publish(config_path, &text).map_err(|error| format!("{}: {error}", config_path.display()))?;
    Ok(hosts::parse(&Value::Array(next)).0)
}

fn check_label(label: &str) -> Result<(), String> {
    if label.trim().is_empty() || label.chars().count() > hosts::MAX_LABEL {
        return Err(format!("a label is 1 to {} characters", hosts::MAX_LABEL));
    }
    Ok(())
}

fn check_endpoints(endpoints: &[String]) -> Result<(), String> {
    if endpoints.is_empty() || endpoints.len() > hosts::MAX_ENDPOINTS {
        return Err(format!("a host takes 1 to {} endpoints", hosts::MAX_ENDPOINTS));
    }
    match endpoints.iter().find(|endpoint| hosts::ssh_endpoint(endpoint).is_none()) {
        Some(bad) => Err(format!(
            "{bad:?} is not an ssh address (ssh://[user@]host[:port], [user@]host or an ~/.ssh/config alias)"
        )),
        None => Ok(()),
    }
}

fn endpoint_list(endpoints: &[String]) -> Value {
    Value::Array(endpoints.iter().cloned().map(Value::String).collect())
}

/// The index of the item labeled `label` (ignoring case), valid host or not.
fn index_of(items: &[Value], label: &str) -> Option<usize> {
    let wanted = label.trim().to_lowercase();
    items.iter().position(|item| {
        item.get("label").and_then(Value::as_str).is_some_and(|l| l.trim().to_lowercase() == wanted)
    })
}

fn find(items: &[Value], label: &str) -> Result<usize, String> {
    index_of(items, label).ok_or_else(|| format!("no host is called {label:?} (cmux hosts list)"))
}

fn member_map(item: Option<&mut Value>) -> Result<&mut Map<String, Value>, String> {
    item.and_then(Value::as_object_mut)
        .ok_or_else(|| "machines.hosts: that entry is not an object".to_owned())
}

#[cfg(test)]
#[path = "hosts_edit_tests.rs"]
mod tests;
