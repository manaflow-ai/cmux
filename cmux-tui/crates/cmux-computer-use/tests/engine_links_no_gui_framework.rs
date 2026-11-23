//! The engine half of this crate (everything outside `platform/`, built
//! without the `desktop` feature) links no macOS GUI framework. acpmux and
//! the cmux-tui daemon link the engine for the tool catalog and the wire
//! types; their macOS builds come from the Linux pool's cross SDK, which has
//! no CoreGraphics, AppKit or ApplicationServices. A `#[link]` to one of them
//! in engine code failed every pool app build of feat-cmux-next (2026-11-21:
//! `locked.rs` linked CoreGraphics, `ld64.lld: framework not found`). Such a
//! link stays under `platform/` or behind `feature = "desktop"`.

use std::path::Path;

const GUI: [&str; 3] = ["CoreGraphics", "AppKit", "ApplicationServices"];

fn rust_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            if path.file_name().is_some_and(|n| n == "platform") {
                continue;
            }
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// A line that starts a top-level item.
fn is_item(line: &str) -> bool {
    ["pub fn ", "fn ", "mod ", "pub mod ", "unsafe extern", "pub(crate) fn ", "#[link("]
        .iter()
        .any(|p| line.starts_with(p))
}

#[test]
fn engine_code_links_no_gui_framework_outside_the_desktop_feature() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    rust_files(&src, &mut files);
    let mut found = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            let Some(name) = GUI
                .iter()
                .find(|n| line.contains(&format!("#[link(name = \"{n}\", kind = \"framework\")]")))
            else {
                continue;
            };
            // Gated when the top-level item that holds the link (the nearest
            // line above at column 0 that is not an attribute or a doc line,
            // or the link itself) carries a `cfg` naming the desktop feature.
            let item = (0..=i)
                .rev()
                .find(|&j| j == i && !line.starts_with(' ') || is_item(lines[j]))
                .unwrap_or(i);
            let gated = lines[..item]
                .iter()
                .rev()
                .take_while(|l| l.starts_with("#[") || l.starts_with("///"))
                .any(|l| l.contains("feature = \"desktop\""));
            if !gated {
                found.push(format!(
                    "{}:{} links {name}",
                    file.strip_prefix(&src).unwrap().display(),
                    i + 1
                ));
            }
        }
    }
    assert!(found.is_empty(), "GUI framework links in engine code: {found:?}");
}
