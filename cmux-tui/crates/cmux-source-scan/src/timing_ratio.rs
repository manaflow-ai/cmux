//! Wall-clock ratio and percentile asserts in cmux-tui's default Rust test run.
//!
//! The class (cmuxterm-hq docs/handbook/timing-on-a-busy-host.md, fix 7): a test in the default,
//! non-ignored run times work on the wall clock and asserts a ratio of two timings
//! (`busy < idle * 4`, `busy / idle < 4`) or an upper bound on a percentile (`p95 < bound`). CI
//! runs cmux-tui's tests under cargo-nextest, one process per test and every test binary at once,
//! so the load beside the test sets the number: cmux#41346 went red on `busy < idle * 4` in
//! acpmux's lib run, fixed in cmux#41391. Keep a deterministic ordering or liveness check in the
//! default run and move the ratio to an `#[ignore]`d test for its own run, or give it every test
//! thread in nextest (`threads-required = 'num-test-threads'` in cmux-tui/.config/nextest.toml).
//!
//! How it reads a test: the file is parsed with `syn`; test functions, their attributes (in any
//! order), inline modules, assert macros and their conditions come from the syntax tree, so a
//! brace in a string or an `#[ignore]` above `#[test]` reads as what it is. It follows the test
//! body's `let`, `for`, assignment and `push` statements, so a name holds what it was built from:
//! `t.elapsed()`, `Instant::now() - t`, `x.duration_since(t)`, a local fn that reads the clock and
//! returns a `Duration`, a Vec of those, a percentile of them (`percentile(&v, 0.95)`,
//! `stats.p99`, `let p99 = sorted[..]`). It flags a comparison when
//!   - one side is a ratio of two timings (`busy / idle`), or both sides are timings and one is
//!     scaled by a constant (`busy < idle * MAX_RATIO`, `4 * idle > busy`), or both are timings
//!     taken apart (`handle_us <= json_us`: a ratio against 1);
//!   - the upper-bounded side is a percentile and the bound is not a timing from the same run
//!     (`p95 < P95_BUDGET_MS`, `metrics.p99 < budget.p99`).
//!
//! It does not flag `p99 <= max` of one sample set (an order load does not change), a lower bound
//! (load only makes a timing longer), or a plain `elapsed < TIMEOUT` (a deadline). A name it cannot
//! follow (a parameter, a match binding) is read by its words: `latency`, `busy`, `*_ms` are
//! timings, `p95`, `median` percentiles, `budget`, `limit`, `timeout` and SCREAMING_CASE bounds.
//!
//! Skipped: `#[ignore]`, `start_paused = true` (tokio's paused clock), a `// not wall-clock: <why>`
//! comment on the line above the assert, and a test nextest runs alone or not at all
//! ([`crate::nextest`]).
//!
//! This replaces cmuxterm-hq's tools/rust-timing-ratio/check.py, which tokenized Rust by hand
//! (hq#9478, hq#9512); its rules and rows carry over (timing_ratio_rows.txt).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt;
use std::path::{Path, PathBuf};

use proc_macro2::{Span, TokenStream, TokenTree};
use quote::ToTokens;
use syn::parse::ParseStream;
use syn::parse::discouraged::Speculative;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{Attribute, BinOp, Block, Expr, ExprBinary, Member, Pat, ReturnType, Type, UnOp};

use crate::nextest::{FileTests, Layout, TestId};
use crate::source::{has_ident, rel_path, rust_files, snippet};

const NOT_WALL_CLOCK: &str = "not wall-clock:";
const ASSERT_MACROS: [&str; 9] = [
    "assert",
    "debug_assert",
    "assert_eq",
    "assert_ne",
    "debug_assert_eq",
    "debug_assert_ne",
    "prop_assert",
    "prop_assert_eq",
    "prop_assert_ne",
];
const TEST_ATTRS: [&str; 3] = ["test", "rstest", "test_case"];
const PCT_WORDS: [&str; 4] = ["median", "percentile", "percentiles", "quantile"];
const BOUND_WORDS: [&str; 13] = [
    "budget",
    "budgets",
    "bound",
    "bounds",
    "limit",
    "limits",
    "deadline",
    "timeout",
    "allowed",
    "threshold",
    "ceiling",
    "cap",
    "slo",
];
const TIMING_WORDS: [&str; 20] = [
    "elapsed",
    "took",
    "latency",
    "latencies",
    "wall",
    "busy",
    "idle",
    "loaded",
    "quiet",
    "baseline",
    "cold",
    "warm",
    "echo",
    "echoes",
    "rtt",
    "duration",
    "durations",
    "timing",
    "timings",
    "trip",
];
const UNIT_WORDS: [&str; 7] = ["us", "ms", "ns", "micros", "millis", "nanos", "secs"];
const COUNT_METHODS: [&str; 9] =
    ["len", "count", "is_empty", "capacity", "is_some", "is_none", "is_ok", "is_err", "contains"];
const SINCE_METHODS: [&str; 3] =
    ["duration_since", "saturating_duration_since", "checked_duration_since"];
const PUSHES: [&str; 7] = ["push", "push_back", "push_front", "insert", "extend", "append", "send"];
/// A file with none of these words reads no clock and is not parsed.
const CLOCK_WORDS: [&str; 5] = ["Instant", "elapsed", "SystemTime", "Duration", "duration_since"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub rel: String,
    pub line: usize,
    pub kind: &'static str,
    pub test: String,
    /// The comparison, its whitespace folded.
    pub text: String,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}: {} in default-run test `{}`: {}",
            self.rel, self.line, self.kind, self.test, self.text
        )
    }
}

/// A scan of a checkout.
#[derive(Debug, Default)]
pub struct Scan {
    pub found: Vec<Finding>,
    /// Files that do not parse, with the parser's error; judged no further.
    pub unparsed: Vec<String>,
    pub files: usize,
}

