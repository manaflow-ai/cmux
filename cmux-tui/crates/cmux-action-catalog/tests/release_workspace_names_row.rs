//! Release All Workspace Names to Automatic (`workspace.releaseNames`) hands every pinned
//! workspace name back to the automatic namer through the daemon's `release-workspace-names`.
//! Leo, 2026-11-24: "should it be auto by default? i kinda like it... unless it was force
//! renamed as a thing... oh! i guess there's auto and manual."
use cmux_action_catalog::model::PALETTE;
use cmux_action_catalog::{find, strings};

#[test]
fn release_workspace_names_is_a_palette_row() {
    let action = find("workspace.releaseNames").expect("Release All Workspace Names to Automatic");
    assert_eq!(strings::resolve(&action.title, 0), "Release All Workspace Names to Automatic");
    assert_ne!(action.surfaces & PALETTE, 0, "the row is in the palette");
    assert_eq!(action.category, "workspace");
    assert!(action.arguments.is_empty(), "it releases every pinned name: no argument");
    for word in ["release", "automatic", "name"] {
        assert!(action.keywords.contains(&word), "a search for {word:?} finds it");
    }
}
