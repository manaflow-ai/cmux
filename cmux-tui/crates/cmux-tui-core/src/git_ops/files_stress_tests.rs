//! The Files tree at scale: `git.files.list` (the first listing of a folder,
//! expanding one folder, and the relist a refresh makes after a one-file
//! change) and `git.files.search` (one quick-open filter keystroke), over
//! synthetic repositories of 1 000, 50 000 and 500 000 paths, shallow-wide
//! (100 folders under the top) and deep (a chain of 12 folders).
//!
//! The rule: listing one folder costs what that folder holds, and a filter
//! keystroke what it matches; neither costs the tree. git itself still walks
//! the folder's subtree for its names (`ls-files`), but the daemon's own look
//! at the disk ([`super::files::Folders::kind`], an `openat`/`fstatat` per
//! call) is counted here (`looks`) and must grow only with the children shown
//! or the paths matched.
//!
//! The timing sweep is slow, so it runs only when asked: `CMUX_STRESS=1`, or a
//! plain `cargo test` whose filter names `files_stress_bench` (not `--exact`).
//! It prints one `STRESS-FILE-TREE` JSON line per shape, size and operation.
//! The `looks_*` tests always run: they count work, not time.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

use cmux_git::Repository;
use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

use super::files::{self, Folders, LOOKS};
use super::list;
use super::work_tree_entry::Kind;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("files_stress_bench"))
        && !args.iter().any(|a| a == "--exact")
}

/// A temp folder this test made; removed on drop.
struct Temp(PathBuf);

