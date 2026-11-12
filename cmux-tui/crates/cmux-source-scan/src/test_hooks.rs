//! No process-wide test hooks in acpmux (cmux#41350), judged on the syntax tree.
//!
//! acpmux's own tests run it over that crate's `src` (`test_hooks_tree.rs` there), so CI's
//! `cargo test -p acpmux --lib` enforces it; `cmux-source-scan test-hooks` runs it by hand.
//!
//! The test harness runs tests on parallel threads of one process. A test hook kept in a
//! process-wide static lets one test's hook replace or clear another's before the code it was
//! meant to stop ran, so the race the test forces never happens, or a test runs another test's
//! hook. folder_instructions::SWAP_HOOK failed 50 of 50 runs that way; hub::transfer_in::SWEEP_PAUSE
//! was one second user away from it.
//!
//! This check fails on a static in this crate's `src` that holds a test hook, outside a
//! `thread_local!` or `task_local!`:
//!   - a test slot: a `Mutex<Option<...>>` or `RwLock<Option<...>>` (also inside a OnceLock or
//!     LazyLock) under `#[cfg(test)]`, in a `#[cfg(test)]` module or function, or in a test file;
//!   - a closure in a cell: a Mutex, RwLock, OnceLock, LazyLock or OnceCell whose type holds
//!     `dyn Fn`/`FnMut`/`FnOnce`, `impl Fn...` or a `fn(...)` pointer;
//!   - any static named `...HOOK`.
//!
//! It reads each file with `syn`, never by hand (the script it replaces, check-test-hooks.py,
//! drew three rounds of tokenizer findings): statics, type aliases, structs, enums, `use`
//! renames and macro invocations come from the tree. A macro's statics are judged unless the
//! macro is `thread_local!` or `task_local!`, whose whole invocation (its span, not its lines) is
//! per thread; another macro's body is judged when it parses as items, statements or expressions
//! (`dbg!({ static .. })`: [`crate::source::visit_macro_body`]). A static's type is judged
//! after the file's own names in it are resolved: aliases (transitive and generic, arguments by
//! position, then defaults in order, then the body, a parameter going before every other name),
//! structs and enums by their fields, and `use ... as` renames. A name the file does not show (one
//! from another file of the crate, a glob import, no import at all) and every projection
//! (`T::Hook`, `<T as Future>::Output`: the check does not read trait impls) is `unresolved`, and
//! refuses the static when it heads the type or sits beside a cell. Two kinds of name are taken at
//! their word: one ending in a cell's name (`StdMutex`) is a cell, and the std names in WELL_KNOWN
//! are std's.
//!
//! The fixes: a per-thread hook, a `thread_local!` slot set through an `on_*` guard that takes it
//! off when dropped (folder_instructions::on_swap); or, when the code the hook stops runs on another
//! thread, a static only an `on_*` guard sets, holding a `Mutex<()>` serializer until it drops (the
//! `HOOK_TEST` pattern). The second needs a marker on the static, in the comment and attribute lines
//! directly above it or on its line:
//!
//! ```text
//! // test-hook-allow: serialized by HOOK_TEST, which every test that sets it holds
//! ```
//!
//! A marker that says `serialized by NAME` must name a `static NAME: Mutex<()>` (std or tokio) in
//! the same file. Any other marker states why the hook cannot race (one process per test, say), in
//! at least three words.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt;
use std::path::Path;

use crate::source::{line_of, rel_path, rust_files, snippet, visit_macro_body};
use proc_macro2::{Span, TokenStream, TokenTree};
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{
    Attribute, GenericArgument, GenericParam, Generics, Item, PathArguments, ReturnType, Type,
    TypeParamBound, UseTree,
};

