//! Cmd-R reloads the agent chat that has the keyboard (Leo, 2026-11-22: "apparently i cant cmd r to refresh an
//! agent page"). Before, Cmd-R in a chat fell to Rename Tab, the unscoped default; the chat's own key is the more
//! specific binding there, as the browser's and the Markdown viewer's Reload are in theirs.
use cmux_action_catalog::{CMD, find};

#[test]
fn cmd_r_reloads_the_focused_agent_chat_and_renames_a_tab_elsewhere() {
    let reload = find("agentPaneReload").expect("agentPaneReload is in the catalog");
    let key = reload.default_shortcut.expect("Agent Chat: Reload has a default key");
    assert_eq!((key.key, key.modifiers), ("r", CMD));
    assert_eq!(
        reload.requires,
        &["agentPaneFocused"],
        "it runs only in a chat that has the keyboard"
    );

    let rename = find("renameTab").expect("renameTab is in the catalog");
    let key = rename.default_shortcut.expect("Rename Tab keeps its key");
    assert_eq!((key.key, key.modifiers), ("r", CMD));
    assert!(
        rename.requires.is_empty(),
        "Rename Tab keeps Cmd-R everywhere a page does not claim it"
    );
}
