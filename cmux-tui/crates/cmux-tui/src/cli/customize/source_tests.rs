use super::*;

#[test]
fn every_source_form() {
    assert_eq!(parse("pr:43496"), Some(Source::Pr(43496)));
    assert_eq!(parse("#7"), Some(Source::Pr(7)));
    assert_eq!(parse("branch:lane/cat-icon"), Some(Source::Branch("lane/cat-icon".into())));
    assert_eq!(parse("sha:DBB1E3E"), Some(Source::Sha("dbb1e3e".into())));
    assert_eq!(parse("dir:/src/cmux"), Some(Source::Dir(PathBuf::from("/src/cmux"))));
    assert_eq!(
        parse("someone/cmux@feat/x"),
        Some(Source::Fork { repo: "someone/cmux".into(), reference: "feat/x".into() })
    );
    // Our own repository written as a fork is a branch (or a commit) of ours.
    assert_eq!(parse("manaflow-ai/cmux@main"), Some(Source::Branch("main".into())));
    assert_eq!(
        parse(&format!("manaflow-ai/cmux@{}", "a".repeat(40))),
        Some(Source::Sha("a".repeat(40)))
    );
}

#[test]
fn profiles_and_bad_names_are_not_code() {
    for text in [
        "night",
        "night.json",
        "pr-43496",
        "branch:",
        "branch:-x",
        "branch:a..b",
        "branch:a b",
        "sha:xyz",
        "sha:abc",
        "dir:",
        "someone@main",
        "some one/cmux@main",
        "someone/cmux@",
        "someone/cmux@--upload-pack=x",
    ] {
        assert_eq!(parse(text), None, "{text}");
    }
}

#[test]
fn a_branch_slug_has_no_slash() {
    assert_eq!(ref_slug("lane/cat-icon"), "lane--cat-icon");
}
