//! Thread names of the shipped crates (p09-observability-117, queue MQ13).
//!
//! A trace or a STRESS decode names a thread by its OS name, which Linux cuts to 15 bytes
//! (`pthread_setname_np`, `/proc/<pid>/task/<tid>/comm`); Chromium names every thread it starts the
//! same way (`base::PlatformThread::SetName`, base/threading/platform_thread.h). So:
//! - no shipped code starts an unnamed thread (`thread::spawn(` outside test code: MQ13 = 0);
//! - every helper thread name that plans/cmux-next/threading-model.md lists under
//!   "Helper threads" is at most 15 bytes, listed once, used by its code, and no other thread name
//!   of the shipped crates cuts to the same 15 bytes.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// The crates whose binaries ship in the app (`observability-audit.py` MQ13).
const SHIPPED: [&str; 6] =
    ["cmux-tui-core", "cmux-tui", "cmux-holder", "acpmux", "cmux-app-host", "cmux-browser-host"];
/// Linux keeps this many bytes of a thread name.
const OS_NAME_BYTES: usize = 15;
const HELPER_TABLE: &str = "### Helper threads";

fn crates_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// One source file with its comments and string contents blanked (newlines kept), and its string
/// literals with their byte offsets in the blanked text.
struct Source {
    path: PathBuf,
    code: String,
    literals: Vec<(usize, String)>,
}

impl Source {
    fn read(path: PathBuf) -> Self {
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("reads {}: {e}", path.display()));
        let (code, literals) = blank(&text);
        Self { path, code, literals }
    }

    fn line_of(&self, offset: usize) -> usize {
        self.code[..offset].matches('\n').count() + 1
    }
}

/// `text` with comments and the contents of string and char literals replaced by spaces.
fn blank(text: &str) -> (String, Vec<(usize, String)>) {
    let chars: Vec<char> = text.chars().collect();
    let mut code = String::with_capacity(text.len());
    let mut literals = Vec::new();
    let mut i = 0;
    let space = |c: char| if c == '\n' { '\n' } else { ' ' };
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        if c == '/' && next == Some('/') {
            while i < chars.len() && chars[i] != '\n' {
                code.push(' ');
                i += 1;
            }
        } else if c == '/' && next == Some('*') {
            let mut depth = 0;
            while i < chars.len() {
                if chars[i] == '/' && chars.get(i + 1) == Some(&'*') {
                    depth += 1;
                    code.push_str("  ");
                    i += 2;
                } else if chars[i] == '*' && chars.get(i + 1) == Some(&'/') {
                    depth -= 1;
                    code.push_str("  ");
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    code.push(space(chars[i]));
                    i += 1;
                }
            }
        } else if c == '"' || (c == 'r' && matches!(next, Some('"' | '#')) && raw_start(&chars, i))
        {
            let raw = c == 'r';
            let mut hashes = 0;
            if raw {
                code.push(' ');
                i += 1;
                while chars[i] == '#' {
                    hashes += 1;
                    code.push(' ');
                    i += 1;
                }
            }
            code.push('"');
            let start = code.len();
            i += 1;
            let mut literal = String::new();
            while i < chars.len() {
                let ch = chars[i];
                if !raw && ch == '\\' {
                    literal.push(ch);
                    if let Some(&escaped) = chars.get(i + 1) {
                        literal.push(escaped);
                        code.push(' ');
                        code.push(space(escaped));
                    }
                    i += 2;
                    continue;
                }
                if ch == '"' && (0..hashes).all(|h| chars.get(i + 1 + h) == Some(&'#')) {
                    break;
                }
                literal.push(ch);
                code.push(space(ch));
                i += 1;
            }
            literals.push((start, literal));
            code.push('"');
            for _ in 0..=hashes {
                i += 1;
            }
            code.extend(std::iter::repeat_n(' ', hashes));
        } else if c == '\'' && (next == Some('\\') || chars.get(i + 2) == Some(&'\'')) {
            // A char literal; `'a` alone is a lifetime.
            code.push(' ');
            i += 1;
            while i < chars.len() && chars[i] != '\'' {
                if chars[i] == '\\' {
                    code.push(' ');
                    i += 1;
                }
                code.push(' ');
                i += 1;
            }
            code.push(' ');
            i += 1;
        } else {
            code.push(c);
            i += 1;
        }
    }
    (code, literals)
}

