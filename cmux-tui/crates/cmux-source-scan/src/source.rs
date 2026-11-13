//! What the checks share: the Rust files of a tree, paths and line numbers.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use proc_macro2::{Span, TokenStream, TokenTree};
use syn::parse::ParseStream;
use syn::parse::discouraged::Speculative;
use syn::visit::Visit;
use syn::{Block, Expr};

/// A directory or file of the tree the scan could not read. A scan that skipped it would read as
/// a clean one, so every reader here returns this, naming the path, and the scan fails.
#[derive(Debug)]
pub struct ReadError {
    pub path: PathBuf,
    pub error: io::Error,
}

impl ReadError {
    pub fn new(path: &Path, error: io::Error) -> ReadError {
        ReadError { path: path.to_path_buf(), error }
    }
}

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: cannot read: {}", self.path.display(), self.error)
    }
}

impl std::error::Error for ReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.error)
    }
}

/// The text of the source file at `path`.
pub fn read_source(path: &Path) -> Result<String, ReadError> {
    std::fs::read_to_string(path).map_err(|e| ReadError::new(path, e))
}

/// The `.rs` files under `dir` (or `dir` itself when it is one), sorted, leaving out `target`
/// directories. Err names the first path it could not read: a missing `dir`, a directory it
/// cannot list, an entry it cannot stat (a dangling symlink too).
pub fn rust_files(dir: &Path) -> Result<Vec<PathBuf>, ReadError> {
    if std::fs::metadata(dir).map_err(|e| ReadError::new(dir, e))?.is_file() {
        return Ok(vec![dir.to_path_buf()]);
    }
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(at) = stack.pop() {
        let entries = std::fs::read_dir(&at).map_err(|e| ReadError::new(&at, e))?;
        for entry in entries {
            let path = entry.map_err(|e| ReadError::new(&at, e))?.path();
            // Follows a symlink, as the walk always has.
            let is_dir = std::fs::metadata(&path).map_err(|e| ReadError::new(&path, e))?.is_dir();
            if is_dir {
                if path.file_name().is_some_and(|n| n != "target") {
                    stack.push(path);
                }
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }
    out.sort();
    Ok(out)
}

/// `path` from `root`, with `/` between its parts (`path` as given when it is not under `root`).
pub fn rel_path(root: &Path, path: &Path) -> String {
    let rel = path.strip_prefix(root).unwrap_or(path);
    rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/")
}

/// The 1-based line a span starts on.
pub fn line_of(span: Span) -> usize {
    span.start().line
}

/// Whether `tokens` hold the identifier `name` at any depth.
pub fn has_ident(tokens: TokenStream, name: &str) -> bool {
    tokens.into_iter().any(|tree| match tree {
        TokenTree::Ident(ident) => ident == name,
        TokenTree::Group(group) => has_ident(group.stream(), name),
        _ => false,
    })
}

/// The source text of `span` in `lines` (the file's lines), its whitespace folded.
pub fn snippet(lines: &[&str], span: Span) -> String {
    let (start, end) = (span.start(), span.end());
    let mut text = String::new();
    for line in start.line..=end.line {
        let Some(row) = lines.get(line.wrapping_sub(1)) else {
            continue;
        };
        let from = if line == start.line { start.column } else { 0 };
        let to = if line == end.line { end.column } else { usize::MAX };
        text.extend(row.chars().skip(from).take(to.saturating_sub(from)));
        text.push(' ');
    }
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Comma-separated expressions, as many as parse; the rest of the input is skipped.
pub fn lenient_exprs(input: ParseStream) -> syn::Result<Vec<Expr>> {
    let mut out = Vec::new();
    while !input.is_empty() {
        let fork = input.fork();
        let Ok(e) = fork.parse::<Expr>() else {
            break;
        };
        input.advance_to(&fork);
        out.push(e);
        if input.parse::<syn::Token![,]>().is_err() {
            break;
        }
    }
    let _rest: TokenStream = input.parse()?;
    Ok(out)
}

/// Visit the code in a macro's body with `v`: items (`mod_tests! { #[test] fn .. }`), else
/// statements (a `tokio::select!`-style block, a user macro over `let`s), else comma-separated
/// expressions (`dbg!({ .. })`, `vec![..]`, `format!(.., x = ..)`, `matches!(x, ..)`'s `x`). A
/// body that parses as none of them (`macro_rules!` arms) is skipped. Every visitor of a body
/// goes through here, so a wrapper macro hides from none of them what it holds.
pub fn visit_macro_body<V>(v: &mut V, mac: &syn::Macro)
where
    V: for<'ast> Visit<'ast>,
{
    if let Ok(file) = syn::parse2::<syn::File>(mac.tokens.clone()) {
        v.visit_file(&file);
    } else if let Ok(stmts) = mac.parse_body_with(Block::parse_within) {
        for stmt in &stmts {
            v.visit_stmt(stmt);
        }
    } else if let Ok(exprs) = mac.parse_body_with(lenient_exprs) {
        for e in &exprs {
            v.visit_expr(e);
        }
    }
}
