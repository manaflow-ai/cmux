use super::*;

#[test]
fn parses_only_pull_request_links() {
    let parsed =
        PullRef::parse("https://github.com/manaflow-ai/cmux/pull/38100/files?w=1#x").unwrap();
    assert_eq!(parsed, PullRef { owner: "manaflow-ai".into(), repo: "cmux".into(), number: 38100 });
    assert_eq!(parsed.url(), "https://github.com/manaflow-ai/cmux/pull/38100");
    for refused in [
        "https://github.com/manaflow-ai/cmux/issues/1",
        "https://github.com/manaflow-ai/cmux/pull/0",
        "https://github.com/manaflow-ai/cmux/pull/x",
        "http://github.com/manaflow-ai/cmux/pull/1",
        "https://gitlab.com/a/b/pull/1",
        "https://github.com/../cmux/pull/1",
        "https://github.com/a b/cmux/pull/1",
    ] {
        assert_eq!(PullRef::parse(refused), None, "{refused}");
    }
}

#[test]
fn matches_remotes_of_its_repository() {
    let pull = PullRef::parse("https://github.com/Manaflow-AI/cmux/pull/1").unwrap();
    for remote in [
        "git@github.com:manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux",
        "https://github.com/manaflow-ai/cmux.git/",
        "ssh://git@github.com/manaflow-ai/cmux.git",
    ] {
        assert!(pull.is_remote(remote), "{remote}");
    }
    for remote in
        ["git@github.com:manaflow-ai/cmux-platform.git", "https://example.com/manaflow-ai/cmux"]
    {
        assert!(!pull.is_remote(remote), "{remote}");
    }
}

#[test]
fn hunks_cover_their_lines_on_each_side() {
    let hunks = Hunks::parse("diff --git a/f b/f\n@@ -10,7 +10,9 @@ fn\n x\n@@ -40 +42,0 @@\n-y\n");
    assert!(hunks.covers(Side::Additions, 10, 18));
    assert!(!hunks.covers(Side::Additions, 18, 19), "a range across a hunk's end");
    assert!(hunks.covers(Side::Deletions, 40, 40));
    assert!(!hunks.covers(Side::Additions, 42, 42), "a hunk with no new lines");
    assert_eq!(hunks.describe(Side::Additions), "10-18");
    assert_eq!(hunks.describe(Side::Deletions), "10-16, 40");
}

#[test]
fn splits_a_whole_diff_by_file() {
    let diff = "diff --git a/a.rs b/a.rs\nindex 1..2 100644\n--- a/a.rs\n+++ b/a.rs\n@@ -1,2 +1,3 @@\n x\n+y\n\
                    diff --git a/old.rs b/new.rs\nsimilarity index 90%\n--- a/old.rs\n+++ b/new.rs\n@@ -5 +5 @@\n-a\n+b\n\
                    diff --git a/gone.rs b/gone.rs\ndeleted file mode 100644\n--- a/gone.rs\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n";
    let files = file_hunks(diff);
    assert_eq!(files.keys().collect::<Vec<_>>(), ["a.rs", "gone.rs", "new.rs"]);
    assert!(files["a.rs"].covers(Side::Additions, 1, 3));
    assert!(files["new.rs"].covers(Side::Deletions, 5, 5));
    assert!(files["gone.rs"].covers(Side::Deletions, 1, 2));
    assert_eq!(files["new.rs"].old_path.as_deref(), Some("old.rs"));
    assert_eq!(files["a.rs"].old_path.as_deref(), Some("a.rs"));
}

#[test]
fn reads_names_with_spaces_and_quoted_names() {
    let diff = "diff --git a/has space.txt b/has space.txt\n--- a/has space.txt\t\n+++ b/has space.txt\t\n@@ -1 +1 @@\n-a\n+b\n\
                    diff --git \"a/q\\\"uote.txt\" \"b/q\\\"uote.txt\"\n--- \"a/q\\\"uote.txt\"\n+++ \"b/q\\\"uote.txt\"\n@@ -1 +1 @@\n-a\n+b\n\
                    diff --git a/caf\\303\\251 b/caf\\303\\251\n--- \"a/caf\\303\\251\"\n+++ \"b/caf\\303\\251\"\n@@ -1 +1 @@\n-a\n+b\n";
    let files = file_hunks(diff);
    assert_eq!(files.keys().collect::<Vec<_>>(), ["caf\u{e9}", "has space.txt", "q\"uote.txt"]);
}

#[test]
fn review_puts_lines_outside_the_diff_in_its_body() {
    let comment = |id: &str, path: &str, side: &str, start: u32, end: u32| {
        json!({"id": id, "filePath": path, "side": side, "startLine": start, "endLine": end, "message": format!("m {id}")})
            .as_object()
            .unwrap()
            .clone()
    };
    let (a, b, c) = (
        comment("a", "src/x.rs", "additions", 11, 12),
        comment("b", "src/x.rs", "deletions", 40, 40),
        comment("c", "src/y.rs", "additions", 5, 5),
    );
    let hunks = BTreeMap::from([(
        "src/x.rs".to_string(),
        Hunks::parse("@@ -10,7 +10,9 @@\n@@ -40 +42,0 @@\n"),
    )]);
    let review = review("abc", &[&a, &b, &c], &hunks, "<!-- m -->");
    assert_eq!((review.inline, review.in_body), (2, 1));
    assert_eq!(review.ids, ["a", "b", "c"]);
    assert_eq!(review.payload["commit_id"], "abc");
    assert_eq!(review.payload["event"], "COMMENT");
    assert_eq!(
        review.payload["comments"][0],
        json!({"path": "src/x.rs", "body": "m a", "line": 12, "side": "RIGHT", "start_line": 11, "start_side": "RIGHT"})
    );
    assert_eq!(
        review.payload["comments"][1],
        json!({"path": "src/x.rs", "body": "m b", "line": 40, "side": "LEFT"})
    );
    assert_eq!(
        review.payload["body"],
        "On lines outside this pull request's diff:\n\n- `src/y.rs:5`: m c\n\n<!-- m -->"
    );
}
