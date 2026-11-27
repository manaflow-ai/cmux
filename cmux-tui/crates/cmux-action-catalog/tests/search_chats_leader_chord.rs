//! Search Agent Chats has Command-J K (RFD 0167 row 8 gap 4): Command-K opens it only outside
//! terminals and the code editor (bindings.rs), where Command-K is Clear and the editor's chords.

use cmux_action_catalog::{CMD, actions, find};

#[test]
fn search_chats_chord_is_command_j_k() {
    let action = find("agentPane.searchChats").expect("an action");
    let chord = action.default_chord.expect("a chord");
    assert_eq!((chord.first.key, chord.first.modifiers), ("j", CMD));
    assert_eq!((chord.second.key, chord.second.modifiers), ("k", 0));
    assert!(action.requires.is_empty(), "the chord works from every surface");
    let others: Vec<_> = actions()
        .filter(|a| a.id != action.id)
        .filter(|a| {
            a.default_chord.is_some_and(|c| {
                c.first.key == "j"
                    && c.first.modifiers == CMD
                    && c.second.key == "k"
                    && c.second.modifiers == 0
            })
        })
        .map(|a| a.id)
        .collect();
    assert!(others.is_empty(), "Command-J K is taken by {others:?}");
}
