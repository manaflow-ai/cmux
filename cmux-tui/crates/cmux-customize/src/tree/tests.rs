use super::*;

#[test]
fn a_path_outside_every_part_is_never_located() {
    let roots = Roots::under(Path::new("/r"));
    for path in [
        "",
        "../x",
        "customize/../../x",
        "/etc/passwd",
        "cloud-secrets.json",
        "automations/a/state.json",
        "automations/a/b/automation.json",
        "themes",
        "customize",
        "agent-pane/registry.js",
        "customize\\x",
    ] {
        assert_eq!(locate(&roots, path), None, "{path}");
    }
    assert_eq!(locate(&roots, SETTINGS), Some(PathBuf::from("/r/config/cmux-next.json")));
    assert_eq!(
        locate(&roots, "automations/auto_1/automation.json"),
        Some(PathBuf::from("/r/config/automations/auto_1/automation.json"))
    );
}

#[test]
fn every_located_path_names_its_part() {
    assert_eq!(Part::of(SETTINGS), Part::Settings);
    assert_eq!(Part::of("themes/night.json"), Part::Themes);
    assert_eq!(Part::of("customize/main.js"), Part::Views);
    assert_eq!(Part::of("agent-pane/theme.css"), Part::Styles);
    assert_eq!(Part::of("automations/auto_1/automation.json"), Part::Automations);
}
