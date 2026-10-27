//! Spawned processes: finding a `spawn()` through `?` and Result plumbing,
//! and following the Child's binding to a wait, a hand-off or nothing.
//!
//! A Child that is dropped without a wait stays a zombie until the parent
//! exits (std) or is killed only with `kill_on_drop` (tokio). Chromium keeps
//! the same rule in base/process/kill.h: EnsureProcessTerminated reaps every
//! child it does not wait for.

use std::collections::HashSet;

use syn::visit::{self, Visit};
use syn::{Block, Expr, Pat};

use crate::config::Config;
use crate::resolve::{Pos, UseMap, call_path, ident_of, pos_of, strip_parens};

/// A process start found in an expression.
pub struct Spawn {
    pub pos: Pos,
    /// `kill_on_drop` appears in the builder chain.
    pub kill_in_chain: bool,
    /// The variable the builder chain starts from (`cmd` in `cmd.spawn()`).
    pub command: Option<String>,
}

/// The process start an expression reduces to through `?`, parentheses and
/// passthrough methods (`context`, `map_err`, ...).
pub fn find_spawn(cfg: &Config, uses: &UseMap, expr: &Expr) -> Option<Spawn> {
    match strip_parens(expr) {
        Expr::Try(t) => find_spawn(cfg, uses, &t.expr),
        Expr::Await(a) => find_spawn(cfg, uses, &a.base),
        Expr::MethodCall(m) => {
            let name = m.method.to_string();
            if cfg.is_child_spawn_method(&name, m.args.len()) {
                let (kill_in_chain, command) = chain_facts(cfg, &m.receiver);
                Some(Spawn { pos: pos_of(m.method.span()), kill_in_chain, command })
            } else if cfg.is_passthrough(&name) {
                find_spawn(cfg, uses, &m.receiver)
            } else {
                None
            }
        }
        Expr::Call(c) => {
            let path = uses.resolve(call_path(&c.func)?);
            if !cfg.child.spawn_functions.contains(&path) {
                return None;
            }
            let command = c.args.first().and_then(ident_of);
            let pos = c.func_ident_pos();
            Some(Spawn { pos, kill_in_chain: false, command })
        }
        _ => None,
    }
}

trait CallPos {
    fn func_ident_pos(&self) -> Pos;
}

impl CallPos for syn::ExprCall {
    fn func_ident_pos(&self) -> Pos {
        call_path(&self.func)
            .and_then(|p| p.segments.last())
            .map_or_else(|| pos_of(self.paren_token.span.join()), |s| pos_of(s.ident.span()))
    }
}

/// Whether a builder chain names `kill_on_drop`, and the variable it starts from.
fn chain_facts(cfg: &Config, mut expr: &Expr) -> (bool, Option<String>) {
    let mut kill = false;
    loop {
        match strip_parens(expr) {
            Expr::MethodCall(m) => {
                kill |= cfg.child.drop_kills.iter().any(|k| m.method == k);
                expr = &m.receiver;
            }
            Expr::Reference(r) => expr = &r.expr,
            other => return (kill, ident_of(other)),
        }
    }
}

/// Whether `cmd.kill_on_drop(..)` is called anywhere in the body.
pub fn command_kills_on_drop(cfg: &Config, body: &Block, command: &str) -> bool {
    struct Finder<'c> {
        cfg: &'c Config,
        command: &'c str,
        found: bool,
    }
    impl<'ast> Visit<'ast> for Finder<'_> {
        fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
            if self.cfg.child.drop_kills.iter().any(|k| m.method == k) {
                let (_, root) = chain_facts(self.cfg, &m.receiver);
                self.found |= root.as_deref() == Some(self.command);
            }
            visit::visit_expr_method_call(self, m);
        }
    }
    let mut finder = Finder { cfg, command, found: false };
    finder.visit_block(body);
    finder.found
}

/// The names a pattern binds, except those inside `Err(..)`.
pub fn pat_idents(pat: &Pat, out: &mut Vec<String>) {
    match pat {
        Pat::Ident(p) => {
            out.push(p.ident.to_string());
            if let Some((_, sub)) = &p.subpat {
                pat_idents(sub, out);
            }
        }
        Pat::TupleStruct(t) => {
            if t.path.segments.last().is_some_and(|s| s.ident == "Err") {
                return;
            }
            t.elems.iter().for_each(|p| pat_idents(p, out));
        }
        Pat::Tuple(t) => t.elems.iter().for_each(|p| pat_idents(p, out)),
        Pat::Struct(s) => s.fields.iter().for_each(|f| pat_idents(&f.pat, out)),
        Pat::Reference(r) => pat_idents(&r.pat, out),
        Pat::Type(t) => pat_idents(&t.pat, out),
        Pat::Or(o) => o.cases.iter().for_each(|p| pat_idents(p, out)),
        Pat::Slice(s) => s.elems.iter().for_each(|p| pat_idents(p, out)),
        Pat::Paren(p) => pat_idents(&p.pat, out),
        _ => {}
    }
}

/// How the Child bound to `names` is used after `after` in `body`.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Fate {
    pub reaped: bool,
    /// Moved or lent somewhere the scan cannot follow (a call, a field, a return).
    pub handed_off: bool,
}

pub fn fate(cfg: &Config, body: &Block, names: &[String], after: Pos) -> Fate {
    let names: HashSet<&str> = names.iter().map(String::as_str).collect();
    let mut tracker = Tracker { cfg, names, after, fate: Fate::default() };
    tracker.visit_block(body);
    tracker.fate
}

struct Tracker<'c> {
    cfg: &'c Config,
    names: HashSet<&'c str>,
    after: Pos,
    fate: Fate,
}

impl Tracker<'_> {
    /// The tracked name an expression is, when it appears after the spawn.
    fn tracked(&self, expr: &Expr) -> bool {
        let Expr::Path(p) = strip_parens(expr) else { return false };
        let Some(ident) = p.path.get_ident() else { return false };
        self.names.contains(ident.to_string().as_str()) && pos_of(ident.span()) > self.after
    }
}

impl<'ast> Visit<'ast> for Tracker<'_> {
    fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
        if self.tracked(&m.receiver) {
            self.fate.reaped |= self.cfg.is_reap_method(&m.method.to_string());
            m.args.iter().for_each(|a| self.visit_expr(a));
            return;
        }
        visit::visit_expr_method_call(self, m);
    }

    fn visit_expr_await(&mut self, a: &'ast syn::ExprAwait) {
        if let Expr::MethodCall(m) = strip_parens(&a.base)
            && self.tracked(&m.receiver)
            && self.cfg.child.awaited_reap_methods.iter().any(|r| m.method == r)
        {
            self.fate.reaped = true;
        }
        visit::visit_expr_await(self, a);
    }

    fn visit_expr_field(&mut self, f: &'ast syn::ExprField) {
        if !self.tracked(&f.base) {
            visit::visit_expr_field(self, f);
        }
    }

    fn visit_expr_call(&mut self, c: &'ast syn::ExprCall) {
        let is_drop =
            call_path(&c.func).and_then(|p| p.segments.last()).is_some_and(|s| s.ident == "drop");
        if is_drop && c.args.len() == 1 && c.args.first().is_some_and(|a| self.tracked(a)) {
            return;
        }
        visit::visit_expr_call(self, c);
    }

    fn visit_expr_path(&mut self, p: &'ast syn::ExprPath) {
        if let Some(ident) = p.path.get_ident()
            && self.names.contains(ident.to_string().as_str())
            && pos_of(ident.span()) > self.after
        {
            self.fate.handed_off = true;
        }
    }
}
