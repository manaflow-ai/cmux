use super::*;

#[test]
fn a_move_folder_is_checked_before_anything_is_made() {
    let folder = |v: Value| named_folder(v.as_object().unwrap());
    assert!(folder(json!({"home": "Projects/x"})).is_ok());
    for home in ["", "/abs", "../up", "a/../b", "a b", "x\ny"] {
        assert!(folder(json!({"home": home})).is_err(), "{home:?}");
    }
    let ok = json!({"repo": "o/n", "url": "https://github.com/o/n.git", "branch": "lane/x", "subdir": ""});
    assert!(folder(ok.clone()).is_ok());
    for (key, bad) in [
        ("repo", "o/n/x"),
        ("repo", "../n"),
        ("url", "file:///etc"),
        ("url", "https://x y"),
        ("branch", "-x"),
        ("branch", "a b"),
        ("subdir", "../x"),
    ] {
        let mut v = ok.clone();
        v[key] = json!(bad);
        assert!(folder(v).is_err(), "{key} {bad:?}");
    }
}

#[test]
fn only_a_plain_daemon_id_is_dialed() {
    assert!(plain_daemon("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    assert!(plain_daemon("inst_0123abcd"));
    for bad in ["", "short", "a b c d e f", "x\ny0000000", &"a".repeat(129)] {
        assert!(!plain_daemon(bad), "{bad:?}");
    }
}