/// Where a finding's path starts, from the repository root.
pub const CRATE_REL: &str = "cmux-tui/crates/acpmux/";
const CELLS: [&str; 6] = ["Mutex", "RwLock", "OnceLock", "LazyLock", "OnceCell", "Lazy"];
const CLOSURES: [&str; 3] = ["Fn", "FnMut", "FnOnce"];
const PER_THREAD: [&str; 2] = ["thread_local", "task_local"];
const MARKER: &str = "test-hook-allow:";
const PRELUDE: &[&str] = &[
    "Self",
    "bool",
    "char",
    "str",
    "u8",
    "u16",
    "u32",
    "u64",
    "u128",
    "usize",
    "i8",
    "i16",
    "i32",
    "i64",
    "i128",
    "isize",
    "f32",
    "f64",
    "Option",
    "Vec",
    "String",
    "Box",
    "Result",
    "Send",
    "Sync",
    "Sized",
    "Unpin",
    "Copy",
    "Clone",
    "Default",
    "Fn",
    "FnMut",
    "FnOnce",
    "Drop",
    "Iterator",
    "IntoIterator",
    "ToString",
    "ToOwned",
    "AsRef",
    "AsMut",
    "From",
    "Into",
    "PartialEq",
    "Eq",
    "PartialOrd",
    "Ord",
    "Future",
    "IntoFuture",
];
/// std and tokio names taken at their word when a glob import (`use super::*`) brings them: none
/// holds a closure.
const WELL_KNOWN: &[&str] = &[
    "AtomicBool",
    "AtomicU8",
    "AtomicU16",
    "AtomicU32",
    "AtomicU64",
    "AtomicUsize",
    "AtomicI8",
    "AtomicI16",
    "AtomicI32",
    "AtomicI64",
    "AtomicIsize",
    "HashMap",
    "HashSet",
    "BTreeMap",
    "BTreeSet",
    "VecDeque",
    "Path",
    "PathBuf",
    "Duration",
    "Instant",
    "SystemTime",
    "Arc",
    "Rc",
    "Weak",
    "Cell",
    "RefCell",
    "Notify",
    "Semaphore",
    "Condvar",
    "Once",
    "Value",
    "Pin",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub rel: String,
    pub line: usize,
    pub name: String,
    pub why: String,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}: {}: {}", self.rel, self.line, self.name, self.why)
    }
}

/// Every finding in the crate at `crate_dir` (its `src`), paths from the repository root.
pub fn judge_tree(crate_dir: &Path) -> Vec<Finding> {
    let mut found = Vec::new();
    for path in rust_files(&crate_dir.join("src")) {
        let rel = rel_path(crate_dir, &path);
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        found.extend(judge_source(&format!("{CRATE_REL}{rel}"), &text));
    }
    found
}

/// The findings of one file, `rel` its path from the repository root.
pub fn judge_source(rel: &str, text: &str) -> Vec<Finding> {
    let file = match syn::parse_file(text) {
        Ok(file) => file,
        Err(error) => {
            return vec![Finding {
                rel: rel.to_string(),
                line: line_of(error.span()),
                name: "-".to_string(),
                why: format!("does not parse ({error}), so the check cannot judge its statics"),
            }];
        }
    };
    let mut names = Names::default();
    Collect { names: &mut names }.visit_file(&file);
    let mut sites = Sites { out: Vec::new(), test_depth: 0, test_file: is_test_file(rel) };
    sites.visit_file(&file);
    let lines: Vec<&str> = text.lines().collect();
    let resolver = Resolver { names: &names, lines: &lines };
    let serializers: HashSet<&str> = sites
        .out
        .iter()
        .filter(|s| resolver.is_serializer(&s.ty, 0))
        .map(|s| s.name.as_str())
        .collect();
    let mut found = Vec::new();
    for site in &sites.out {
        let Some((why, unresolved)) = resolver.why(site) else {
            continue;
        };
        let line = lines.get(site.line.saturating_sub(1)).copied().unwrap_or("");
        let reason = std::iter::once(line)
            .chain(leading_block(&lines, site.line.saturating_sub(1)))
            .find_map(marker_reason);
        let finding = |why: String| Finding {
            rel: rel.to_string(),
            line: site.line,
            name: site.name.clone(),
            why,
        };
        match reason {
            None if unresolved => found.push(finding(format!(
                "{why}; spell the type out or alias it in this file, or mark it \
                 `// test-hook-allow: <why it holds no hook>`"
            ))),
            None => found.push(finding(format!(
                "{why}; put it in a thread_local! behind an on_* guard, or serialize it and mark it \
                 `// test-hook-allow: serialized by <Mutex<()> static>, <why>`"
            ))),
            Some(reason) => match serialized_by(&reason) {
                Some(lock) if !serializers.contains(lock.as_str()) => found.push(finding(format!(
                    "its test-hook-allow names {lock}, which is no `static {lock}: Mutex<()>` in this file"
                ))),
                Some(_) => {}
                None if reason.split_whitespace().count() < 3 => found.push(finding(
                    "its test-hook-allow gives no reason (at least three words)".to_string(),
                )),
                None => {}
            },
        }
    }
    found
}

