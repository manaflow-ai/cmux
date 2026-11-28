use super::*;

fn git(dir: &Path, args: &[&str]) -> String {
    let out = local(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[test]
fn one_batch_answers_the_base_check() {
    let dir = tempfile::tempdir().unwrap();
    git(dir.path(), &["init", "-q"]);
    std::fs::write(dir.path().join("a"), "a\n").unwrap();
    git(dir.path(), &["add", "a"]);
    git(dir.path(), &["commit", "-qm", "one"]);
    let head = git(dir.path(), &["rev-parse", "HEAD"]);
    let tree = git(dir.path(), &["rev-parse", "HEAD^{tree}"]);
    let gone = "0".repeat(head.len());
    assert!(commits_present(dir.path(), &[&head, &head, &head]).unwrap());
    assert!(!commits_present(dir.path(), &[&head, &gone, &head]).unwrap());
    assert!(!commits_present(dir.path(), &[&head, &tree]).unwrap());
    assert!(!commits_present(dir.path(), &[&"HEAD\nHEAD".to_string()]).unwrap());
}
