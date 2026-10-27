//! A std (or parking_lot) lock guard held across an `.await` inside one
//! block: a `let` guard still alive at a later statement's await, or a lock
//! temporary that lives to the end of a statement that awaits.
//!
//! Temporaries follow Rust's drop scopes: a `match`, `if let`, `while let` or
//! `for` head keeps its temporaries for the whole construct; a plain `if` or
//! `while` condition, a block and a match arm end theirs.
//!
//! A lock call handed directly to another call (`timeout(d, m.lock())`,
//! `join!(a.lock(), b.lock())`) is a future the callee awaits, so its lock is
//! an async one (tokio's): the same reading as an `async_twin` method.

use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Block, Expr, Pat, Stmt};

use crate::config::Config;
use crate::expand::expanded_macro;
use crate::resolve::{Pos, call_path, ident_of, pos_of, snippet, strip_parens};

/// One guard held across an await.
pub struct GuardHit {
    pub lock: Pos,
    pub awaited_at: Pos,
    /// The binding, or `None` for a temporary.
    pub guard: Option<String>,
    pub snippet: String,
    /// The first line of the statement that takes the lock, where an allow
    /// comment for it goes.
    pub stmt_line: usize,
}

struct LiveGuard {
    name: String,
    lock: Pos,
    snippet: String,
    stmt_line: usize,
}

pub fn guards_over_await(cfg: &Config, block: &Block) -> Vec<GuardHit> {
    let mut hits = Vec::new();
    let mut live: Vec<LiveGuard> = Vec::new();
    for stmt in &block.stmts {
        let stmt_line = pos_of(stmt.span()).0;
        let awaits = await_points(cfg, stmt);
        live.retain(|guard| {
            let dropped_at = drop_point(stmt, &guard.name);
            let held = awaits.iter().find(|a| dropped_at.is_none_or(|d| **a < d));
            if let Some(at) = held {
                hits.push(GuardHit {
                    lock: guard.lock,
                    awaited_at: *at,
                    guard: Some(guard.name.clone()),
                    snippet: guard.snippet.clone(),
                    stmt_line: guard.stmt_line,
                });
                return false;
            }
            dropped_at.is_none()
        });
        let new_guard = guard_binding(cfg, stmt);
        if new_guard.is_none() {
            for (lock, text) in temporary_locks(cfg, stmt) {
                if let Some(at) = awaits.iter().find(|a| **a > lock) {
                    hits.push(GuardHit {
                        lock,
                        awaited_at: *at,
                        guard: None,
                        snippet: text,
                        stmt_line,
                    });
                }
            }
        }
        live.extend(new_guard);
    }
    hits
}

/// `let g = m.lock().unwrap();` binds a guard; `let _ = ...` does not.
fn guard_binding(cfg: &Config, stmt: &Stmt) -> Option<LiveGuard> {
    let Stmt::Local(local) = stmt else { return None };
    let name = match &local.pat {
        Pat::Ident(p) => p.ident.to_string(),
        Pat::Type(t) => match &*t.pat {
            Pat::Ident(p) => p.ident.to_string(),
            _ => return None,
        },
        _ => return None,
    };
    let init = local.init.as_ref()?;
    let lock = guard_call(cfg, &init.expr)?;
    Some(LiveGuard { name, lock, snippet: snippet(&init.expr), stmt_line: pos_of(stmt.span()).0 })
}

