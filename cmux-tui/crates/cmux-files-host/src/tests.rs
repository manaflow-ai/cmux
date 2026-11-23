use super::*;

fn args(list: &[&str]) -> Vec<OsString> {
    list.iter().map(OsString::from).collect()
}

#[test]
fn parse_reads_both_roles_and_launch_services() {
    assert_eq!(parse(&args(&["run", "--", "/a/b", "x"])), Invocation::Run(args(&["/a/b", "x"])));
    assert_eq!(parse(&args(&["host", "--", "/a/b"])), Invocation::Host(args(&["/a/b"])));
    assert_eq!(parse(&[]), Invocation::LaunchServicesOpen);
    assert_eq!(parse(&args(&["-psn_0_12345"])), Invocation::LaunchServicesOpen);
    assert_eq!(parse(&args(&["run", "--"])), Invocation::Usage);
    assert_eq!(parse(&args(&["run", "/a/b"])), Invocation::Usage);
    assert_eq!(parse(&args(&["serve", "--", "/a/b"])), Invocation::Usage);
}

#[test]
fn outermost_app_and_own_bundle() {
    let inner = Path::new(
        "/A/cmux DEV x.app/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host",
    );
    assert_eq!(outermost_app(inner), Some(PathBuf::from("/A/cmux DEV x.app")));
    let bundle = own_bundle(inner).unwrap();
    assert_eq!(bundle, PathBuf::from("/A/cmux DEV x.app/Contents/Library/cmux Files (dev).app"));
    assert!(nested_in_app(&bundle));
    let staged = Path::new("/H/files-host/app/0123/cmux Files (dev).app");
    assert!(!nested_in_app(staged));
    assert_eq!(own_bundle(Path::new("/usr/bin/true")), None);
    assert_eq!(outermost_app(Path::new("/usr/bin/true")), None);
}

#[test]
fn a_program_runs_only_from_an_app_that_embeds_the_same_helper() {
    let dir = tempfile::tempdir().unwrap();
    let own = dir.path().join("own");
    std::fs::write(&own, b"helper bytes").unwrap();
    let app = dir.path().join("cmux DEV a.app");
    let embedded = app.join(EMBEDDED_EXECUTABLE);
    std::fs::create_dir_all(embedded.parent().unwrap()).unwrap();
    std::fs::write(&embedded, b"helper bytes").unwrap();
    let program = app.join("Contents/Resources/bin/cmux-tui");
    std::fs::create_dir_all(program.parent().unwrap()).unwrap();
    std::fs::write(&program, b"daemon").unwrap();
    let canonical = std::fs::canonicalize(&program).unwrap();
    assert_eq!(allowed_program(program.as_os_str(), &own), Some(canonical));

    // Relative paths, `..` out of the app, other helper bytes and apps without it: refused.
    assert_eq!(allowed_program(OsStr::new("cmux-tui"), &own), None);
    let outside = dir.path().join("tool");
    std::fs::write(&outside, b"x").unwrap();
    let escaped = app.join("Contents/../../tool");
    assert_eq!(allowed_program(escaped.as_os_str(), &own), None);
    std::fs::write(&own, b"other helper").unwrap();
    assert_eq!(allowed_program(program.as_os_str(), &own), None);
    let other = dir.path().join("Other.app/Contents/MacOS/other");
    std::fs::create_dir_all(other.parent().unwrap()).unwrap();
    std::fs::write(&other, b"x").unwrap();
    assert_eq!(allowed_program(other.as_os_str(), &own), None);
}

#[test]
fn staging_root_is_shared_by_every_build() {
    let root = staging_root(Path::new("/Users/p"));
    assert!(root.starts_with("/Users/p/Library"));
    assert!(root.ends_with("cmux/files-host/app"));
    assert!(requirement().contains("\"com.cmuxterm.files.dev\""));
    assert!(requirement().contains("\"7WLXT3NR37\""));
}
