//! The scan of one file: a syn visitor that knows whether it is in async
//! code, which calls run on a blocking-allowed thread, and the followed types
//! of the current function's locals.

use std::collections::{HashMap, HashSet};

use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Block, Expr, FnArg, Pat, Signature, Stmt, Type};

use crate::attrs::{is_test_only, item_attrs};
use crate::child::{self, Spawn};
use crate::config::Config;
use crate::expand;
use crate::finding::{Finding, Kind};
use crate::guards::guards_over_await;
use crate::pre_exec;
use crate::resolve::{Pos, UseMap, call_path, pos_of, snippet, strip_parens};

/// A file that does not parse as Rust.
#[derive(Debug, Clone)]
pub struct ParseError {
    pub file: String,
    pub message: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: does not parse: {}", self.file, self.message)
    }
}

impl std::error::Error for ParseError {}

/// One file to scan: the path shown in findings, its crate and its text.
pub struct FileInput<'a> {
    pub file: &'a str,
    pub krate: &'a str,
    pub text: &'a str,
}

/// Every finding in one file, exempt ones carrying their allow reason.
pub fn scan_file(cfg: &Config, input: &FileInput<'_>) -> Result<Vec<Finding>, ParseError> {
    let parsed = syn::parse_file(input.text);
    let result = parsed
        .map(|mut ast| {
            expand::expand_file(&mut ast);
            let uses = UseMap::of_file(&ast);
            let mut scanner = Scanner::new(cfg, &uses, input);
            scanner.visit_file(&ast);
            scanner.findings
        })
        .map_err(|e| ParseError {
            file: input.file.to_string(),
            message: format!("{}:{}: {e}", e.span().start().line, e.span().start().column),
        });
    // Spans of this file are no longer used; free the thread's source map.
    proc_macro2::extra::invalidate_current_thread_spans();
    let mut findings = result?;
    let lines: Vec<&str> = input.text.lines().collect();
    for finding in &mut findings {
        finding.exempt = exemption(&lines, finding.kind, finding.line, finding.stmt_line);
    }
    findings.sort_by_key(|f| (f.line, f.column, f.kind));
    findings.dedup_by(|a, b| {
        a.line == b.line && a.column == b.column && a.kind == b.kind && a.rule == b.rule
    });
    Ok(findings)
}