/// Every finding under `roots` (files or directories; default `checkout`/cmux-tui/crates), paths
/// from `checkout`. Err for a missing checkout or scan root, a root with no `.rs` file, or a
/// nextest.toml that does not parse: no scan is not a clean scan.
pub fn scan(checkout: &Path, roots: &[PathBuf]) -> Result<Scan, String> {
    scan_with(checkout, roots, scan_text)
}

/// The judge of one file [`scan_with`] runs: [`scan_text`] or [`spread_bounds`].
pub type Judge =
    fn(&str, &str, &dyn Fn(&TestId) -> bool, &FileTests) -> Result<Vec<Finding>, syn::Error>;

/// [`scan`] with another judge of each file, on the same walk, layout and nextest reading.
pub fn scan_with(checkout: &Path, roots: &[PathBuf], judge: Judge) -> Result<Scan, String> {
    if !checkout.is_dir() {
        return Err(format!("{}: no such checkout", checkout.display()));
    }
    let checkout = checkout.canonicalize().map_err(|e| format!("{}: {e}", checkout.display()))?;
    let roots: Vec<PathBuf> =
        if roots.is_empty() { vec![checkout.join("cmux-tui/crates")] } else { roots.to_vec() };
    let mut layout = Layout::default();
    let mut out = Scan::default();
    for root in &roots {
        let Ok(root) = root.canonicalize() else {
            return Err(format!("{}: scan root does not exist", root.display()));
        };
        let files = rust_files(&root);
        if files.is_empty() {
            return Err(format!("{}: scan root holds no .rs file", root.display()));
        }
        for path in files {
            out.files += 1;
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let tests = layout.file_tests(&path, &checkout);
            if matches!(tests, FileTests::NotRun) {
                continue;
            }
            let profiles = layout
                .profiles(&path, &checkout)
                .map_err(|e| format!("nextest config above {}: {e}", path.display()))?;
            let beside = |t: &TestId| profiles.as_ref().is_none_or(|p| p.runs_beside_others(t));
            let rel = rel_path(&checkout, &path);
            match judge(&rel, &text, &beside, &tests) {
                Ok(found) => out.found.extend(found),
                Err(error) => out.unparsed.push(format!("{rel}: {error}")),
            }
        }
    }
    Ok(out)
}

/// The findings of one file: `beside` says whether nextest runs a test beside others, `tests`
/// how it names the file's tests.
pub fn scan_text(
    rel: &str,
    text: &str,
    beside: &dyn Fn(&TestId) -> bool,
    tests: &FileTests,
) -> Result<Vec<Finding>, syn::Error> {
    if !text.contains("test") || !CLOCK_WORDS.iter().any(|w| text.contains(w)) {
        return Ok(Vec::new());
    }
    let file = syn::parse_file(text)?;
    let clock_ident =
        |name: &str| CLOCK_WORDS[..4].contains(&name) || SINCE_METHODS.contains(&name);
    if !flatten(file.to_token_stream())
        .iter()
        .any(|t| matches!(t, Flat::Ident(i) if clock_ident(i.as_str())))
    {
        return Ok(Vec::new());
    }
    let mut items = Items::default();
    items.visit_file(&file);
    let lines: Vec<&str> = text.lines().collect();
    let mut found = Vec::new();
    for test in &items.tests {
        if !beside(&tests.id(&test.mods, &test.name)) {
            continue;
        }
        let mut body = BodyScan {
            sc: Scope { env: HashMap::new(), consts: &items.consts, clock_fns: &items.clock_fns },
            lines: &lines,
            found: Vec::new(),
        };
        body.visit_block(&test.block);
        for (span, kind) in body.found {
            found.push(Finding {
                rel: rel.to_string(),
                line: span.start().line,
                kind,
                test: test.name.clone(),
                text: snippet(&lines, span),
            });
        }
    }
    Ok(found)
}

/// A shape the check is known to miss: `site` is `PATH TEST COMPARISON` (the path from the
/// checkout, the test, the comparison [`spread_bounds`] names), `row` a file of that shape. [`scan_text`] finds nothing
/// in `row` and [`spread_bounds`] finds it there; acpmux's `source_scan_smoke` holds both, and
/// holds [`spread_bounds`] over cmux-tui/crates to exactly these sites, so a fix that catches the
/// shape, or a new instance of it, fails there until this list changes with it.
#[derive(Debug, Clone, Copy)]
pub struct KnownMiss {
    pub site: &'static str,
    pub why: &'static str,
    pub row: &'static str,
}

pub const KNOWN_MISSES: &[KnownMiss] = &[KnownMiss {
    site: "cmux-tui/crates/acpmux/tests/start_mode.rs \
           the_policy_gate_round_trip_under_approve_all_is_measured g50 < 500.0",
    why: "milliseconds parsed from a JSON log (`hook[\"ms\"].as_f64()`), then a median taken by a \
          local fn that sorts them: no clock is read, and `g50` is no percentile word",
    row: include_str!("timing_ratio_known_miss_start_mode.txt"),
}];

const SPREAD_KIND: &str = "spread bound";
const SORTS: [&str; 5] = ["sort", "sort_by", "sort_by_key", "sort_unstable", "sort_unstable_by"];

/// The shape of [`KNOWN_MISSES`]: in a default-run test, an upper bound on a name taken from
/// `let (a, b, ..) = f(..)`, where `f` is a local fn that sorts and returns a tuple of floats (a
/// hand-rolled percentile helper, `fn spread(ms: &mut [f64]) -> (f64, f64, f64)`). Not a rule of
/// the check: the count its ratchet holds.
pub fn spread_bounds(
    rel: &str,
    text: &str,
    beside: &dyn Fn(&TestId) -> bool,
    tests: &FileTests,
) -> Result<Vec<Finding>, syn::Error> {
    if !text.contains("test") || !text.contains("sort") {
        return Ok(Vec::new());
    }
    let file = syn::parse_file(text)?;
    let mut items = Items::default();
    items.visit_file(&file);
    if items.spread_fns.is_empty() {
        return Ok(Vec::new());
    }
    let lines: Vec<&str> = text.lines().collect();
    let mut found = Vec::new();
    for test in &items.tests {
        if !beside(&tests.id(&test.mods, &test.name)) {
            continue;
        }
        let mut body =
            SpreadScan { spread_fns: &items.spread_fns, names: HashSet::new(), found: Vec::new() };
        body.visit_block(&test.block);
        for span in body.found {
            found.push(Finding {
                rel: rel.to_string(),
                line: span.start().line,
                kind: SPREAD_KIND,
                test: test.name.clone(),
                text: snippet(&lines, span),
            });
        }
    }
    Ok(found)
}

