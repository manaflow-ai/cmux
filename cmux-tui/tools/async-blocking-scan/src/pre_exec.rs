//! The body of a `pre_exec` closure runs in the child between fork and exec,
//! where only async-signal-safe calls are allowed (signal-safety(7)): an
//! allocation or a lock another thread held at fork time deadlocks. Chromium
//! keeps the same rule in base/process/launch_posix.cc: after fork the child
//! calls only raw syscalls (no malloc, no logging) until exec.

use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Expr, ExprClosure};

use crate::config::Config;
use crate::expand::expanded_macro;
use crate::resolve::{Pos, UseMap, call_path, pos_of, snippet, strip_parens};

pub struct PreExecHit {
    pub pos: Pos,
    pub rule: &'static str,
    pub message: String,
    pub snippet: String,
}

/// The calls in a `pre_exec` argument that are not async-signal-safe.
pub fn check(cfg: &Config, uses: &UseMap, arg: &Expr) -> Vec<PreExecHit> {
    let Expr::Closure(closure) = strip_parens(arg) else {
        return vec![PreExecHit {
            pos: pos_of(arg.span()),
            rule: "opaque",
            message: "pre_exec gets a closure the scan cannot see; pass the closure inline"
                .to_string(),
            snippet: snippet(arg),
        }];
    };
    let mut checker = Checker { cfg, uses, hits: Vec::new() };
    checker.visit_closure_body(closure);
    checker.hits
}

struct Checker<'c> {
    cfg: &'c Config,
    uses: &'c UseMap,
    hits: Vec<PreExecHit>,
}

impl Checker<'_> {
    fn visit_closure_body(&mut self, closure: &ExprClosure) {
        self.visit_expr(&closure.body);
    }
}

impl<'ast> Visit<'ast> for Checker<'_> {
    fn visit_expr_call(&mut self, c: &'ast syn::ExprCall) {
        match call_path(&c.func) {
            Some(path) => {
                let full = self.uses.resolve(path);
                let pos = path
                    .segments
                    .last()
                    .map_or_else(|| pos_of(c.paren_token.span.join()), |s| pos_of(s.ident.span()));
                if let Some(name) = expanded_macro(&full) {
                    self.hits.push(PreExecHit {
                        pos,
                        rule: "macro",
                        message: format!("`{name}!` between fork and exec may allocate or lock"),
                        snippet: format!("{name}!(..)"),
                    });
                } else if !self.cfg.is_signal_safe(&full) {
                    self.hits.push(PreExecHit {
                        pos,
                        rule: "call",
                        message: format!("`{full}` is not on the async-signal-safe list"),
                        snippet: snippet(c),
                    });
                }
            }
            None => self.hits.push(PreExecHit {
                pos: pos_of(c.paren_token.span.join()),
                rule: "call",
                message: "an indirect call between fork and exec".to_string(),
                snippet: snippet(c),
            }),
        }
        visit::visit_expr_call(self, c);
    }

    fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
        let name = m.method.to_string();
        if !self.cfg.pre_exec.safe_methods.contains(&name) {
            self.hits.push(PreExecHit {
                pos: pos_of(m.method.span()),
                rule: "method",
                message: format!("method `{name}` between fork and exec may allocate or lock"),
                snippet: snippet(m),
            });
        }
        visit::visit_expr_method_call(self, m);
    }
}