/// The reason of the kind's allow comment on the line, or in the comment
/// lines directly above it or above the statement's first line.
pub fn exemption(lines: &[&str], kind: Kind, line: usize, stmt_line: usize) -> Option<String> {
    let tag = kind.allow_tag();
    let reason_in = |text: &str| {
        let at = text.find(tag)?;
        let reason = text[at + tag.len()..].trim();
        (!reason.is_empty()).then(|| reason.to_string())
    };
    for anchor in [line, stmt_line] {
        let Some(index) = anchor.checked_sub(1) else { continue };
        if let Some(reason) = lines.get(index).and_then(|l| reason_in(l)) {
            return Some(reason);
        }
        for above in lines[..index.min(lines.len())].iter().rev() {
            if !above.trim_start().starts_with("//") {
                break;
            }
            if let Some(reason) = reason_in(above) {
                return Some(reason);
            }
        }
    }
    None
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Ctx {
    /// Code that may block: sync functions, offloaded closures.
    Sync,
    /// Code that runs on an async executor.
    Async,
}

struct Scanner<'c, 'ast> {
    cfg: &'c Config,
    uses: &'c UseMap,
    file: &'c str,
    krate: &'c str,
    findings: Vec<Finding>,
    ctx: Ctx,
    scope: Vec<String>,
    bodies: Vec<&'ast Block>,
    locals: Vec<HashMap<String, String>>,
    awaited: HashSet<Pos>,
    as_argument: HashSet<Pos>,
    supervised: usize,
    stmt_lines: Vec<usize>,
}

impl<'c, 'ast> Scanner<'c, 'ast> {
    fn new(cfg: &'c Config, uses: &'c UseMap, input: &FileInput<'c>) -> Self {
        Scanner {
            cfg,
            uses,
            file: input.file,
            krate: input.krate,
            findings: Vec::new(),
            ctx: Ctx::Sync,
            scope: Vec::new(),
            bodies: Vec::new(),
            locals: Vec::new(),
            awaited: HashSet::new(),
            as_argument: HashSet::new(),
            supervised: 0,
            stmt_lines: Vec::new(),
        }
    }

    fn report(&mut self, kind: Kind, rule: &str, pos: Pos, message: String, snippet: String) {
        let stmt_line = self.stmt_lines.last().copied().unwrap_or(pos.0);
        self.report_in(stmt_line, kind, rule, pos, message, snippet);
    }

    /// A finding whose allow comment goes above `stmt_line`.
    fn report_in(
        &mut self,
        stmt_line: usize,
        kind: Kind,
        rule: &str,
        pos: Pos,
        message: String,
        snippet: String,
    ) {
        let function = self.scope.join("::");
        self.findings.push(Finding {
            kind,
            rule: rule.to_string(),
            file: self.file.to_string(),
            line: pos.0,
            column: pos.1 + 1,
            krate: self.krate.to_string(),
            function,
            message,
            snippet,
            exempt: None,
            stmt_line,
        });
    }

    fn visit_fn(&mut self, name: String, sig: &'ast Signature, body: &'ast Block) {
        let saved_ctx = self.ctx;
        self.ctx = if sig.asyncness.is_some() { Ctx::Async } else { Ctx::Sync };
        self.scope.push(name);
        self.bodies.push(body);
        self.locals.push(self.param_types(sig));
        self.visit_block(body);
        self.locals.pop();
        self.bodies.pop();
        self.scope.pop();
        self.ctx = saved_ctx;
    }

    fn param_types(&self, sig: &Signature) -> HashMap<String, String> {
        let mut types = HashMap::new();
        for input in &sig.inputs {
            let FnArg::Typed(arg) = input else { continue };
            let Pat::Ident(name) = &*arg.pat else { continue };
            let mut ty = &*arg.ty;
            while let Type::Reference(r) = ty {
                ty = &r.elem;
            }
            if let Type::Path(p) = ty {
                let full = self.uses.resolve(&p.path);
                if self.cfg.type_rule(&full).is_some() {
                    types.insert(name.ident.to_string(), full);
                }
            }
        }
        types
    }

    /// The followed type an expression has, when the scan can tell.
    fn type_of(&self, expr: &Expr) -> Option<String> {
        match strip_parens(expr) {
            Expr::Call(c) => {
                let path = self.uses.resolve(call_path(&c.func)?);
                self.cfg.constructed_type(&path).map(str::to_string)
            }
            Expr::MethodCall(m) => {
                let receiver = self.type_of(&m.receiver)?;
                let rule = self.cfg.type_rule(&receiver)?;
                let name = m.method.to_string();
                if rule.chain.contains(&name) || self.cfg.is_passthrough(&name) {
                    Some(receiver)
                } else {
                    rule.returns.get(&name).cloned()
                }
            }
            Expr::Try(t) => self.type_of(&t.expr),
            Expr::Reference(r) => self.type_of(&r.expr),
            Expr::Path(p) => {
                let ident = p.path.get_ident()?.to_string();
                self.locals.last()?.get(&ident).cloned()
            }
            _ => None,
        }
    }

    fn bind_name(&mut self, name: &syn::Ident, init: &Expr) {
        let ty = self.type_of(init);
        if let Some(locals) = self.locals.last_mut() {
            match ty {
                Some(ty) => locals.insert(name.to_string(), ty),
                None => locals.remove(&name.to_string()),
            };
        }
    }

    fn bind_local(&mut self, pat: &Pat, init: &Expr) {
        let pat = match pat {
            Pat::Type(t) => &*t.pat,
            other => other,
        };
        match pat {
            Pat::Ident(p) => self.bind_name(&p.ident, init),
            // `let Ok(rt) = Handle::try_current() else { .. }`, `if let Some(x) = ..`:
            // the one binding holds the followed value.
            Pat::TupleStruct(t)
                if t.elems.len() == 1
                    && t.path
                        .segments
                        .last()
                        .is_some_and(|s| s.ident == "Ok" || s.ident == "Some") =>
            {
                if let Some(Pat::Ident(p)) = t.elems.first() {
                    self.bind_name(&p.ident, init);
                }
            }
            Pat::Tuple(t) => {
                let pair = match strip_parens(init) {
                    Expr::Call(c) => call_path(&c.func).map(|p| self.uses.resolve(p)),
                    _ => None,
                };
                let Some(types) =
                    pair.and_then(|p| self.cfg.pair_types(&p)).map(<[String]>::to_vec)
                else {
                    return;
                };
                for (elem, ty) in t.elems.iter().zip(types) {
                    if let (Pat::Ident(p), Some(locals)) = (elem, self.locals.last_mut()) {
                        locals.insert(p.ident.to_string(), ty);
                    }
                }
            }
            _ => {}
        }
    }

    fn check_call(&mut self, call: &'ast syn::ExprCall, path: &str) {
        let pos = call_path(&call.func)
            .and_then(|p| p.segments.last())
            .map_or_else(|| pos_of(call.span()), |s| pos_of(s.ident.span()));
        if self.ctx == Ctx::Async && self.cfg.is_blocking_function(path) {
            let message = format!(
                "`{path}` blocks a runtime thread in async code; use the tokio equivalent, spawn_blocking or a cmux-blocking wrapper"
            );
            self.report(Kind::Blocking, "call", pos, message, snippet(call));
        }
        if self.supervised == 0 && self.cfg.spawn.thread_functions.iter().any(|f| f == path) {
            let message =
                format!("`{path}` starts a thread outside cmux_panic_log::supervise_thread");
            self.report(Kind::Spawn, "thread", pos, message, snippet(call));
        }
        if self.cfg.is_unbounded(path) {
            let message = format!(
                "`{path}` makes an unbounded queue; bound it with an overflow policy or say why it is bounded"
            );
            self.report(Kind::Unbounded, "channel", pos, message, snippet(call));
        }
    }

    fn check_method(&mut self, call: &'ast syn::ExprMethodCall) {
        let name = call.method.to_string();
        let nargs = call.args.len();
        let pos = pos_of(call.method.span());
        if name == "pre_exec"
            && nargs == 1
            && let Some(arg) = call.args.first()
        {
            for hit in pre_exec::check(self.cfg, self.uses, arg) {
                self.report(Kind::PreExec, hit.rule, hit.pos, hit.message, hit.snippet);
            }
        }
        let receiver = self.type_of(&call.receiver);
        let rule = receiver.as_deref().and_then(|t| self.cfg.type_rule(t));
        if let (Some(rule), Some(ty)) = (rule, receiver.as_deref()) {
            if self.supervised == 0 && rule.spawns_threads.contains(&name) {
                let message = format!(
                    "`{ty}::{name}` starts a thread outside cmux_panic_log::supervise_thread"
                );
                self.report(Kind::Spawn, "thread", pos, message, snippet(call));
            }
            if self.ctx == Ctx::Async
                && rule.blocking.contains(&name)
                && !self.awaited.contains(&pos)
            {
                let message = format!("`{ty}::{name}` blocks a runtime thread in async code");
                self.report(Kind::Blocking, "typed-method", pos, message, snippet(call));
            }
        }
        let Some(method) = self.cfg.blocking_method(&name, nargs) else { return };
        // A followed type's own list decides its methods; `always` ones
        // (block_on, blocking_*) block on any receiver.
        if rule.is_some() && !method.always {
            return;
        }
        if self.ctx != Ctx::Async {
            return;
        }
        if method.always {
            let message =
                format!("`.{name}()` blocks (or panics) on a runtime thread even when awaited");
            self.report(Kind::Blocking, "always", pos, message, snippet(call));
        } else if !(self.awaited.contains(&pos)
            || method.async_twin && self.as_argument.contains(&pos))
        {
            let message = format!(
                "`.{name}()` is not awaited in async code: a std call that blocks a runtime thread"
            );
            self.report(Kind::Blocking, "method", pos, message, snippet(call));
        }
    }

    fn mark_arguments<'a>(&mut self, args: impl Iterator<Item = &'a Expr>) {
        for arg in args {
            if let Expr::MethodCall(m) = strip_parens(arg) {
                self.as_argument.insert(pos_of(m.method.span()));
            }
        }
    }

    /// A spawned task whose JoinHandle the statement drops.
    fn dropped_task(&self, expr: &Expr) -> Option<Pos> {
        match strip_parens(expr) {
            Expr::Call(c) => {
                let path = call_path(&c.func)?;
                let full = self.uses.resolve(path);
                let spawns = self.cfg.spawn.task_functions.contains(&full);
                spawns.then(|| {
                    path.segments
                        .last()
                        .map_or_else(|| pos_of(c.span()), |s| pos_of(s.ident.span()))
                })
            }
            Expr::MethodCall(m) => {
                let ty = self.type_of(&m.receiver)?;
                let rule = self.cfg.type_rule(&ty)?;
                rule.spawns_tasks.iter().any(|s| m.method == s).then(|| pos_of(m.method.span()))
            }
            _ => None,
        }
    }

    fn check_dropped_task(&mut self, expr: &'ast Expr) {
        if let Some(pos) = self.dropped_task(expr) {
            let message = "the spawned task's JoinHandle is dropped: its panic is lost; keep the handle with its owner or use supervise_task".to_string();
            self.report(Kind::Spawn, "dropped-handle", pos, message, snippet(expr));
        }
    }

    fn check_child(&mut self, spawn: Spawn, names: Vec<String>, text: String) {
        if spawn.kill_in_chain {
            return;
        }
        let Some(body) = self.bodies.last().copied() else { return };
        if let Some(command) = &spawn.command
            && child::command_kills_on_drop(self.cfg, body, command)
        {
            return;
        }
        if names.is_empty() {
            let message =
                "the spawned Child is dropped at once: it is never waited (a zombie) or killed"
                    .to_string();
            self.report(Kind::Child, "dropped", spawn.pos, message, text);
            return;
        }
        let fate = child::fate(self.cfg, body, &names, spawn.pos);
        if !fate.reaped && !fate.handed_off {
            let message = format!(
                "Child `{}` is never awaited, waited, stored or kill_on_drop: it stays a zombie",
                names.join("`, `")
            );
            self.report(Kind::Child, "unreaped", spawn.pos, message, text);
        }
    }

    fn check_guards(&mut self, block: &'ast Block) {
        for hit in guards_over_await(self.cfg, block) {
            let held = hit
                .guard
                .as_deref()
                .map_or_else(|| "a temporary guard".to_string(), |g| format!("guard `{g}`"));
            let message = format!(
                "std lock {held} is held across the await at line {}: release it first or use an async lock",
                hit.awaited_at.0
            );
            let rule = "lock-over-await";
            self.report_in(hit.stmt_line, Kind::Blocking, rule, hit.lock, message, hit.snippet);
        }
    }

    fn with_ctx(&mut self, ctx: Ctx, f: impl FnOnce(&mut Self)) {
        let saved = self.ctx;
        self.ctx = ctx;
        f(self);
        self.ctx = saved;
    }
}

