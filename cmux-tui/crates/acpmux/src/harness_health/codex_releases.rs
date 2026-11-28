//! Visible models added between two published Codex CLI bundles. A release's catalog is
//! immutable; reuse the saved delta until either version changes. The live provider list
//! still decides what the session can select.
use super::{HarnessHealth, channel::Channel, latest};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

fn catalog_url(version: &str) -> Option<String> {
    let parts: Vec<_> = version.split('.').collect();
    if parts.len() != 3
        || parts
            .iter()
            .any(|part| part.parse::<u32>().is_err() || !part.bytes().all(|b| b.is_ascii_digit()))
    {
        return None;
    }
    Some(format!(
        "https://raw.githubusercontent.com/openai/codex/rust-v{version}/codex-rs/models-manager/models.json"
    ))
}

fn visible(bundle: &Value) -> Option<BTreeMap<String, String>> {
    let mut models = BTreeMap::new();
    for row in bundle.get("models")?.as_array()? {
        if row.get("visibility")?.as_str()? != "list" {
            continue;
        }
        let id = row.get("slug")?.as_str()?;
        models.insert(
            id.to_owned(),
            row.get("display_name").and_then(Value::as_str).unwrap_or(id).to_owned(),
        );
    }
    (!models.is_empty()).then_some(models)
}

async fn read(version: &str) -> Option<BTreeMap<String, String>> {
    let value = latest::fetch_json(&catalog_url(version)?).await.ok()?;
    visible(&value)
}

pub(super) async fn fill(rows: &mut [HarnessHealth], previous: &[HarnessHealth]) {
    let mut answers: HashMap<(String, String), Option<BTreeMap<String, String>>> = HashMap::new();
    for row in rows {
        let official = matches!(
            (row.channel, row.package.as_deref()),
            (Channel::Npm | Channel::Bun | Channel::Native, Some("@openai/codex"))
                | (Channel::Brew | Channel::BrewCask, Some("codex"))
        );
        if !row.outdated || !official {
            continue;
        }
        let (Some(old), Some(new)) = (&row.version, &row.latest) else { continue };
        if let Some(saved) = previous.iter().find(|r| {
            r.package == row.package
                && r.version == row.version
                && r.latest == row.latest
                && r.new_codex_models.is_some()
        }) {
            row.new_codex_models = saved.new_codex_models.clone();
            continue;
        }
        let key = (old.clone(), new.clone());
        if let Some(added) = answers.get(&key) {
            row.new_codex_models = added.clone();
            continue;
        }
        let (from, to) = tokio::join!(read(old), read(new));
        let added = from.zip(to).map(|(from, mut to)| {
            to.retain(|id, _| !from.contains_key(id));
            to
        });
        row.new_codex_models = added.clone();
        answers.insert(key, added);
    }
}

#[cfg(test)]
#[path = "codex_releases_tests.rs"]
mod tests;