fn is_test_file(rel: &str) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    let (name, dirs) = parts.split_last().unwrap_or((&"", &[]));
    dirs.contains(&"tests")
        || matches!(*name, "tests.rs" | "test.rs")
        || name.ends_with("_tests.rs")
        || name.ends_with("_test.rs")
}

/// The comment and attribute lines directly above `lines[at]`, nearest first.
fn leading_block<'a>(lines: &[&'a str], at: usize) -> Vec<&'a str> {
    lines[..at.min(lines.len())]
        .iter()
        .rev()
        .map(|l| l.trim())
        .take_while(|l| l.starts_with("//") || l.starts_with("#["))
        .collect()
}

/// The reason a `// test-hook-allow:` comment on `line` gives.
fn marker_reason(line: &str) -> Option<String> {
    let mut rest = line;
    while let Some(at) = rest.find("//") {
        rest = &rest[at + 2..];
        if let Some(reason) = rest.trim_start().strip_prefix(MARKER) {
            return Some(reason.trim().to_string());
        }
    }
    None
}

fn serialized_by(reason: &str) -> Option<String> {
    let rest = &reason[reason.find("serialized by ")? + "serialized by ".len()..];
    let name: String = rest.chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
    (!name.is_empty() && !name.starts_with(|c: char| c.is_ascii_digit())).then_some(name)
}

fn is_cell(name: &str) -> bool {
    CELLS.iter().any(|c| name.ends_with(c))
}

/// Whether `attrs` hold a `#[cfg(...)]` that names `test` (not under `not(...)`).
fn is_cfg_test(attrs: &[Attribute]) -> bool {
    fn names_test(tokens: TokenStream) -> bool {
        let mut iter = tokens.into_iter().peekable();
        while let Some(tree) = iter.next() {
            match tree {
                TokenTree::Ident(id) if id == "not" => {
                    if matches!(iter.peek(), Some(TokenTree::Group(_))) {
                        iter.next();
                    }
                }
                TokenTree::Ident(id) if id == "test" => return true,
                TokenTree::Group(group) if names_test(group.stream()) => return true,
                _ => {}
            }
        }
        false
    }
    attrs.iter().any(|a| {
        a.path().is_ident("cfg")
            && a.meta.require_list().is_ok_and(|l| names_test(l.tokens.clone()))
    })
}

/// Whether a macro's body holds process-wide statics: every macro's but a per-thread (or per-task)
/// one's.
fn process_wide(mac: &syn::Macro) -> bool {
    mac.path.segments.last().is_some_and(|s| !PER_THREAD.iter().any(|p| s.ident == p))
}

enum Body {
    Alias(Box<Type>),
    Fields(Vec<Type>),
    Value,
}

struct Param {
    name: String,
    default: Option<Type>,
}

struct Def {
    params: Vec<Param>,
    body: Body,
}

fn params_of(generics: &Generics) -> Vec<Param> {
    generics
        .params
        .iter()
        .filter_map(|p| match p {
            GenericParam::Type(t) => {
                Some(Param { name: t.ident.to_string(), default: t.default.clone() })
            }
            GenericParam::Const(c) => Some(Param { name: c.ident.to_string(), default: None }),
            GenericParam::Lifetime(_) => None,
        })
        .collect()
}

fn field_types(fields: &syn::Fields) -> impl Iterator<Item = Type> + '_ {
    fields.iter().map(|f| f.ty.clone())
}

/// What the names in a file's static types stand for, as far as the file shows: its aliases,
/// structs, enums, unions and consts, its `use` names, and its modules.
///
/// The file's modules share one table, so a name another module binds differently is not taken
/// at one of its meanings: `uses` keeps every path a name is imported as, and `twice` the names
/// defined more than once (review of cmux#41693, F1).
#[derive(Default)]
struct Names {
    defs: HashMap<String, Def>,
    twice: HashSet<String>,
    uses: HashMap<String, Vec<String>>,
    mods: HashSet<String>,
}

