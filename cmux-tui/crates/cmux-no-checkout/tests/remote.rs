#![cfg(unix)]
//! A chat on a GitHub branch with nothing cloned, against the loopback stand-in: reads on first
//! use, only the run's paths on disk (gone after), a patch applied to the touched files alone,
//! and the edits committed as a branch through the git data API, then a pull request.

use cmux_no_checkout::github::{Pull, TreeChange};
use cmux_no_checkout::mock::Mock;
use cmux_no_checkout::{GitHub, GitWriter, Remote, patch};

const CORE: &[u8] = b"def add(a, b):\n    return a + b\n";
const TEST: &[u8] = b"from pkg.core import add\n\ndef test_add():\n    assert add(1, 2) == 3\n";

async fn repo() -> Mock {
    Mock::start(
        "o/r",
        &[
            ("README.md", b"# r\n", "100644"),
            ("bin/run.sh", b"#!/bin/sh\necho hi\n", "100755"),
            ("docs/big.txt", &[b'x'; 100_000], "100644"),
            ("src/pkg/__init__.py", b"", "100644"),
            ("src/pkg/core.py", CORE, "100644"),
            ("tests/test_core.py", TEST, "100644"),
        ],
    )
    .await
    .unwrap()
}

async fn open(mock: &Mock) -> Remote {
    let gh = GitHub::new(&mock.url, &mock.repo, None, None).unwrap();
    Remote::open(gh, None).await.unwrap()
}

fn patterns(p: &[&str]) -> Vec<String> {
    p.iter().map(|s| (*s).to_owned()).collect()
}

#[tokio::test]
async fn only_the_paths_a_run_names_reach_the_disk_and_the_folder_is_gone_after() {
    let mock = repo().await;
    let mut remote = open(&mock).await;
    assert_eq!(&**remote.read("src/pkg/core.py").await.unwrap(), CORE);
    remote.write("src/pkg/core.py", b"def add(a, b):\n    return b + a\n".to_vec()).await.unwrap();

    let projected =
        remote.project(&patterns(&["src/pkg", "tests/test_core.py", "bin/**"])).await.unwrap();
    let root = projected.path().to_owned();
    assert_eq!(projected.files, 4);
    // The edit, not the base.
    assert_eq!(
        std::fs::read(root.join("src/pkg/core.py")).unwrap(),
        b"def add(a, b):\n    return b + a\n"
    );
    assert_eq!(std::fs::read(root.join("tests/test_core.py")).unwrap(), TEST);
    use std::os::unix::fs::PermissionsExt as _;
    let mode = std::fs::metadata(root.join("bin/run.sh")).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0o111, "the executable bit comes with it");
    // Nothing else: the 100 kB file the run does not name never crossed the network.
    assert!(!root.join("docs").exists() && !root.join("README.md").exists());
    let down = remote.github().meter().bytes_down();
    assert!(down < 50_000, "{down} bytes read");
    projected.close().unwrap();
    assert!(!root.exists(), "the projected folder is deleted when the run ends");
    mock.close().await;
}

