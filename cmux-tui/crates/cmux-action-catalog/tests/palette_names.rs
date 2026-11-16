//! One name per command, checked here at the source: the app's `PaletteMenuVocabularyTests.
//! everyNameBelongsToOneCommand` reads this catalog only through the pinned app FFI, so a
//! look-alike name a step A pull request adds fails it only after the re-pin, on the base
//! (browser and terminal both had "Scroll to Top"; New ▸ New Tab Page and the tab bar's New Tab
//! Page both read "New Tab Page").
use cmux_action_catalog::{json, palette};
use std::collections::BTreeMap;

/// A title as the app compares it: without a trailing ellipsis, lowercased.
fn name(title: &str) -> String {
    title.strip_suffix('…').unwrap_or(title).to_lowercase()
}

/// No two palette or menu bar rows share a name unless one is a declared duplicate of the other
/// (`palette::DUPLICATES`), and a duplicate carries its canonical action's name.
#[test]
fn every_name_belongs_to_one_command() {
    let catalog = json::catalog_value(0);
    let actions = catalog["actions"].as_array().expect("actions");
    let canonical = |id: &str| -> String {
        palette::DUPLICATES
            .iter()
            .find(|(duplicate, _)| *duplicate == id)
            .map_or(id, |(_, original)| *original)
            .to_owned()
    };
    let mut by_name: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for action in actions {
        let shown = action["surfacePlan"]["palette"] == "offered" || !action["mainMenu"].is_null();
        if !shown {
            continue;
        }
        let title = action["title"].as_str().expect("title");
        // The app titles debug rows "Debug: <name>" (`withDebugActionsLast`).
        let title = if action["isDebugOnly"] == true {
            format!("Debug: {title}")
        } else {
            title.to_owned()
        };
        by_name
            .entry(name(&title))
            .or_default()
            .push(action["id"].as_str().expect("id").to_owned());
    }
    let mut clashes = Vec::new();
    for (shared, ids) in &by_name {
        let mut commands: Vec<String> = ids.iter().map(|id| canonical(id)).collect();
        commands.sort();
        commands.dedup();
        if commands.len() > 1 {
            clashes.push(format!("{shared}: {ids:?} are different commands with one name"));
        }
    }
    assert!(clashes.is_empty(), "{}", clashes.join("\n"));

    let title_of = |id: &str| -> String {
        let action =
            actions.iter().find(|action| action["id"] == id).unwrap_or_else(|| panic!("{id}"));
        name(action["title"].as_str().expect("title"))
    };
    for (duplicate, original) in palette::DUPLICATES {
        assert_eq!(
            title_of(duplicate),
            title_of(original),
            "{duplicate} does not read as {original}"
        );
        assert_eq!(canonical(original), *original, "{original} is itself a duplicate");
    }
}
