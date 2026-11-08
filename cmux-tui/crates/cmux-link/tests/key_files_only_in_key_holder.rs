//! Only `cmux_link::key_holder` names a WireGuard key file in shipped code,
//! so a new reader of a key must come through its lock (`KeyHolder::open`)
//! or its public-half door (`open_for_public_key`).
//!
//! The check reads the Rust source of every crate in this workspace and
//! fails on a string literal of a key file name outside `key_holder.rs`.
//! Test code is skipped: files under `tests/`, `*_tests.rs`, `tests.rs`, and
//! a file's test module and everything after it.

use std::path::{Path, PathBuf};

const KEY_FILE_LITERALS: [&str; 2] = ["\"private.key\"", "\"node.wg.key\""];

#[test]
fn only_key_holder_names_a_key_file() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let mut sources = Vec::new();
    collect(&crates, &mut sources);
    assert!(sources.len() > 100, "found only {} source files under {crates:?}", sources.len());
    let mut found = Vec::new();
    for path in sources {
        let relative = path.strip_prefix(&crates).unwrap().to_string_lossy().replace('\\', "/");
        if relative == "cmux-link/src/key_holder.rs" || is_test_file(&relative) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        for (number, line) in shipped_lines(&text) {
            if KEY_FILE_LITERALS.iter().any(|literal| line.contains(literal)) {
                found.push((relative.clone(), number, line.trim().to_owned()));
            }
        }
    }
    assert!(
        found.is_empty(),
        "a WireGuard key file is named outside cmux_link::key_holder; use \
         key_holder::KeyFile and open it through KeyHolder::open or open_for_public_key:\n{found:#?}"
    );
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if name == "target" || name == "node_modules" || name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

fn is_test_file(relative: &str) -> bool {
    relative.split('/').any(|part| part == "tests" || part == "benches" || part == "examples")
        || relative.ends_with("_tests.rs")
        || relative.ends_with("/tests.rs")
}

/// The lines before the file's inline test module (a `#[cfg(test)]` or
/// `#[cfg(all(test, ...))]` on a `mod ... {`), numbered from 1, without `//`
/// comments.
fn shipped_lines(text: &str) -> impl Iterator<Item = (usize, &str)> {
    let lines: Vec<&str> = text.lines().collect();
    let end = (0..lines.len())
        .find(|&index| {
            let line = lines[index].trim();
            (line == "#[cfg(test)]" || line.starts_with("#[cfg(all(test"))
                && lines[index + 1..]
                    .iter()
                    .map(|next| next.trim())
                    .find(|next| !next.starts_with("#["))
                    .is_some_and(|next| {
                        (next.starts_with("mod ") || next.starts_with("pub mod "))
                            && next.ends_with('{')
                    })
        })
        .unwrap_or(lines.len());
    lines
        .into_iter()
        .take(end)
        .enumerate()
        .map(|(index, line)| (index + 1, line))
        .filter(|(_, line)| !line.trim_start().starts_with("//"))
}