impl Names {
    /// Whether `path` names something of this crate (whose definition this file does not show).
    fn local(&self, path: &str, seen: &mut Vec<String>) -> bool {
        let root = path.split("::").next().unwrap_or("");
        if matches!(root, "crate" | "super" | "self") || self.mods.contains(root) {
            return true;
        }
        if path.contains("::")
            && !seen.iter().any(|s| s == root)
            && let Some(fulls) = self.uses.get(root)
        {
            seen.push(root.to_string());
            return fulls.iter().any(|full| self.local(full, &mut seen.clone()));
        }
        false
    }

    fn bind_use(&mut self, local: String, path: String) {
        let paths = self.uses.entry(local).or_default();
        if !paths.contains(&path) {
            paths.push(path);
        }
    }

    fn use_tree(&mut self, prefix: &str, tree: &UseTree) {
        let path_of = |ident: &syn::Ident| {
            if ident == "self" {
                prefix.trim_end_matches("::").to_string()
            } else {
                format!("{prefix}{ident}")
            }
        };
        match tree {
            UseTree::Path(p) => self.use_tree(&format!("{prefix}{}::", p.ident), &p.tree),
            UseTree::Name(n) => {
                let path = path_of(&n.ident);
                let local = path.rsplit("::").next().unwrap_or(&path).to_string();
                self.bind_use(local, path);
            }
            UseTree::Rename(r) => {
                if r.rename != "_" {
                    self.bind_use(r.rename.to_string(), path_of(&r.ident));
                }
            }
            UseTree::Glob(_) => {}
            UseTree::Group(g) => g.items.iter().for_each(|t| self.use_tree(prefix, t)),
        }
    }
}

/// Fills a file's Names from every item, in any module, function or macro body.
struct Collect<'n> {
    names: &'n mut Names,
}

impl Collect<'_> {
    fn define(&mut self, name: &syn::Ident, generics: &Generics, body: Body) {
        let params = params_of(generics);
        if self.names.defs.insert(name.to_string(), Def { params, body }).is_some() {
            self.names.twice.insert(name.to_string());
        }
    }
}

impl<'ast> Visit<'ast> for Collect<'_> {
    fn visit_item_type(&mut self, i: &'ast syn::ItemType) {
        self.define(&i.ident, &i.generics, Body::Alias(i.ty.clone()));
        visit::visit_item_type(self, i);
    }
    fn visit_item_struct(&mut self, i: &'ast syn::ItemStruct) {
        self.define(&i.ident, &i.generics, Body::Fields(field_types(&i.fields).collect()));
        visit::visit_item_struct(self, i);
    }
    fn visit_item_enum(&mut self, i: &'ast syn::ItemEnum) {
        let types = i.variants.iter().flat_map(|v| field_types(&v.fields)).collect();
        self.define(&i.ident, &i.generics, Body::Fields(types));
        visit::visit_item_enum(self, i);
    }
    fn visit_item_union(&mut self, i: &'ast syn::ItemUnion) {
        let types = i.fields.named.iter().map(|f| f.ty.clone()).collect();
        self.define(&i.ident, &i.generics, Body::Fields(types));
        visit::visit_item_union(self, i);
    }
    fn visit_item_const(&mut self, i: &'ast syn::ItemConst) {
        self.define(&i.ident, &i.generics, Body::Value);
        visit::visit_item_const(self, i);
    }
    fn visit_item_mod(&mut self, i: &'ast syn::ItemMod) {
        self.names.mods.insert(i.ident.to_string());
        visit::visit_item_mod(self, i);
    }
    fn visit_item_use(&mut self, i: &'ast syn::ItemUse) {
        self.names.use_tree("", &i.tree);
    }
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        if process_wide(mac) {
            visit_macro_body(self, mac);
        }
    }
}

struct Site {
    name: String,
    line: usize,
    ty: Type,
    gated: bool,
}

/// The file's process-wide statics: every static outside a `thread_local!` or `task_local!`.
struct Sites {
    out: Vec<Site>,
    test_depth: usize,
    test_file: bool,
}

impl Sites {
    fn push(&mut self, ident: &syn::Ident, ty: &Type, attrs: &[Attribute]) {
        self.out.push(Site {
            name: ident.to_string(),
            line: line_of(ident.span()),
            ty: ty.clone(),
            gated: self.test_file || self.test_depth > 0 || is_cfg_test(attrs),
        });
    }
}