impl Temp {
    fn new(tag: &str) -> Self {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-files-stress-{tag}-{hex}"));
        std::fs::create_dir_all(&path).unwrap();
        // git gives the top folder with real folders only.
        Self(std::fs::canonicalize(path).unwrap())
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn git(repo: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(repo)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdout(Stdio::null());
    command
}

fn run(repo: &Path, arguments: &[&str]) {
    let status = git(repo).args(arguments).status().unwrap();
    assert!(status.success(), "git {arguments:?} failed");
}

/// Writes `files` (empty) and `tracked` into the index in one `update-index`
/// run: no hashing per file, so 500 000 paths index in about a second.
fn repository(temp: &Temp, files: &[String], untracked: &[String]) -> PathBuf {
    let repo = temp.0.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    run(&repo, &["init", "--quiet"]);
    for path in files.iter().chain(untracked) {
        let path = repo.join(path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::File::create(path).unwrap();
    }
    let empty = git(&repo)
        .args(["hash-object", "-w", "--stdin"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .output()
        .unwrap();
    let empty = String::from_utf8(empty.stdout).unwrap();
    let empty = empty.trim();
    let mut child =
        git(&repo).args(["update-index", "--index-info"]).stdin(Stdio::piped()).spawn().unwrap();
    {
        let mut stdin = std::io::BufWriter::new(child.stdin.take().unwrap());
        for path in files {
            writeln!(stdin, "100644 {empty}\t{path}").unwrap();
        }
    }
    assert!(child.wait().unwrap().success(), "update-index");
    repo
}

#[derive(Clone, Copy, Debug)]
enum Shape {
    /// 100 folders under the top, the paths spread evenly, and 5 top files.
    Wide,
    /// A chain of 12 folders (`l00/l01/...`), the paths spread over its levels.
    Deep,
}

const DEPTH: usize = 12;

impl Shape {
    fn name(self) -> &'static str {
        match self {
            Self::Wide => "wide",
            Self::Deep => "deep",
        }
    }

    fn paths(self, count: usize) -> Vec<String> {
        match self {
            Self::Wide => {
                let mut paths: Vec<String> = (0..5).map(|i| format!("top-{i}.md")).collect();
                paths.extend(
                    (0..count.saturating_sub(5)).map(|i| format!("d{:03}/f{i}.rs", i % 100)),
                );
                paths
            }
            Self::Deep => (0..count)
                .map(|i| {
                    let level = i % DEPTH;
                    let mut path = String::new();
                    for l in 0..=level {
                        path.push_str(&format!("l{l:02}/"));
                    }
                    path.push_str(&format!("f{i}.rs"));
                    path
                })
                .collect(),
        }
    }

    /// The folder a person expands: one of the 100 (wide), the middle of the chain (deep).
    fn expanded(self) -> String {
        match self {
            Self::Wide => "d050".to_owned(),
            Self::Deep => (0..DEPTH / 2).map(|l| format!("l{l:02}")).collect::<Vec<_>>().join("/"),
        }
    }
}

/// One `git.files.list` the way the daemon answers it: open, then list.
/// Returns the reply and the looks it made.
fn list_folder(repo: &Path, folder: &str) -> (Value, usize) {
    let directory = if folder.is_empty() { repo.to_path_buf() } else { repo.join(folder) };
    LOOKS.with(|looks| looks.set(0));
    let repository = Repository::open(&directory).unwrap();
    let reply = list::list(&repository, &directory, &Map::new()).unwrap();
    (reply, LOOKS.with(std::cell::Cell::get))
}

/// Readies the daemon's listing of `repo` before a measure: what a Files page
/// that is already open has. Returns how long that took.
fn warm(repo: &Path) -> std::time::Duration {
    let start = Instant::now();
    let _ = list_folder(repo, "");
    start.elapsed()
}

/// The entries the daemon went over for `repo` since the last call
/// ([`files::TOUCHED`]), on any thread.
fn touched_since(repo: &Path) -> usize {
    let mut touched = files::TOUCHED.lock().unwrap();
    touched.iter_mut().find(|(root, _)| root == repo).map_or(0, |(_, n)| std::mem::take(n))
}

/// One `git.files.search` keystroke from the top folder.
fn search(repo: &Path, query: &str) -> (Value, usize) {
    LOOKS.with(|looks| looks.set(0));
    let repository = Repository::open(repo).unwrap();
    let mut fields = Map::new();
    fields.insert("query".into(), json!(query));
    let reply = files::search(&repository, repo, &fields).unwrap();
    (reply, LOOKS.with(std::cell::Cell::get))
}

fn entries(reply: &Value) -> Vec<(String, bool)> {
    reply["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (entry["name"].as_str().unwrap().to_owned(), entry["kind"] == "directory"))
        .collect()
}

/// The listing as it was made before the lazy look: every listed path looked
/// at, then folded into its first component. The lazy listing must equal it.
fn every_path_look(repo: &Path, folder: &str) -> (Vec<(String, bool)>, bool) {
    let directory = if folder.is_empty() { repo.to_path_buf() } else { repo.join(folder) };
    let repository = Repository::open(&directory).unwrap();
    let below = files::folder(&repository, &directory, "test").unwrap();
    let (mut paths, cut) = files::listed(&repository, &directory, "test").unwrap();
    let mut folders = Folders::of(&repository, &below);
    paths.retain(|path| folders.kind(path).is_some());
    let mut children: std::collections::BTreeMap<String, bool> = Default::default();
    for path in &paths {
        let (name, nested) =
            path.split_once('/').map_or((path.as_str(), false), |(name, _)| (name, true));
        let directory = children.entry(name.to_owned()).or_insert(false);
        if !*directory && (nested || folders.kind(name) == Some(Kind::Folder)) {
            *directory = true;
        }
    }
    let total = children.len();
    let mut children: Vec<(String, bool)> = children.into_iter().collect();
    children.sort_by(|l, r| {
        r.1.cmp(&l.1)
            .then_with(|| l.0.to_lowercase().cmp(&r.0.to_lowercase()))
            .then_with(|| l.0.cmp(&r.0))
    });
    children.truncate(list::DEFAULT_LIMIT);
    (children, cut || total > list::DEFAULT_LIMIT)
}

/// Listing the top folder or one folder makes a fixed number of looks per
/// child shown, at 200 paths and at 100 times that: never one per path below.
#[test]
fn looks_of_a_folder_listing_grow_with_its_children_not_the_tree() {
    for shape in [Shape::Wide, Shape::Deep] {
        let mut by_size = Vec::new();
        for count in [200, 20_000] {
            let temp = Temp::new("looks-list");
            let repo = repository(&temp, &shape.paths(count), &[]);
            for folder in [String::new(), shape.expanded()] {
                let (reply, looks) = list_folder(&repo, &folder);
                let children = entries(&reply).len();
                assert!(!reply["truncated"].as_bool().unwrap());
                // At most two looks per child (the child, and one path below it), plus
                // the folder itself.
                assert!(
                    looks <= 2 * children + 2,
                    "{} {count} paths, folder {folder:?}: {looks} looks for {children} children",
                    shape.name()
                );
                by_size.push((folder, children, looks));
            }
        }
        // The top folder shows the same children at both sizes, so the same looks.
        assert_eq!(by_size[0].1, by_size[2].1);
        assert_eq!(
            by_size[0].2,
            by_size[2].2,
            "{}: top folder looks at 200 and 20 000 paths",
            shape.name()
        );
    }
}

/// A filter keystroke looks at the paths it matches, not every path.
#[test]
fn looks_of_a_filter_keystroke_grow_with_its_matches_not_the_tree() {
    for count in [200, 20_000] {
        let temp = Temp::new("looks-search");
        let mut paths = Shape::Wide.paths(count);
        paths.extend(
            ["d001/needle-a.txt", "d002/needle-b.txt", "needle-top.txt"].map(str::to_owned),
        );
        let repo = repository(&temp, &paths, &[]);
        let (reply, looks) = search(&repo, "needle");
        let shown = reply["results"].as_array().unwrap().len();
        assert_eq!(shown, 3, "{count} paths: {reply}");
        // One look per match, and the second look per shown result.
        assert!(looks <= 2 * 3, "{count} paths: {looks} looks for 3 matches");
    }
}

/// The work of what a person waits on, in entries the daemon goes over (listed
/// paths, kept tree nodes; [`files::TOUCHED`]), at 50 000 and 500 000 paths:
/// listing the top folder, a one-file change then the top folder's relist,
/// and each filter keystroke that extends the one before. None may grow with
/// the tree: a listing goes over the folder's children, a change the changed
/// path's folders, a keystroke the previous keystroke's matches.
#[test]
fn work_of_a_listing_a_change_and_a_keystroke_grows_with_what_it_shows_not_the_tree() {
    let mut by_size = Vec::new();
    for count in [50_000, 500_000] {
        let temp = Temp::new("work");
        let mut paths = Shape::Wide.paths(count);
        paths.extend(
            ["d001/needle-a.txt", "d002/needle-b.txt", "needle-top.txt"].map(str::to_owned),
        );
        let repo = repository(&temp, &paths, &[]);
        warm(&repo);
        touched_since(&repo);
        let (top, _) = list_folder(&repo, "");
        let children = entries(&top).len();
        let list = touched_since(&repo);
        std::fs::write(repo.join("d050/edit.txt"), "").unwrap();
        let (top, _) = list_folder(&repo, "");
        assert_eq!(entries(&top).len(), children, "{count} paths: {top}");
        let change = touched_since(&repo);
        let _ = search(&repo, "n");
        touched_since(&repo);
        let mut keystroke = 0;
        for query in ["ne", "nee", "need", "needl", "needle"] {
            let (reply, _) = search(&repo, query);
            assert_eq!(reply["results"].as_array().unwrap().len(), 3, "{count} paths, {query}");
            keystroke = keystroke.max(touched_since(&repo));
        }
        eprintln!(
            "WORK-FILE-TREE paths={count} children={children} list={list} change={change} keystroke={keystroke}"
        );
        assert!(
            list <= 2 * children + 8,
            "{count} paths: listing went over {list} entries for {children} children"
        );
        assert!(
            change <= list + 32,
            "{count} paths: a one-file change and relist went over {change} entries"
        );
        assert!(
            keystroke <= 16,
            "{count} paths: an extending keystroke went over {keystroke} entries for 3 matches"
        );
        by_size.push((list, change, keystroke));
    }
    assert_eq!(by_size[0].0, by_size[1].0, "listing work at 50 000 and 500 000 paths");
}

/// The lazy look lists exactly what a look at every path lists, on a tree with
/// the cases that look decides: tracked files gone from the disk, a folder whose
/// files are all gone (still there, or gone itself), a link, a nested
/// repository, a tracked file now a folder, unicode, conflict stages (the same
/// path three times), an empty folder, and one folder past the limit.
#[test]
fn looks_lazy_listing_equals_a_look_at_every_path() {
    let temp = Temp::new("looks-equal");
    let mut tracked: Vec<String> = [
        "README.md",
        "gone.txt",
        "empty/a.txt",
        "empty/b.txt",
        "vanished/a.txt",
        "half/here.txt",
        "half/gone.txt",
        "real/x.txt",
        "ünïcode/файл.txt",
        "日本語.md",
        "swap",
        "deep/a/b/c/d.txt",
        "deep/a/gone/e.txt",
    ]
    .map(str::to_owned)
    .to_vec();
    tracked.extend((0..2_500).map(|i| format!("huge/f{i:05}.txt")));
    let repo = repository(&temp, &tracked, &["new.txt".into(), "real/untracked.txt".into()]);
    for gone in
        ["gone.txt", "empty/a.txt", "empty/b.txt", "half/gone.txt", "deep/a/gone/e.txt", "swap"]
    {
        std::fs::remove_file(repo.join(gone)).unwrap();
    }
    std::fs::remove_dir_all(repo.join("vanished")).unwrap();
    std::fs::create_dir_all(repo.join("swap")).unwrap();
    std::fs::write(repo.join("swap/inner.txt"), "").unwrap();
    std::os::unix::fs::symlink("real", repo.join("link")).unwrap();
    std::fs::create_dir_all(repo.join("nested")).unwrap();
    run(&repo.join("nested"), &["init", "--quiet"]);
    std::fs::create_dir_all(repo.join("blank")).unwrap();
    // Conflict stages: dup.txt three times in the index.
    let mut child =
        git(&repo).args(["update-index", "--index-info"]).stdin(Stdio::piped()).spawn().unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        let empty = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
        for stage in 1..=3 {
            writeln!(stdin, "100644 {empty} {stage}\tdup.txt").unwrap();
        }
    }
    assert!(child.wait().unwrap().success());
    std::fs::write(repo.join("dup.txt"), "").unwrap();
    for folder in ["", "empty", "half", "deep", "deep/a", "real", "huge", "ünïcode", "swap"] {
        let (reply, _) = list_folder(&repo, folder);
        let (expected, cut) = every_path_look(&repo, folder);
        assert_eq!(entries(&reply), expected, "folder {folder:?}");
        assert_eq!(reply["truncated"].as_bool().unwrap(), cut, "folder {folder:?}");
    }
    let (top, _) = list_folder(&repo, "");
    let names: Vec<String> = entries(&top).into_iter().map(|(name, _)| name).collect();
    assert!(
        !names.contains(&"vanished".to_owned()) && !names.contains(&"empty".to_owned()),
        "{names:?}"
    );
    assert!(names.contains(&"half".to_owned()) && names.contains(&"link".to_owned()), "{names:?}");
    assert_eq!(names.iter().filter(|name| *name == "dup.txt").count(), 1);
    let (huge, _) = list_folder(&repo, "huge");
    assert!(huge["truncated"].as_bool().unwrap());
    // An empty repository lists nothing.
    let empty = Temp::new("looks-empty");
    let repo = repository(&empty, &[], &[]);
    let (reply, looks) = list_folder(&repo, "");
    assert!(entries(&reply).is_empty() && looks == 0, "{reply} {looks}");
}

/// Milliseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1000.0);
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 10.0).round() / 10.0
        };
        json!({ "n": v.len(), "p50": at(0.5), "p95": at(0.95), "max": at(1.0) })
    }
}

