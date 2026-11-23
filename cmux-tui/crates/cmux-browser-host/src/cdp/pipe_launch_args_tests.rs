use super::*;

fn options() -> HeadlessOptions {
    HeadlessOptions::new(PathBuf::from("/bin/chromium"))
}

#[test]
fn launch_args_refuse_running_without_the_sandbox() {
    for switch in ["--no-sandbox", "--NO-SANDBOX", "--no-sandbox=1", "--disable-setuid-sandbox"] {
        let mut options = options();
        options.extra_args = vec!["--lang=en".into(), switch.into()];
        let error = launch_args(&options, std::path::Path::new("/tmp/p")).unwrap_err();
        assert!(error.to_string().contains("sandbox"), "{switch}: {error}");
    }
}

#[test]
fn launch_args_follow_the_headless_and_background_options() {
    let path = std::path::Path::new("/tmp/p");
    let default = launch_args(&options(), path).unwrap();
    assert!(default.contains(&"--headless".to_string()));
    assert!(default.contains(&"--disable-background-timer-throttling".to_string()));
    let mut headful = options();
    headful.headless = false;
    headful.full_rate_background = false;
    let args = launch_args(&headful, path).unwrap();
    assert!(!args.iter().any(|a| a.starts_with("--headless")), "{args:?}");
    for switch in [
        "--disable-background-timer-throttling",
        "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
    ] {
        assert!(!args.contains(&switch.to_string()), "{switch} in {args:?}");
    }
    // The page URL stays last.
    assert_eq!(args.last().map(String::as_str), Some("about:blank"));
}

#[test]
fn disabled_features_merge_into_one_switch() {
    let mut options = options();
    options.extra_args =
        vec!["--disable-features=Translate,PaintHolding".into(), "--lang=en".into()];
    let args = launch_args(&options, std::path::Path::new("/tmp/p")).unwrap();
    let switches: Vec<&String> =
        args.iter().filter(|a| a.starts_with("--disable-features=")).collect();
    assert_eq!(
        switches,
        vec!["--disable-features=PaintHolding,HappyEyeballsV3,Translate"],
        "{args:?}"
    );
    assert_eq!(args.last().map(String::as_str), Some("about:blank"));
}