/// The names a `match` or `if let` binds from a spawned Child.
fn arm_names<'a>(pats: impl Iterator<Item = &'a Pat>) -> Vec<String> {
    let mut names = Vec::new();
    for pat in pats {
        child::pat_idents(pat, &mut names);
    }
    names
}

impl<'ast> Visit<'ast> for Scanner<'_, 'ast> {
    fn visit_item(&mut self, item: &'ast syn::Item) {
        if !is_test_only(item_attrs(item)) {
            visit::visit_item(self, item);
        }
    }

    fn visit_item_fn(&mut self, item: &'ast syn::ItemFn) {
        self.visit_fn(item.sig.ident.to_string(), &item.sig, &item.block);
    }

    fn visit_item_impl(&mut self, item: &'ast syn::ItemImpl) {
        let name = match &*item.self_ty {
            Type::Path(p) => p.path.segments.last().map(|s| s.ident.to_string()),
            _ => None,
        };
        self.scope.push(name.unwrap_or_else(|| "impl".to_string()));
        visit::visit_item_impl(self, item);
        self.scope.pop();
    }

    fn visit_item_mod(&mut self, item: &'ast syn::ItemMod) {
        self.scope.push(item.ident.to_string());
        visit::visit_item_mod(self, item);
        self.scope.pop();
    }

