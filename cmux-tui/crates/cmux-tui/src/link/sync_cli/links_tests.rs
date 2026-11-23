use super::*;

#[test]
fn a_text_is_inside_only_by_its_own_words() {
    assert_eq!(resolve("", "src").as_deref(), Some("src"));
    assert_eq!(resolve("a/b", "../c/./d").as_deref(), Some("a/c/d"));
    assert_eq!(resolve("a", "..").as_deref(), Some(""));
    assert_eq!(resolve("a", "../.."), None);
    assert_eq!(resolve("", "/etc/passwd"), None);
    assert_eq!(resolve("", ""), None);
    assert_eq!(resolve("", ".git/hooks"), None);
    assert_eq!(resolve("", "x/.GIT"), None);
    assert_eq!(resolve("", "a\nb"), None);
}

/// Chained links are followed: `src/up -> ..` makes
/// `src/up/../../x` climb out, though its words alone stay inside.
#[test]
fn a_text_through_other_links_is_followed() {
    let links = |path: &str| -> Vec<String> {
        match path {
            "src/up" => vec!["..".into()],
            "lib" => vec!["src".into()],
            "two" => vec!["src".into(), "/etc".into()],
            "loop" => vec!["loop".into()],
            _ => Vec::new(),
        }
    };
    assert_eq!(resolve("", "src/up/../../x").as_deref(), Some("x"));
    assert!(!reaches_inside("", "src/up/../../x", &links));
    assert!(reaches_inside("", "src/up/x", &links));
    assert!(reaches_inside("a", "../lib/a.txt", &links));
    assert!(!reaches_inside("", "two/a", &links));
    assert!(!reaches_inside("", "loop", &links));
    assert!(!reaches_inside("", "/etc", &links));
    assert!(!reaches_inside("", "lib/../.git", &links));
}

#[test]
fn a_target_is_named_relative_from_the_links_folder() {
    assert_eq!(relative_from("", "src/a"), "src/a");
    assert_eq!(relative_from("a/b", "a/c"), "../c");
    assert_eq!(relative_from("a/b", ""), "../..");
    assert_eq!(relative_from("", ""), ".");
}

#[test]
fn a_push_keeps_inside_links_and_names_the_rest() {
    let top = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(top.path()).unwrap();
    std::fs::create_dir_all(top.join("src/deep")).unwrap();
    std::fs::create_dir_all(top.join(".git")).unwrap();
    std::fs::write(top.join("src/a.txt"), "a").unwrap();
    let link = |name: &str, target: &Path| {
        std::os::unix::fs::symlink(target, top.join(name)).unwrap();
        local(&top, name, &top.join(name)).unwrap()
    };
    let kept = |target: &str, here: Option<&str>| {
        Local::Keep(Linked { target: target.into(), here: here.map(str::to_string) })
    };
    assert_eq!(link("rel", Path::new("src/a.txt")), kept("src/a.txt", None));
    let abs = top.join("src/deep");
    assert_eq!(link("abs", &abs), kept("src/deep", abs.to_str()));
    assert_eq!(link("src/up", Path::new("../src/a.txt")), kept("../src/a.txt", None));
    assert_eq!(link("out", Path::new("/etc")), Local::Skip(Why::SymlinkOutside));
    assert_eq!(link("climb", Path::new("../..")), Local::Skip(Why::SymlinkOutside));
    assert_eq!(link("gone", Path::new("nothing")), Local::Skip(Why::SymlinkBroken));
    assert_eq!(link("hooks", Path::new(".git")), Local::Skip(Why::SymlinkIntoRepository));
}
