use super::*;

fn lines(text: &str) -> Patterns {
    parse(text.lines())
}

#[test]
fn parses_like_gitignore_from_the_root() {
    let parsed = lines("# env\n.env\n\n!.env.test\nconfig/*.local/\n\\#hash\n/abs\n../out\n~/x\n");
    assert_eq!(parsed.patterns.len(), 4);
    assert!(parsed.patterns[1].negated);
    assert!(parsed.patterns[2].directory_only);
    assert_eq!(parsed.patterns[3].segments, ["#hash"]);
    assert_eq!(parsed.problems.len(), 3);
    assert!(parsed.problems[0].starts_with("line 7"));
    // A long chain of `**` is refused before anything walks or matches it.
    assert!(lines(&format!("{}.env", "a/**/".repeat(40_000))).patterns.is_empty());
    assert!(lines(&format!("{}.env", "a/".repeat(80_000))).patterns.is_empty());
    // `**/**` is `**`, however many there are.
    assert_eq!(lines("a/**/**/b").patterns[0].segments, ["a", "**", "b"]);
    assert_eq!(
        lines(&format!("{}.env", "**/".repeat(80_000))).patterns[0].segments,
        ["**", ".env"]
    );
}

#[test]
fn keeps_an_escaped_trailing_space() {
    assert_eq!(trim_line("  name\\  "), "name ");
    assert_eq!(trim_line("name \t"), "name");
}

#[test]
fn globs_within_one_name() {
    assert!(glob(b"*.env", b"dev.env"));
    assert!(glob(b".env*", b".env"));
    assert!(glob(b"a?c", b"abc"));
    assert!(!glob(b"*.env", b"dev.env.bak"));
    assert!(matches(&["**".into(), ".env".into()], &["a".into(), "b".into(), ".env".into()]));
    assert!(matches(&["**".into(), ".env".into()], &[".env".into()]));
    assert!(!matches(&["**".into(), ".env".into()], &[]));
    assert!(matches(&["a".into(), "**".into()], &["a".into()]));
    // Many `**` over a deep path answer at once.
    let mut deep: Vec<String> = Vec::new();
    for _ in 0..8 {
        deep.extend(["**".into(), "a".into()]);
    }
    deep.push("missing".into());
    let names: Vec<String> = std::iter::repeat_n("a".to_string(), 64).collect();
    assert!(!matches(&deep, &names));
}

fn scratch(name: &str) -> PathBuf {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let path = std::env::temp_dir().join(format!("cmux-include-{name}-{hex}"));
    fs::create_dir_all(&path).unwrap();
    fs::canonicalize(path).unwrap()
}

#[cfg(unix)]
#[test]
fn copies_what_is_selected_and_overwrites_nothing() {
    let source = scratch("source");
    let destination = scratch("destination");
    fs::write(source.join(".env"), "SECRET=1").unwrap();
    fs::write(source.join(".env.test"), "x").unwrap();
    fs::create_dir_all(source.join("app/config")).unwrap();
    fs::write(source.join("app/config/local.json"), "{}").unwrap();
    fs::create_dir_all(source.join("node_modules/pkg")).unwrap();
    fs::write(source.join("node_modules/pkg/index.js"), "1").unwrap();
    fs::write(source.join("tracked.txt"), "main's edit").unwrap();
    fs::write(destination.join("tracked.txt"), "branch").unwrap();
    fs::create_dir_all(source.join("config/deep")).unwrap();
    fs::write(source.join("config/deep/a.json"), "a").unwrap();
    fs::write(source.join("config/private.env"), "p").unwrap();
    fs::create_dir_all(source.join("keys")).unwrap();
    fs::write(source.join("keys/k"), "k").unwrap();
    let patterns = lines(
        ".env*\n!.env.test\n**/local.json\nnode_modules/\ntracked.txt\nconfig/\n!config/private.env\nkeys/**\n",
    );
    let report = copy(&source, &destination, &patterns, &|| false);
    assert_eq!(fs::read_to_string(destination.join(".env")).unwrap(), "SECRET=1");
    assert!(!destination.join(".env.test").exists());
    assert!(destination.join("app/config/local.json").is_file());
    assert!(destination.join("node_modules/pkg/index.js").is_file());
    assert_eq!(fs::read_to_string(destination.join("tracked.txt")).unwrap(), "branch");
    assert!(destination.join("config/deep/a.json").is_file());
    assert!(!destination.join("config/private.env").exists());
    assert!(destination.join("keys/k").is_file());
    assert_eq!(report.copied, 5);
    assert_eq!(report.kept, 1);
    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(destination).unwrap();
}

