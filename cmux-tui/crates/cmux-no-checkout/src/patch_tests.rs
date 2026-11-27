use super::*;

#[test]
fn a_git_diff_names_what_it_reads_and_writes() {
    let patch = "diff --git a/src/a.py b/src/a.py\nindex 1..2 100644\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n\
diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+n\n\
diff --git a/old.txt b/old.txt\ndeleted file mode 100644\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-o\n\
diff --git a/r1 b/r2\nsimilarity index 100%\nrename from r1\nrename to r2\n";
    let t = touched(patch).unwrap();
    let set = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<BTreeSet<_>>();
    assert_eq!(t.before, set(&["old.txt", "r1", "src/a.py"]));
    assert_eq!(t.after, set(&["new.txt", "r2", "src/a.py"]));
}

#[test]
fn a_patch_that_leaves_the_repository_or_is_binary_or_empty_is_refused() {
    assert!(touched("--- a/../x\n+++ b/../x\n").is_err());
    assert!(touched("--- a/.git/config\n+++ b/.git/config\n").is_err());
    assert!(touched("--- \"a/q\\tx\"\n").is_err());
    assert!(touched("GIT binary patch\nliteral 3\n").is_err());
    assert!(touched("hello\n").is_err());
    // A plain diff's names with times.
    let t = touched("--- a/x.c\t2026-11-17 10:00\n+++ b/x.c\t2026-11-17 10:01\n").unwrap();
    assert!(t.after.contains("x.c"));
}
