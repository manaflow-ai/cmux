use super::*;

fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "cmux-setup-approvals-{name}-{}-{}",
        std::process::id(),
        now_ms()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn an_answer_is_kept_by_its_fingerprint_alone() {
    let path = scratch("kept");
    let folder = OwnFolder::open(&path);
    assert!(!approved(&folder, "aa"));
    approve(&folder, "aa").unwrap();
    assert!(approved(&folder, "aa"));
    assert!(!approved(&folder, "bb"), "another recipe needs its own answer");
    let _ = fs::remove_dir_all(path);
}

#[test]
fn only_the_newest_answers_are_kept() {
    let path = scratch("newest");
    let folder = OwnFolder::open(&path);
    for index in 0..(KEPT + 3) {
        approve(&folder, &format!("f{index}")).unwrap();
    }
    assert!(!approved(&folder, "f0"));
    assert!(approved(&folder, &format!("f{}", KEPT + 2)));
    assert_eq!(list(&folder).len(), KEPT);
    let _ = fs::remove_dir_all(path);
}

#[test]
fn an_unreadable_list_approves_nothing() {
    let path = scratch("unreadable");
    fs::write(path.join(FILE), b"not json").unwrap();
    let folder = OwnFolder::open(&path);
    assert!(!approved(&folder, "aa"));
    approve(&folder, "aa").unwrap();
    assert!(approved(&folder, "aa"));
    let _ = fs::remove_dir_all(path);
}
