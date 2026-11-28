//! Lists draw only their visible rows: per-frame work in a draw fn must not grow with the
//! number of items it lists.
//!
//! A terminal UI shows a few dozen rows. A rail that walks, groups or clones every session each
//! frame costs time in the number of sessions, and at 10,000 that is the lag. The rule: in a draw
//! fn, the rows built, the items cloned and the items walked stay flat in N (a cheap index is
//! fine); only the viewport's rows (and an overscan) are built.
//!
//! A draw fn is a fn (free, method, or nested) named `draw*` or `render*`, or one with a ratatui
//! `Frame` or `Buffer` parameter (in a file that names `ratatui`). Test code is not judged: a
//! `#[cfg(test)]` module, a `#[test]` fn, a file under `tests/`, `benches/` or `examples/`, or a
//! `tests.rs` / `*_tests.rs` file. In a draw fn's body (its closures and macro bodies too; a fn
//! nested in it is judged on its own) it flags:
//!   - walk: a loop or iterator chain over a whole collection. `for x in coll`, `for x in &coll`,
//!     `for x in a.b()` and a chain with `.iter()`, `.iter_mut()`, `.into_iter()`, `.values()`,
//!     `.values_mut()`, `.keys()` or `.drain(..)`, with no `skip`, `take`, `nth`, `next`, `last`,
//!     `step_by`, `skip_while` or `take_while` after it. Not a walk: a range (`a..b`, cells of a
//!     row), an array literal or macro (`[a, b]`, `vec![..]`), a range slice (`rows[a..b]`), a
//!     SCREAMING_CASE constant, a string's characters or lines (`chars`, `lines`, `split*`).
//!   - clone: a copy of a whole collection. `.to_vec()`, an unbounded walk that ends in
//!     `.cloned()`, `.copied()` or `.map(|x| x.clone())`, and `.clone()` of a field or name that
//!     reads as a collection (plural, `*rows`, `*list`, `*map`, `*cache`).
//!
//! It reads names, not types, so it is a ratchet, not a proof: each hit is a place to look. A
//! line that is bounded for a reason the tree does not show carries `// visible-only: <why>` on
//! it or the line above. The tree's hits as of the check's start are in visible_only_known.txt,
//! per fn; that list only shrinks ([`ratchet`]).

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use proc_macro2::Span;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Attribute, Expr, ExprMethodCall, FnArg, Signature, Type};

use crate::source::{has_ident, read_source, rel_path, rust_files, snippet, visit_macro_body};

/// The comment that marks a line bounded for a reason the tree does not show.
pub const MARKER: &str = "visible-only:";
/// The ratchet: `PATH FN walks=W clones=C :: why` per fn with hits, PATH from the checkout.
pub const KNOWN: &str = include_str!("visible_only_known.txt");
pub const KNOWN_FILE: &str = "cmux-tui/crates/cmux-source-scan/src/visible_only_known.txt";

const WALK_STARTS: [&str; 7] =
    ["iter", "iter_mut", "into_iter", "values", "values_mut", "keys", "drain"];
/// What ends a walk early: the first of these after the walk start, with only `PASS` adapters
/// between, bounds it. `last`, `nth`, `step_by` and the `_while` forms still read the whole
/// collection (or as much of it as the data says), and a `take` after a `filter` keeps reading
/// until enough items pass, so none of those bound a walk.
const BOUNDS: [&str; 4] = ["skip", "take", "next", "next_back"];
/// Adapters that yield one item per item read, so a bound after them still bounds the walk.
const PASS: [&str; 8] =
    ["map", "enumerate", "rev", "inspect", "cloned", "copied", "by_ref", "fuse"];