/// Whether the `r` at `i` starts a raw string (`r"`, `r#"`), not an identifier ending in r.
fn raw_start(chars: &[char], i: usize) -> bool {
    let after_word = i > 0 && (chars[i - 1].is_alphanumeric() || chars[i - 1] == '_');
    let mut j = i + 1;
    while chars.get(j) == Some(&'#') {
        j += 1;
    }
    !after_word && chars.get(j) == Some(&'"')
}

/// A `#[cfg(test)]`, `#[cfg(all(test, ...))]` or `#[test]`-style attribute starts at `at`.
fn test_attribute(code: &str, at: usize) -> Option<usize> {
    let rest = &code[at..];
    ["#[cfg(test)]", "#[cfg(all(test", "#[test]", "#[tokio::test"]
        .iter()
        .find(|attribute| rest.starts_with(**attribute))
        .map(|_| rest.find(']').map_or(code.len(), |end| at + end + 1))
}

/// The byte ranges of `code` inside test items, and the modules declared test-only (`mod name;`).
fn test_items(code: &str) -> (Vec<(usize, usize)>, Vec<String>) {
    let bytes = code.as_bytes();
    let (mut ranges, mut modules) = (Vec::new(), Vec::new());
    let mut at = 0;
    while let Some(found) = code[at..].find("#[") {
        let start = at + found;
        let Some(mut i) = test_attribute(code, start) else {
            at = start + 2;
            continue;
        };
        let mut depth = 0usize;
        while i < bytes.len() {
            match bytes[i] {
                b'{' => depth += 1,
                b'}' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        break;
                    }
                }
                b';' if depth == 0 => {
                    let item = code[start..i].split_whitespace().collect::<Vec<_>>();
                    if let [.., "mod", name] = item.as_slice() {
                        modules.push((*name).to_owned());
                    }
                    break;
                }
                _ => {}
            }
            i += 1;
        }
        ranges.push((start, i));
        at = i.max(start + 2);
    }
    (ranges, modules)
}

/// The shipped crates' source files that are not test code, each with its test item ranges.
fn shipped_sources() -> Vec<(Source, Vec<(usize, usize)>)> {
    let mut files = Vec::new();
    for name in SHIPPED {
        collect(&crates_dir().join(name).join("src"), &mut files);
    }
    files.sort();
    let mut sources: Vec<(Source, Vec<(usize, usize)>)> = Vec::new();
    let mut test_only: Vec<PathBuf> = Vec::new();
    for path in files {
        let source = Source::read(path);
        let (ranges, modules) = test_items(&source.code);
        let parent = source.path.parent().expect("a source file has a directory");
        let stem = source.path.file_stem().and_then(|s| s.to_str()).unwrap_or_default();
        let dir = if matches!(stem, "mod" | "lib" | "main") {
            parent.to_path_buf()
        } else {
            parent.join(stem)
        };
        for module in modules {
            test_only.push(dir.join(format!("{module}.rs")));
            test_only.push(dir.join(&module));
        }
        sources.push((source, ranges));
    }
    sources.retain(|(source, _)| !test_only.iter().any(|t| source.path.starts_with(t)));
    sources
}

fn collect(dir: &Path, files: &mut Vec<PathBuf>) {
    let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("reads {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.expect("a directory entry").path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned();
        if path.is_dir() {
            if name != "tests" {
                collect(&path, files);
            }
        } else if name.ends_with(".rs") && !name.contains("tests") {
            files.push(path);
        }
    }
}

fn in_ranges(ranges: &[(usize, usize)], offset: usize) -> bool {
    ranges.iter().any(|&(start, end)| (start..=end).contains(&offset))
}

/// Every unnamed thread start (`thread::spawn(`, not `echo_thread::spawn(`) outside test code.
fn unnamed_spawns(sources: &[(Source, Vec<(usize, usize)>)]) -> Vec<String> {
    let mut hits = Vec::new();
    for (source, ranges) in sources {
        for (offset, _) in source.code.match_indices("thread::spawn(") {
            let word_before = source.code[..offset]
                .chars()
                .next_back()
                .is_some_and(|c| c.is_alphanumeric() || c == '_');
            if !word_before && !in_ranges(ranges, offset) {
                hits.push(format!("{}:{}", source.path.display(), source.line_of(offset)));
            }
        }
    }
    hits
}

