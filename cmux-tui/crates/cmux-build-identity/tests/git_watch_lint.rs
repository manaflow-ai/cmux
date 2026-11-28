//! Detector: no cmux-tui build script watches a Git file whose bytes are not
//! the ref state. logs/ (reflogs) carry wall-clock times, so a fresh clone of
//! the same commit has different bytes and a restored target/ reran
//! acpmux-build-id and relinked acpmux (133 s instead of about 1 s); index is
//! rewritten by every `git status` stat refresh; FETCH_HEAD and ORIG_HEAD move
//! on fetches and resets that change no source. Watch HEAD, packed-refs and
//! the branch's loose ref (or its directory when the ref is packed) instead.

use std::fs;
use std::path::{Path, PathBuf};

/// A path a build script may not hand Git (`--git-path`) or Cargo.
fn is_volatile_git_path(literal: &str) -> bool {
    let literal = literal.trim_start_matches(".git/");
    literal.starts_with("logs/")
        || literal.contains("/logs/")
        || literal == "logs"
        || literal == "index"
        || literal.ends_with("/index")
        || literal.contains("FETCH_HEAD")
        || literal.contains("ORIG_HEAD")
}

/// The string literals of `source` outside `//` comments (a plain split on
/// quotes: enough for build scripts, which hold no raw strings with quotes).
fn string_literals(source: &str) -> Vec<String> {
    let mut literals = Vec::new();
    for line in source.lines() {
        let code = match line.find("//") {
            Some(at) if !line[..at].ends_with(':') => &line[..at],
            _ => line,
        };
        literals.extend(code.split('"').skip(1).step_by(2).map(str::to_owned));
    }
    literals
}

/// Whether the script reads Git's own directory (as opposed to running
/// `git checkout FETCH_HEAD` on a vendored checkout).
fn reads_git_dir(literals: &[String]) -> bool {
    literals.iter().any(|literal| {
        matches!(literal.as_str(), "--git-path" | "--git-dir" | "--git-common-dir")
            || literal.contains(".git/")
    })
}

fn violations(source: &str) -> Vec<String> {
    let literals = string_literals(source);
    if !reads_git_dir(&literals) {
        return Vec::new();
    }
    literals.into_iter().filter(|literal| is_volatile_git_path(literal)).collect()
}

fn build_scripts(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if path.is_dir() {
            if name != "target" && name != "vendor" && !name.starts_with('.') {
                build_scripts(&path, found);
            }
        } else if name == "build.rs"
            || name == "build_support.rs"
            || (name.ends_with(".rs") && dir.ends_with("build-support"))
        {
            found.push(path);
        }
    }
}

#[test]
fn no_build_script_watches_a_volatile_git_file() {
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap();
    let mut scripts = Vec::new();
    build_scripts(&workspace.join("crates"), &mut scripts);
    build_scripts(&workspace.join("build-support"), &mut scripts);
    for crate_name in ["acpmux-build-id", "cmux-build-identity"] {
        assert!(
            scripts.iter().any(|path| path.ends_with(format!("{crate_name}/build.rs"))),
            "the lint did not reach {crate_name}/build.rs: {scripts:?}"
        );
    }
    let mut found = Vec::new();
    for script in &scripts {
        for literal in violations(&fs::read_to_string(script).unwrap()) {
            found.push(format!("{}: \"{literal}\"", script.display()));
        }
    }
    assert!(
        found.is_empty(),
        "build scripts watch Git files whose bytes differ between clones of one commit \
         or change without a ref move (watch HEAD, packed-refs and the branch ref):\n{}",
        found.join("\n")
    );
}

#[test]
fn the_lint_flags_the_reflog_watch_it_replaced() {
    let before = r#"
    let mut git_paths = vec!["HEAD".to_owned(), "packed-refs".to_owned(), "logs/HEAD".to_owned()];
    git(&["rev-parse", "--path-format=absolute", "--git-path", path]);
    "#;
    assert_eq!(violations(before), ["logs/HEAD"]);
    assert_eq!(violations(r#"track_git_path(dir, "index"); git(&["--git-path", p]);"#), ["index"]);
    assert_eq!(
        violations(r#"let p = ".git/logs/refs/heads/main";"#),
        [".git/logs/refs/heads/main"]
    );
    // A vendored checkout's FETCH_HEAD is not a watch.
    assert!(violations(r#"git(&["checkout", "-q", "FETCH_HEAD"]);"#).is_empty());
    // Comments are not code.
    assert!(violations("// not \"logs/HEAD\"\ngit(&[\"--git-path\", \"HEAD\"]);").is_empty());
}