const TEXT_WALKS: [&str; 12] = [
    "chars",
    "char_indices",
    "bytes",
    "lines",
    "split",
    "split_whitespace",
    "splitn",
    "rsplit",
    "split_terminator",
    "graphemes",
    "grapheme_indices",
    "matches",
];
const COPIES: [&str; 2] = ["cloned", "copied"];
/// Methods of an iterator that `Option` and `Result` do not have.
const ITER_ONLY: [&str; 16] = [
    "collect",
    "enumerate",
    "for_each",
    "filter_map",
    "flat_map",
    "sum",
    "count",
    "fold",
    "max_by_key",
    "min_by_key",
    "position",
    "find_map",
    "any",
    "all",
    "rev",
    "peekable",
];
/// A chain these take as an argument walks beside the chain they extend: judged with it.
const BESIDE: [&str; 2] = ["zip", "chain"];
const CLONE_FNS: [&str; 4] = ["clone", "to_owned", "to_string", "into_owned"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Walk,
    Clone,
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Kind::Walk => "walk",
            Kind::Clone => "clone",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub rel: String,
    pub line: usize,
    /// The draw fn the hit is in.
    pub func: String,
    pub kind: Kind,
    /// The loop head or chain, its whitespace folded.
    pub text: String,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}: {} in `{}`: {}", self.rel, self.line, self.kind, self.func, self.text)
    }
}

/// A scan of a tree.
#[derive(Debug, Default)]
pub struct Scan {
    pub found: Vec<Finding>,
    /// Files that do not parse, with the parser's error; judged no further.
    pub unparsed: Vec<String>,
    pub files: usize,
}

/// Every finding under `roots` (default: the `src` of each crate of `checkout`/cmux-tui/crates
/// that depends on ratatui, [`tui_crates`]), paths from `checkout`. Err
/// for a missing checkout or root, or a path it could not read (named): no scan is no clean scan.
pub fn scan(checkout: &Path, roots: &[PathBuf]) -> Result<Scan, String> {
    if !checkout.is_dir() {
        return Err(format!("{}: no such checkout", checkout.display()));
    }
    let checkout = checkout.canonicalize().map_err(|e| format!("{}: {e}", checkout.display()))?;
    let roots: Vec<PathBuf> = if roots.is_empty() {
        tui_crates(&checkout.join("cmux-tui/crates"))?
    } else {
        roots.to_vec()
    };
    let mut out = Scan::default();
    for root in &roots {
        let Ok(root) = root.canonicalize() else {
            return Err(format!("{}: scan root does not exist", root.display()));
        };
        for path in rust_files(&root).map_err(|e| e.to_string())? {
            let rel = rel_path(&checkout, &path);
            if is_test_path(&rel) {
                continue;
            }
            out.files += 1;
            let text = read_source(&path).map_err(|e| e.to_string())?;
            match judge_source(&rel, &text) {
                Ok(found) => out.found.extend(found),
                Err(error) => out.unparsed.push(format!("{rel}: {error}")),
            }
        }
    }
    Ok(out)
}

/// The crates under `crates` that draw a terminal UI: their Cargo.toml depends on `ratatui`.
/// Err when there is none (no scan is no clean scan) or a manifest cannot be read.
pub fn tui_crates(crates: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = std::fs::read_dir(crates).map_err(|e| format!("{}: {e}", crates.display()))?;
    let mut out = Vec::new();
    for entry in entries {
        let dir = entry.map_err(|e| format!("{}: {e}", crates.display()))?.path();
        let manifest = dir.join("Cargo.toml");
        if !manifest.is_file() {
            continue;
        }
        let text = read_source(&manifest).map_err(|e| e.to_string())?;
        if text.lines().any(|l| l.trim_start().starts_with("ratatui")) {
            out.push(dir.join("src"));
        }
    }
    out.sort();
    if out.is_empty() {
        return Err(format!("{}: no crate depends on ratatui", crates.display()));
    }
    Ok(out)
}

/// A path whose code is test, bench or example code, judged no further.
pub fn is_test_path(rel: &str) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    let file = parts.last().copied().unwrap_or("");
    parts.iter().rev().skip(1).any(|p| matches!(*p, "tests" | "benches" | "examples" | "fixtures"))
        || file == "tests.rs"
        || file.ends_with("_tests.rs")
        || file.ends_with("_test.rs")
        || !rel.ends_with(".rs")
}

