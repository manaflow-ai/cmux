use super::{HOLDER_BY_DEFAULT, model_enabled, model_enabled_with_default};

#[test]
fn the_model_names_win_over_the_default() {
    for default in [false, true] {
        assert!(model_enabled_with_default(Some("holder"), default));
        assert!(model_enabled_with_default(Some(" holder "), default));
        assert!(!model_enabled_with_default(Some("hosts"), default));
        assert_eq!(model_enabled_with_default(None, default), default);
        assert_eq!(model_enabled_with_default(Some(""), default), default);
        assert_eq!(model_enabled_with_default(Some("bogus"), default), default);
    }
}

#[test]
fn the_holder_is_the_default_on_macos_only() {
    assert_eq!(HOLDER_BY_DEFAULT, cfg!(target_os = "macos"));
    assert_eq!(model_enabled(None), cfg!(target_os = "macos"));
    assert!(!model_enabled(Some("hosts")));
}
