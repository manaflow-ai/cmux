//! Name resolution the scan can do lexically: a file's `use` items map a
//! short name to its full path, and a few expression shapes are peeled.

use std::collections::HashMap;

use quote::ToTokens;
use syn::visit::Visit;
use syn::{Expr, Path, UseTree};

/// A source position, 1-based line and 0-based column (proc-macro2's).
pub type Pos = (usize, usize);

pub fn pos_of(span: proc_macro2::Span) -> Pos {
    let start = span.start();
    (start.line, start.column)
}

/// Every `use` in a file, flattened: `fs` -> `std::fs`, `Command` ->
/// `std::process::Command`. Scopes are merged (the last import of a name
/// wins), which is the lexical approximation the tool documents.
#[derive(Debug, Default)]
pub struct UseMap {
    names: HashMap<String, String>,
}

impl UseMap {
    pub fn of_file(file: &syn::File) -> UseMap {
        let mut collector = UseCollector::default();
        collector.visit_file(file);
        UseMap { names: collector.names }
    }

    /// The full path of `path` with its first segment resolved through the
    /// imports; generic arguments are dropped.
    pub fn resolve(&self, path: &Path) -> String {
        let segments: Vec<String> = path.segments.iter().map(|s| s.ident.to_string()).collect();
        self.resolve_segments(&segments)
    }

    pub fn resolve_segments(&self, segments: &[String]) -> String {
        let Some((first, rest)) = segments.split_first() else {
            return String::new();
        };
        let head = self.names.get(first).cloned().unwrap_or_else(|| first.clone());
        let mut full = head;
        for segment in rest {
            full.push_str("::");
            full.push_str(segment);
        }
        full
    }
}

#[derive(Default)]
struct UseCollector {
    names: HashMap<String, String>,
}

impl UseCollector {
    fn add(&mut self, prefix: &[String], tree: &UseTree) {
        match tree {
            UseTree::Path(p) => {
                let mut next = prefix.to_vec();
                next.push(p.ident.to_string());
                self.add(&next, &p.tree);
            }
            UseTree::Name(n) => {
                let name = n.ident.to_string();
                if name == "self" {
                    if let Some(last) = prefix.last() {
                        self.names.insert(last.clone(), prefix.join("::"));
                    }
                } else {
                    let mut full = prefix.to_vec();
                    full.push(name.clone());
                    self.names.insert(name, full.join("::"));
                }
            }
            UseTree::Rename(r) => {
                let mut full = prefix.to_vec();
                if r.ident != "self" {
                    full.push(r.ident.to_string());
                }
                self.names.insert(r.rename.to_string(), full.join("::"));
            }
            UseTree::Group(g) => {
                for item in &g.items {
                    self.add(prefix, item);
                }
            }
            UseTree::Glob(_) => {}
        }
    }
}

impl<'ast> Visit<'ast> for UseCollector {
    fn visit_item_use(&mut self, item: &'ast syn::ItemUse) {
        self.add(&[], &item.tree);
    }
}

/// `(e)` -> `e`.
pub fn strip_parens(mut expr: &Expr) -> &Expr {
    while let Expr::Paren(p) = expr {
        expr = &p.expr;
    }
    expr
}

/// The callee path of a call `path(args)`.
pub fn call_path(expr: &Expr) -> Option<&Path> {
    match strip_parens(expr) {
        Expr::Path(p) => Some(&p.path),
        _ => None,
    }
}

/// The single identifier an expression names (`x`, `(x)`), if any.
pub fn ident_of(expr: &Expr) -> Option<String> {
    match strip_parens(expr) {
        Expr::Path(p) if p.qself.is_none() => p.path.get_ident().map(|i| i.to_string()),
        Expr::Reference(r) => ident_of(&r.expr),
        _ => None,
    }
}

/// The source text of a node, whitespace-normalized and cut at 120 characters.
pub fn snippet<T: ToTokens>(node: &T) -> String {
    let text = node.to_token_stream().to_string();
    let mut out = String::new();
    for word in text.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
    }
    match out.char_indices().nth(120) {
        Some((cut, _)) => format!("{}...", &out[..cut]),
        None => out,
    }
}

/// The last segment of a macro path (`tokio::select` -> `select`).
pub fn macro_name(mac: &syn::Macro) -> String {
    mac.path.segments.last().map(|s| s.ident.to_string()).unwrap_or_default()
}
