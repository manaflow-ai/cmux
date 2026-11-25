use super::*;

/// A frontend's shell on the holder starts through login(1), as on the
/// hosted path: a login shell whose `$0` starts with `-`, with
/// `.zprofile`, a utmpx record and "Last login" as its first paint. The
/// surface still records the shell's own argv, and the marker never
/// reaches the shell.
#[cfg(target_os = "macos")]
#[test]
fn a_marked_frontend_shell_starts_through_login_as_on_the_hosted_path() {
    let shell = vec!["/bin/zsh".to_string()];
    let opts = SurfaceOptions {
        command: Some(shell.clone()),
        extra_env: vec![(crate::login_shell::MARKER.to_string(), "1".to_string())],
        ..SurfaceOptions::default()
    };
    let Some(expected) = crate::login_shell::wrap(&shell, &opts.extra_env) else {
        // An isolated HOME or no /usr/bin/login: the hosted path does
        // not wrap either.
        eprintln!("login(1) start not available here; nothing to compare");
        return;
    };
    let command = holder_command(&opts);
    assert_eq!(command.spawn_argv, expected);
    assert_eq!(command.spawn_argv[0], "/usr/bin/login");
    assert_eq!(command.spawn_argv.last(), Some(&"/bin/zsh".to_string()));
    assert_eq!(command.argv, shell, "the recorded command stays the shell's");
    let marker = format!("{}=", crate::login_shell::MARKER);
    assert!(
        !command.env.iter().any(|entry| entry.starts_with(marker.as_bytes())),
        "the marker reaches the shell"
    );
}

/// `echo $TERM_PROGRAM` in a cmux terminal says `cmux`, with cmux's own
/// version, whatever Ghostty identity the daemon inherited (a Cloud
/// daemon starts with `TERM_PROGRAM=ghostty` and a Ghostty version) or an
/// older app passed in the launch env.
#[test]
fn holder_children_identify_as_cmux() {
    let launch = crate::shell_integration::ShellLaunch {
        command: vec!["/bin/zsh".to_string()],
        env: vec![
            ("TERM_PROGRAM".to_string(), "ghostty".to_string()),
            ("TERM_PROGRAM_VERSION".to_string(), "1.3.2".to_string()),
        ],
    };
    let inherited = BTreeMap::from([
        (OsString::from("TERM_PROGRAM"), OsString::from("ghostty")),
        (OsString::from("TERM_PROGRAM_VERSION"), OsString::from("1.3.2")),
    ]);

    let environment = holder_environment(&launch, &SurfaceOptions::default(), inherited);

    assert_eq!(environment.get(OsStr::new("TERM_PROGRAM")), Some(&OsString::from("cmux")));
    assert_eq!(
        environment.get(OsStr::new("TERM_PROGRAM_VERSION")),
        Some(&OsString::from(env!("CARGO_PKG_VERSION")))
    );
    assert_eq!(environment.get(OsStr::new("COLORTERM")), Some(&OsString::from("truecolor")));
}