#[tokio::test]
async fn a_patch_becomes_a_commit_on_a_new_branch_and_a_pull_request() {
    let mock = repo().await;
    let mut remote = open(&mock).await;
    let diff = "diff --git a/src/pkg/core.py b/src/pkg/core.py\n--- a/src/pkg/core.py\n+++ b/src/pkg/core.py\n@@ -1,2 +1,2 @@\n def add(a, b):\n-    return a + b\n+    return int(a) + int(b)\n\
diff --git a/NEW.md b/NEW.md\nnew file mode 100644\n--- /dev/null\n+++ b/NEW.md\n@@ -0,0 +1 @@\n+new\n\
diff --git a/docs/big.txt b/docs/big.txt\ndeleted file mode 100644\n--- a/docs/big.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n";
    // `big.txt`'s deletion hunk does not match its bytes, so git apply refuses the whole patch,
    // and nothing changes.
    assert!(patch::apply(&mut remote, diff).await.is_err());
    assert!(remote.edits().is_empty());
    let diff = diff.split("diff --git a/docs").next().unwrap();
    let mut changed = patch::apply(&mut remote, diff).await.unwrap();
    changed.sort();
    assert_eq!(changed, ["NEW.md", "src/pkg/core.py"]);
    remote.delete("docs/big.txt").await.unwrap();

    let commit = remote.commit("lane/fix", "core: add numbers").await.unwrap();
    assert!(!commit.is_empty());
    let branch = mock.branch("lane/fix").unwrap();
    assert_eq!(branch["src/pkg/core.py"].0, b"def add(a, b):\n    return int(a) + int(b)\n");
    assert_eq!(branch["NEW.md"].0, b"new\n");
    assert!(!branch.contains_key("docs/big.txt"));
    assert_eq!(branch["bin/run.sh"].1, "100755", "untouched files keep their mode");
    // The base is untouched.
    assert_eq!(mock.branch("main").unwrap()["src/pkg/core.py"].0, CORE);

    // A second edit commits on top, to the same branch (a fast-forward).
    remote.write("README.md", b"# r, edited\n".to_vec()).await.unwrap();
    remote.commit("lane/fix", "readme").await.unwrap();
    let branch = mock.branch("lane/fix").unwrap();
    assert_eq!(branch["README.md"].0, b"# r, edited\n");
    assert_eq!(branch["NEW.md"].0, b"new\n");

    let gh = remote.github();
    let pull = gh.open_pull("Add numbers", "body", "lane/fix", "main", true).await.unwrap();
    assert_eq!(pull.number, 1);
    assert_eq!(mock.pulls()[0]["head"], "lane/fix");
    gh.close_pull(pull.number).await.unwrap();
    gh.delete_branch("lane/fix").await.unwrap();
    assert!(mock.branch("lane/fix").is_none());
    assert_eq!(mock.pulls()[0]["state"], "closed");
    mock.close().await;
}

#[tokio::test]
async fn nothing_to_commit_and_paths_outside_the_repository_are_refused() {
    let mock = repo().await;
    let mut remote = open(&mock).await;
    assert!(remote.commit("lane/x", "m").await.is_err());
    assert!(remote.write("../escape", b"x".to_vec()).await.is_err());
    assert!(remote.write(".git/config", b"x".to_vec()).await.is_err());
    assert!(remote.read("missing.txt").await.is_err());
    assert!(remote.delete("missing.txt").await.is_err());
    assert!(mock.branch("lane/x").is_none());
    mock.close().await;
}

#[tokio::test]
async fn chained_links_never_expose_a_sibling_in_either_blob_order_or_a_later_projection() {
    let sentinel = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(sentinel.path(), b"outside sentinel").unwrap();
    let name = sentinel.path().file_name().unwrap().to_str().unwrap();
    for (pivot, leak) in [("a-pivot", "z-leak"), ("z-pivot", "a-leak")] {
        let target = format!("{pivot}/../{name}");
        let mock =
            Mock::start("o/r", &[(pivot, b".", "120000"), (leak, target.as_bytes(), "120000")])
                .await
                .unwrap();
        let mut remote = open(&mock).await;
        // Cached blobs make the projection order deterministic, in path order.
        remote.read(pivot).await.unwrap();
        remote.read(leak).await.unwrap();
        let projected = remote.project(&patterns(&["**"])).await.unwrap();
        assert!(std::fs::read(projected.path().join(leak)).is_err());
        projected.close().unwrap();

        let mut projected = remote.project(&patterns(&[leak])).await.unwrap();
        let extended = remote.project_into(&patterns(&[pivot]), &mut projected).await;
        assert!(extended.is_err(), "a later batch must not redirect an existing link");
        assert!(std::fs::read(projected.path().join(leak)).is_err());
        projected.close().unwrap();
        mock.close().await;
    }
    assert_eq!(std::fs::read(sentinel.path()).unwrap(), b"outside sentinel");
}

