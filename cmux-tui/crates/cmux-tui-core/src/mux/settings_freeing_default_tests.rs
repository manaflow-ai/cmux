use super::*;

fn store_with(file: &str) -> ConfigStore {
    let dir = std::env::temp_dir().join(format!(
        "cmux-freeing-default-{}-{}",
        std::process::id(),
        file.len()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, file).expect("write");
    ConfigStore::open(
        config,
        None,
        None,
        Box::new(cmux_config::managed::FixedManagedReader::default()),
    )
}

/// Leo, 2026-11-19: freeing idle shells in workspaces hidden for a day is on by default. A
/// settings file that never names it turns the daemon's freeing timer on, after a day.
#[test]
fn freeing_is_on_by_default_after_a_day() {
    let store = store_with("{}");
    let settings = freeing_settings(store.state());
    assert!(settings.enabled);
    assert_eq!(settings.idle, std::time::Duration::from_secs(1440 * 60));
    assert!(settings.agents);
    assert!(!settings.relaunch_running_commands);
    assert_eq!(settings, super::super::idle_freeing::FreeingSettings::default());
}

#[test]
fn freeing_off_in_the_file_keeps_it_off() {
    let store = store_with(r#"{"workspaces":{"freeing":{"enabled":false}}}"#);
    assert!(!freeing_settings(store.state()).enabled);
}
