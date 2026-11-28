use super::*;

#[test]
fn with_no_home_both_files_stay_relative() {
    assert_eq!(
        paths_from(|_| None, || None),
        [PathBuf::from(".config/cmux/cmux-next.json"), PathBuf::from(".config/cmux/cmux.json")]
    );
}

#[test]
fn home_and_override_resolve_as_cmux_config_does() {
    let home = |name: &str| (name == "HOME").then(|| OsString::from("/h"));
    assert_eq!(
        paths_from(home, || None),
        [
            PathBuf::from("/h/.config/cmux/cmux-next.json"),
            PathBuf::from("/h/.config/cmux/cmux.json")
        ]
    );
    let fallback = paths_from(|_| None, || Some(PathBuf::from("/d")));
    assert_eq!(fallback[1], PathBuf::from("/d/.config/cmux/cmux.json"));
    let over = |name: &str| match name {
        "HOME" => Some(OsString::from("/h")),
        CONFIG_OVERRIDE => Some(OsString::from("~/t.json")),
        _ => None,
    };
    assert_eq!(paths_from(over, || None), [PathBuf::from("/h/t.json")]);
}
