use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

#[test]
fn parses_the_verbs_and_leaves_other_apps_verbs() {
    assert_eq!(parse(&words("on"), false), Some(Ok((Request::On, None))));
    assert_eq!(
        parse(&words("off --state-dir /tmp/x"), false),
        Some(Ok((Request::Off, Some(PathBuf::from("/tmp/x")))))
    );
    assert_eq!(parse(&words("status"), false), Some(Ok((Request::Status, None))));
    assert!(matches!(parse(&words("maybe"), false), Some(Err(_))));
    assert!(matches!(parse(&words("on --state-dir"), false), Some(Err(_))));
    assert_eq!(
        parse(&words("rollback local/customize"), true),
        Some(Ok((Request::Rollback { app: "local/customize".into() }, None)))
    );
    assert!(matches!(parse(&words("rollback"), true), Some(Err(_))));
    assert_eq!(parse(&words("list"), true), None, "apps list is apps_list");
    assert_eq!(parse(&words("install acme/x"), true), None, "install is the app action");
}

#[test]
fn with_no_daemon_on_and_off_write_the_flag_file() {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-cli-safe-mode-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    let path = safe_mode_flag::path_in(&dir);
    assert_eq!(offline(&Request::Status, &path).unwrap(), json!({"on": false}));
    let on = offline(&Request::On, &path).unwrap();
    assert_eq!((on["on"].clone(), on["reason"].clone()), (json!(true), json!("user")));
    // On again keeps the first time (and a crash loop's names).
    assert_eq!(offline(&Request::On, &path).unwrap()["sinceMs"], on["sinceMs"]);
    assert!(human(&on, &Request::Status, true).contains("starts in safe mode next time"));
    assert_eq!(offline(&Request::Off, &path).unwrap(), json!({"on": false}));
    assert!(!path.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_crash_loop_status_names_the_extensions() {
    let state = json!({"on": true, "reason": "crash-loop", "sinceMs": 1, "extensions": ["local/customize"]});
    let text = human(&state, &Request::Status, false);
    assert!(text.contains("crashed several times"), "{text}");
    assert!(text.contains("local/customize"), "{text}");
    assert!(text.contains("Roll Back"), "{text}");
}

#[test]
fn bisect_parses_its_steps_and_says_what_to_do_next() {
    assert_eq!(
        parse(&words("bisect"), false),
        Some(Ok((Request::Bisect { step: "status".into() }, None)))
    );
    for step in ["start", "good", "bad", "reset", "status"] {
        assert_eq!(
            parse(&words(&format!("bisect {step}")), false),
            Some(Ok((Request::Bisect { step: step.into() }, None)))
        );
    }
    assert!(matches!(parse(&words("bisect maybe"), false), Some(Err(_))));
    assert!(matches!(parse(&words("bisect good bad"), false), Some(Err(_))));

    let running = json!({"on": true, "bisect": {
        "suspects": ["a", "b", "c"], "running": ["a", "b"], "held": ["c"], "steps": 0}});
    let text = bisect_human(&running);
    assert!(text.contains("3 extensions left") && text.contains("Running now: a, b."), "{text}");
    assert!(text.contains("Still off: c.") && text.contains("bisect bad"), "{text}");
    let found = json!({"on": true, "bisect": {"suspects": ["b"], "running": [], "held": ["b"], "steps": 2, "found": "b"}});
    assert!(bisect_human(&found).starts_with("Found it: b breaks cmux."));
    assert!(bisect_human(&json!({"on": true})).contains("bisect start"));
    assert!(bisect_human(&json!({"on": false})).contains("Safe mode is off"));
}