    fn visit_impl_item_fn(&mut self, item: &'ast syn::ImplItemFn) {
        if !is_test_only(&item.attrs) {
            self.visit_fn(item.sig.ident.to_string(), &item.sig, &item.block);
        }
    }

    fn visit_trait_item_fn(&mut self, item: &'ast syn::TraitItemFn) {
        if let Some(body) = &item.default
            && !is_test_only(&item.attrs)
        {
            self.visit_fn(item.sig.ident.to_string(), &item.sig, body);
        }
    }

    fn visit_expr_async(&mut self, e: &'ast syn::ExprAsync) {
        self.with_ctx(Ctx::Async, |s| visit::visit_expr_async(s, e));
    }

    fn visit_expr_closure(&mut self, e: &'ast syn::ExprClosure) {
        let ctx = if e.asyncness.is_some() { Ctx::Async } else { self.ctx };
        self.with_ctx(ctx, |s| visit::visit_expr_closure(s, e));
    }

    fn visit_expr_await(&mut self, e: &'ast syn::ExprAwait) {
        if let Expr::MethodCall(m) = strip_parens(&e.base) {
            self.awaited.insert(pos_of(m.method.span()));
        }
        visit::visit_expr_await(self, e);
    }

    fn visit_expr_call(&mut self, e: &'ast syn::ExprCall) {
        let path = call_path(&e.func).map(|p| self.uses.resolve(p)).unwrap_or_default();
        self.check_call(e, &path);
        self.mark_arguments(e.args.iter());
        let offload = self.cfg.is_offload_function(&path);
        let supervisor = self.cfg.is_supervisor(&path);
        self.supervised += usize::from(supervisor);
        self.visit_expr(&e.func);
        let ctx = if offload { Ctx::Sync } else { self.ctx };
        self.with_ctx(ctx, |s| e.args.iter().for_each(|a| s.visit_expr(a)));
        self.supervised -= usize::from(supervisor);
    }

