use super::*;

#[test]
fn parses_and_refuses_traversal() {
    let r = parse("/github.com/Manaflow-AI/cmux.git/info/refs").unwrap();
    assert_eq!(r.action, Action::InfoRefs);
    assert_eq!(r.key(), "manaflow-ai/cmux");
    assert_eq!(
        r.url("https://github.com/", "/info/refs"),
        "https://github.com/Manaflow-AI/cmux.git/info/refs"
    );
    assert_eq!(parse("/github.com/a/b/git-upload-pack").unwrap().action, Action::UploadPack);
    for bad in [
        "/github.com/../b/info/refs",
        "/github.com/a/..git/info/refs",
        "/github.com/a/b/c/info/refs",
        "/gitlab.com/a/b/info/refs",
        "/github.com/a%2f/b/info/refs",
        "/github.com/a/b/objects/info/packs",
    ] {
        assert!(parse(bad).is_none(), "{bad}");
    }
}