struct SpreadScan<'a> {
    spread_fns: &'a HashSet<String>,
    names: HashSet<String>,
    found: Vec<Span>,
}

impl SpreadScan<'_> {
    fn spread_name(&self, e: &Expr) -> bool {
        matches!(e, Expr::Path(p) if p.path.get_ident().is_some_and(|i| self.names.contains(&i.to_string())))
    }
}

impl<'ast> Visit<'ast> for SpreadScan<'_> {
    fn visit_local(&mut self, l: &'ast syn::Local) {
        if let (Pat::Tuple(t), Some(init)) = (&l.pat, &l.init)
            && let Expr::Call(call) = &*init.expr
            && let Expr::Path(f) = &*call.func
            && f.path
                .segments
                .last()
                .is_some_and(|s| self.spread_fns.contains(&s.ident.to_string()))
        {
            for elem in &t.elems {
                if let Pat::Ident(i) = elem {
                    self.names.insert(i.ident.to_string());
                }
            }
        }
        visit::visit_local(self, l);
    }
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        if !ASSERT_MACROS.contains(&macro_name(mac).as_str()) {
            return;
        }
        let Ok(args) = mac.parse_body_with(lenient_exprs) else {
            return;
        };
        let conds = if ["assert", "debug_assert", "prop_assert"].contains(&macro_name(mac).as_str())
        {
            1
        } else {
            2
        };
        for cond in args.iter().take(conds) {
            for cmp in comparisons(cond) {
                let bounded = match cmp.op {
                    BinOp::Lt(_) | BinOp::Le(_) => &cmp.left,
                    _ => &cmp.right,
                };
                if self.spread_name(bounded) {
                    self.found.push(cmp.span());
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// What an expression holds

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Base {
    Const,
    Other,
    /// A closure that reads the clock.
    ClockFn,
    Instant,
    Timing,
    Pct,
    Ratio,
}

impl Base {
    fn rank(self) -> u8 {
        match self {
            Base::Const => 0,
            Base::Other | Base::ClockFn => 1,
            Base::Instant => 2,
            Base::Timing => 3,
            Base::Pct => 4,
            Base::Ratio => 5,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Kind {
    base: Base,
    /// Scaled by a constant in the expression being judged (`idle * 4`).
    scaled: bool,
    /// Where a measurement came from: `at:LINE:COL` of a clock read or call, `name:x` of a name.
    src: BTreeSet<String>,
}

impl Kind {
    fn of(base: Base) -> Kind {
        Kind { base, scaled: false, src: BTreeSet::new() }
    }

    fn from(base: Base, src: BTreeSet<String>) -> Kind {
        Kind { base, scaled: false, src }
    }

    fn measured(&self) -> bool {
        matches!(self.base, Base::Timing | Base::Pct)
    }

    fn with_src(mut self, src: BTreeSet<String>) -> Kind {
        self.src = src;
        self
    }

    fn scaled(mut self) -> Kind {
        self.scaled = true;
        self
    }
}

/// The source of a value read at `node`.
fn here(node: &impl Spanned) -> BTreeSet<String> {
    let at = node.span().start();
    BTreeSet::from([format!("at:{}:{}", at.line, at.column)])
}

fn union<'k>(kinds: impl IntoIterator<Item = &'k Kind>) -> BTreeSet<String> {
    kinds.into_iter().flat_map(|k| k.src.iter().cloned()).collect()
}

fn join<'k>(kinds: impl IntoIterator<Item = &'k Kind> + Clone) -> Kind {
    let mut best = Kind::of(Base::Const);
    for k in kinds.clone() {
        if k.base.rank() > best.base.rank() || (k.base == best.base && k.scaled && !best.scaled) {
            best = k.clone();
        }
    }
    best.with_src(union(kinds))
}

fn words(name: &str) -> Vec<String> {
    name.to_lowercase().split('_').filter(|w| !w.is_empty()).map(str::to_string).collect()
}

fn is_screaming(name: &str) -> bool {
    name.chars().any(char::is_alphabetic) && name == name.to_uppercase()
}

fn is_pct_word(w: &str) -> bool {
    PCT_WORDS.contains(&w)
        || (w.len() >= 3
            && w.strip_prefix('p').is_some_and(|d| d.chars().all(|c| c.is_ascii_digit())))
}

fn names_pct(name: &str) -> bool {
    words(name).iter().any(|w| is_pct_word(w))
}

/// What a name holds when its binding can't be followed: read by its words.
fn name_kind(name: &str) -> Kind {
    if is_screaming(name) {
        return Kind::of(Base::Const);
    }
    let ws = words(name);
    if ws.iter().any(|w| BOUND_WORDS.contains(&w.as_str())) {
        return Kind::of(Base::Const);
    }
    if ws.iter().any(|w| is_pct_word(w)) {
        return Kind::of(Base::Pct);
    }
    let unit = ws.len() > 1 && ws.last().is_some_and(|w| UNIT_WORDS.contains(&w.as_str()));
    let bare_unit = matches!(ws.as_slice(), [w] if ["us", "ms", "ns"].contains(&w.as_str()));
    if ws.iter().any(|w| TIMING_WORDS.contains(&w.as_str())) || unit || bare_unit {
        return Kind::of(Base::Timing);
    }
    Kind::of(Base::Other)
}

fn named(name: &str, key: String) -> Kind {
    let k = name_kind(name);
    if k.measured() { k.with_src(BTreeSet::from([key])) } else { k }
}

fn arith(op: char, a: &Kind, b: &Kind) -> Kind {
    let src = union([a, b]);
    let both_const = a.base == Base::Const && b.base == Base::Const;
    let plain = || Kind::of(if both_const { Base::Const } else { Base::Other });
    match op {
        '*' | '/' if a.base == Base::Ratio && !b.measured() => a.clone().with_src(src),
        '*' if b.base == Base::Ratio && !a.measured() => b.clone().with_src(src),
        '/' if a.measured() && b.measured() => Kind::from(Base::Ratio, src),
        '*' if a.measured() && b.measured() => Kind::of(Base::Other),
        '*' if a.measured() => a.clone().scaled().with_src(src),
        '*' if b.measured() => b.clone().scaled().with_src(src),
        '/' if a.measured() => a.clone().scaled().with_src(src),
        '*' | '/' => plain(),
        '+' | '-' if a.base == Base::Instant && b.base == Base::Instant => {
            if op == '-' {
                Kind::from(Base::Timing, src)
            } else {
                Kind::of(Base::Other)
            }
        }
        '+' | '-' if a.base == Base::Instant || b.base == Base::Instant => {
            Kind::from(Base::Instant, src)
        }
        '+' | '-' if a.measured() || b.measured() => {
            let mut m = join([a, b]);
            m.scaled = a.scaled || b.scaled;
            m
        }
        '+' | '-' => plain(),
        '%' if a.base == Base::Const => a.clone(),
        _ => Kind::of(Base::Other),
    }
}

fn arith_op(op: &BinOp) -> Option<char> {
    Some(match op {
        BinOp::Add(_) | BinOp::AddAssign(_) => '+',
        BinOp::Sub(_) | BinOp::SubAssign(_) => '-',
        BinOp::Mul(_) | BinOp::MulAssign(_) => '*',
        BinOp::Div(_) | BinOp::DivAssign(_) => '/',
        BinOp::Rem(_) => '%',
        _ => return None,
    })
}

fn is_assign(op: &BinOp) -> bool {
    matches!(
        op,
        BinOp::AddAssign(_)
            | BinOp::SubAssign(_)
            | BinOp::MulAssign(_)
            | BinOp::DivAssign(_)
            | BinOp::RemAssign(_)
            | BinOp::BitXorAssign(_)
            | BinOp::BitAndAssign(_)
            | BinOp::BitOrAssign(_)
            | BinOp::ShlAssign(_)
            | BinOp::ShrAssign(_)
    )
}

fn scale_op(method: &str) -> Option<char> {
    match method {
        "mul_f64" | "mul_f32" | "checked_mul" | "saturating_mul" => Some('*'),
        "div_f64" | "div_f32" | "checked_div" | "div_duration_f64" | "div_duration_f32" => {
            Some('/')
        }
        _ => None,
    }
}

/// The segments of a path expression, after any `<T as Trait>::`.
fn path_segs(p: &syn::ExprPath) -> Vec<String> {
    let skip = p.qself.as_ref().map_or(0, |q| q.position);
    p.path.segments.iter().skip(skip).map(|s| s.ident.to_string()).collect()
}

/// The name an expression is, when it is one plain identifier.
fn single_ident(e: &Expr) -> Option<String> {
    match e {
        Expr::Path(p) if p.qself.is_none() && p.path.segments.len() == 1 => {
            p.path.segments.first().map(|s| s.ident.to_string())
        }
        _ => None,
    }
}

/// The tokens of an expression run together, as a name to read words from (`budget.p95`).
fn compact(e: &Expr) -> String {
    e.to_token_stream().to_string().split_whitespace().collect()
}

struct Scope<'a> {
    env: HashMap<String, Kind>,
    consts: &'a HashSet<String>,
    clock_fns: &'a HashMap<String, Option<Vec<bool>>>,
}

impl Scope<'_> {
    fn kind_of(&self, e: &Expr) -> Kind {
        match e {
            Expr::Lit(_) => Kind::of(Base::Const),
            Expr::Paren(x) => self.kind_of(&x.expr),
            Expr::Group(x) => self.kind_of(&x.expr),
            Expr::Cast(x) => self.kind_of(&x.expr),
            Expr::Try(x) => self.kind_of(&x.expr),
            Expr::Await(x) => self.kind_of(&x.base),
            Expr::Reference(x) => self.kind_of(&x.expr),
            Expr::Unary(x) => match x.op {
                UnOp::Not(_) => Kind::of(Base::Other),
                _ => self.kind_of(&x.expr),
            },
            Expr::Path(p) => self.path_kind(p),
            Expr::Binary(b) => match arith_op(&b.op) {
                Some(op) if !is_assign(&b.op) => {
                    arith(op, &self.kind_of(&b.left), &self.kind_of(&b.right))
                }
                _ => Kind::of(Base::Other), // a bool, a bit operation or an assignment
            },
            Expr::Tuple(t) => self.join_all(t.elems.iter()),
            Expr::Array(a) => self.join_all(a.elems.iter()),
            Expr::Repeat(r) => self.join_all([&*r.expr, &*r.len]),
            Expr::Index(i) => self.kind_of(&i.expr),
            Expr::Block(b) => match b.block.stmts.last() {
                Some(syn::Stmt::Expr(tail, None)) => self.kind_of(tail),
                _ => Kind::of(Base::Other),
            },
            Expr::Field(f) => self.field_kind(f),
            Expr::MethodCall(m) => self.method_kind(m),
            Expr::Call(c) => self.call_kind(c),
            Expr::Closure(c) => {
                if reads_clock(c.to_token_stream()) {
                    return Kind::of(Base::ClockFn);
                }
                // A closure over a measurement (`|busy| run(busy).p99.min(..)`, cmux#41346's
                // shape) holds what its body is. Its calls share its sources, so two calls
                // compare as one sample set's order (`at(a) < at(b)`) unless one is scaled.
                let body = self.kind_of(&c.body);
                if body.measured() || body.base == Base::Ratio {
                    Kind { scaled: false, ..body }
                } else {
                    Kind::of(Base::Other)
                }
            }
            _ => Kind::of(Base::Other),
        }
    }

    fn join_all<'e>(&self, exprs: impl IntoIterator<Item = &'e Expr>) -> Kind {
        let kinds: Vec<Kind> = exprs.into_iter().map(|e| self.kind_of(e)).collect();
        if kinds.is_empty() { Kind::of(Base::Other) } else { join(&kinds) }
    }

    fn path_kind(&self, p: &syn::ExprPath) -> Kind {
        let segs = path_segs(p);
        let Some(last) = segs.last() else {
            return Kind::of(Base::Other);
        };
        if segs.len() == 1 {
            if let Some(k) = self.env.get(last) {
                return k.clone();
            }
            if self.consts.contains(last) {
                return Kind::of(Base::Const);
            }
            return named(last, format!("name:{last}"));
        }
        if is_screaming(last) || self.consts.contains(last) {
            return Kind::of(Base::Const);
        }
        if last.starts_with(|c: char| c.is_lowercase()) {
            return named(last, format!("name:{}", segs.join("::")));
        }
        Kind::of(Base::Other)
    }

    fn field_kind(&self, f: &syn::ExprField) -> Kind {
        let base = self.kind_of(&f.base);
        let field = match &f.member {
            Member::Named(ident) => ident.to_string(),
            Member::Unnamed(index) => index.index.to_string(),
        };
        if base.measured() || base.base == Base::Ratio {
            if names_pct(&field) {
                return Kind { base: Base::Pct, ..base };
            }
            return base;
        }
        let base_name = compact(&f.base);
        let bound_base =
            words(&base_name.replace('.', "_")).iter().any(|w| BOUND_WORDS.contains(&w.as_str()));
        if bound_base || base.base == Base::Const {
            return Kind::of(Base::Const);
        }
        named(&field, format!("name:{base_name}"))
    }

    fn method_kind(&self, m: &syn::ExprMethodCall) -> Kind {
        let recv = self.kind_of(&m.receiver);
        let args: Vec<Kind> = m.args.iter().map(|a| self.kind_of(a)).collect();
        let name = m.method.to_string();
        if name == "elapsed" {
            let src =
                if recv.base == Base::Instant && !recv.src.is_empty() { recv.src } else { here(m) };
            return Kind::from(Base::Timing, src);
        }
        if SINCE_METHODS.contains(&name.as_str()) {
            let src = union(std::iter::once(&recv).chain(&args));
            return Kind::from(Base::Timing, if src.is_empty() { here(m) } else { src });
        }
        if COUNT_METHODS.contains(&name.as_str()) {
            return Kind::of(Base::Other);
        }
        if names_pct(&name) {
            if recv.measured() || recv.base == Base::Other {
                let src = if recv.src.is_empty() { here(m) } else { recv.src };
                return Kind::from(Base::Pct, src);
            }
            return recv;
        }
        if let (Some(op), Some(first)) = (scale_op(&name), args.first()) {
            return arith(op, &recv, first);
        }
        let joins = [
            "max",
            "min",
            "saturating_sub",
            "checked_sub",
            "abs_diff",
            "saturating_add",
            "checked_add",
        ];
        if joins.contains(&name.as_str())
            && let Some(first) = args.first()
        {
            return if recv.base != Base::Instant { join([&recv, first]) } else { recv };
        }
        if recv.base == Base::ClockFn && ["call", "call_mut", "call_once"].contains(&name.as_str())
        {
            return Kind::from(Base::Timing, here(m));
        }
        recv
    }

    fn call_kind(&self, c: &syn::ExprCall) -> Kind {
        let args: Vec<Kind> = c.args.iter().map(|a| self.kind_of(a)).collect();
        let segs = match &*c.func {
            Expr::Path(p) => path_segs(p),
            _ => Vec::new(),
        };
        let last = segs.last().map_or("", String::as_str);
        let parent = segs.len().checked_sub(2).and_then(|i| segs.get(i)).map(String::as_str);
        let measured: Vec<&Kind> =
            args.iter().filter(|a| a.measured() || a.base == Base::Ratio).collect();
        let all_const = !args.is_empty() && args.iter().all(|a| a.base == Base::Const);
        if matches!(parent, Some("Instant" | "SystemTime")) && last == "now" {
            return Kind::from(Base::Instant, here(c));
        }
        if parent == Some("Duration") {
            return if measured.is_empty() { Kind::of(Base::Const) } else { join(measured) };
        }
        if segs.len() == 1
            && let Some(v) = self.env.get(last)
        {
            return match v.base {
                Base::ClockFn => Kind::from(Base::Timing, here(c)),
                Base::Other => Kind::of(Base::Other),
                _ => v.clone(),
            };
        }
        if !last.is_empty() && names_pct(last) {
            let src = union(measured.iter().copied());
            return Kind::from(Base::Pct, if src.is_empty() { here(c) } else { src });
        }
        if let Some(flags) = self.clock_fns.get(last) {
            return if flags.as_ref().is_none_or(|f| f.iter().all(|x| *x)) {
                Kind::from(Base::Timing, here(c))
            } else {
                Kind::of(Base::Other)
            };
        }
        if COUNT_METHODS.contains(&last) {
            return Kind::of(Base::Other);
        }
        if last.starts_with(|ch: char| ch.is_uppercase()) {
            // A constructor: Some(x), Ok(x), Stats::new(..) keep the measure.
            if !measured.is_empty() {
                return join(measured);
            }
            return Kind::of(if all_const { Base::Const } else { Base::Other });
        }
        if !measured.is_empty() {
            return join(measured);
        }
        if all_const {
            // test_timeout(Duration::from_secs(5)): a bound built from constants.
            return Kind::of(Base::Const);
        }
        if !last.is_empty() && name_kind(last).base == Base::Timing && !is_screaming(last) {
            return Kind::from(Base::Timing, BTreeSet::from([format!("name:{last}")]));
        }
        Kind::of(Base::Other)
    }

    /// The tuple positions of a clock fn's value that are timings, when `e` calls one that
    /// returns a tuple.
    fn tuple_fn_flags(&self, e: &Expr) -> Option<&Vec<bool>> {
        let Expr::Call(c) = e else {
            return None;
        };
        let Expr::Path(p) = &*c.func else {
            return None;
        };
        self.clock_fns.get(path_segs(p).last()?)?.as_ref()
    }

    /// What the name at `pos` in a pattern bound to `value` (of kind `vkind`) holds.
    fn kind_at(&self, value: Option<&Expr>, pos: &[i64], vkind: &Kind) -> Kind {
        let Some(value) = value else {
            return vkind.clone();
        };
        if pos.first().is_none_or(|p| *p < 0) {
            return vkind.clone();
        }
        let mut node = value;
        for (depth, &p) in pos.iter().enumerate() {
            loop {
                node = match node {
                    Expr::Paren(x) => &x.expr,
                    Expr::Try(x) => &x.expr,
                    _ => break,
                };
            }
            let index = usize::try_from(p).unwrap_or(usize::MAX);
            if let Expr::Tuple(t) = node
                && let Some(element) = t.elems.iter().nth(index)
            {
                node = element;
                continue;
            }
            if let Some(flags) = self.tuple_fn_flags(node)
                && depth == pos.len() - 1
            {
                return if flags.get(index).copied().unwrap_or(false) {
                    Kind::from(Base::Timing, here(node))
                } else {
                    Kind::of(Base::Other)
                };
            }
            return vkind.clone();
        }
        self.kind_of(node)
    }

    /// Bind the names of `pat` to what `value` (of kind `vkind`) holds.
    fn bind(&mut self, pat: &Pat, value: Option<&Expr>, vkind: &Kind) {
        let mut names = Vec::new();
        pattern_names(pat, &mut Vec::new(), &mut names);
        for (name, pos) in names {
            let mut k = self.kind_at(value, &pos, vkind);
            // A name holds a measurement in its own unit: `let json_us = elapsed * 1e6 / n` is not
            // scaled against anything; only a scale in the compared expression is.
            k.scaled = false;
            if k.measured() && names_pct(&name) {
                k.base = Base::Pct;
            }
            self.env.insert(name, k);
        }
    }

    fn judge(&self, cmp: &ExprBinary) -> Option<&'static str> {
        const RATIO: &str = "ratio of two timings";
        let (lk, rk) = (self.kind_of(&cmp.left), self.kind_of(&cmp.right));
        if lk.base == Base::Ratio || rk.base == Base::Ratio {
            return Some(RATIO);
        }
        if lk.measured() && rk.measured() {
            if lk.scaled || rk.scaled {
                return Some(RATIO);
            }
            if lk.src.intersection(&rk.src).next().is_some() {
                return None; // p99 <= max: one sample set's own order, which load does not change
            }
            let taken = |k: &Kind| k.src.iter().any(|s| s.starts_with("at:"));
            if taken(&lk) && taken(&rk) {
                return Some(RATIO); // two timings taken apart (`handle_us <= json_us`)
            }
            return None; // a name read by its words (`since_ms`) may be a timestamp
        }
        let upper = if matches!(cmp.op, BinOp::Lt(_) | BinOp::Le(_)) { &lk } else { &rk };
        (upper.base == Base::Pct).then_some("percentile bound")
    }
}