/// The findings of one file.
pub fn judge_source(rel: &str, text: &str) -> Result<Vec<Finding>, syn::Error> {
    // Without one of these words the file holds no draw fn: not parsed.
    if !["draw", "render", "Frame", "Buffer"].iter().any(|w| text.contains(w)) {
        return Ok(Vec::new());
    }
    let file = syn::parse_file(text)?;
    let lines: Vec<&str> = text.lines().collect();
    let ratatui = text.contains("ratatui");
    let ui = ratatui || rel.split('/').any(|p| p == "ui" || p == "tui");
    let mut items = Items { ratatui, ui, fns: Vec::new() };
    items.visit_file(&file);
    let mut found = Vec::new();
    for (name, block) in items.fns {
        let mut body = Body { found: Vec::new(), quiet: 0 };
        body.visit_block(block);
        for (span, kind) in body.found {
            let line = span.start().line;
            let marked = |at: usize| {
                at >= 1 && lines.get(at - 1).is_some_and(|l| l.contains(&format!("// {MARKER}")))
            };
            if marked(line) || marked(line.wrapping_sub(1)) {
                continue;
            }
            found.push(Finding {
                rel: rel.to_string(),
                line,
                func: name.clone(),
                kind,
                text: snippet(&lines, span),
            });
        }
    }
    found.sort_by_key(|f| f.line);
    Ok(found)
}

/// The draw fns of a file, outside test code.
struct Items<'ast> {
    ratatui: bool,
    /// The file names ratatui or sits in a `ui` or `tui` module: a `render*` fn draws there, where
    /// elsewhere it may print a CLI table.
    ui: bool,
    fns: Vec<(String, &'ast syn::Block)>,
}

impl Items<'_> {
    fn is_draw(&self, sig: &Signature) -> bool {
        let name = sig.ident.to_string();
        let named = name.starts_with("draw") || name.starts_with("render");
        let takes_frame = self.ratatui
            && sig.inputs.iter().any(|arg| match arg {
                FnArg::Typed(t) => type_names(&t.ty, &["Frame", "Buffer"]),
                FnArg::Receiver(_) => false,
            });
        (named && self.ui) || takes_frame
    }
}

fn type_names(ty: &Type, names: &[&str]) -> bool {
    names.iter().any(|n| has_ident(quote::ToTokens::to_token_stream(ty), n))
}

fn is_test_code(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|a| {
        let last = a.path().segments.last().map(|s| s.ident.to_string()).unwrap_or_default();
        if last == "test" || last == "rstest" || last == "test_case" {
            return true;
        }
        a.path().is_ident("cfg")
            && a.meta.require_list().is_ok_and(|l| {
                let text = l.tokens.to_string();
                has_ident(l.tokens.clone(), "test") && !text.contains("not")
            })
    })
}

impl<'ast> Visit<'ast> for Items<'ast> {
    fn visit_item_mod(&mut self, m: &'ast syn::ItemMod) {
        if !is_test_code(&m.attrs) {
            visit::visit_item_mod(self, m);
        }
    }
    fn visit_item_impl(&mut self, i: &'ast syn::ItemImpl) {
        if !is_test_code(&i.attrs) {
            visit::visit_item_impl(self, i);
        }
    }
    fn visit_item_fn(&mut self, f: &'ast syn::ItemFn) {
        if is_test_code(&f.attrs) {
            return;
        }
        if self.is_draw(&f.sig) {
            self.fns.push((f.sig.ident.to_string(), &f.block));
        }
        visit::visit_item_fn(self, f);
    }
    fn visit_impl_item_fn(&mut self, f: &'ast syn::ImplItemFn) {
        if is_test_code(&f.attrs) {
            return;
        }
        if self.is_draw(&f.sig) {
            self.fns.push((f.sig.ident.to_string(), &f.block));
        }
        visit::visit_impl_item_fn(self, f);
    }
    fn visit_trait_item_fn(&mut self, f: &'ast syn::TraitItemFn) {
        if is_test_code(&f.attrs) {
            return;
        }
        if let Some(block) = &f.default
            && self.is_draw(&f.sig)
        {
            self.fns.push((f.sig.ident.to_string(), block));
        }
        visit::visit_trait_item_fn(self, f);
    }
}