impl<'ast> Visit<'ast> for Sites {
    fn visit_item(&mut self, item: &'ast Item) {
        let attrs: &[Attribute] = match item {
            Item::Mod(i) => &i.attrs,
            Item::Fn(i) => &i.attrs,
            Item::Impl(i) => &i.attrs,
            Item::Trait(i) => &i.attrs,
            _ => &[],
        };
        let test = is_cfg_test(attrs);
        self.test_depth += usize::from(test);
        visit::visit_item(self, item);
        self.test_depth -= usize::from(test);
    }
    fn visit_impl_item_fn(&mut self, i: &'ast syn::ImplItemFn) {
        let test = is_cfg_test(&i.attrs);
        self.test_depth += usize::from(test);
        visit::visit_impl_item_fn(self, i);
        self.test_depth -= usize::from(test);
    }
    fn visit_item_static(&mut self, i: &'ast syn::ItemStatic) {
        self.push(&i.ident, &i.ty, &i.attrs);
        visit::visit_item_static(self, i);
    }
    fn visit_foreign_item_static(&mut self, i: &'ast syn::ForeignItemStatic) {
        self.push(&i.ident, &i.ty, &i.attrs);
    }
    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        if process_wide(mac) {
            visit_macro_body(self, mac);
        }
    }
}

/// What a type holds, as far as the file shows.
#[derive(Clone, Default)]
struct Facts {
    cell: bool,
    closure: bool,
    slot: bool,
    unresolved: BTreeSet<String>,
}

impl Facts {
    fn merge(&mut self, other: &Facts) {
        self.cell |= other.cell;
        self.closure |= other.closure;
        self.slot |= other.slot;
        self.unresolved.extend(other.unresolved.iter().cloned());
    }
}

/// A generic parameter's binding: what its argument (or default) holds, whether it is an
/// `Option<...>`, and its text for a finding. `given` is false for a parameter with neither.
#[derive(Clone, Default)]
struct Bound {
    facts: Facts,
    option: bool,
    text: String,
    given: bool,
}

type Env = HashMap<String, Bound>;

struct Resolver<'a> {
    names: &'a Names,
    lines: &'a [&'a str],
}