/// The position of the unawaited lock call an expression reduces to through
/// `?` and passthrough methods.
fn guard_call(cfg: &Config, expr: &Expr) -> Option<Pos> {
    match strip_parens(expr) {
        Expr::Try(t) => guard_call(cfg, &t.expr),
        Expr::MethodCall(m) => {
            let name = m.method.to_string();
            if cfg.is_guard_method(&name, m.args.len()) {
                Some(pos_of(m.method.span()))
            } else if cfg.is_passthrough(&name) {
                guard_call(cfg, &m.receiver)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// Await points of a statement outside nested closures, async blocks and
/// items: each `.await` and each future macro (`select!`, `join!`).
fn await_points(cfg: &Config, stmt: &Stmt) -> Vec<Pos> {
    let mut finder = AwaitFinder { cfg, points: Vec::new() };
    finder.visit_stmt(stmt);
    finder.points.sort_unstable();
    finder.points
}

struct AwaitFinder<'c> {
    cfg: &'c Config,
    points: Vec<Pos>,
}

impl<'ast> Visit<'ast> for AwaitFinder<'_> {
    fn visit_expr_await(&mut self, e: &'ast syn::ExprAwait) {
        visit::visit_expr_await(self, e);
        self.points.push(pos_of(e.await_token.span));
    }

    fn visit_expr_call(&mut self, e: &'ast syn::ExprCall) {
        if let Some(path) = call_path(&e.func)
            && let Some(ident) = path.get_ident()
            && expanded_macro(&ident.to_string()).is_some_and(|m| self.cfg.is_future_macro(m))
        {
            self.points.push(pos_of(ident.span()));
        }
        visit::visit_expr_call(self, e);
    }

    fn visit_expr_closure(&mut self, _: &'ast syn::ExprClosure) {}
    fn visit_expr_async(&mut self, _: &'ast syn::ExprAsync) {}
    fn visit_item(&mut self, _: &'ast syn::Item) {}
}

/// Where `drop(name)` (or `mem::drop(name)`) runs in a statement.
fn drop_point(stmt: &Stmt, name: &str) -> Option<Pos> {
    let mut finder = DropFinder { name, at: None };
    finder.visit_stmt(stmt);
    finder.at
}

struct DropFinder<'n> {
    name: &'n str,
    at: Option<Pos>,
}

impl<'ast> Visit<'ast> for DropFinder<'_> {
    fn visit_expr_call(&mut self, e: &'ast syn::ExprCall) {
        let is_drop =
            call_path(&e.func).and_then(|p| p.segments.last()).is_some_and(|s| s.ident == "drop");
        if is_drop
            && e.args.len() == 1
            && e.args.first().and_then(ident_of).as_deref() == Some(self.name)
        {
            self.at = self.at.or(Some(pos_of(e.paren_token.span.join())));
        }
        visit::visit_expr_call(self, e);
    }

    fn visit_expr_closure(&mut self, _: &'ast syn::ExprClosure) {}
    fn visit_item(&mut self, _: &'ast syn::Item) {}
}

/// Unawaited lock calls whose temporary guard lives to the end of the statement.
fn temporary_locks(cfg: &Config, stmt: &Stmt) -> Vec<(Pos, String)> {
    let mut finder = TempLocks { cfg, awaited: Vec::new(), futures: Vec::new(), locks: Vec::new() };
    match stmt {
        Stmt::Local(local) => {
            if let Some(init) = &local.init {
                finder.visit_expr(&init.expr);
            }
        }
        Stmt::Expr(expr, _) => finder.visit_expr(expr),
        Stmt::Item(_) | Stmt::Macro(_) => {}
    }
    finder.locks
}

struct TempLocks<'c> {
    cfg: &'c Config,
    awaited: Vec<Pos>,
    /// Method calls passed directly as a call's argument: futures.
    futures: Vec<Pos>,
    locks: Vec<(Pos, String)>,
}

impl TempLocks<'_> {
    fn mark_futures<'a>(&mut self, args: impl Iterator<Item = &'a Expr>) {
        for arg in args {
            if let Expr::MethodCall(m) = strip_parens(arg) {
                self.futures.push(pos_of(m.method.span()));
            }
        }
    }

    /// An `if`/`while` head: only `let` scrutinees keep their temporaries.
    fn visit_head(&mut self, cond: &Expr) {
        match strip_parens(cond) {
            Expr::Let(l) => self.visit_expr(&l.expr),
            Expr::Binary(b) if matches!(b.op, syn::BinOp::And(_)) => {
                self.visit_head(&b.left);
                self.visit_head(&b.right);
            }
            _ => {}
        }
    }
}

impl<'ast> Visit<'ast> for TempLocks<'_> {
    fn visit_expr_await(&mut self, e: &'ast syn::ExprAwait) {
        if let Expr::MethodCall(m) = strip_parens(&e.base) {
            self.awaited.push(pos_of(m.method.span()));
        }
        visit::visit_expr_await(self, e);
    }

    fn visit_expr_call(&mut self, e: &'ast syn::ExprCall) {
        self.mark_futures(e.args.iter());
        visit::visit_expr_call(self, e);
    }

    fn visit_expr_method_call(&mut self, e: &'ast syn::ExprMethodCall) {
        let at = pos_of(e.method.span());
        if self.cfg.is_guard_method(&e.method.to_string(), e.args.len())
            && !self.awaited.contains(&at)
            && !self.futures.contains(&at)
        {
            self.locks.push((at, snippet(e)));
        }
        self.mark_futures(e.args.iter());
        visit::visit_expr_method_call(self, e);
    }

    fn visit_expr_if(&mut self, e: &'ast syn::ExprIf) {
        self.visit_head(&e.cond);
    }

    fn visit_expr_while(&mut self, e: &'ast syn::ExprWhile) {
        self.visit_head(&e.cond);
    }

    fn visit_expr_for_loop(&mut self, e: &'ast syn::ExprForLoop) {
        self.visit_expr(&e.expr);
    }

    fn visit_expr_match(&mut self, e: &'ast syn::ExprMatch) {
        self.visit_expr(&e.expr);
    }

    fn visit_block(&mut self, _: &'ast Block) {}
    fn visit_expr_closure(&mut self, _: &'ast syn::ExprClosure) {}
    fn visit_expr_async(&mut self, _: &'ast syn::ExprAsync) {}
    fn visit_item(&mut self, _: &'ast syn::Item) {}
}