/// One draw fn's body: what it walks and clones.
struct Body {
    found: Vec<(Span, Kind)>,
    /// Inside the arguments of a chain already flagged: not flagged again.
    quiet: usize,
}

/// A method chain from its outermost call in: the calls, then the expression it starts on.
fn chain(top: &ExprMethodCall) -> (Vec<&ExprMethodCall>, &Expr) {
    let mut links = vec![top];
    let mut at = &*top.receiver;
    while let Expr::MethodCall(m) = at {
        links.push(m);
        at = &*m.receiver;
    }
    (links, at)
}

fn strip(e: &Expr) -> &Expr {
    match e {
        Expr::Reference(r) => strip(&r.expr),
        Expr::Paren(p) => strip(&p.expr),
        Expr::Group(g) => strip(&g.expr),
        _ => e,
    }
}

/// The last name of a path or field expression.
fn last_name(e: &Expr) -> Option<String> {
    match strip(e) {
        Expr::Path(p) => p.path.segments.last().map(|s| s.ident.to_string()),
        Expr::Field(f) => match &f.member {
            syn::Member::Named(n) => Some(n.to_string()),
            syn::Member::Unnamed(_) => None,
        },
        _ => None,
    }
}

fn is_constant(name: &str) -> bool {
    name.len() > 1 && name.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

/// Whether a walk that starts on `root` is bounded by what `root` is: a range, an array literal,
/// a macro (`vec![..]`), a range slice, a constant.
fn bounded_root(root: &Expr) -> bool {
    match strip(root) {
        Expr::Range(_) | Expr::Array(_) | Expr::Macro(_) | Expr::Lit(_) | Expr::Tuple(_) => true,
        Expr::Index(i) => matches!(strip(&i.index), Expr::Range(_)),
        e => last_name(e).is_some_and(|n| is_constant(&n)),
    }
}

/// Whether a name reads as a collection.
fn collection_name(name: &str) -> bool {
    let name = name.trim_start_matches('_');
    let plural = name.len() > 3
        && name.ends_with('s')
        && !name.ends_with("ss")
        && !name.ends_with("us")
        && !name.ends_with("is");
    plural || ["rows", "list", "map", "cache", "vec", "set"].iter().any(|w| name.ends_with(w))
}

/// Whether `.map(f)`'s `f` copies what it is given: `Clone::clone`, `|x| x.clone()`, a closure
/// that builds an owned row (`|e| (e.name.clone(), e.is_dir())`).
fn clones_each(args: &syn::punctuated::Punctuated<Expr, syn::Token![,]>) -> bool {
    struct Copies(bool);
    impl<'ast> Visit<'ast> for Copies {
        fn visit_expr_method_call(&mut self, m: &'ast ExprMethodCall) {
            self.0 |= CLONE_FNS.contains(&m.method.to_string().as_str());
            visit::visit_expr_method_call(self, m);
        }
        fn visit_macro(&mut self, mac: &'ast syn::Macro) {
            visit_macro_body(self, mac);
        }
    }
    let Some(arg) = args.first() else { return false };
    match arg {
        Expr::Path(p) => p
            .path
            .segments
            .last()
            .is_some_and(|s| CLONE_FNS.contains(&s.ident.to_string().as_str())),
        Expr::Closure(c) => {
            let mut v = Copies(false);
            v.visit_expr(&c.body);
            v.0
        }
        _ => false,
    }
}

impl Body {
    /// Judges a chain whose top is `top`; `looped` when a `for` iterates it.
    fn judge_chain(&self, top: &ExprMethodCall, looped: bool) -> Option<Kind> {
        let (links, root) = chain(top);
        let names: Vec<String> = links.iter().map(|m| m.method.to_string()).collect();
        // `links` run outermost first: the walk's start is the innermost walk method.
        // With no walk method, an iterator-only adapter (`collect`, `enumerate`, ..) says the
        // innermost call returns an iterator (`files.visible_entries().map(..).collect()`).
        let text_walk = names.iter().any(|n| TEXT_WALKS.contains(&n.as_str()));
        let start = names.iter().rposition(|n| WALK_STARTS.contains(&n.as_str())).or_else(|| {
            (!text_walk && names.iter().any(|n| ITER_ONLY.contains(&n.as_str())))
                .then(|| names.len().saturating_sub(1))
        });
        // `rows.to_vec()` copies them all; `rows[a..b].to_vec()` a bounded slice.
        if let Some(m) = links.iter().find(|m| m.method == "to_vec")
            && !bounded_root(&m.receiver)
        {
            return Some(Kind::Clone);
        }
        let walk_from = match start {
            Some(i) => i,
            None if looped => names.len(),
            None => {
                // `.clone()` of a field or name that reads as a collection.
                let top_name = names.first().map(String::as_str);
                if names.len() == 1
                    && top_name == Some("clone")
                    && last_name(root).is_some_and(|n| collection_name(&n))
                    && !bounded_root(root)
                {
                    return Some(Kind::Clone);
                }
                return None;
            }
        };
        if bounded_root(root) {
            return None;
        }
        // The receiver of the walk: the calls inside the walk start and the root.
        let (outer, inner) = names.split_at(walk_from.min(names.len()));
        if inner.iter().any(|n| TEXT_WALKS.contains(&n.as_str())) {
            return None;
        }
        // `outer` runs outermost first: read it from the walk outward.
        if outer
            .iter()
            .rev()
            .find(|n| !PASS.contains(&n.as_str()))
            .is_some_and(|n| BOUNDS.contains(&n.as_str()))
        {
            return None;
        }
        if text_walk && start.is_none() {
            return None;
        }
        let copies = outer.iter().any(|n| COPIES.contains(&n.as_str()))
            || links.iter().take(walk_from).any(|m| m.method == "map" && clones_each(&m.args));
        Some(if copies { Kind::Clone } else { Kind::Walk })
    }

    /// Visits a chain's arguments and root without judging its links again.
    fn visit_chain_parts(&mut self, top: &ExprMethodCall) {
        let (links, root) = chain(top);
        for m in &links {
            let beside = BESIDE.contains(&m.method.to_string().as_str());
            for arg in &m.args {
                match strip(arg) {
                    Expr::MethodCall(inner) if beside => self.visit_chain_parts(inner),
                    _ => self.visit_expr(arg),
                }
            }
        }
        self.visit_expr(root);
    }
}

impl<'ast> Visit<'ast> for Body {
    // A fn or impl nested in the body is judged on its own, when it is a draw fn.
    fn visit_item(&mut self, _: &'ast syn::Item) {}

    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        visit_macro_body(self, mac);
    }

    fn visit_expr_for_loop(&mut self, f: &'ast syn::ExprForLoop) {
        let iterated = strip(&f.expr);
        match iterated {
            Expr::MethodCall(m) => {
                let kind = if self.quiet == 0 { self.judge_chain(m, true) } else { None };
                if let Some(kind) = kind {
                    self.found.push((f.expr.span(), kind));
                    self.quiet += 1;
                    self.visit_chain_parts(m);
                    self.quiet -= 1;
                } else {
                    self.visit_chain_parts(m);
                }
            }
            Expr::Path(_) | Expr::Field(_) | Expr::Index(_) => {
                if self.quiet == 0 && !bounded_root(iterated) {
                    self.found.push((f.expr.span(), Kind::Walk));
                }
                self.visit_expr(&f.expr);
            }
            _ => self.visit_expr(&f.expr),
        }
        self.visit_block(&f.body);
    }

    fn visit_expr_method_call(&mut self, m: &'ast ExprMethodCall) {
        let kind = if self.quiet == 0 { self.judge_chain(m, false) } else { None };
        match kind {
            Some(kind) => {
                self.found.push((m.span(), kind));
                // What the walk's closures do per item is part of that walk (`spans` of a row).
                self.quiet += 1;
                self.visit_chain_parts(m);
                self.quiet -= 1;
            }
            None => self.visit_chain_parts(m),
        }
    }
}

/// A row of the ratchet: a draw fn's walks and clones as of the check's start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Known {
    pub rel: String,
    pub func: String,
    pub walks: usize,
    pub clones: usize,
    pub why: String,
}

