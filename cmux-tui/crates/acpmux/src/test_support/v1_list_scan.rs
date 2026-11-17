//! The v1 list scan (agent service v2, rows 7b and 7c): every use of `_acpmux/sessions`,
//! `_acpmux/watch` or `session/list` in a crate's sources is a named fallback, each with its
//! reason. acpmux's `single_shot_list_tests.rs` scans acpmux with it; `cmux-tui-core` scans
//! itself, so a change to `cmux-tui-core` alone runs its scan.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

/// A named use: the file (from the scan's root), the method as written, how many such uses the
/// file holds, and why each is a fallback.
pub type Named<'a> = (&'a str, &'a str, usize, &'a str);

/// Every Rust source under `dir` into `out`, test and bench files and `target`, `tests`,
/// `benches`, `node_modules` and `.git` left out.
pub fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if !matches!(name.as_str(), "target" | "tests" | "benches" | "node_modules" | ".git") {
                sources(&path, out);
            }
        } else if name.ends_with(".rs")
            && !name.ends_with("_tests.rs")
            && !name.ends_with("_test.rs")
            && !name.contains("bench")
        {
            out.push(path);
        }
    }
}

/// The sources under each of `dirs` (test files left out), each as `(path from root, text)`.
pub fn sources_from(root: &Path, dirs: &[PathBuf]) -> Vec<(String, String)> {
    let mut files = Vec::new();
    for dir in dirs {
        sources(dir, &mut files);
    }
    files
        .into_iter()
        .filter(|path| path.file_name().is_some_and(|name| name != "tests.rs"))
        .filter_map(|path| {
            let text = std::fs::read_to_string(&path).ok()?;
            let rel = path.strip_prefix(root).ok()?.to_string_lossy().replace('\\', "/");
            Some((rel, text))
        })
        .collect()
}

/// The uses in `files` (`(path, text)`), outside the directories `skip` names, that `named`
/// does not hold, one line each.
pub fn unnamed_v1_list_uses(
    files: &[(String, String)],
    named: &[Named<'_>],
    skip: &[&str],
) -> io::Result<Vec<String>> {
    let token = regex::Regex::new(
        r#"method::(?:MUX_SESSIONS|MUX_WATCH|SESSION_LIST)\b|"(?:_acpmux/sessions|_acpmux/watch|session/list)""#,
    )
    .map_err(io::Error::other)?;
    let mut found: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    for (rel, text) in files {
        if skip.iter().any(|dir| rel.starts_with(dir)) {
            continue;
        }
        for hit in token.find_iter(text) {
            let line = text[..hit.start()].matches('\n').count() + 1;
            found.entry((rel.clone(), hit.as_str().to_owned())).or_default().push(line);
        }
    }
    let mut wrong = Vec::new();
    for ((file, method), lines) in &found {
        // A file may name one method in several rows, each a use with its own reason.
        let allowed: usize = named
            .iter()
            .filter(|(f, m, _, _)| f == file && m == method)
            .map(|(_, _, n, _)| *n)
            .sum();
        if lines.len() != allowed {
            wrong.push(format!(
                "src/{file}:{lines:?} uses {method} {} time(s); the table names {allowed}",
                lines.len()
            ));
        }
    }
    for (file, method, _, _) in named {
        if !found.contains_key(&((*file).to_owned(), (*method).to_owned())) {
            wrong.push(format!("src/{file} no longer uses {method}: take it out of the table"));
        }
    }
    Ok(wrong)
}
