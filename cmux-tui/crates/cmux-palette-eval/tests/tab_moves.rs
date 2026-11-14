//! Moving the focused tab from the Command Palette by the words a person types (user, 2026-11-11:
//! "im in a tab and i want to move it to right split"; Cmd-Shift-P "move to right split" listed
//! only "Tab: Move…" and "Tab Group: Move…").
//!
//! The rows are the catalog's own palette rows in English, built as `RegistryPaletteProvider`
//! builds them (title, keywords plus the catalog's built-in aliases, the tier's rank bias, a family
//! row whose keywords are its members' titles), ranked by the real ranker with the built-in aliases
//! as its alias table. So a catalog edit that loses one of these phrases fails here, not in a
//! person's palette.

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
/// without a parent. The ids are `action:<id>` and `family:<id>`.
fn rows() -> (Vec<String>, Vec<Value>) {
    let aliases: HashMap<&str, &[&str]> = palette::ALIASES.iter().copied().collect();
    let mut ids = Vec::new();
    let mut entries = Vec::new();
    let mut titles: HashMap<&str, String> = HashMap::new();
    for action in actions().filter(|action| action.is_palette_visible()) {
        let title = strings::resolve(&action.title, 0);
        titles.insert(action.id, title.clone());
        let mut keywords: Vec<String> =
            action.keywords.iter().map(|word| (*word).to_owned()).collect();
        keywords.extend(
            aliases
                .get(action.id)
                .into_iter()
                .flat_map(|words| words.iter().map(|word| (*word).to_owned())),
        );
        ids.push(format!("action:{}", action.id));
        entries.push(json!({
            "title": title, "keywords": keywords, "actionID": action.id,
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

/// The row ids for `query`, best first.
fn ranked(query: &str) -> Vec<String> {
    let (ids, entries) = rows();
    let aliases: HashMap<String, Vec<String>> = palette::ALIASES
        .iter()
        .map(|(id, words)| {
            ((*id).to_owned(), words.iter().map(|word| (*word).to_owned()).collect())
        })
        .collect();
    let request: RankRequest = serde_json::from_value(json!({
        "operation": "rank", "entries": entries, "query": query, "sectionOrders": [0],
        "frecency": {}, "now": 800_000_000.0, "showsRecent": false, "aliases": aliases,
    }))
    .expect("a rank request");
    rank_request(&request)
        .iter()
        .flat_map(|section| section.rows.iter().map(|row| ids[row.index].clone()))
        .collect()
}

/// What a person types, and the action that must be the first row.
const FIRST: &[(&str, &str)] = &[
    ("move to right split", "moveSurfaceToPaneRight"),
    ("move tab to right split", "moveSurfaceToPaneRight"),
    ("move to split right", "moveSurfaceToPaneRight"),
    ("send tab right", "moveSurfaceToPaneRight"),
    ("move to left split", "moveSurfaceToPaneLeft"),
    ("send tab left", "moveSurfaceToPaneLeft"),
    ("move to split below", "moveSurfaceToPaneDown"),
    ("move to bottom split", "moveSurfaceToPaneDown"),
    ("move to split above", "moveSurfaceToPaneUp"),
    ("move to top split", "moveSurfaceToPaneUp"),
    ("move to new split", "tab.moveToNewSplit"),
    ("move to new column", "tab.moveToNewColumn"),
    ("move to new workspace", "palette.moveTabToNewWorkspace"),
    ("move to workspace", "tab.moveToWorkspace"),
    ("move to new window", "tab.moveToNewWindow"),
    ("pop out", "tab.moveToNewWindow"),
    ("pop out tab", "tab.moveToNewWindow"),
    ("move to other window", "tab.moveToWindow"),
    ("move to window", "tab.moveToWindow"),
    ("duplicate to split", "tab.duplicateToNewSplit"),
    ("duplicate tab to split", "tab.duplicateToNewSplit"),
    ("move group to new split", "tabGroup.moveToNewSplit"),
    ("move group to new window", "tabGroup.moveToNewWindow"),
];

#[test]
fn each_tab_move_phrase_puts_its_action_first() {
    let failed: Vec<String> = FIRST
        .iter()
        .filter_map(|(query, id)| {
            let top = ranked(query);
            let want = format!("action:{id}");
            (top.first() != Some(&want))
                .then(|| format!("{query:?}: want {want}, got {:?}", &top[..top.len().min(4)]))
        })
        .collect();
    assert!(failed.is_empty(), "{failed:#?}");
}

/// "split right" stays the Split Right command (a daily row, the new terminal beside), with the move
/// close behind it.
#[test]
fn split_right_still_splits_and_the_move_is_in_reach() {
    let top = ranked("split right");
    assert_eq!(top.first().map(String::as_str), Some("action:splitRight"), "{top:?}");
    assert!(
        top.iter().take(10).any(|id| id == "action:moveSurfaceToPaneRight"),
        "{:?}",
        &top[..top.len().min(10)]
    );
}

/// Tab: Move… lists every tab move this file names, so a person who opens it finds them there too.
#[test]
fn tab_move_lists_every_tab_move() {
    let family =
        palette::FAMILIES.iter().find(|family| family.id == "tab.move").expect("Tab: Move…");
    for id in ["tab.moveToWindow", "tab.duplicateToNewSplit", "tab.moveToSpace"] {
        assert!(family.members.contains(&id), "Tab: Move… lacks {id}");
    }
}
