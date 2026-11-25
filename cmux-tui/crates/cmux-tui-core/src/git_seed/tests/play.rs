//! Playing while the checkout downloads: the sparse patterns that widen a head-first
//! checkout file by file and folder by folder, and the background download of every blob
//! the blobless clone does not have yet.

use super::*;
use run::{Widened, download_missing, fill_after, head_ledger, literal_path, write_fill};

/// A repository with `a/x`, `a/sub/y`, `a/sub/z`, `b/deep/w`, `c/d/e`, `top` committed.
fn repo(home: &Home) -> PathBuf {
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    for path in ["a/x", "a/sub/y", "a/sub/z", "b/deep/w", "c/d/e", "top"] {
        write(&repo.join(path), &format!("{path}\n"));
    }
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "base"]);
    repo
}

fn checked_out(folder: &Path) -> Vec<String> {
    let listing = git(folder, &["ls-files", "-t"]);
    let mut paths: Vec<String> =
        listing.lines().filter_map(|line| line.strip_prefix("H ")).map(str::to_owned).collect();
    paths.sort();
    paths
}

/// A folder's own files exclude its subfolders (`!/a/*/`); a hot file or a whole folder
/// below it, added before or after, still comes in, whatever order the lines arrive in.
#[test]
fn widened_patterns_bring_in_each_line_and_nothing_an_exclusion_takes_out() {
    let home = Home::new("play-patterns");
    let repo = repo(&home);
    git(&repo, &["config", "core.sparseCheckout", "true"]);
    git(&repo, &["config", "core.sparseCheckoutCone", "false"]);
    let head = params::HeadFirst::of(None).unwrap();
    let mut wide = Widened::default();
    for line in ["a/sub/y", "c/d/**", "a/"] {
        wide.lines.insert(line.to_owned());
    }
    let info = repo.join(".git/info");
    std::fs::create_dir_all(&info).unwrap();
    std::fs::write(info.join("sparse-checkout"), wide.patterns(&head)).unwrap();
    git(&repo, &["sparse-checkout", "reapply"]);
    assert_eq!(checked_out(&repo), ["a/sub/y", "a/x", "c/d/e", "top"]);
    assert!(!repo.join("a/sub/z").exists(), "a/'s own files leave its subfolders out");
    assert!(!repo.join("b").exists(), "a folder nobody named waits");
}

#[test]
fn only_a_literal_path_becomes_a_pattern() {
    for path in ["a", "a/b.rs", ".claude/x", "dir with space/f"] {
        assert!(literal_path(path), "{path}");
    }
    for path in
        ["", " a", "a ", "!a", "#a", "a/*", "a?", "a[b]", "a\\b", "a//b", "./a", "a/..", "a\nb"]
    {
        assert!(!literal_path(path), "{path:?}");
    }
}

#[test]
fn a_heads_ledger_holds_the_root_the_subpath_and_harness_folders() {
    let head = params::HeadFirst::of(Some("p/q")).unwrap();
    let ledger = head_ledger(&head).join("\n");
    for (path, is_dir, held) in [
        ("README.md", false, true),
        ("p/f", false, true),
        ("p/q/f", false, true),
        ("p/other/f", false, false),
        (".claude/rules/r.md", false, true),
        ("p/q/.agents/s/SKILL.md", false, true),
        ("src/main.rs", false, false),
    ] {
        assert_eq!(cmux_git::sync_barrier::ledger_holds(&ledger, path, is_dir), held, "{path}");
    }
}

/// A blobless clone gets every blob of the tree in the background,
/// and a second run after the first (a seed started again) fetches nothing more.
#[test]
fn the_download_fetches_every_missing_blob_and_resumes_with_what_is_left() {
    let home = Home::new("play-download");
    let repo = repo(&home);
    let remote = home.join("remote.git");
    git(&home.path, &["clone", "-q", "--bare", repo.to_str().unwrap(), remote.to_str().unwrap()]);
    git(&remote, &["config", "uploadpack.allowFilter", "true"]);
    git(&remote, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    let clone = home.join("clone");
    let url = format!("file://{}", remote.display());
    git(
        &home.path,
        &[
            "-c",
            "protocol.file.allow=always",
            "clone",
            "-q",
            "--filter=blob:none",
            "--no-checkout",
            &url,
            clone.to_str().unwrap(),
        ],
    );
    let missing = |folder: &Path| {
        git(folder, &["rev-list", "--objects", "--missing=print", "HEAD^{tree}"])
            .lines()
            .filter(|line| line.starts_with('?'))
            .count()
    };
    assert_eq!(missing(&clone), 6, "a blobless clone has no blob");
    let tool = Git { extra_config: vec!["protocol.file.allow=always".into()] };
    let head = git(&clone, &["rev-parse", "HEAD"]);
    assert!(download_missing(&tool, &Credential::Anonymous, &clone, &head));
    assert_eq!(missing(&clone), 0);
    assert!(download_missing(&tool, &Credential::Anonymous, &clone, &head), "nothing is left");
}

#[test]
fn fill_runs_ten_to_ninety_nine_and_lives_in_the_marker() {
    assert_eq!(fill_after(0, 4), 10);
    assert_eq!(fill_after(2, 4), 54);
    assert_eq!(fill_after(4, 4), 99);
    assert_eq!(fill_after(9, 4), 99);
    assert_eq!(fill_after(0, 0), 99, "nothing to download: only the final checkout is left");

    let home = Home::new("fill");
    let folder = home.join("w");
    let git_dir = folder.join(".git");
    std::fs::create_dir_all(&git_dir).unwrap();
    write_fill(&folder, 40);
    assert!(!git_dir.join("cmux-seed-filling").exists(), "no marker, no fill: the fill ended");
    std::fs::write(git_dir.join("cmux-seed-filling"), b"").unwrap();
    write_fill(&folder, 40);
    let text = std::fs::read_to_string(git_dir.join("cmux-seed-filling")).unwrap();
    assert_eq!(text.trim(), r#"{"fill":40}"#);
    write_fill(&folder, 250);
    let text = std::fs::read_to_string(git_dir.join("cmux-seed-filling")).unwrap();
    assert_eq!(text.trim(), r#"{"fill":100}"#);
}