impl Resolver<'_> {
    /// Why a static is refused (with whether that is for an unresolved name), or None.
    fn why(&self, site: &Site) -> Option<(String, bool)> {
        let mut facts = Facts::default();
        self.ty(&site.ty, &Env::new(), &mut Vec::new(), &mut facts);
        if site.gated && facts.slot {
            return Some(("a process-wide test slot (`Mutex<Option<...>>`)".to_string(), false));
        }
        if facts.cell && facts.closure {
            return Some(("a closure in a process-wide cell".to_string(), false));
        }
        if site.name.ends_with("HOOK") {
            return Some(("a process-wide static named as a hook".to_string(), false));
        }
        if !facts.unresolved.is_empty() && (facts.cell || self.head_unresolved(&site.ty)) {
            let names: Vec<&str> = facts.unresolved.iter().map(String::as_str).collect();
            return Some((
                format!(
                    "unresolved: its type names {}, which this file does not define, so the check \
                     cannot tell whether it holds a hook",
                    names.join(", ")
                ),
                true,
            ));
        }
        None
    }

    /// The source text of `span`, its whitespace folded.
    fn snippet(&self, span: Span) -> String {
        snippet(self.lines, span)
    }

    /// A type's text, a bound parameter's argument put in for it.
    fn type_text(&self, ty: &Type, env: &Env) -> String {
        if let Type::Path(p) = ty
            && let Some(ident) = p.path.get_ident()
            && let Some(bound) = env.get(&ident.to_string()).filter(|b| b.given)
        {
            return bound.text.clone();
        }
        self.snippet(ty.span())
    }

    /// Resolves `ty` into `facts`; returns whether it is an `Option<...>`.
    fn ty(&self, ty: &Type, env: &Env, stack: &mut Vec<String>, facts: &mut Facts) -> bool {
        match ty {
            Type::Path(p) => match &p.qself {
                Some(q) => {
                    // A projection, `<T as Trait>::Assoc`: what it names is in an impl, which the
                    // check does not read. What T holds still counts.
                    self.ty(&q.ty, env, stack, facts);
                    for seg in &p.path.segments {
                        self.args(&seg.arguments, env, stack, facts);
                    }
                    let idents: Vec<String> =
                        p.path.segments.iter().map(|s| s.ident.to_string()).collect();
                    let (tr, assoc) = idents.split_at(q.position.min(idents.len()));
                    let arg = self.type_text(&q.ty, env);
                    facts.unresolved.insert(if tr.is_empty() {
                        format!("<{arg}>::{}", assoc.join("::"))
                    } else {
                        format!("<{arg} as {}>::{}", tr.join("::"), assoc.join("::"))
                    });
                    false
                }
                None => self.path(&p.path, env, stack, facts),
            },
            Type::Array(a) => {
                self.ty(&a.elem, env, stack, facts);
                false
            }
            Type::Slice(s) => {
                self.ty(&s.elem, env, stack, facts);
                false
            }
            Type::Ptr(p) => {
                self.ty(&p.elem, env, stack, facts);
                false
            }
            Type::Reference(r) => {
                self.ty(&r.elem, env, stack, facts);
                false
            }
            Type::Paren(p) => self.ty(&p.elem, env, stack, facts),
            Type::Group(g) => self.ty(&g.elem, env, stack, facts),
            Type::Tuple(t) => {
                for elem in &t.elems {
                    self.ty(elem, env, stack, facts);
                }
                false
            }
            Type::BareFn(f) => {
                facts.closure = true;
                for input in &f.inputs {
                    self.ty(&input.ty, env, stack, facts);
                }
                if let ReturnType::Type(_, out) = &f.output {
                    self.ty(out, env, stack, facts);
                }
                false
            }
            Type::TraitObject(o) => {
                self.bounds(&o.bounds, env, stack, facts);
                false
            }
            Type::ImplTrait(i) => {
                self.bounds(&i.bounds, env, stack, facts);
                false
            }
            Type::Never(_) | Type::Infer(_) => false,
            Type::Macro(m) => {
                let path: Vec<String> =
                    m.mac.path.segments.iter().map(|s| s.ident.to_string()).collect();
                facts.unresolved.insert(format!("{}!", path.join("::")));
                false
            }
            other => {
                facts.unresolved.insert(self.snippet(other.span()));
                false
            }
        }
    }

    fn bounds(
        &self,
        bounds: &Punctuated<TypeParamBound, syn::Token![+]>,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) {
        for bound in bounds {
            if let TypeParamBound::Trait(t) = bound {
                if t.path.segments.last().is_some_and(|s| CLOSURES.iter().any(|c| s.ident == c)) {
                    facts.closure = true;
                }
                self.path(&t.path, env, stack, facts);
            }
        }
    }

    /// Resolves generic arguments into `facts`; returns, for each type argument in order, whether
    /// it is an `Option<...>`.
    fn args(
        &self,
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> Vec<bool> {
        match args {
            PathArguments::None => Vec::new(),
            PathArguments::AngleBracketed(a) => a
                .args
                .iter()
                .filter_map(|arg| match arg {
                    GenericArgument::Type(t) => Some(self.ty(t, env, stack, facts)),
                    GenericArgument::AssocType(a) => {
                        self.ty(&a.ty, env, stack, facts);
                        None
                    }
                    GenericArgument::Constraint(c) => {
                        self.bounds(&c.bounds, env, stack, facts);
                        None
                    }
                    _ => None,
                })
                .collect(),
            PathArguments::Parenthesized(p) => {
                for input in &p.inputs {
                    self.ty(input, env, stack, facts);
                }
                if let ReturnType::Type(_, out) = &p.output {
                    self.ty(out, env, stack, facts);
                }
                Vec::new()
            }
        }
    }

    fn path(
        &self,
        path: &syn::Path,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> bool {
        let leading = path.leading_colon.is_some();
        let mut segs: Vec<&syn::PathSegment> = path.segments.iter().collect();
        if !leading && segs.len() == 2 && segs[0].ident == "self" {
            segs.remove(0);
        }
        let Some(last) = segs.last() else {
            return false;
        };
        if !leading && segs.len() == 1 {
            return self.name(&last.ident.to_string(), &last.arguments, env, stack, facts);
        }
        let idents: Vec<String> = segs.iter().map(|s| s.ident.to_string()).collect();
        for seg in &segs[..segs.len() - 1] {
            self.args(&seg.arguments, env, stack, facts);
        }
        if !leading {
            if let Some(bound) = env.get(&idents[0]) {
                // A projection of a parameter (`T::Hook`): its argument stays in, what it names is unresolved.
                facts.merge(&bound.facts);
                facts.unresolved.insert(if bound.given {
                    format!("<{}>::{}", bound.text, idents[1..].join("::"))
                } else {
                    idents.join("::")
                });
                self.args(&last.arguments, env, stack, facts);
                return false;
            }
            if self.names.local(&idents.join("::"), &mut Vec::new()) {
                facts.unresolved.insert(idents.join("::"));
                self.args(&last.arguments, env, stack, facts);
                return false;
            }
        }
        self.foreign(&last.ident.to_string(), &last.arguments, env, stack, facts)
    }

    /// A name taken at its word (std's, a dependency's, a cell by its name): judged by its name and
    /// what its arguments hold.
    fn foreign(
        &self,
        name: &str,
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> bool {
        let heads = self.args(args, env, stack, facts);
        if is_cell(name) && matches!(args, PathArguments::AngleBracketed(_)) {
            facts.cell = true;
            if (name.ends_with("Mutex") || name.ends_with("RwLock")) && heads.first() == Some(&true)
            {
                facts.slot = true;
            }
        }
        name == "Option"
    }

    /// A one-segment name: a parameter first, then the prelude, the file's definitions, its `use`
    /// names, a cell by its name and the well-known std names; anything else is unresolved.
    fn name(
        &self,
        name: &str,
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> bool {
        if let Some(bound) = env.get(name) {
            if bound.given {
                facts.merge(&bound.facts);
            }
            return bound.given && bound.option;
        }
        if PRELUDE.contains(&name) {
            return self.foreign(name, args, env, stack, facts);
        }
        if let Some(def) = self.names.defs.get(name) {
            if stack.iter().any(|s| s == name) {
                self.args(args, env, stack, facts);
                return false;
            }
            let given = self.bind(name, def, args, env, stack);
            stack.push(name.to_string());
            let option = match &def.body {
                Body::Alias(ty) => self.ty(ty, &given, stack, facts),
                Body::Fields(types) => {
                    for ty in types {
                        self.ty(ty, &given, stack, facts);
                    }
                    false
                }
                Body::Value => false,
            };
            stack.pop();
            return option;
        }
        if let Some(fulls) = self.names.uses.get(name) {
            // Every path the name is imported as, in any module: what any of them holds counts.
            let mut option = false;
            for full in fulls {
                if self.names.local(full, &mut Vec::new()) {
                    facts.unresolved.insert(name.to_string());
                    self.args(args, env, stack, facts);
                } else {
                    let last = full.rsplit("::").next().unwrap_or(full);
                    option |= self.foreign(last, args, env, stack, facts);
                }
            }
            return option;
        }
        if !is_cell(name) && !WELL_KNOWN.contains(&name) {
            facts.unresolved.insert(name.to_string());
        }
        self.foreign(name, args, env, stack, facts)
    }

    /// The parameters of definition `name` bound in one ordered pass: the arguments given (read
    /// where they are written, in `env`), then each default in declaration order, read with the
    /// parameters bound before it.
    fn bind(
        &self,
        name: &str,
        def: &Def,
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
    ) -> Env {
        let given: Vec<&GenericArgument> = match args {
            PathArguments::AngleBracketed(a) => a
                .args
                .iter()
                .filter(|g| matches!(g, GenericArgument::Type(_) | GenericArgument::Const(_)))
                .collect(),
            _ => Vec::new(),
        };
        let mut out = Env::new();
        for (index, param) in def.params.iter().enumerate() {
            let mut facts = Facts::default();
            let bound = match (given.get(index), &param.default) {
                (Some(GenericArgument::Type(ty)), _) => {
                    let option = self.ty(ty, env, stack, &mut facts);
                    Bound { facts, option, text: self.type_text(ty, env), given: true }
                }
                (Some(arg), _) => {
                    Bound { text: self.snippet(arg.span()), given: true, ..Bound::default() }
                }
                (None, Some(default)) => {
                    stack.push(name.to_string());
                    let option = self.ty(default, &out, stack, &mut facts);
                    stack.pop();
                    Bound { facts, option, text: self.type_text(default, &out), given: true }
                }
                (None, None) => Bound { text: param.name.clone(), ..Bound::default() },
            };
            out.insert(param.name.clone(), bound);
        }
        out
    }

    /// Whether the name heading `ty` (its arguments left out) is one the file does not show.
    fn head_unresolved(&self, ty: &Type) -> bool {
        match ty {
            Type::Reference(r) => self.head_unresolved(&r.elem),
            Type::Array(a) => self.head_unresolved(&a.elem),
            Type::Slice(s) => self.head_unresolved(&s.elem),
            Type::Ptr(p) => self.head_unresolved(&p.elem),
            Type::Paren(p) => self.head_unresolved(&p.elem),
            Type::Group(g) => self.head_unresolved(&g.elem),
            Type::Tuple(t) => t.elems.iter().any(|e| self.head_unresolved(e)),
            Type::Path(p) if p.qself.is_none() => {
                let mut path = p.path.clone();
                for seg in path.segments.iter_mut() {
                    seg.arguments = PathArguments::None;
                }
                let mut facts = Facts::default();
                self.path(&path, &Env::new(), &mut Vec::new(), &mut facts);
                !facts.unresolved.is_empty()
            }
            Type::Path(_) | Type::Macro(_) => true,
            _ => false,
        }
    }

    /// Every path `idents` can stand for: its first segment replaced by each path the file's `use`
    /// items give it, again and again (`use std::sync as s; use s::Mutex as Lock;`), until no `use`
    /// names its head. A name two modules import differently gives both; None past 64 paths.
    fn used_paths(&self, idents: &[String]) -> Option<Vec<Vec<String>>> {
        let mut done = Vec::new();
        let mut todo: Vec<(Vec<String>, Vec<String>)> = vec![(idents.to_vec(), Vec::new())];
        while let Some((path, seen)) = todo.pop() {
            let Some(head) = path.first().filter(|h| !seen.contains(h)).cloned() else {
                done.push(path);
                continue;
            };
            let Some(fulls) = self.names.uses.get(&head) else {
                done.push(path);
                continue;
            };
            for full in fulls {
                let mut next: Vec<String> = full.split("::").map(str::to_string).collect();
                next.extend(path.iter().skip(1).cloned());
                let mut seen = seen.clone();
                seen.push(head.clone());
                todo.push((next, seen));
            }
            if done.len() + todo.len() > 64 {
                return None;
            }
        }
        Some(done)
    }

    /// Whether `ty` is a `Mutex<()>`, std's or tokio's (through the file's aliases and its
    /// `use` names, renames included: `use std::sync::Mutex as Lock` makes `Lock<()>` one). A name
    /// the file binds more than one way is one only when every way is (review of cmux#41693, F1).
    fn is_serializer(&self, ty: &Type, depth: usize) -> bool {
        let Type::Path(p) = ty else {
            return false;
        };
        if p.qself.is_some() || depth > 8 {
            return false;
        }
        let idents: Vec<String> = p.path.segments.iter().map(|s| s.ident.to_string()).collect();
        if let [name] = idents.as_slice()
            && let Some(def) = self.names.defs.get(name)
        {
            if self.names.twice.contains(name) {
                return false;
            }
            return match def {
                Def { params, body: Body::Alias(inner) } if params.is_empty() => {
                    self.is_serializer(inner, depth + 1)
                }
                _ => false,
            };
        }
        // A bare `Mutex` the file does not import is taken as std's (the prelude has none, so it
        // is an import from another file or a glob).
        let is_mutex = |path: &Vec<String>| {
            matches!(
                path.iter().map(String::as_str).collect::<Vec<_>>().as_slice(),
                ["Mutex"] | ["std" | "tokio", "sync", "Mutex"]
            )
        };
        let shape = self
            .used_paths(&idents)
            .is_some_and(|paths| !paths.is_empty() && paths.iter().all(is_mutex));
        let Some(PathArguments::AngleBracketed(args)) =
            p.path.segments.last().map(|s| &s.arguments)
        else {
            return false;
        };
        shape
            && args.args.len() == 1
            && matches!(args.args.first(), Some(GenericArgument::Type(Type::Tuple(t))) if t.elems.is_empty())
    }
}

#[cfg(test)]
#[path = "test_hooks_tests.rs"]
mod tests;