fn positional<'p>(
    elems: impl Iterator<Item = &'p Pat>,
    path: &mut Vec<i64>,
    out: &mut Vec<(String, Vec<i64>)>,
) {
    path.push(0);
    for (i, elem) in elems.enumerate() {
        if let Some(at) = path.last_mut() {
            *at = i64::try_from(i).unwrap_or(i64::MAX);
        }
        pattern_names(elem, path, out);
    }
    path.pop();
}

/// The names a pattern binds, with the tuple positions that lead to each: `(a, (b, c))` gives a
/// [0], b [1, 0]; a struct pattern's names get [-1] (no position).
fn pattern_names(pat: &Pat, path: &mut Vec<i64>, out: &mut Vec<(String, Vec<i64>)>) {
    match pat {
        Pat::Ident(p) => {
            let name = p.ident.to_string();
            if name.starts_with(|c: char| c.is_lowercase()) {
                out.push((name, path.clone()));
            }
            if let Some((_, sub)) = &p.subpat {
                pattern_names(sub, path, out);
            }
        }
        Pat::Tuple(t) => positional(t.elems.iter(), path, out),
        Pat::TupleStruct(t) => positional(t.elems.iter(), path, out),
        Pat::Slice(s) => positional(s.elems.iter(), path, out),
        Pat::Struct(s) => {
            let mut inner = Vec::new();
            for field in &s.fields {
                pattern_names(&field.pat, &mut Vec::new(), &mut inner);
            }
            out.extend(inner.into_iter().map(|(name, _)| (name, vec![-1])));
        }
        Pat::Reference(r) => pattern_names(&r.pat, path, out),
        Pat::Type(t) => pattern_names(&t.pat, path, out),
        Pat::Paren(p) => pattern_names(&p.pat, path, out),
        Pat::Or(o) => {
            for case in &o.cases {
                pattern_names(case, path, out);
            }
        }
        _ => {}
    }
}

