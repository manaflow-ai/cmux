//! The diff viewer's text size keys (user 2026-11-19: "cmd + and - need to work in diff viewer"):
//! Cmd-= (and Cmd-Shift-=), Cmd-- and Cmd-0 zoom the diff tab that has the keyboard, as the
//! Markdown viewer's and the code editor's do, and nowhere else.
use cmux_action_catalog::{CMD, SHIFT, bindings, find};

fn zoom_aliases() -> &'static [cmux_action_catalog::Binding] {
    bindings::ZOOM_ALIASES
}

#[test]
fn the_diff_viewer_owns_its_zoom_keys_while_it_has_the_keyboard() {
    for (id, key) in
        [("diffViewerZoomIn", "="), ("diffViewerZoomOut", "-"), ("diffViewerZoomReset", "0")]
    {
        let action = find(id).unwrap_or_else(|| panic!("{id} is in the catalog"));
        let shortcut = action.default_shortcut.unwrap_or_else(|| panic!("{id} has a default key"));
        assert_eq!((shortcut.key, shortcut.modifiers), (key, CMD), "{id}");
        assert_eq!(action.requires, &["diffViewerFocused"], "{id} runs only in a focused diff tab");
    }
    assert!(
        zoom_aliases().iter().any(|binding| binding.command == "diffViewerZoomIn"
            && binding.keys.len() == 1
            && binding.keys[0].key == "="
            && binding.keys[0].modifiers == SHIFT | CMD
            && binding.when == Some("diffViewerFocused")),
        "Cmd-+ (Cmd-Shift-=) zooms in too, only in a focused diff tab (the Markdown viewer's alias has the key unscoped)"
    );
}