#[cfg(unix)]
#[test]
fn a_later_folder_pattern_decides_what_is_inside_it() {
    let source = scratch("source");
    let destination = scratch("destination");
    for folder in ["private", "public", "back"] {
        fs::create_dir_all(source.join(folder)).unwrap();
        fs::write(source.join(folder).join("token.env"), folder).unwrap();
    }
    let patterns = lines("**/*.env\n!private/\n!back/\nback/*.env\n");
    let report = copy(&source, &destination, &patterns, &|| false);
    assert!(!destination.join("private/token.env").exists());
    assert!(destination.join("public/token.env").is_file());
    assert!(destination.join("back/token.env").is_file());
    assert_eq!(report.copied, 2);
    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(destination).unwrap();
}

#[cfg(unix)]
#[test]
fn never_writes_through_a_link_the_worktree_has() {
    let source = scratch("source");
    let destination = scratch("destination");
    let elsewhere = scratch("elsewhere");
    fs::write(source.join(".env"), "SECRET=1").unwrap();
    fs::write(elsewhere.join("target"), "mine").unwrap();
    std::os::unix::fs::symlink(elsewhere.join("target"), destination.join(".env")).unwrap();
    let report = copy(&source, &destination, &lines(".env\n"), &|| false);
    assert_eq!(fs::read_to_string(elsewhere.join("target")).unwrap(), "mine");
    assert_eq!((report.copied, report.kept), (0, 1));
    for folder in [source, destination, elsewhere] {
        fs::remove_dir_all(folder).unwrap();
    }
}

