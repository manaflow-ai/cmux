//! The machine's side (cmux-host's Cloud role): read `GET /v1/cloud/vault/machine`, open each value with the
//! daemon's private key, refuse a revision lower than one it holds, and write the names it owns into
//! `~/.config/cmux/machine-secrets.env`, keeping every line it does not own (`cmux cloud deliver-secrets` writes
//! the same file).
//!
//! `vault-delivered.json` (kept by the caller, root-only) holds per name the highest revision opened and whether the
//! vault owns it now. Names only; never a value.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::Zeroizing;

use crate::crypto::{self, Sealed};

/// One delivered item as the route answers it.
#[derive(Clone)]
pub struct Delivered {
    pub vault: String,
    pub name: String,
    pub revision: u64,
    pub sealed: Sealed,
}

impl std::fmt::Debug for Delivered {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Delivered({} {} r{})", self.vault, self.name, self.revision)
    }
}

/// The route's answer: `{machine, items: [{vault, name, revision, enc, ct}]}`. Malformed items are counted, not kept.
pub fn parse_answer(body: &Value) -> Option<(String, Vec<Delivered>, usize)> {
    let machine = body.get("machine")?.as_str()?.to_owned();
    let mut items = Vec::new();
    let mut refused = 0;
    for raw in body.get("items")?.as_array()? {
        let item = (|| {
            Some(Delivered {
                vault: raw.get("vault")?.as_str()?.to_owned(),
                name: raw.get("name")?.as_str().filter(|n| crate::valid_name(n))?.to_owned(),
                revision: raw.get("revision")?.as_u64()?,
                sealed: Sealed {
                    enc: crate::b64::decode(raw.get("enc")?.as_str()?)?,
                    ct: crate::b64::decode(raw.get("ct")?.as_str()?)?,
                },
            })
        })();
        match item {
            Some(item) => items.push(item),
            None => refused += 1,
        }
    }
    Some((machine, items, refused))
}

/// What the machine remembers between pulls.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    /// Per name: the highest revision this machine opened.
    #[serde(default)]
    pub revisions: BTreeMap<String, u64>,
    /// The names the vault wrote into machine-secrets.env at the last pull.
    #[serde(default)]
    pub owned: BTreeSet<String>,
}

/// One pull's result, names only.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Applied {
    pub written: Vec<String>,
    pub removed: Vec<String>,
    /// Name and code: a value that did not open, a rollback, another machine's id.
    pub refused: Vec<(String, &'static str)>,
}

/// Open `items` for `machine_id` (the answer's own machine must match it). The personal vault's value wins over the
/// team's for one name. Returns the values to write and the new state.
pub fn open_all(
    daemon_private: &[u8; 32],
    machine_id: &str,
    answered_machine: &str,
    items: &[Delivered],
    state: &State,
) -> (BTreeMap<String, Zeroizing<String>>, State, Applied) {
    let mut applied = Applied::default();
    let mut values: BTreeMap<String, (bool, Zeroizing<String>)> = BTreeMap::new();
    let mut next = State { revisions: state.revisions.clone(), owned: BTreeSet::new() };
    if answered_machine != machine_id {
        applied.refused.extend(items.iter().map(|i| (i.name.clone(), "vault.other_machine")));
        next.owned = state.owned.clone();
        return (BTreeMap::new(), next, applied);
    }
    for item in items {
        let held = state.revisions.get(&item.name).copied().unwrap_or(0);
        if item.revision < held {
            applied.refused.push((item.name.clone(), "vault.rollback"));
            continue;
        }
        let opened = match crypto::open_delivery(
            daemon_private,
            machine_id,
            &item.name,
            item.revision,
            &item.sealed,
        ) {
            Ok(bytes) => bytes,
            Err(error) => {
                applied.refused.push((item.name.clone(), error.code()));
                continue;
            }
        };
        let Ok(text) = String::from_utf8(opened.to_vec()) else {
            applied.refused.push((item.name.clone(), "vault.not_text"));
            continue;
        };
        let text = Zeroizing::new(text);
        let personal = item.vault == "personal";
        match values.get(&item.name) {
            Some((true, _)) if !personal => {}
            _ => {
                values.insert(item.name.clone(), (personal, text));
            }
        }
        let revision = next.revisions.entry(item.name.clone()).or_insert(0);
        *revision = (*revision).max(item.revision);
    }
    let values: BTreeMap<String, Zeroizing<String>> =
        values.into_iter().map(|(k, (_, v))| (k, v)).collect();
    next.owned = values.keys().cloned().collect();
    applied.written = next.owned.iter().cloned().collect();
    applied.removed = state.owned.difference(&next.owned).cloned().collect();
    (values, next, applied)
}

/// `'value'` for a POSIX shell, with `'` written as `'\''`.
fn quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn export_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("export ")?;
    let (name, _) = rest.split_once('=')?;
    Some(name)
}

/// machine-secrets.env with the vault's names: every line of `existing` whose name the vault does not own now and
/// did not own before stays; the vault's names follow, one `export NAME='value'` each. A value with a NUL is
/// skipped (a shell cannot hold it).
pub fn render_env(
    existing: &str,
    previously_owned: &BTreeSet<String>,
    values: &BTreeMap<String, Zeroizing<String>>,
) -> Zeroizing<String> {
    let mut out = Zeroizing::new(String::new());
    for line in existing.lines() {
        if let Some(name) = export_name(line)
            && (values.contains_key(name) || previously_owned.contains(name))
        {
            continue;
        }
        if line.starts_with("# cmux vault") {
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if !values.is_empty() {
        out.push_str("# cmux vault (end to end encrypted, delivered by cmux host): names below\n");
    }
    for (name, value) in values {
        if value.contains('\0') {
            continue;
        }
        out.push_str("export ");
        out.push_str(name);
        out.push('=');
        out.push_str(&quoted(value));
        out.push('\n');
    }
    out
}