/// The string literal passed as a thread name outside test code: `.name("x"`, or the first argument
/// of `spawn("x"` / `spawn_with_stack("x"` (cmux_threads, echo_thread), by literal.
fn thread_name_literals(sources: &[(Source, Vec<(usize, usize)>)]) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for (source, ranges) in sources {
        for (offset, literal) in &source.literals {
            let before = source.code[..offset - 1].trim_end();
            let named =
                [".name(", "spawn(", "spawn_with_stack("].iter().any(|call| before.ends_with(call));
            if named && !in_ranges(ranges, *offset) {
                names.insert(literal.clone());
            }
        }
    }
    names
}

/// The files of the shipped crates whose non-test code has the string literal `text`.
fn files_with_literal(sources: &[(Source, Vec<(usize, usize)>)], text: &str) -> Vec<String> {
    sources
        .iter()
        .filter(|(source, ranges)| {
            source
                .literals
                .iter()
                .any(|(offset, literal)| literal == text && !in_ranges(ranges, *offset))
        })
        .map(|(source, _)| source.path.display().to_string())
        .collect()
}

/// The backticked first cells of the doc's "Helper threads" table.
fn helper_table() -> Vec<String> {
    let path = crates_dir().join("../../plans/cmux-next/threading-model.md");
    let doc =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reads {}: {e}", path.display()));
    let start = doc
        .find(HELPER_TABLE)
        .unwrap_or_else(|| panic!("{} has no {HELPER_TABLE:?}", path.display()));
    let section = &doc[start + HELPER_TABLE.len()..];
    let section = &section[..section.find("\n#").unwrap_or(section.len())];
    let names: Vec<String> = section
        .lines()
        .filter_map(|line| line.strip_prefix("| `"))
        .filter_map(|cell| cell.split_once('`'))
        .map(|(name, _)| name.to_owned())
        .collect();
    assert!(!names.is_empty(), "{HELPER_TABLE} in {} lists no thread", path.display());
    names
}

#[test]
fn shipped_crates_start_no_unnamed_thread() {
    let sources = shipped_sources();
    assert!(sources.len() > 100, "found only {} source files", sources.len());
    let hits = unnamed_spawns(&sources);
    assert!(
        hits.is_empty(),
        "name these threads with std::thread::Builder::new().name(..) or cmux_threads::spawn and \
         list them in plans/cmux-next/threading-model.md:\n{}",
        hits.join("\n")
    );
}

#[test]
fn helper_thread_names_are_short_unique_and_used() {
    let listed = helper_table();
    let sources = shipped_sources();
    let names = thread_name_literals(&sources);
    let mut seen = BTreeSet::new();
    for name in &listed {
        assert!(seen.insert(name.as_str()), "{name} is listed twice in {HELPER_TABLE}");
        assert!(
            name.len() <= OS_NAME_BYTES,
            "{name} is {} bytes; the OS keeps {OS_NAME_BYTES}",
            name.len()
        );
        let files = files_with_literal(&sources, name);
        assert_eq!(
            files.len(),
            1,
            "{name}: one file of shipped code names the thread, found {files:?}"
        );
        let clashes: Vec<&String> = names
            .iter()
            .filter(|other| *other != name && other.len() > OS_NAME_BYTES)
            .filter(|other| other.as_bytes()[..OS_NAME_BYTES] == *name.as_bytes())
            .collect();
        assert!(
            clashes.is_empty(),
            "{name} reads the same as {clashes:?} once cut to {OS_NAME_BYTES} bytes"
        );
    }
}

#[test]
fn the_scanner_skips_comments_strings_and_test_items() {
    let (code, literals) = blank(
        "let a = \"thread::spawn(\"; // thread::spawn(\nfn f<'a>(c: char) { c == '{' }\n\
         #[cfg(test)]\nmod tests { fn t() { std::thread::spawn(|| {}); } }\n#[cfg(all(test, unix))]\nmod pty;\n\
         std::thread::Builder::new().name(\"x-y\".into());\n",
    );
    assert_eq!(
        code.matches("thread::spawn(").count(),
        1,
        "only the call in the test module is code"
    );
    assert_eq!(
        literals.iter().map(|(_, l)| l.as_str()).collect::<Vec<_>>(),
        ["thread::spawn(", "x-y"]
    );
    let (ranges, modules) = test_items(&code);
    assert_eq!(modules, ["pty"]);
    let spawn = code.find("thread::spawn(").expect("the test module's spawn");
    assert!(in_ranges(&ranges, spawn));
    assert!(!in_ranges(&ranges, code.find(".name(").expect("the named builder")));
}