#[tokio::test]
async fn safe_link_chains_and_dangling_links_remain_but_writes_never_follow_them() {
    let mock = Mock::start(
        "o/r",
        &[
            ("dir/file", b"inside", "100644"),
            ("alias", b"dir", "120000"),
            ("chain", b"alias/file", "120000"),
            ("dangling", b"future/file", "120000"),
            ("cycle-a", b"cycle-b", "120000"),
            ("cycle-b", b"cycle-a", "120000"),
        ],
    )
    .await
    .unwrap();
    let mut remote = open(&mock).await;
    let mut projected = remote.project(&patterns(&["**"])).await.unwrap();
    assert_eq!(std::fs::read(projected.path().join("chain")).unwrap(), b"inside");
    assert_eq!(
        std::fs::read_link(projected.path().join("dangling")).unwrap(),
        std::path::Path::new("future/file")
    );
    assert!(std::fs::symlink_metadata(projected.path().join("cycle-a")).is_err());
    remote.write_mode("alias/new", b"redirected".to_vec(), "100644").unwrap();
    assert!(remote.project_into(&patterns(&["alias/new"]), &mut projected).await.is_err());
    assert!(!projected.path().join("dir/new").exists());
    remote.write_mode("chain", b"overwritten".to_vec(), "100644").unwrap();
    assert!(remote.project_into(&patterns(&["chain"]), &mut projected).await.is_err());
    assert_eq!(std::fs::read(projected.path().join("dir/file")).unwrap(), b"inside");
    projected.close().unwrap();
    mock.close().await;
}

/// A writer that is not the REST client (a broker, on a lane VM) makes every write of a commit.
struct Recording {
    inner: GitHub,
    calls: std::sync::Mutex<Vec<&'static str>>,
}

#[async_trait::async_trait]
impl GitWriter for Recording {
    async fn create_blob(&self, bytes: &[u8]) -> anyhow::Result<String> {
        self.calls.lock().unwrap().push("blob");
        self.inner.create_blob(bytes).await
    }
    async fn create_tree(&self, base: &str, changes: &[TreeChange]) -> anyhow::Result<String> {
        self.calls.lock().unwrap().push("tree");
        self.inner.create_tree(base, changes).await
    }
    async fn create_commit(
        &self,
        message: &str,
        tree: &str,
        parent: &str,
    ) -> anyhow::Result<String> {
        self.calls.lock().unwrap().push("commit");
        self.inner.create_commit(message, tree, parent).await
    }
    async fn set_branch(&self, branch: &str, commit: &str) -> anyhow::Result<()> {
        self.calls.lock().unwrap().push("ref");
        self.inner.set_branch(branch, commit).await
    }
    async fn open_pull(
        &self,
        title: &str,
        body: &str,
        head: &str,
        base: &str,
        draft: bool,
    ) -> anyhow::Result<Pull> {
        self.calls.lock().unwrap().push("pull");
        self.inner.open_pull(title, body, head, base, draft).await
    }
}

#[tokio::test]
async fn another_writer_makes_the_commit_through_the_one_seam() {
    let mock = repo().await;
    let mut remote = open(&mock).await;
    remote.write("README.md", b"# via the seam\n".to_vec()).await.unwrap();
    let writer = Recording { inner: remote.github().clone(), calls: Default::default() };
    remote.commit_with(&writer, "lane/seam", "via the seam").await.unwrap();
    writer.open_pull("t", "", "lane/seam", "main", true).await.unwrap();
    assert_eq!(*writer.calls.lock().unwrap(), ["blob", "tree", "commit", "ref", "pull"]);
    assert_eq!(mock.branch("lane/seam").unwrap()["README.md"].0, b"# via the seam\n");
    mock.close().await;
}
