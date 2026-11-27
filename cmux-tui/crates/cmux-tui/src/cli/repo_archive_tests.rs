use super::*;

use cmux_projection::repo_archive::{DirStore, Publish};

const URL: &str = "https://github.com/acme/widget.git";

fn words(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A source repo on `main` with a root file and one in a folder.
fn source(root: &Path) -> (PathBuf, String) {
    let repo = root.join("source");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "--quiet", "--initial-branch", "main"]);
    std::fs::write(repo.join("AGENTS.md"), "root").unwrap();
    std::fs::write(repo.join("src/lib.rs"), "lib").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "--quiet", "-m", "one"]);
    let head = git(&repo, &["rev-parse", "HEAD"]);
    (repo, head)
}

fn opts(url: &str, at: &Path) -> Opts {
    Opts { url: url.to_owned(), at: at.to_owned(), ..Opts::default() }
}

#[test]
fn flags_parse_and_a_missing_one_is_named() {
    let parsed =
        parse(&words(&["--url", URL, "--at", "/w/x", "--branch", "lane/a", "--archive-only"]))
            .unwrap();
    assert_eq!(
        parsed,
        Opts {
            url: URL.to_owned(),
            at: PathBuf::from("/w/x"),
            branch: Some("lane/a".to_owned()),
            store: None,
            archive_only: true,
        }
    );
    // An empty --branch (the repo step's empty ref) means the store's default branch.
    assert_eq!(parse(&words(&["--url", URL, "--at", "d", "--branch", ""])).unwrap().branch, None);
    assert_eq!(parse(&words(&["--at", "d"])).unwrap_err(), "--url is required");
    assert_eq!(parse(&words(&["--url", URL])).unwrap_err(), "--at is required");
    assert_eq!(parse(&words(&["--url"])).unwrap_err(), "--url takes a value");
    assert_eq!(parse(&words(&["--bogus", "1"])).unwrap_err(), "unknown flag --bogus");
}

#[test]
fn an_archived_repo_is_checked_out_from_the_store_with_its_increment() {
    let root = tempfile::tempdir().unwrap();
    let (repo, _) = source(root.path());
    let store = DirStore { root: root.path().join("store") };
    let publish = |work: &str| {
        let work = root.path().join(work);
        std::fs::create_dir_all(&work).unwrap();
        cmux_projection::repo_archive::publish(
            &store,
            &Publish {
                source: repo.to_str().unwrap(),
                url: URL,
                branch: "main",
                default: true,
                max_age: std::time::Duration::from_secs(3600),
                max_increment: 1 << 20,
                now: std::time::SystemTime::now(),
                work: &work,
            },
        )
        .unwrap();
    };
    publish("work-1");
    // A commit after the archive: the next run writes only the increment bundle.
    std::fs::write(repo.join("src/lib.rs"), "two").unwrap();
    git(&repo, &["commit", "--quiet", "-am", "two"]);
    let tip = git(&repo, &["rev-parse", "HEAD"]);
    publish("work-2");

    let at = root.path().join("checkout");
    let (code, line) = from_archive(&opts(URL, &at), Some(&store));
    assert_eq!(code, 0, "{line}");
    assert_eq!(line["source"], "archive");
    assert_eq!(line["commit"], tip.as_str());
    assert_eq!(git(&at, &["rev-parse", "HEAD"]), tip);
    assert_eq!(std::fs::read_to_string(at.join("src/lib.rs")).unwrap(), "two");
    assert_eq!(git(&at, &["remote", "get-url", "origin"]), URL);
    assert_eq!(git(&at, &["status", "--porcelain"]), "");
}

#[test]
fn an_unknown_repo_with_archive_only_exits_3_and_leaves_nothing() {
    let root = tempfile::tempdir().unwrap();
    let store = DirStore { root: root.path().join("store") };
    let at = root.path().join("checkout");
    let only = Opts { archive_only: true, ..opts(URL, &at) };
    let (code, line) = from_archive(&only, Some(&store));
    assert_eq!((code, line["source"].as_str()), (NO_ARCHIVE, Some("none")));
    assert!(!at.exists());
    // No store configured (the default) is the same answer: nothing changes without one.
    let (code, line) = from_archive(&only, None);
    assert_eq!(code, NO_ARCHIVE);
    assert_eq!(line["why"], "no repo archive store is configured");
    assert!(!at.exists());
}

#[test]
fn an_unknown_repo_falls_back_to_a_shallow_blobless_sparse_clone() {
    let root = tempfile::tempdir().unwrap();
    let (repo, head) = source(root.path());
    git(&repo, &["config", "uploadpack.allowFilter", "true"]);
    let url = format!("file://{}", repo.display());
    let store = DirStore { root: root.path().join("store") };
    for (name, store) in [("with-store", Some(&store as &dyn Store)), ("no-store", None)] {
        let at = root.path().join(name);
        let (code, line) = from_archive(&opts(&url, &at), store);
        assert_eq!((code, line["source"].as_str()), (0, Some("clone")), "{line}");
        assert_eq!(git(&at, &["rev-parse", "HEAD"]), head);
        assert_eq!(git(&at, &["rev-parse", "--is-shallow-repository"]), "true");
        assert_eq!(git(&at, &["config", "core.sparseCheckout"]), "true");
        assert_eq!(git(&at, &["config", "remote.origin.partialclonefilter"]), "blob:none");
        // Sparse: the root's files are there, a folder's are not until it is added.
        assert!(at.join("AGENTS.md").is_file());
        assert!(!at.join("src/lib.rs").exists());
    }
}

#[test]
fn a_checkout_is_never_written_over() {
    let root = tempfile::tempdir().unwrap();
    let store = DirStore { root: root.path().join("store") };
    let at = root.path().join("checkout");
    std::fs::create_dir_all(&at).unwrap();
    std::fs::write(at.join("mine.txt"), "keep").unwrap();
    let (code, line) = from_archive(&opts(URL, &at), Some(&store));
    assert_eq!((code, line["source"].as_str()), (1, Some("failed")), "{line}");
    assert_eq!(std::fs::read_to_string(at.join("mine.txt")).unwrap(), "keep");
}
