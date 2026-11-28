//! Open Last Turn's Changes (`agentPane.openLastTurnChanges`) opens the diff of the focused chat's
//! last turn that edited files, beside the chat, as that turn's edited-files card's View changes
//! does, from the keyboard: Command-J G. The page runs it (`pane.commandAvailability` lists it
//! while a turn edited something); the App's `AgentPageCommand` case follows the re-pin.
use cmux_action_catalog::model::{CMD, Chord, KEYBOARD, PALETTE, Shortcut};
use cmux_action_catalog::{actions, find, strings};

#[test]
fn open_last_turn_changes_is_command_j_g_on_the_focused_chat() {
    let action = find("agentPane.openLastTurnChanges").expect("Open Last Turn's Changes");
    assert_eq!(strings::resolve(&action.title, 0), "Open Last Turn's Changes");
    let chord = Chord {
        first: Shortcut { key: "j", modifiers: CMD },
        second: Shortcut { key: "g", modifiers: 0 },
    };
    assert_eq!(action.default_chord, Some(chord));
    assert_ne!(action.surfaces & PALETTE, 0, "the row is in the palette");
    assert_ne!(action.surfaces & KEYBOARD, 0, "the chord is a keyboard shortcut");
    assert_eq!(action.requires, ["agentPaneFocused"]);
    assert_eq!(action.targets, ["pane"]);
    for word in ["diff", "changes", "turn"] {
        assert!(action.keywords.contains(&word), "a search for {word:?} finds it");
    }
    // No other default chord is Command-J G.
    let others: Vec<&str> = actions()
        .filter(|a| a.id != action.id && a.default_chord == Some(chord))
        .map(|a| a.id)
        .collect();
    assert!(others.is_empty(), "Command-J G is also {others:?}");
}
