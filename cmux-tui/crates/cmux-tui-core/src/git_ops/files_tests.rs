//! `git.files.search`: candidates, ranking, folders and bounds.

use std::fs;
use std::path::Path;

use serde_json::{Value, json};

use super::super::files::score;
use super::{call, commit_all, failure, git, mux, ok, repository, write};

fn search(
    mux: &std::sync::Arc<crate::Mux>,
    folder: &Path,
    query: &str,
    limit: Option<u64>,
) -> Value {
    let mut params = json!({"path": folder.to_string_lossy(), "query": query});
    if let Some(limit) = limit {
        params["limit"] = json!(limit);
    }
    ok(call(mux, "git.files.search", params))
}

fn paths(result: &Value) -> Vec<String> {
    result["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["path"].as_str().unwrap().to_string())
        .collect()
}

fn chars(query: &str) -> Vec<char> {
    query.chars().collect()
}

#[test]
fn lists_tracked_and_untracked_files_but_not_ignored_or_deleted_ones() {
    let mux = mux();
    let repository = repository("files-candidates");
    write(&repository, ".gitignore", b"build/\n*.log\n");
    write(&repository, "src/app.rs", b"x");
    write(&repository, "src/gone.rs", b"x");
    commit_all(&repository, "first");
    fs::remove_file(repository.join("src/gone.rs")).unwrap();
    write(&repository, "src/added.rs", b"x");
    write(&repository, "build/out.rs", b"x");
    write(&repository, "debug.log", b"x");

    let result = search(&mux, &repository, "rs", None);
    assert_eq!(result["root"], repository.to_string_lossy().as_ref());
    assert_eq!(result["search_root"], repository.to_string_lossy().as_ref());
    let mut found = paths(&result);
    found.sort();
    assert_eq!(found, vec!["src/added.rs", "src/app.rs"]);
    assert_eq!(result["truncated"], false);
    assert_eq!(result["total_matches"], 2);
}

#[test]
fn ranks_name_matches_first_and_marks_the_matched_characters() {
    let mux = mux();
    let repository = repository("files-rank");
    write(&repository, "Sources/Fleet/upload.ts", b"x");
    write(&repository, "Sources/Fleet/upload.test.ts", b"x");
    write(&repository, "unrelated/plo/ad.ts", b"x");
    write(&repository, "README.md", b"x");
    commit_all(&repository, "first");

    let result = search(&mux, &repository, "upload", None);
    assert_eq!(
        paths(&result),
        vec!["Sources/Fleet/upload.ts", "Sources/Fleet/upload.test.ts", "unrelated/plo/ad.ts"]
    );
    assert_eq!(result["results"][0]["matches"], json!([14, 15, 16, 17, 18, 19]));
    // Case and whitespace in the query do not matter.
    assert_eq!(paths(&search(&mux, &repository, "READ me", None)), vec!["README.md"]);
    // An empty query lists nothing but still names the folder.
    let empty = search(&mux, &repository, "  ", None);
    assert_eq!(paths(&empty), Vec::<String>::new());
    assert_eq!(empty["search_root"], repository.to_string_lossy().as_ref());
}

#[test]
fn a_subfolder_searches_only_under_it_with_paths_relative_to_it() {
    let mux = mux();
    let repository = repository("files-folder");
    write(&repository, "web/src/App.tsx", b"x");
    write(&repository, "web/package.json", b"x");
    write(&repository, "app/App.swift", b"x");
    commit_all(&repository, "first");
    write(&repository, "web/src/new.tsx", b"x");

    let result = search(&mux, &repository.join("web"), "app", None);
    assert_eq!(paths(&result), vec!["src/App.tsx"]);
    assert_eq!(result["root"], repository.to_string_lossy().as_ref());
    assert_eq!(result["search_root"], repository.join("web").to_string_lossy().as_ref());
    assert_eq!(paths(&search(&mux, &repository.join("web"), "tsx", None)).len(), 2);
    // A file path searches its folder.
    let from_file = search(&mux, &repository.join("web/package.json"), "new", None);
    assert_eq!(paths(&from_file), vec!["src/new.tsx"]);
}

#[test]
fn limit_cuts_the_results_and_says_so() {
    let mux = mux();
    let repository = repository("files-limit");
    for index in 0..12 {
        write(&repository, &format!("file{index:02}.txt"), b"x");
    }
    commit_all(&repository, "first");
    let result = search(&mux, &repository, "file", Some(5));
    assert_eq!(paths(&result).len(), 5);
    assert_eq!(result["truncated"], true);
    assert_eq!(result["total_matches"], 12);
    // Equal scores sort by path.
    assert_eq!(paths(&result)[0], "file00.txt");
}

#[test]
fn a_terminal_selector_searches_its_working_directory() {
    let mux = mux();
    let repository = repository("files-terminal");
    write(&repository, "main.rs", b"x");
    commit_all(&repository, "first");
    let missing = call(
        &mux,
        "git.files.search",
        json!({"terminal": "term_00000000000000000000000000000099", "query": "main"}),
    );
    assert!(failure(&missing).0.starts_with("selector."), "{missing}");
    let both = call(
        &mux,
        "git.files.search",
        json!({"path": repository.to_string_lossy(), "terminal": "current", "query": "main"}),
    );
    assert_eq!(failure(&both).0, "validation.invalid");
    // The setup's git is still usable after the searches.
    assert_eq!(git(&repository, &["ls-files"]), "main.rs");
}

#[test]
fn score_rejects_missing_characters_and_prefers_runs_and_word_starts() {
    assert!(score("src/main.rs", &chars("xyz")).is_none());
    assert!(score("ab", &chars("abc")).is_none());
    let (_, matches) = score("src/main.rs", &chars("main")).unwrap();
    assert_eq!(matches, vec![4, 5, 6, 7]);
    let (run, _) = score("a/main.rs", &chars("main")).unwrap();
    let (spread, _) = score("a/m_a_i_n.rs", &chars("main")).unwrap();
    assert!(run > spread);
    let (camel, matches) = score("FooBarBaz.ts", &chars("fbb")).unwrap();
    assert_eq!(matches, vec![0, 3, 6]);
    let (inner, _) = score("fobbaz.ts", &chars("fbb")).unwrap();
    assert!(camel > inner);
    let (in_name, _) = score("x/y/readme.md", &chars("rd")).unwrap();
    let (in_folder, _) = score("readers/y/a.md", &chars("rd")).unwrap();
    assert!(in_name > in_folder, "{in_name} {in_folder}");
}
