//! Rename Agent Session… (`agentChat.renameSession`) renames the focused chat's agent session,
//! the name `cmux agent ls` and `HOST/NAME` read. Rename Tab (`renameTab`) only retitles the tab
//! and stays its own row. The CLI verb is the session owner's: `cmux agent session rename`.
//! Leo, 2026-11-20: "we need to honestly like rename the VMs that we have, and then like rename
//! the sessions that we have".
use cmux_action_catalog::model::{Decision, PALETTE};
use cmux_action_catalog::{find, strings};

#[test]
fn rename_agent_session_is_a_palette_row_on_the_focused_chat() {
    let action = find("agentChat.renameSession").expect("Rename Agent Session");
    assert_eq!(strings::resolve(&action.title, 0), "Rename Agent Session…");
    assert_ne!(action.surfaces & PALETTE, 0, "the row is in the palette");
    assert_eq!(action.category, "agents");
    assert_eq!(action.requires, ["agentPaneFocused"]);
    assert_eq!(action.targets, ["pane"]);
    let names: Vec<&str> = action.arguments.iter().map(|argument| argument.name).collect();
    assert_eq!(names, ["name"], "the new name is its one argument");
    for word in ["rename", "session", "agent"] {
        assert!(action.keywords.contains(&word), "a search for {word:?} finds it");
    }
    // The CLI already has the verb (acpmux's `agent session rename`): no second CLI command.
    assert!(matches!(action.surface_plan.cli, Some(Decision::Exempt("ownerVerb"))));
}

#[test]
fn rename_tab_stays_its_own_row() {
    let tab = find("renameTab").expect("Rename Tab");
    let session = find("agentChat.renameSession").expect("Rename Agent Session");
    assert_ne!(strings::resolve(&tab.title, 0), strings::resolve(&session.title, 0));
    assert_eq!(tab.targets, ["tab"]);
}
