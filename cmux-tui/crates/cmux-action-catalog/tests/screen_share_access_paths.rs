//! Every way a person starts a screen share onto another machine, read back from the catalog in
//! one place (Leo, 2026-11-14: "for screen sharing but what about how people access it in the
//! first place? is that tested?"). Each path runs `macScreen.open`, which takes the machine as
//! `device`, so a path that names a machine opens it in one step. The app-side paths have their
//! own tests: the sidebar machine header's screen button (CmuxNextAppTests
//! SidebarScreenIntentActionsTests) and Session Info's View screen (cmux-window-rules
//! `screen_share`, webviews session-info-screen-sharing-kind).
use cmux_action_catalog::{CMD, Decision, PALETTE, SHIFT, find, palette};

#[test]
fn screen_sharing_starts_from_every_path_with_no_setting_in_the_way() {
    let open = find("macScreen.open").expect("Screen Sharing");

    // Command palette: listed by default, with the daily commands.
    assert_ne!(open.surfaces & PALETTE, 0, "not in the palette");
    assert_eq!(open.surface_plan.palette, Decision::Offered);
    assert!(palette::DAILY.contains(&"macScreen.open"));

    // File menu.
    assert_eq!(open.main_menu, Some("file"));

    // Cmd-Shift-S.
    let key = open.default_shortcut.expect("a default shortcut");
    assert_eq!((key.key, key.modifiers), ("s", SHIFT | CMD));

    // The chevron beside the new tab +, and the pane and tab menus.
    for context in ["newTab", "pane", "tab"] {
        assert!(
            open.surface_plan.context_menus.iter().any(|p| p.context == context),
            "Screen Sharing is not in the {context} menu"
        );
    }

    // `cmux tab new-mac-screen --device NAME`: one command onto a named machine.
    assert_eq!(open.surface_plan.cli, Some(Decision::Offered));
    assert_eq!(open.cli_name, "tab new-mac-screen");
    let device = open.arguments.iter().find(|a| a.name == "device").expect("a device argument");
    assert!(!device.required, "the picker opens with no device");

    // No Labs switch or other setting gates viewing another machine (`labs.machineJoin` only
    // narrows what this Mac itself serves).
    assert!(open.requires.is_empty(), "macScreen.open requires {:?}", open.requires);
    assert!(!open.is_debug_only);
}
