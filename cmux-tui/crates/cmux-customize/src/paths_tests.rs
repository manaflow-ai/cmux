use super::*;

fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
    move |name| pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value))
}

#[test]
fn the_default_roots_sit_under_home() {
    let roots = Roots::from(env(&[("HOME", "/home/pat")])).unwrap();
    assert_eq!(roots.settings_file, PathBuf::from("/home/pat/.config/cmux/cmux-next.json"));
    assert_eq!(roots.customize_dir, PathBuf::from("/home/pat/.config/cmux/customize"));
    assert_eq!(roots.state_dir, PathBuf::from("/home/pat/.local/state/cmux/customize"));
}

#[test]
fn a_launch_with_its_own_settings_file_keeps_its_own_generations() {
    let roots = Roots::from(env(&[
        ("HOME", "/home/pat"),
        ("CMUX_NEXT_CONFIG_FILE", "/tmp/tagged/cmux-next.json"),
    ]))
    .unwrap();
    assert_eq!(roots.state_dir, PathBuf::from("/tmp/tagged/.customize-state"));
}

#[test]
fn the_customize_folder_follows_the_daemons_order() {
    let roots = Roots::from(env(&[
        ("HOME", "/home/pat"),
        ("XDG_CONFIG_HOME", "/x"),
        ("CMUX_CUSTOMIZE_DIR", "/mine"),
    ]))
    .unwrap();
    assert_eq!(roots.customize_dir, PathBuf::from("/mine"));
    let roots = Roots::from(env(&[("HOME", "/home/pat"), ("XDG_CONFIG_HOME", "/x")])).unwrap();
    assert_eq!(roots.customize_dir, PathBuf::from("/x/cmux/customize"));
}