/// The rows of [`KNOWN`] (or another text in its form): `PATH FN walks=W clones=C :: why`; `#`
/// lines and blank lines are not rows. Err names a line that is not a row.
pub fn parse_known(text: &str) -> Result<Vec<Known>, String> {
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let bad = || format!("{KNOWN_FILE}:{}: not `PATH FN walks=W clones=C :: why`", n + 1);
        let (head, why) = line.split_once(" :: ").ok_or_else(bad)?;
        let parts: Vec<&str> = head.split_whitespace().collect();
        let [rel, func, walks, clones] = parts.as_slice() else { return Err(bad()) };
        let count = |p: &str, key: &str| -> Result<usize, String> {
            p.strip_prefix(key).and_then(|v| v.parse().ok()).ok_or_else(bad)
        };
        if why.trim().is_empty() {
            return Err(format!("{KNOWN_FILE}:{}: a row says why", n + 1));
        }
        out.push(Known {
            rel: (*rel).to_string(),
            func: (*func).to_string(),
            walks: count(walks, "walks=")?,
            clones: count(clones, "clones=")?,
            why: why.trim().to_string(),
        });
    }
    Ok(out)
}

/// Counts per draw fn: (path, fn) to (walks, clones).
pub fn tally(found: &[Finding]) -> BTreeMap<(String, String), (usize, usize)> {
    let mut out: BTreeMap<(String, String), (usize, usize)> = BTreeMap::new();
    for f in found {
        let at = out.entry((f.rel.clone(), f.func.clone())).or_default();
        match f.kind {
            Kind::Walk => at.0 += 1,
            Kind::Clone => at.1 += 1,
        }
    }
    out
}

