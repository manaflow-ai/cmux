use super::may_bind;

#[test]
fn a_key_mode_owns_bare_keys() {
    for when in [
        "keyMode == 'resize'",
        "keyMode == \"resize\"",
        "keyMode == resize",
        "keyMode",
        "keyMode == 'resize' && surfaceKind == 'terminal'",
        "(keyMode == 'pane') && !paletteOpen",
    ] {
        assert!(may_bind(Some(when)), "{when}");
    }
}

#[test]
fn a_key_mode_term_must_hold_on_every_branch_and_never_in_a_text_field() {
    for when in [
        "keyMode == ''",
        "keyMode != 'resize'",
        "!keyMode",
        "keyMode == 'resize' || terminalFocused",
        "keyMode == 'resize' && textInputFocus",
        "keyMode == 'resize' && terminalFocused",
        "keyMode =~ /re/",
        "resizeMode == 'resize'",
        "keyMode == 'resize",
    ] {
        assert!(!may_bind(Some(when)), "{when}");
    }
}
