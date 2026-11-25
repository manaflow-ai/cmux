use super::*;

#[test]
fn with_no_home_the_settings_path_stays_relative() {
    assert_eq!(path_from(|_| None, || None), PathBuf::from(".config/cmux/cmux-next.json"));
}

#[test]
fn home_and_override_resolve_as_cmux_config_does() {
    let home = |name: &str| (name == "HOME").then(|| OsString::from("/h"));
    assert_eq!(path_from(home, || None), PathBuf::from("/h/.config/cmux/cmux-next.json"));
    let fallback = path_from(|_| None, || Some(PathBuf::from("/d")));
    assert_eq!(fallback, PathBuf::from("/d/.config/cmux/cmux-next.json"));
    let over = |name: &str| match name {
        "HOME" => Some(OsString::from("/h")),
        CONFIG_OVERRIDE => Some(OsString::from("~/t.json")),
        _ => None,
    };
    assert_eq!(path_from(over, || None), PathBuf::from("/h/t.json"));
}