/// What fails the ratchet, one message each: a fn with more hits than its row (or none), and a
/// row with more than its fn now has (lower it: the list only shrinks). `scanned` says which
/// paths the scan read, so a row under a root not scanned is not stale.
pub fn ratchet(found: &[Finding], known: &[Known], scanned: &dyn Fn(&str) -> bool) -> Vec<String> {
    let counts = tally(found);
    let mut out = Vec::new();
    let mut rows: BTreeMap<(String, String), (usize, usize)> = BTreeMap::new();
    for k in known {
        let at = rows.entry((k.rel.clone(), k.func.clone())).or_default();
        at.0 += k.walks;
        at.1 += k.clones;
    }
    for ((rel, func), &(walks, clones)) in &counts {
        let (kw, kc) = rows.get(&(rel.clone(), func.clone())).copied().unwrap_or((0, 0));
        if walks > kw || clones > kc {
            let hits: Vec<String> = found
                .iter()
                .filter(|f| &f.rel == rel && &f.func == func)
                .map(|f| format!("    {f}"))
                .collect();
            out.push(format!(
                "new: {rel} `{func}` has walks={walks} clones={clones}, {KNOWN_FILE} allows walks={kw} clones={kc}. \
                 Bound it to the viewport (skip/take over the visible range; see the files rail's row loop in \
                 cmux-tui/crates/cmux-tui/src/ui/sidebar.rs), cache the model between frames (acpmux \
                 src/tui/render/cache.rs), or add the fn to {KNOWN_FILE} with a reason:\n{}",
                hits.join("\n")
            ));
        }
    }
    for ((rel, func), &(kw, kc)) in &rows {
        if !scanned(rel) {
            continue;
        }
        let (walks, clones) = counts.get(&(rel.clone(), func.clone())).copied().unwrap_or((0, 0));
        if walks < kw || clones < kc {
            let row = if walks + clones == 0 {
                "take the row out".to_string()
            } else {
                format!("lower the row to walks={walks} clones={clones}")
            };
            out.push(format!(
                "fewer: {rel} `{func}` now has walks={walks} clones={clones}, under its row's walks={kw} clones={kc}: {row} in {KNOWN_FILE} (the list only shrinks)"
            ));
        }
    }
    out
}

#[cfg(test)]
#[path = "visible_only_tests.rs"]
mod tests;
