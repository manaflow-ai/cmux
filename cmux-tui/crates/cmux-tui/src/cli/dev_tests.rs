use super::*;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn only_curated_surface_handles_ui_layer_command() {
    let args = strings(&["dev", "ui-host"]);
    assert!(is_requested(&args));
    assert!(run_if_requested(&args, Surface::CmuxTui).is_none());
}

#[test]
fn forwards_launcher_arguments() {
    assert!(is_requested(&strings(&["dev", "ui-host", "--watch"])));
    assert!(is_requested(&strings(&["preview", "open", "--size", "1280x800"])));
    assert!(!is_requested(&strings(&["preview"])));
    assert!(!is_requested(&strings(&["open", "preview"])));
    assert!(!is_requested(&strings(&["dev"])));
    assert!(!is_requested(&strings(&["ui-host", "dev"])));
}
