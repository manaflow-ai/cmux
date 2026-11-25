//! The Files tree, the file search, `git.status` and `git.branches` answer from
//! the daemon's tagged cache of a repository's reads (`read_cache`):
//!
//! - a refresh of the Files page lists the top folder and each expanded one,
//!   and all of them share one `git ls-files` of the repository;
//! - a listing the index moved under answers at once from the cache and is
//!   read again behind the answer (stale-while-revalidate), never waiting for
//!   the slow read; a new name in the folder asked about is read at once;
//! - `git.status` and `git.branches` run no git while the refs, HEAD and the
//!   config are as they were, and a moved ref is read at once.
//!
//! Each read is counted, and made slow, through `read_probe`.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_git::Repository;
use serde_json::{Map, Value, json};

use super::read_probe::{self, Read};
use super::{branches_reply, files, list, status_reply};

/// A temp folder this test made; removed on drop.
struct Temp(PathBuf);

impl Temp {
    fn new(tag: &str) -> Self {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-read-cache-{tag}-{hex}"));
        std::fs::create_dir_all(&path).unwrap();
        Self(std::fs::canonicalize(path).unwrap())
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn git(repo: &Path, arguments: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {arguments:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write(repo: &Path, path: &str) {
    let path = repo.join(path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, "x\n").unwrap();
}

/// A committed repository with `folders` folders of three files each.
fn repository(temp: &Temp, folders: usize) -> PathBuf {
    let repo = temp.0.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet", "--initial-branch=main"]);
    write(&repo, "README.md");
    for folder in 0..folders {
        for file in 0..3 {
            write(&repo, &format!("d{folder:02}/f{file}.txt"));
        }
    }
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "--quiet", "-m", "first"]);
    // The listing compares a folder's change time with the time it was read
    // at: let the setup's changes be older than any read.
    std::thread::sleep(Duration::from_millis(60));
    repo
}

/// One `git.files.list` the way the daemon answers it: open, then list.
fn list_folder(repo: &Path, folder: &str) -> Value {
    let directory = if folder.is_empty() { repo.to_path_buf() } else { repo.join(folder) };
    let repository = Repository::open(&directory).unwrap();
    list::list(&repository, &directory, &Map::new()).unwrap()
}

fn names(reply: &Value) -> Vec<String> {
    reply["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["name"].as_str().unwrap().to_owned())
        .collect()
}

fn search(repo: &Path, query: &str) -> Vec<String> {
    let repository = Repository::open(repo).unwrap();
    let mut fields = Map::new();
    fields.insert("query".into(), json!(query));
    let reply = files::search(&repository, repo, &fields).unwrap();
    reply["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|result| result["path"].as_str().unwrap().to_owned())
        .collect()
}

/// Waits until `read` of `at` ran `count` times (a read behind an answer).
fn wait_for_reads(read: Read, at: &Path, count: usize) {
    let start = Instant::now();
    while read_probe::count(read, at) < count {
        assert!(start.elapsed() < Duration::from_secs(20), "{read:?} of {at:?} never ran again");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The Files page's refresh: the top folder and every expanded one. Before
/// the cache each folder ran its own `git ls-files` (21 for 20 expanded
/// folders); now the first one reads the repository and the rest share it.
#[test]
fn a_refresh_of_twenty_expanded_folders_runs_one_listing() {
    let temp = Temp::new("refresh");
    let repo = repository(&temp, 20);
    let start = Instant::now();
    let top = list_folder(&repo, "");
    assert_eq!(names(&top).len(), 21, "{top}");
    for folder in 0..20 {
        let reply = list_folder(&repo, &format!("d{folder:02}"));
        assert_eq!(names(&reply), ["f0.txt", "f1.txt", "f2.txt"], "{reply}");
    }
    let cold = start.elapsed();
    let reads = read_probe::count(Read::Listing, &repo);
    let start = Instant::now();
    for folder in std::iter::once(String::new()).chain((0..20).map(|f| format!("d{f:02}"))) {
        list_folder(&repo, &folder);
    }
    let warm = start.elapsed();
    let warm_reads = read_probe::count(Read::Listing, &repo) - reads;
    println!(
        "READ-CACHE-BENCH {}",
        json!({"op": "files_refresh_21_folders", "ls_files_cold": reads, "ls_files_warm": warm_reads,
               "cold_ms": cold.as_secs_f64() * 1000.0, "warm_ms": warm.as_secs_f64() * 1000.0})
    );
    assert_eq!(reads, 1, "one ls-files for the whole refresh");
    assert_eq!(warm_reads, 0, "a second refresh of an unchanged repository runs none");
}

/// The index moved (a `git add` in a folder the page does not show): the
/// listing answers at once from the cache, though the read takes 800 ms, and
/// the read runs behind the answer; the next search sees the added file
/// without another read.
#[test]
fn a_listing_the_index_moved_under_answers_without_waiting_for_the_read() {
    let temp = Temp::new("stale");
    let repo = repository(&temp, 3);
    list_folder(&repo, "");
    assert_eq!(read_probe::count(Read::Listing, &repo), 1);
    write(&repo, "d01/added.txt");
    git(&repo, &["add", "d01/added.txt"]);
    read_probe::slow(Read::Listing, &repo, Duration::from_millis(800));
    let start = Instant::now();
    let top = list_folder(&repo, "");
    let waited = start.elapsed();
    println!(
        "READ-CACHE-BENCH {}",
        json!({"op": "files_list_after_index_change", "read_ms": 800,
               "answer_ms": waited.as_secs_f64() * 1000.0})
    );
    assert_eq!(names(&top).len(), 4, "{top}");
    assert!(waited < Duration::from_millis(400), "the listing waited {waited:?} for the read");
    wait_for_reads(Read::Listing, &repo, 2);
    // The read behind the answer is in the cache once it is counted and written.
    let start = Instant::now();
    loop {
        let found = search(&repo, "added");
        if found == ["d01/added.txt"] {
            break;
        }
        assert!(start.elapsed() < Duration::from_secs(20), "{found:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(read_probe::count(Read::Listing, &repo), 2);
}

/// Asks that come while the read behind a moved index runs do not mark that
/// read stale before it lands: the Files page's refresh lists several folders
/// at once, and each of them used to invalidate the index again, so the read
/// behind landed stale and the next ask ran a third read.
#[test]
fn asks_during_the_read_behind_do_not_spend_it() {
    let temp = Temp::new("asks-during");
    let repo = repository(&temp, 3);
    list_folder(&repo, "");
    write(&repo, "d01/added.txt");
    git(&repo, &["add", "d01/added.txt"]);
    read_probe::slow(Read::Listing, &repo, Duration::from_millis(800));
    list_folder(&repo, "");
    wait_for_reads(Read::Listing, &repo, 2);
    // The read behind sleeps 800 ms: these all come while it runs.
    for folder in ["d00", "d02", "d00"] {
        list_folder(&repo, folder);
    }
    let start = Instant::now();
    while search(&repo, "added") != ["d01/added.txt"] {
        assert!(start.elapsed() < Duration::from_secs(20), "the read behind never landed");
        std::thread::sleep(Duration::from_millis(20));
    }
    list_folder(&repo, "d00");
    assert_eq!(read_probe::count(Read::Listing, &repo), 2, "the read behind landed stale");
}

/// A new untracked file in the folder the page lists shows on its next
/// listing: the folder changed after the cached listing was read, so the
/// listing is read again before the answer, never served without it.
#[test]
fn a_new_file_in_the_listed_folder_shows_on_the_next_listing() {
    let temp = Temp::new("new-file");
    let repo = repository(&temp, 2);
    assert!(!names(&list_folder(&repo, "d00")).contains(&"new.txt".to_owned()));
    write(&repo, "d00/new.txt");
    assert!(names(&list_folder(&repo, "d00")).contains(&"new.txt".to_owned()));
    write(&repo, "top.txt");
    assert!(names(&list_folder(&repo, "")).contains(&"top.txt".to_owned()));
}

/// `git.status` runs its reads once while HEAD, the refs and the config stay;
/// a commit moves the branch, and the next status has the new head at once.
#[test]
fn status_reads_the_refs_once_until_a_ref_moves() {
    let temp = Temp::new("status");
    let repo = repository(&temp, 1);
    let first = status_reply(&repo, false).unwrap();
    let again = status_reply(&repo, false).unwrap();
    assert_eq!(first, again);
    assert_eq!(read_probe::count(Read::Status, &repo), 1, "the second status ran git");
    write(&repo, "d00/more.txt");
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "--quiet", "-m", "second"]);
    let after = status_reply(&repo, false).unwrap();
    assert_ne!(after["head"], first["head"], "{after}");
    assert_eq!(after["branch"], "main");
    git(&repo, &["checkout", "--quiet", "-b", "topic"]);
    assert_eq!(status_reply(&repo, false).unwrap()["branch"], "topic");
}

/// `git.branches` runs its reads once while the refs stay; a new branch is
/// listed by the next read.
#[test]
fn branches_read_the_refs_once_until_a_ref_moves() {
    let temp = Temp::new("branches");
    let repo = repository(&temp, 1);
    let fields = Map::new();
    let first = branches_reply(&repo, &fields).unwrap();
    assert_eq!(first, branches_reply(&repo, &fields).unwrap());
    assert_eq!(read_probe::count(Read::Branches, &repo), 1, "the second listing ran git");
    git(&repo, &["branch", "topic"]);
    let after = branches_reply(&repo, &fields).unwrap();
    let listed: Vec<&str> =
        after["branches"].as_array().unwrap().iter().map(|b| b["name"].as_str().unwrap()).collect();
    assert!(listed.contains(&"topic"), "{after}");
}
