//! Leo, 2026-10-22, searching the command palette for "TICK RAIL" and getting No Results:
//! "doesn't show as an option". The chat's edge is one setting, Settings > Agent Chat > Chat
//! Minimap (`agentPane.display.minimap`); the palette finds it under the words people use for it.
//!
//! The palette's settings rows as SettingsPaletteSource and SettingsPaletteProvider build them
//! from the generated schema: the title, the group as subtitle, the value as accessory, and the
//! keywords plus the key, the section, the group and "setting"; demoted under commands.

use cmux_palette_ranker::{RankRequest, rank_request};
use serde_json::{Value, json};
use std::collections::HashMap;

const MINIMAP_KEY: &str = "agentPane.display.minimap";
const RAIL_SIDE_KEY: &str = "agentPane.display.rail.side";

struct Rows {
    keys: Vec<String>,
    entries: Vec<Value>,
}

fn rows() -> Result<Rows, String> {
    let path =
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../../schemas/settings/settings-schema.json");
    let text = std::fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    let schema: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
    let text_of = |value: &Value| value["text"].as_str().unwrap_or("").to_owned();
    let section_titles: HashMap<String, String> = schema["sections"]
        .as_array()
        .ok_or("schema has no sections")?
        .iter()
        .map(|section| {
            (section["id"].as_str().unwrap_or("").to_owned(), text_of(&section["title"]))
        })
        .collect();
    let mut rows = Rows { keys: Vec::new(), entries: Vec::new() };
    for row in schema["rows"].as_array().ok_or("schema has no rows")? {
        let consumers = row["consumers"].as_array().cloned().unwrap_or_default();
        if !consumers.iter().any(|consumer| consumer == "cmux-next") {
            continue;
        }
        let key = row["key"].as_str().unwrap_or("").to_owned();
        let section = row["section"].as_str().unwrap_or("");
        let group = text_of(&row["group"]);
        let accessory = row["choices"].as_array().and_then(|choices| {
            choices
                .iter()
                .find(|choice| choice["value"] == row["default"])
                .map(|choice| text_of(&choice["title"]))
        });
        let mut keywords: Vec<String> = row["keywords"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|word| word.as_str().map(str::to_owned))
            .collect();
        keywords.push(key.clone());
        keywords.push(section_titles.get(section).cloned().unwrap_or_else(|| section.to_owned()));
        keywords.push(group.clone());
        keywords.push("setting".into());
        rows.entries.push(json!({
            "title": text_of(&row["title"]), "subtitle": group, "accessory": accessory,
            "keywords": keywords, "demoted": true,
        }));
        rows.keys.push(key);
    }
    Ok(rows)
}

fn palette(rows: &Rows, query: &str) -> Result<Vec<String>, String> {
    let request: RankRequest = serde_json::from_value(json!({
        "operation": "rank", "entries": rows.entries, "query": query,
        "sectionOrders": [0], "now": 800_000_000, "showsRecent": false,
    }))
    .map_err(|error| error.to_string())?;
    Ok(rank_request(&request)
        .iter()
        .flat_map(|section| section.rows.iter().map(|row| rows.keys[row.index].clone()))
        .collect())
}

#[test]
fn a_rail_query_keeps_chat_minimap_beside_the_rail_side_setting() -> Result<(), String> {
    let rows = rows()?;
    for query in ["TICK RAIL", "tick rail", "prompt rail", "scroll rail"] {
        let top: Vec<String> = palette(&rows, query)?.into_iter().take(2).collect();
        assert!(top.iter().any(|key| key == MINIMAP_KEY), "{query}: {top:?}");
        assert!(top.iter().any(|key| key == RAIL_SIDE_KEY), "{query}: {top:?}");
    }
    Ok(())
}

#[test]
fn wave_rail_and_thread_minimap_rank_chat_minimap_first() -> Result<(), String> {
    let rows = rows()?;
    for query in ["wave rail", "thread minimap"] {
        assert_eq!(
            palette(&rows, query)?.first().map(String::as_str),
            Some(MINIMAP_KEY),
            "{query}"
        );
    }
    Ok(())
}

#[test]
fn a_rail_side_query_ranks_prompt_rail_side_first() -> Result<(), String> {
    let rows = rows()?;
    assert_eq!(palette(&rows, "rail side")?.first().map(String::as_str), Some(RAIL_SIDE_KEY));
    Ok(())
}

#[test]
fn minimap_lists_chat_minimap_in_the_top_three() -> Result<(), String> {
    let rows = rows()?;
    let top: Vec<String> = palette(&rows, "minimap")?.into_iter().take(3).collect();
    assert!(top.iter().any(|key| key == MINIMAP_KEY), "{top:?}");
    Ok(())
}