    fn visit_expr_method_call(&mut self, e: &'ast syn::ExprMethodCall) {
        self.check_method(e);
        self.mark_arguments(e.args.iter());
        self.visit_expr(&e.receiver);
        let name = e.method.to_string();
        let starts_thread = self
            .type_of(&e.receiver)
            .and_then(|t| self.cfg.type_rule(&t))
            .is_some_and(|rule| rule.spawns_threads.contains(&name));
        let offload = starts_thread || self.cfg.is_offload_method(&name);
        let ctx = if offload { Ctx::Sync } else { self.ctx };
        self.with_ctx(ctx, |s| e.args.iter().for_each(|a| s.visit_expr(a)));
    }

    fn visit_expr_match(&mut self, e: &'ast syn::ExprMatch) {
        if let Some(spawn) = child::find_spawn(self.cfg, self.uses, &e.expr) {
            self.check_child(spawn, arm_names(e.arms.iter().map(|a| &a.pat)), snippet(&e.expr));
        }
        visit::visit_expr_match(self, e);
    }

    fn visit_expr_let(&mut self, e: &'ast syn::ExprLet) {
        if let Some(spawn) = child::find_spawn(self.cfg, self.uses, &e.expr) {
            self.check_child(spawn, arm_names(std::iter::once(&*e.pat)), snippet(&e.expr));
        }
        visit::visit_expr_let(self, e);
        // The `if let` / `while let` body, visited next, sees the binding.
        self.bind_local(&e.pat, &e.expr);
    }

    fn visit_block(&mut self, block: &'ast Block) {
        if self.ctx == Ctx::Async {
            self.check_guards(block);
        }
        visit::visit_block(self, block);
    }

    fn visit_stmt(&mut self, stmt: &'ast Stmt) {
        self.stmt_lines.push(pos_of(stmt.span()).0);
        match stmt {
            Stmt::Local(local) => {
                visit::visit_stmt(self, stmt);
                if let Some(init) = &local.init {
                    let wild = matches!(local.pat, Pat::Wild(_));
                    if wild {
                        self.check_dropped_task(&init.expr);
                    }
                    if let Some(spawn) = child::find_spawn(self.cfg, self.uses, &init.expr) {
                        self.check_child(
                            spawn,
                            arm_names(std::iter::once(&local.pat)),
                            snippet(&init.expr),
                        );
                    }
                    self.bind_local(&local.pat, &init.expr);
                }
            }
            Stmt::Expr(expr, Some(_)) => {
                self.check_dropped_task(expr);
                if let Some(spawn) = child::find_spawn(self.cfg, self.uses, expr) {
                    self.check_child(spawn, Vec::new(), snippet(expr));
                }
                visit::visit_stmt(self, stmt);
            }
            _ => visit::visit_stmt(self, stmt),
        }
        self.stmt_lines.pop();
    }
}
