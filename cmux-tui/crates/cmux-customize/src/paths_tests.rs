use super::*;

fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
    move |name| pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value))
}

#[test]
fn the_default_roots_sit_under_home() {
    let roots = Roots::from(env(&[("HOME", "/home/pat")])).unwrap();
    // `cmux-next` on macOS (cmux Classic owns `cmux` there), `cmux` elsewhere.
    let dir = cmux_config::NEXT_DIR;
    let under = |path: &str| PathBuf::from(path.replace("{dir}", dir));
    assert_eq!(roots.settings_file, under("/home/pat/.config/{dir}/cmux-next.json"));
    assert_eq!(roots.customize_dir, under("/home/pat/.config/{dir}/customize"));
    assert_eq!(roots.state_dir, under("/home/pat/.local/state/{dir}/customize"));
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
    assert_eq!(
        roots.customize_dir,
        PathBuf::from("/x").join(cmux_config::NEXT_DIR).join("customize")
    );
}

#[test]
fn the_automations_folder_is_the_runners() {
    let roots = Roots::from(env(&[
        ("HOME", "/home/pat"),
        ("CMUX_NEXT_CONFIG_FILE", "/tmp/tagged/cmux-next.json"),
    ]))
    .unwrap();
    // Not the tagged settings file's folder: the runner's own default,
    // next to the customize folder under HOME.
    assert_eq!(roots.automations_dir, roots.customize_dir.with_file_name("automations"));
    assert!(roots.automations_dir.starts_with("/home/pat"));
    let roots = Roots::from(env(&[
        ("HOME", "/home/pat"),
        ("CMUX_NEXT_CONFIG_FILE", "/tmp/tagged/cmux-next.json"),
        ("CMUX_AUTOMATIONS_DIR", "/tmp/tagged/automations"),
    ]))
    .unwrap();
    assert_eq!(roots.automations_dir, PathBuf::from("/tmp/tagged/automations"));
}
