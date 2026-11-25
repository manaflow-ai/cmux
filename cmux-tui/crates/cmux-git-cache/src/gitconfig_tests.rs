use super::*;

#[test]
fn text_rewrites_fetch_not_push() {
    let t = include_text(1234, "!/opt/cmux/current/bin/cmux host git-cache credential");
    assert!(t.starts_with(HEADER));
    assert!(t.contains(
        "[url \"http://127.0.0.1:1234/github.com/\"]\n\tinsteadOf = https://github.com/\n"
    ));
    assert!(t.contains("\tinsteadOf = git@github.com:\n"));
    assert!(t.contains("[url \"git@github.com:\"]\n\tpushInsteadOf = git@github.com:\n"));
    assert!(t.contains("[credential \"http://127.0.0.1:1234\"]\n\thelper = !/opt/cmux"));
}

#[test]
fn remove_only_ours() {
    let dir = tempfile::tempdir().unwrap();
    let ours = dir.path().join("a");
    write_include(&ours, &include_text(1, "x")).unwrap();
    remove_include(&ours);
    assert!(!ours.exists());
    let theirs = dir.path().join("b");
    std::fs::write(&theirs, "[user]\n").unwrap();
    remove_include(&theirs);
    assert!(theirs.exists());
}