#[cfg(unix)]
#[test]
fn leaves_out_a_fifo_instead_of_waiting_on_it() {
    let source = scratch("source");
    let destination = scratch("destination");
    let fifo = std::ffi::CString::new(source.join("pipe").as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    fs::write(source.join(".env"), "e").unwrap();
    let report = copy(&source, &destination, &lines("pipe\n.env\n"), &|| false);
    assert_eq!(report.copied, 1);
    assert_eq!(report.problems, ["pipe: not a regular file"]);
    assert!(fs::symlink_metadata(destination.join("pipe")).is_err());
    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(destination).unwrap();
}

#[cfg(not(unix))]
#[test]
fn says_why_nothing_is_copied_where_it_cannot_be() {
    let source = scratch("source");
    let destination = scratch("destination");
    fs::write(source.join(".env"), "e").unwrap();
    let report = copy(&source, &destination, &lines(".env\n"), &|| false);
    assert_eq!(report.copied, 0);
    assert_eq!(report.problems.len(), 1);
    assert!(!destination.join(".env").exists());
    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(destination).unwrap();
}

#[cfg(unix)]
#[test]
fn a_folder_it_makes_stays_as_private_as_the_repository_has_it() {
    use std::os::unix::fs::PermissionsExt as _;
    let source = scratch("source");
    let destination = scratch("destination");
    fs::create_dir_all(source.join("private/deeper")).unwrap();
    fs::write(source.join("private/deeper/token"), "t").unwrap();
    fs::write(source.join("private/whole"), "w").unwrap();
    fs::set_permissions(source.join("private"), fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(source.join("private/deeper"), fs::Permissions::from_mode(0o750)).unwrap();
    let report =
        copy(&source, &destination, &lines("private/deeper/token\nprivate/whole\n"), &|| false);
    assert_eq!(report.copied, 2);
    let mode = |path: &str| fs::metadata(destination.join(path)).unwrap().permissions().mode();
    assert_eq!(mode("private") & 0o777, 0o700);
    assert_eq!(mode("private/deeper") & 0o777, 0o750);
    fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
    fs::set_permissions(&destination, fs::Permissions::from_mode(0o755)).unwrap();
    copy(&source, &destination, &lines("private/whole\n"), &|| false);
    // A folder the worktree already has loses what the repository's denies others.
    fs::create_dir_all(source.join("config")).unwrap();
    fs::write(source.join("config/token"), "t").unwrap();
    fs::set_permissions(source.join("config"), fs::Permissions::from_mode(0o700)).unwrap();
    fs::create_dir_all(destination.join("config")).unwrap();
    fs::set_permissions(destination.join("config"), fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(copy(&source, &destination, &lines("config/token\n"), &|| false).copied, 1);
    assert_eq!(mode("config") & 0o777, 0o700);
    // A read-only folder still gets its files.
    fs::create_dir_all(source.join("frozen")).unwrap();
    fs::write(source.join("frozen/file"), "f").unwrap();
    fs::set_permissions(source.join("frozen"), fs::Permissions::from_mode(0o555)).unwrap();
    assert_eq!(copy(&source, &destination, &lines("frozen/\n"), &|| false).copied, 1);
    fs::set_permissions(source.join("frozen"), fs::Permissions::from_mode(0o755)).unwrap();
    // A worktree that gets copied files is its owner's only.
    assert_eq!(fs::metadata(&destination).unwrap().permissions().mode() & 0o777, 0o700);
    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(destination).unwrap();
}

#[cfg(unix)]
#[test]
fn a_stopped_copy_leaves_nothing_behind() {
    let source = scratch("source");
    let destination = scratch("destination");
    fs::write(source.join("big"), vec![7_u8; 3 << 20]).unwrap();
    let (from, to) = (at::root(&source).unwrap(), at::root(&destination).unwrap());
    // Stopped after the first chunk.
    let checks = std::cell::Cell::new(0);
    let cancelled = || {
        checks.set(checks.get() + 1);
        checks.get() > 1
    };
    let error = to.copy_from(&from, std::ffi::OsStr::new("big"), &cancelled).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::Interrupted);
    assert_eq!(checks.get(), 2);
    assert_eq!(fs::read_dir(&destination).unwrap().count(), 0);
    fs::remove_dir_all(source).unwrap();
    fs::remove_dir_all(destination).unwrap();
}

#[cfg(unix)]
#[test]
fn never_follows_a_link_out_of_the_repository() {
    let outside = scratch("outside");
    fs::write(outside.join("secret"), "s").unwrap();
    let source = scratch("source");
    let destination = scratch("destination");
    std::os::unix::fs::symlink(outside.join("secret"), source.join(".env")).unwrap();
    std::os::unix::fs::symlink(&outside, source.join("shared")).unwrap();
    fs::write(source.join("real"), "r").unwrap();
    std::os::unix::fs::symlink("real", source.join("alias")).unwrap();
    // A tracked link in the worktree must not carry a copy out of it.
    fs::create_dir_all(source.join("out")).unwrap();
    fs::write(source.join("out/file"), "f").unwrap();
    std::os::unix::fs::symlink(&outside, destination.join("out")).unwrap();
    let patterns = lines(".env\nshared/**/secret\nalias\nout/\n");
    let report = copy(&source, &destination, &patterns, &|| false);
    assert!(fs::symlink_metadata(destination.join(".env")).is_err());
    assert_eq!(report.outside, [".env"]);
    assert_eq!(fs::read_link(destination.join("alias")).unwrap(), Path::new("real"));
    assert!(!outside.join("file").exists());
    assert_eq!(report.problems.len(), 1);
    for path in [outside, source, destination] {
        fs::remove_dir_all(path).unwrap();
    }
}
