use super::*;

#[test]
fn app_ids_are_publisher_slash_name() {
    assert!(valid_widget_app("cmux/pr-card"));
    assert!(valid_widget_app("local/customize"));
    assert!(!valid_widget_app("cmux"));
    assert!(!valid_widget_app("cmux/pr/card"));
    assert!(!valid_widget_app("Cmux/pr"));
    assert!(!valid_widget_app("/pr"));
}

#[test]
fn only_extensions_draw_widgets() {
    assert!(is_extension_widget_app("local/pr-card"));
    assert!(is_extension_widget_app("octo/pr-card"));
    assert!(!is_extension_widget_app("cmux/pr-card"));
    assert!(!is_extension_widget_app("manaflow-ai/pr-card"));
}