fn line(shape: Shape, paths: usize, op: &str, samples: &Samples, looks: usize, shown: usize) {
    let mut value = samples.summary();
    value.set("shape", json!(shape.name()));
    value.set("paths", json!(paths));
    value.set("op", json!(op));
    value.set("looks", json!(looks));
    value.set("shown", json!(shown));
    println!("STRESS-FILE-TREE {value}");
}

#[test]
fn files_stress_bench() {
    if !bench_selected() {
        return;
    }
    for (count, runs) in [(1_000, 15), (50_000, 9), (500_000, 5)] {
        for shape in [Shape::Wide, Shape::Deep] {
            let temp = Temp::new("bench");
            let repo = repository(&temp, &shape.paths(count), &[]);
            let expanded = shape.expanded();

            // Readying the daemon's listing, one time per repository (none
            // before a kept listing: then it is one more listing).
            let mut ready = Samples::default();
            ready.0.push(warm(&repo).as_secs_f64() * 1000.0);
            line(shape, count, "ready", &ready, 0, 0);

            let mut first = Samples::default();
            let (mut looks, mut shown) = (0, 0);
            for _ in 0..runs {
                let start = Instant::now();
                let (reply, l) = list_folder(&repo, "");
                first.push(start);
                (looks, shown) = (l, entries(&reply).len());
            }
            line(shape, count, "first_list", &first, looks, shown);

            let mut expand = Samples::default();
            for _ in 0..runs {
                let start = Instant::now();
                let (reply, l) = list_folder(&repo, &expanded);
                expand.push(start);
                (looks, shown) = (l, entries(&reply).len());
            }
            line(shape, count, "expand", &expand, looks, shown);

            // A one-file change, then the page's refresh: the top folder and the
            // expanded one listed again.
            let mut change = Samples::default();
            for run in 0..runs {
                std::fs::write(repo.join(&expanded).join(format!("new-{run}.txt")), "").unwrap();
                let start = Instant::now();
                let (top, l1) = list_folder(&repo, "");
                let (folder, l2) = list_folder(&repo, &expanded);
                change.push(start);
                (looks, shown) = (l1 + l2, entries(&top).len() + entries(&folder).len());
            }
            line(shape, count, "change_refresh", &change, looks, shown);

            // A filter keystroke: the third character of a query most paths match (a subsequence).
            let mut filter = Samples::default();
            for _ in 0..runs {
                let start = Instant::now();
                let (reply, l) = search(&repo, "f12");
                filter.push(start);
                (looks, shown) = (l, reply["results"].as_array().unwrap().len());
            }
            line(shape, count, "filter_keystroke", &filter, looks, shown);

            // Typing the query: each keystroke after the first extends the one
            // before ("f", then "f1", then "f12").
            let mut typed = [Samples::default(), Samples::default(), Samples::default()];
            let mut typed_shown = [0; 3];
            for _ in 0..runs {
                for (at, query) in ["f", "f1", "f12"].into_iter().enumerate() {
                    let start = Instant::now();
                    let (reply, _) = search(&repo, query);
                    typed[at].push(start);
                    typed_shown[at] = reply["results"].as_array().unwrap().len();
                }
                // The next run types from an empty field.
                let _ = search(&repo, "zz");
            }
            for (at, samples) in typed.iter().enumerate() {
                let op = format!("typed_keystroke_{}", at + 1);
                line(shape, count, &op, samples, 0, typed_shown[at]);
            }
        }
    }
}