/// The comparisons a condition asserts, through `( )`, `!`, `&&` and `||`.
fn comparisons(e: &Expr) -> Vec<&ExprBinary> {
    match e {
        Expr::Paren(x) => comparisons(&x.expr),
        Expr::Group(x) => comparisons(&x.expr),
        Expr::Unary(x) if matches!(x.op, UnOp::Not(_)) => comparisons(&x.expr),
        Expr::Binary(b) if matches!(b.op, BinOp::And(_) | BinOp::Or(_)) => {
            let mut out = comparisons(&b.left);
            out.extend(comparisons(&b.right));
            out
        }
        Expr::Binary(b)
            if matches!(b.op, BinOp::Lt(_) | BinOp::Le(_) | BinOp::Gt(_) | BinOp::Ge(_)) =>
        {
            vec![b]
        }
        _ => Vec::new(),
    }
}

// ---------------------------------------------------------------------------------------------
// Clock reads

#[derive(Debug, PartialEq, Eq)]
enum Flat {
    Ident(String),
    Punct(char),
    Other,
}

fn flatten(tokens: TokenStream) -> Vec<Flat> {
    fn walk(tokens: TokenStream, out: &mut Vec<Flat>) {
        for tree in tokens {
            match tree {
                TokenTree::Ident(i) => out.push(Flat::Ident(i.to_string())),
                TokenTree::Punct(p) => out.push(Flat::Punct(p.as_char())),
                TokenTree::Literal(_) => out.push(Flat::Other),
                TokenTree::Group(g) => {
                    out.push(Flat::Other);
                    walk(g.stream(), out);
                    out.push(Flat::Other);
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(tokens, &mut out);
    out
}

/// Whether `tokens` read the clock: `.elapsed`, `Instant::now`, `SystemTime::now`, a
/// `duration_since`.
fn reads_clock(tokens: TokenStream) -> bool {
    let flat = flatten(tokens);
    flat.iter().enumerate().any(|(k, t)| {
        let Flat::Ident(name) = t else {
            return false;
        };
        match name.as_str() {
            "elapsed" => k.checked_sub(1).and_then(|j| flat.get(j)) == Some(&Flat::Punct('.')),
            "Instant" | "SystemTime" => {
                flat.get(k + 1) == Some(&Flat::Punct(':'))
                    && flat.get(k + 2) == Some(&Flat::Punct(':'))
                    && matches!(flat.get(k + 3), Some(Flat::Ident(now)) if now == "now")
            }
            other => SINCE_METHODS.contains(&other),
        }
    })
}

// ---------------------------------------------------------------------------------------------
// Items: test functions, consts, local clock helpers

struct TestFn {
    name: String,
    mods: Vec<String>,
    block: Block,
}

#[derive(Default)]
struct Items {
    mods: Vec<String>,
    tests: Vec<TestFn>,
    consts: HashSet<String>,
    /// Local fns whose value is a timing: None when all of it is, else which tuple positions are.
    clock_fns: HashMap<String, Option<Vec<bool>>>,
    /// Local fns that sort and return a tuple of floats ([`spread_bounds`]).
    spread_fns: HashSet<String>,
}

/// Whether an attribute's tokens set `start_paused = true` (tokio's paused clock), at any depth.
/// `start_paused = false` runs on the wall clock (#41523 F3).
fn starts_paused(tokens: TokenStream) -> bool {
    let trees: Vec<TokenTree> = tokens.into_iter().collect();
    trees.iter().enumerate().any(|(i, tree)| match tree {
        TokenTree::Group(group) => starts_paused(group.stream()),
        TokenTree::Ident(ident) if ident == "start_paused" => matches!(
            (trees.get(i + 1), trees.get(i + 2)),
            (Some(TokenTree::Punct(eq)), Some(TokenTree::Ident(value)))
                if eq.as_char() == '=' && value == "true"
        ),
        _ => false,
    })
}

fn macro_name(mac: &syn::Macro) -> String {
    mac.path.segments.last().map(|s| s.ident.to_string()).unwrap_or_default()
}

impl Items {
    fn consider(&mut self, attrs: &[Attribute], sig: &syn::Signature, block: &Block) {
        let paths: Vec<Vec<String>> = attrs
            .iter()
            .map(|a| a.path().segments.iter().map(|s| s.ident.to_string()).collect())
            .collect();
        let is_test =
            paths.iter().any(|p| p.last().is_some_and(|last| TEST_ATTRS.contains(&last.as_str())));
        if is_test {
            let ignored = paths.iter().any(|p| matches!(p.as_slice(), [only] if only == "ignore"));
            let paused = attrs.iter().any(|a| starts_paused(a.meta.to_token_stream()));
            if !ignored && !paused {
                self.tests.push(TestFn {
                    name: sig.ident.to_string(),
                    mods: self.mods.clone(),
                    block: block.clone(),
                });
            }
            return;
        }
        // A fn that reads the clock and returns a Duration (`-> Duration`, `-> Vec<Duration>`,
        // `-> (u64, Duration)`). One that builds a Duration from constants is not, and a number
        // from the clock (`fn now_ms() -> u64`) is a timestamp.
        let ReturnType::Type(_, ty) = &sig.output else {
            return;
        };
        if let Type::Tuple(t) = &**ty
            && t.elems
                .iter()
                .any(|e| ["f64", "f32"].iter().any(|f| has_ident(e.to_token_stream(), f)))
            && SORTS.iter().any(|m| has_ident(block.to_token_stream(), m))
        {
            self.spread_fns.insert(sig.ident.to_string());
        }
        if !has_ident(ty.to_token_stream(), "Duration") || !reads_clock(block.to_token_stream()) {
            return;
        }
        let flags = match &**ty {
            Type::Tuple(t) => {
                Some(t.elems.iter().map(|e| has_ident(e.to_token_stream(), "Duration")).collect())
            }
            Type::Paren(p) => Some(vec![has_ident(p.elem.to_token_stream(), "Duration")]),
            _ => None,
        };
        self.clock_fns.insert(sig.ident.to_string(), flags);
    }
}

impl<'ast> Visit<'ast> for Items {
    fn visit_item_fn(&mut self, i: &'ast syn::ItemFn) {
        self.consider(&i.attrs, &i.sig, &i.block);
        visit::visit_item_fn(self, i);
    }
    fn visit_impl_item_fn(&mut self, i: &'ast syn::ImplItemFn) {
        self.consider(&i.attrs, &i.sig, &i.block);
        visit::visit_impl_item_fn(self, i);
    }
    fn visit_item_mod(&mut self, i: &'ast syn::ItemMod) {
        let inline = i.content.is_some();
        if inline {
            self.mods.push(i.ident.to_string());
        }
        visit::visit_item_mod(self, i);
        if inline {
            self.mods.pop();
        }
    }
    fn visit_item_const(&mut self, i: &'ast syn::ItemConst) {
        self.consts.insert(i.ident.to_string());
        visit::visit_item_const(self, i);
    }
    fn visit_item_static(&mut self, i: &'ast syn::ItemStatic) {
        self.consts.insert(i.ident.to_string());
        visit::visit_item_static(self, i);
    }
    fn visit_impl_item_const(&mut self, i: &'ast syn::ImplItemConst) {
        self.consts.insert(i.ident.to_string());
        visit::visit_impl_item_const(self, i);
    }
    fn visit_trait_item_const(&mut self, i: &'ast syn::TraitItemConst) {
        self.consts.insert(i.ident.to_string());
        visit::visit_trait_item_const(self, i);
    }
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        // Items a macro wraps (`mod_tests! { #[test] fn .. }`); expression macros don't parse.
        if !ASSERT_MACROS.contains(&macro_name(mac).as_str())
            && let Ok(file) = syn::parse2::<syn::File>(mac.tokens.clone())
        {
            self.visit_file(&file);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// A test body: follow its bindings, judge its asserts

/// Comma-separated expressions, as many as parse; the rest of the input is skipped.
fn lenient_exprs(input: ParseStream) -> syn::Result<Vec<Expr>> {
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

struct BodyScan<'a> {
    sc: Scope<'a>,
    lines: &'a [&'a str],
    found: Vec<(Span, &'static str)>,
}

impl BodyScan<'_> {
    /// Whether the line above `line` (1-based) holds a `// not wall-clock: <why>` comment.
    fn not_wall_clock(&self, line: usize) -> bool {
        let above = line.checked_sub(2).and_then(|i| self.lines.get(i)).copied().unwrap_or("");
        above.split_once("//").is_some_and(|(_, comment)| comment.contains(NOT_WALL_CLOCK))
    }
}

impl<'ast> Visit<'ast> for BodyScan<'_> {
    fn visit_local(&mut self, l: &'ast syn::Local) {
        match &l.init {
            Some(init) => {
                let k = self.sc.kind_of(&init.expr);
                self.sc.bind(&l.pat, Some(&init.expr), &k);
            }
            None => self.sc.bind(&l.pat, None, &Kind::of(Base::Other)),
        }
        visit::visit_local(self, l);
    }
    fn visit_expr_let(&mut self, e: &'ast syn::ExprLet) {
        let k = self.sc.kind_of(&e.expr);
        self.sc.bind(&e.pat, Some(&e.expr), &k);
        visit::visit_expr_let(self, e);
    }
    fn visit_expr_for_loop(&mut self, f: &'ast syn::ExprForLoop) {
        let k = self.sc.kind_of(&f.expr);
        self.sc.bind(&f.pat, None, &k);
        visit::visit_expr_for_loop(self, f);
    }
    fn visit_expr_assign(&mut self, a: &'ast syn::ExprAssign) {
        let target = match &*a.left {
            Expr::Unary(u) if matches!(u.op, UnOp::Deref(_)) => &*u.expr,
            other => other,
        };
        if let Some(name) = single_ident(target) {
            let k = self.sc.kind_of(&a.right);
            self.sc.env.insert(name, k);
        }
        visit::visit_expr_assign(self, a);
    }
    fn visit_expr_binary(&mut self, b: &'ast ExprBinary) {
        let compound = matches!(
            b.op,
            BinOp::AddAssign(_) | BinOp::SubAssign(_) | BinOp::MulAssign(_) | BinOp::DivAssign(_)
        );
        if compound && let (Some(op), Some(name)) = (arith_op(&b.op), single_ident(&b.left)) {
            let old = self.sc.env.get(&name).cloned().unwrap_or_else(|| name_kind(&name));
            let k = arith(op, &old, &self.sc.kind_of(&b.right));
            self.sc.env.insert(name, k);
        }
        visit::visit_expr_binary(self, b);
    }
    fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
        if PUSHES.contains(&m.method.to_string().as_str())
            && let (Some(name), Some(last)) = (single_ident(&m.receiver), m.args.last())
        {
            let pushed = self.sc.kind_of(last);
            let old = self.sc.env.get(&name).cloned().unwrap_or_else(|| Kind::of(Base::Const));
            self.sc.env.insert(name, join([&old, &pushed]));
        }
        visit::visit_expr_method_call(self, m);
    }
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        let name = macro_name(mac);
        if ASSERT_MACROS.contains(&name.as_str()) {
            let line = mac.path.span().start().line;
            if self.not_wall_clock(line) {
                return;
            }
            let Ok(args) = mac.parse_body_with(lenient_exprs) else {
                return;
            };
            let conds = if ["assert", "debug_assert", "prop_assert"].contains(&name.as_str()) {
                1
            } else {
                2
            };
            for cond in args.iter().take(conds) {
                for cmp in comparisons(cond) {
                    if let Some(kind) = self.sc.judge(cmp) {
                        self.found.push((cmp.span(), kind));
                    }
                }
            }
            return;
        }
        // Another macro's body: statements (`tokio::spawn`-style blocks) or arguments
        // (`vec![..]`, `format!(.., x = ..)`).
        if let Ok(stmts) = mac.parse_body_with(Block::parse_within) {
            for stmt in &stmts {
                self.visit_stmt(stmt);
            }
        } else if let Ok(exprs) = mac.parse_body_with(lenient_exprs) {
            for e in &exprs {
                self.visit_expr(e);
            }
        }
    }
}

#[cfg(test)]
#[path = "timing_ratio_tests.rs"]
mod tests;
