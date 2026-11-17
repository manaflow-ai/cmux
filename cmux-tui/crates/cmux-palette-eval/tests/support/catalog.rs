//! The catalog's own palette rows in English, built as `RegistryPaletteProvider` builds them, and
//! the real ranker over them.
//!
//! A row has its title, its keywords plus the catalog's built-in aliases (`palette::ALIASES`), the
//! same aliases as its own `aliases`, the tier's rank bias, and a family row whose keywords are its
//! members' titles. The ids are `action:<id>` and `family:<id>`.

#![allow(dead_code)]

use cmux_action_catalog::{PaletteTier, actions, palette, strings};
use cmux_palette_ranker::{RankRequest, rank_request};
use serde_json::{Value, json};
use std::collections::HashMap;

/// `RegistryPaletteProvider.rankBias(for:)` of the action's tier (a family member is niche).
fn rank_bias(tier: PaletteTier) -> i64 {
    match tier {
        PaletteTier::Daily => 120,
        PaletteTier::Standard => 0,
        PaletteTier::Niche => -120,
    }
}

/// Every palette row of the catalog: one per palette-visible action, plus a row per family
/// without a parent.
pub fn rows() -> (Vec<String>, Vec<Value>) {
    let aliases: HashMap<&str, &[&str]> = palette::ALIASES.iter().copied().collect();
    let mut ids = Vec::new();
    let mut entries = Vec::new();
    let mut titles: HashMap<&str, String> = HashMap::new();
    for action in actions().filter(|action| action.is_palette_visible()) {
        let title = strings::resolve(&action.title, 0);
        titles.insert(action.id, title.clone());
        let own: Vec<String> = aliases
            .get(action.id)
            .into_iter()
            .flat_map(|words| words.iter().map(|word| (*word).to_owned()))
            .collect();
        let mut keywords: Vec<String> =
            action.keywords.iter().map(|word| (*word).to_owned()).collect();
        keywords.extend(own.iter().cloned());
        ids.push(format!("action:{}", action.id));
        entries.push(json!({
            "title": title, "keywords": keywords, "aliases": own, "actionID": action.id,
            "frecencyKey": format!("action:{}", action.id), "rankBias": rank_bias(action.palette_tier()),
            "isEnabled": true, "isVisibleWhenQueryEmpty": true, "sectionIndex": 0,
            "hasShortcut": action.default_shortcut.is_some(),
        }));
    }
    for family in palette::FAMILIES.iter().filter(|family| family.parent.is_none()) {
        let keywords: Vec<&String> =
            family.members.iter().filter_map(|id| titles.get(id)).collect();
        if keywords.is_empty() {
            continue;
        }
        ids.push(format!("family:{}", family.id));
        entries.push(json!({
            "title": strings::resolve(&family.title, 0), "keywords": keywords,
            "frecencyKey": format!("family:{}", family.id), "rankBias": 0,
            "isEnabled": true, "isVisibleWhenQueryEmpty": true, "sectionIndex": 0,
        }));
    }
    (ids, entries)
}

/// The catalog's built-in aliases as a user alias table (`palette.aliases` shape), the way the
/// app's `PaletteRankSettings.addingBuiltInAliases` merges them today.
pub fn alias_table() -> HashMap<String, Vec<String>> {
    palette::ALIASES
        .iter()
        .map(|(id, words)| {
            ((*id).to_owned(), words.iter().map(|word| (*word).to_owned()).collect())
        })
        .collect()
}

/// One ranked row: its id, title and score.
pub struct Ranked {
    pub id: String,
    pub title: String,
    pub score: i64,
}

/// The rows for `query`, best first. `with_alias_table` also sends the built-in aliases as the
/// request's alias table; without it only each row's own `aliases` carry them.
pub fn ranked_rows(query: &str, with_alias_table: bool) -> Vec<Ranked> {
    let (ids, entries) = rows();
    let aliases = if with_alias_table { json!(alias_table()) } else { Value::Null };
    let request: RankRequest = serde_json::from_value(json!({
        "operation": "rank", "entries": entries, "query": query, "sectionOrders": [0],
        "frecency": {}, "now": 800_000_000.0, "showsRecent": false, "aliases": aliases,
    }))
    .expect("a rank request");
    rank_request(&request)
        .iter()
        .flat_map(|section| section.rows.iter())
        .map(|row| Ranked {
            id: ids[row.index].clone(),
            title: entries[row.index]["title"].as_str().unwrap_or_default().to_owned(),
            score: row.score,
        })
        .collect()
}

/// The row ids for `query`, best first, ranked as the app ranks them (alias table and own aliases).
pub fn ranked(query: &str) -> Vec<String> {
    ranked_rows(query, true).into_iter().map(|row| row.id).collect()
}
