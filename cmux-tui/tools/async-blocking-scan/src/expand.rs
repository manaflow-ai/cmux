//! Macro bodies become plain calls before the scan, so calls inside
//! `format!(...)`, `join!(...)` or the arm bodies of `select! { ... }` are
//! seen. `name!(a, b)` becomes the call `__macro_name(a, b)`; a body that is
//! not a comma list keeps only its `{ ... }` groups that parse as blocks.

use proc_macro2::{Delimiter, Ident, Span, TokenStream, TokenTree};
use syn::parse::Parser;
use syn::punctuated::Punctuated;
use syn::visit_mut::{self, VisitMut};
use syn::{Block, Expr, ExprBlock, ExprCall, ExprPath, Macro, Stmt, Token};

use crate::resolve::macro_name;

/// The callee prefix of an expanded macro.
pub const MACRO_PREFIX: &str = "__macro_";

/// Macros whose bodies are not code that runs here.
const OPAQUE: [&str; 5] = ["macro_rules", "quote", "quote_spanned", "parse_quote", "include_str"];

pub fn expand_file(file: &mut syn::File) {
    Expander.visit_file_mut(file);
}

/// The macro name of an expanded call's callee (`__macro_select` -> `select`).
pub fn expanded_macro(path: &str) -> Option<&str> {
    path.strip_prefix(MACRO_PREFIX)
}

struct Expander;

impl VisitMut for Expander {
    fn visit_expr_mut(&mut self, expr: &mut Expr) {
        if let Expr::Macro(m) = expr
            && let Some(call) = expand(&m.mac)
        {
            *expr = call;
        }
        visit_mut::visit_expr_mut(self, expr);
    }

    fn visit_stmt_mut(&mut self, stmt: &mut Stmt) {
        if let Stmt::Macro(m) = stmt
            && let Some(call) = expand(&m.mac)
        {
            let semi = m.semi_token.take();
            *stmt = Stmt::Expr(call, semi);
        }
        visit_mut::visit_stmt_mut(self, stmt);
    }
}

fn expand(mac: &Macro) -> Option<Expr> {
    let name = macro_name(mac);
    if OPAQUE.contains(&name.as_str()) {
        return None;
    }
    let span = mac.path.segments.last().map_or_else(Span::call_site, |s| s.ident.span());
    let args = match Punctuated::<Expr, Token![,]>::parse_terminated.parse2(mac.tokens.clone()) {
        Ok(list) => list,
        Err(_) => brace_blocks(mac.tokens.clone()),
    };
    if args.is_empty() {
        return None;
    }
    let func = Expr::Path(ExprPath {
        attrs: Vec::new(),
        qself: None,
        path: Ident::new(&format!("{MACRO_PREFIX}{name}"), span).into(),
    });
    Some(Expr::Call(ExprCall {
        attrs: Vec::new(),
        func: Box::new(func),
        paren_token: Default::default(),
        args,
    }))
}

/// The top-level `{ ... }` groups of a macro body that parse as blocks.
fn brace_blocks(tokens: TokenStream) -> Punctuated<Expr, Token![,]> {
    let mut blocks = Punctuated::new();
    for tree in tokens {
        let TokenTree::Group(group) = tree else { continue };
        if group.delimiter() != Delimiter::Brace {
            continue;
        }
        let Ok(stmts) = Block::parse_within.parse2(group.stream()) else { continue };
        let block = Block { brace_token: syn::token::Brace { span: group.delim_span() }, stmts };
        blocks.push(Expr::Block(ExprBlock { attrs: Vec::new(), label: None, block }));
    }
    blocks
}
