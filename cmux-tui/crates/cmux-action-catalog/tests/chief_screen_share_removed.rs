//! Share Screen with Chief is gone (user 2026-11-20: "remove share screen with chief"): no
//! `chief.screenShare.*` action, no `cmux chief share-screen` CLI verb (or its stop, look and toggle
//! verbs), and no catalog string for them, so neither the palette, the CLI nor MCP offers it.
use cmux_action_catalog::{actions, find, strings};

#[test]
fn share_screen_with_chief_has_no_action_verb_or_string() {
    for id in [
        "chief.screenShare.toggle",
        "chief.screenShare.start",
        "chief.screenShare.stop",
        "chief.screenShare.look",
    ] {
        assert!(find(id).is_none(), "{id} is still an action");
    }
    let verbs = [
        "chief share-screen",
        "chief stop-sharing-screen",
        "chief look-at-screen",
        "chief toggle-screen-share",
    ];
    let left: Vec<_> = actions().filter(|a| verbs.contains(&a.cli_name)).map(|a| a.id).collect();
    assert!(left.is_empty(), "these actions still take a Share Screen with Chief verb: {left:?}");
    let keys: Vec<_> = strings::entries()
        .filter(|(_, key, _)| key.starts_with("action.chief.screenShare."))
        .map(|(_, key, _)| key)
        .collect();
    assert!(keys.is_empty(), "strings left for Share Screen with Chief: {keys:?}");
}
