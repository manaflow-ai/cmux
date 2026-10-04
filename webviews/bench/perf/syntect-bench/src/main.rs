//! Usage: syntect-bench <patch>... Splits each patch into per-file new-side line lists (context +
//! additions, like the viewer's additionLines), then highlights every file with syntect and with
//! tree-sitter-highlight, single-threaded and with rayon over files. Prints JSON.
use rayon::prelude::*;
use std::time::Instant;
use syntect::parsing::{ParseState, ScopeStack, SyntaxSet};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

struct File {
    ext: String,
    text: String,
    lines: usize,
}

fn split(patch: &str) -> Vec<File> {
    let mut files = Vec::new();
    let mut current: Option<File> = None;
    for line in patch.split_inclusive('\n') {
        if let Some(rest) = line.strip_prefix("+++ b/") {
            if let Some(file) = current.take() {
                files.push(file);
            }
            let path = rest.trim_end();
            let ext = path.rsplit('.').next().unwrap_or("").to_string();
            current = Some(File { ext, text: String::new(), lines: 0 });
        } else if let Some(file) = current.as_mut() {
            if line.starts_with("+++") || line.starts_with("---") || line.starts_with("@@") {
                continue;
            }
            if let Some(body) = line.strip_prefix('+').or_else(|| line.strip_prefix(' ')) {
                file.text.push_str(body);
                file.lines += 1;
            }
        }
    }
    files.extend(current);
    files
}

fn syntect_one(set: &SyntaxSet, file: &File) -> usize {
    let token = match file.ext.as_str() {
        "ts" | "tsx" | "js" => "js",
        "sh" => "sh",
        other => other,
    };
    let Some(syntax) = set.find_syntax_by_extension(token) else { return 0 };
    let mut state = ParseState::new(syntax);
    let mut stack = ScopeStack::new();
    let mut ops = 0;
    for line in file.text.split_inclusive('\n') {
        if line.len() > 1000 {
            continue;
        }
        if let Ok(changes) = state.parse_line(line, set) {
            ops += changes.len();
            for (_, op) in changes {
                let _ = stack.apply(&op);
            }
        }
    }
    ops
}

fn ts_config(ext: &str) -> Option<HighlightConfiguration> {
    let (language, highlights) = match ext {
        "rs" => (tree_sitter_rust::LANGUAGE.into(), tree_sitter_rust::HIGHLIGHTS_QUERY),
        "py" => (tree_sitter_python::LANGUAGE.into(), tree_sitter_python::HIGHLIGHTS_QUERY),
        "go" => (tree_sitter_go::LANGUAGE.into(), tree_sitter_go::HIGHLIGHTS_QUERY),
        "ts" | "tsx" | "js" => (tree_sitter_javascript::LANGUAGE.into(), tree_sitter_javascript::HIGHLIGHT_QUERY),
        _ => return None,
    };
    let mut config = HighlightConfiguration::new(language, ext, highlights, "", "").ok()?;
    let names = ["keyword", "function", "type", "string", "number", "comment", "variable", "operator", "property", "punctuation"];
    config.configure(&names);
    Some(config)
}

fn tree_sitter_one(file: &File) -> usize {
    let Some(config) = ts_config(&file.ext) else { return 0 };
    let mut highlighter = Highlighter::new();
    let Ok(events) = highlighter.highlight(&config, file.text.as_bytes(), None, |_| None) else { return 0 };
    events.filter(|event| matches!(event, Ok(HighlightEvent::HighlightStart(_)))).count()
}

fn main() {
    let set = SyntaxSet::load_defaults_newlines();
    for path in std::env::args().skip(1) {
        let patch = std::fs::read_to_string(&path).unwrap();
        let files = split(&patch);
        let syn_files: Vec<&File> = files.iter().filter(|f| matches!(f.ext.as_str(), "rs" | "py" | "go" | "ts" | "tsx" | "js" | "css" | "md" | "json" | "sh")).collect();
        let syn_lines: usize = syn_files.iter().map(|f| f.lines).sum();
        let ts_files: Vec<&File> = files.iter().filter(|f| ts_config(&f.ext).is_some()).collect();
        let ts_lines: usize = ts_files.iter().map(|f| f.lines).sum();

        let start = Instant::now();
        let ops: usize = syn_files.iter().map(|f| syntect_one(&set, f)).sum();
        let syn_single = start.elapsed().as_secs_f64();
        let start = Instant::now();
        let _: usize = syn_files.par_iter().map(|f| syntect_one(&set, f)).sum();
        let syn_par = start.elapsed().as_secs_f64();

        let start = Instant::now();
        let spans: usize = ts_files.iter().map(|f| tree_sitter_one(f)).sum();
        let ts_single = start.elapsed().as_secs_f64();
        let start = Instant::now();
        let _: usize = ts_files.par_iter().map(|f| tree_sitter_one(f)).sum();
        let ts_par = start.elapsed().as_secs_f64();

        println!(
            "{{\"patch\":\"{path}\",\"syntectFiles\":{},\"syntectLines\":{syn_lines},\"syntectOps\":{ops},\"syntectSingleMs\":{:.0},\"syntectLinesPerSec\":{:.0},\"syntectParallelMs\":{:.0},\"treeSitterFiles\":{},\"treeSitterLines\":{ts_lines},\"treeSitterSpans\":{spans},\"treeSitterSingleMs\":{:.0},\"treeSitterLinesPerSec\":{:.0},\"treeSitterParallelMs\":{:.0},\"threads\":{}}}",
            syn_files.len(), syn_single * 1000.0, syn_lines as f64 / syn_single, syn_par * 1000.0,
            ts_files.len(), ts_single * 1000.0, ts_lines as f64 / ts_single, ts_par * 1000.0,
            rayon::current_num_threads()
        );
    }
}
