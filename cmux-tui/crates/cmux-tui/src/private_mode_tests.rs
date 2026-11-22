use super::{render_capabilities, run};

/// `__daemon-capabilities --json` prints the list `identify` always serves, the one
/// the app bundle's daemon-capabilities.json records.
#[test]
fn capabilities_prints_the_static_identify_list() {
    let listed = cmux_tui_core::server::static_capabilities();
    assert!(listed.contains(&"ws-conversations-v1"), "{listed:?}");
    let printed: serde_json::Value = serde_json::from_str(&render_capabilities(true)).unwrap();
    assert_eq!(printed, serde_json::json!({ "capabilities": listed }));
    let lines: Vec<String> = render_capabilities(false).lines().map(str::to_owned).collect();
    assert_eq!(lines, listed);
}

/// `cmux capabilities` stays the classic verb that asks the app
/// (`system.capabilities`); only the private name runs offline.
#[test]
fn the_public_capabilities_verb_is_left_to_the_app() {
    for args in [
        &["capabilities"][..],
        &["capabilities", "--json"],
        &["capabilities", "--id-format", "both"],
    ] {
        let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
        assert_eq!(run(&args), None, "{args:?}");
    }
}
