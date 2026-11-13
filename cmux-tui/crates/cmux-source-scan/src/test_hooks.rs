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
//! (`dbg!({ static .. })`: [`crate::source::visit_macro_body`]). A name a block defines (an alias,
//! a struct or a `use` in a fn body or in a wrapper macro's `{ .. }`) is that block's alone: a static
//! in the block reads it, one outside reads what the outer scope defines. A static's type is judged
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

use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt;
use std::path::Path;

use crate::source::{
    ReadError, line_of, read_source, rel_path, rust_files, snippet, visit_macro_body,
};
use proc_macro2::{Span, TokenStream, TokenTree};
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::visit::{self, Visit};
use syn::{
    Attribute, Block, GenericArgument, GenericParam, Generics, Item, PathArguments, ReturnType,
    Type, TypeParamBound, UseTree,
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

/// Every finding in the crate at `crate_dir` (its `src`), paths from the repository root. A
/// path into another file of the crate (`crate::a::B`, `super::B`, a `use` of one) is followed
/// there ([`Crate`]). Err names a path of `src` the check could not read (a missing `src` too):
/// a source it skipped would read as clean.
pub fn judge_tree(crate_dir: &Path) -> Result<Vec<Finding>, ReadError> {
    let src = crate_dir.join("src");
    let mut files = Vec::new();
    let mut krate = Crate::default();
    for path in rust_files(&src)? {
        let rel = rel_path(crate_dir, &path);
        let text = read_source(&path)?;
        let module = module_of(&rel_path(&src, &path));
        let parsed = syn::parse_file(&text);
        if let (Ok(file), Some(module)) = (&parsed, &module) {
            krate
                .files
                .insert(module.join("::"), Indexed { names: names_of(file), text: text.clone() });
        }
        files.push((rel, text, parsed, module));
    }
    let memo = Memo::default();
    let mut found = Vec::new();
    for (rel, text, parsed, module) in &files {
        let at = module.as_deref().map(|module| (&krate, module, &memo));
        found.extend(judge_parsed(&format!("{CRATE_REL}{rel}"), text, parsed, at));
    }
    Ok(found)
}

/// The findings of one file, `rel` its path from the repository root. A name from another file
/// of the crate is `unresolved` here; [`judge_tree`] follows it.
pub fn judge_source(rel: &str, text: &str) -> Vec<Finding> {
    judge_parsed(rel, text, &syn::parse_file(text), None)
}

/// The crate's files by module path (`crate::a::b`), for following a path of the crate into the
/// file that defines it. Only `src/lib.rs` and the files under it by name (`a.rs`, `a/mod.rs`,
/// `a/b.rs`) are in it: a `#[path]` module or a binary's file is not, so a path into one stays
/// unresolved.
#[derive(Default)]
pub struct Crate {
    files: HashMap<String, Indexed>,
}

struct Indexed {
    names: Names,
    text: String,
}

/// The module path of the file at `rel` (from `src/`), or None for a binary's (`main.rs`,
/// `bin/...`).
fn module_of(rel: &str) -> Option<Vec<String>> {
    let stem = rel.strip_suffix(".rs")?;
    let mut parts: Vec<&str> = stem.split('/').collect();
    match parts.as_slice() {
        ["lib"] => parts.clear(),
        ["main"] | ["bin", ..] => return None,
        _ if parts.last() == Some(&"mod") => {
            parts.pop();
        }
        _ => {}
    }
    Some(std::iter::once("crate").chain(parts).map(String::from).collect())
}

fn names_of(file: &syn::File) -> Names {
    let mut names = Names::default();
    Collect { names: &mut names, scope: Vec::new() }.visit_file(file);
    names
}

fn judge_parsed(
    rel: &str,
    text: &str,
    parsed: &syn::Result<syn::File>,
    krate: Option<(&Crate, &[String], &Memo)>,
) -> Vec<Finding> {
    let file = match parsed {
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
    let names = names_of(file);
    let mut sites =
        Sites { out: Vec::new(), test_depth: 0, test_file: is_test_file(rel), scope: Vec::new() };
    sites.visit_file(file);
    let lines: Vec<&str> = text.lines().collect();
    let one_file = Memo::default();
    let file_module = krate.map(|(_, module, _)| module.to_vec()).unwrap_or_default();
    let resolver = Resolver {
        names: &names,
        lines: &lines,
        krate: krate.map(|(krate, _, _)| krate),
        file: file_module.clone(),
        module: file_module,
        at: Vec::new(),
        memo: krate.map_or(&one_file, |(_, _, memo)| memo),
    };
    let serializers: HashSet<&str> = sites
        .out
        .iter()
        .filter(|s| resolver.within(&s.scope).is_serializer(&s.ty, 0))
        .map(|s| s.name.as_str())
        .collect();
    let mut found = Vec::new();
    for site in &sites.out {
        let Some((why, unresolved)) = resolver.within(&site.scope).why(site) else {
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
    lines
        .get(..at)
        .unwrap_or(lines)
        .iter()
        .rev()
        .map(|l| l.trim())
        .take_while(|l| l.starts_with("//") || l.starts_with("#["))
        .collect()
}

/// The reason a `// test-hook-allow:` comment on `line` gives.
fn marker_reason(line: &str) -> Option<String> {
    let mut rest = line;
    while let Some((_, after)) = rest.split_once("//") {
        rest = after;
        if let Some(reason) = rest.trim_start().strip_prefix(MARKER) {
            return Some(reason.trim().to_string());
        }
    }
    None
}

fn serialized_by(reason: &str) -> Option<String> {
    let (_, rest) = reason.split_once("serialized by ")?;
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

#[derive(Clone)]
enum Body {
    Alias(Box<Type>),
    Fields(Vec<Type>),
    Value,
}

#[derive(Clone)]
struct Param {
    name: String,
    default: Option<Type>,
}

#[derive(Clone)]
struct Def {
    params: Vec<Param>,
    body: Body,
    /// The inline modules (`mod m { ... }`) and blocks it is in, from the file's top.
    scope: Vec<String>,
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

/// A block's step in a scope (`{LINE:COLUMN}` of its opening brace), beside the inline modules'
/// names. Collect and Sites read the same tree (a macro's body parsed from the same tokens), so
/// both name a block alike.
fn block_step(block: &Block) -> String {
    let at = block.brace_token.span.open().start();
    format!("{{{}:{}}}", at.line, at.column)
}

fn is_block_step(step: &str) -> bool {
    step.starts_with('{')
}

/// The key of the innermost block in `scope` (`scope` up to that block's step), or None outside
/// every block.
fn block_key(scope: &[String]) -> Option<String> {
    let last = scope.iter().rposition(|s| is_block_step(s))?;
    Some(scope.get(..=last).unwrap_or_default().join("::"))
}

/// The names one block defines (review of cmux#41581 F1): what a static in it reads before the
/// file's, and what no static outside it reads.
#[derive(Default)]
struct Layer {
    defs: HashMap<String, Def>,
    /// Every `use` of each name in the block, with the scope it is in.
    uses: HashMap<String, Vec<(String, Vec<String>)>>,
}

/// What the names in a file's static types stand for, as far as the file shows: its aliases,
/// structs, enums, unions and consts, its `use` names, and its modules.
#[derive(Default)]
struct Names {
    defs: HashMap<String, Def>,
    uses: HashMap<String, String>,
    mods: HashSet<String>,
    /// The definitions at the file's top (not in an inline module), which a path of the crate
    /// into this file names.
    top: HashMap<String, Def>,
    /// Every `use` of each name with the inline modules it is in, for following it into another
    /// file (`uses` keeps one).
    candidates: HashMap<String, Vec<(String, Vec<String>)>>,
    /// The modules this file declares as files (`mod m;`), `scope::m` from the file's top.
    file_mods: HashSet<String>,
    /// The names each block defines, by [`block_key`]; none of them is in the maps above.
    blocks: HashMap<String, Layer>,
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
            && let Some(full) = self.uses.get(root)
        {
            seen.push(root.to_string());
            return self.local(full, seen);
        }
        false
    }

    fn use_tree(&mut self, prefix: &str, tree: &UseTree, scope: &[String]) {
        let path_of = |ident: &syn::Ident| {
            if ident == "self" {
                prefix.trim_end_matches("::").to_string()
            } else {
                format!("{prefix}{ident}")
            }
        };
        match tree {
            UseTree::Path(p) => self.use_tree(&format!("{prefix}{}::", p.ident), &p.tree, scope),
            UseTree::Name(n) => {
                let path = path_of(&n.ident);
                let local = path.rsplit("::").next().unwrap_or(&path).to_string();
                self.add_use(local, path, scope);
            }
            UseTree::Rename(r) => {
                if r.rename != "_" {
                    self.add_use(r.rename.to_string(), path_of(&r.ident), scope);
                }
            }
            UseTree::Glob(_) => {}
            UseTree::Group(g) => g.items.iter().for_each(|t| self.use_tree(prefix, t, scope)),
        }
    }

    fn add_use(&mut self, local: String, path: String, scope: &[String]) {
        if let Some(key) = block_key(scope) {
            let layer = self.blocks.entry(key).or_default();
            layer.uses.entry(local).or_default().push((path, scope.to_vec()));
            return;
        }
        self.candidates.entry(local.clone()).or_default().push((path.clone(), scope.to_vec()));
        self.uses.insert(local, path);
    }
}

/// Fills a file's Names from every item, in any module, function or macro body: a block's into
/// its [`Layer`].
struct Collect<'n> {
    names: &'n mut Names,
    /// The inline modules the visit is in.
    scope: Vec<String>,
}

impl Collect<'_> {
    fn define(&mut self, name: &syn::Ident, generics: &Generics, body: Body) {
        let params = params_of(generics);
        let def = Def { params, body, scope: self.scope.clone() };
        if let Some(key) = block_key(&self.scope) {
            self.names.blocks.entry(key).or_default().defs.insert(name.to_string(), def);
            return;
        }
        if self.scope.is_empty() {
            self.names.top.insert(name.to_string(), def.clone());
        }
        self.names.defs.insert(name.to_string(), def);
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
        if i.content.is_none() {
            let at = self.scope.iter().chain([&i.ident.to_string()]).cloned().collect::<Vec<_>>();
            self.names.file_mods.insert(at.join("::"));
        }
        self.scope.push(i.ident.to_string());
        visit::visit_item_mod(self, i);
        self.scope.pop();
    }
    fn visit_item_use(&mut self, i: &'ast syn::ItemUse) {
        self.names.use_tree("", &i.tree, &self.scope);
    }
    fn visit_block(&mut self, b: &'ast Block) {
        self.scope.push(block_step(b));
        visit::visit_block(self, b);
        self.scope.pop();
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
    /// The inline modules and blocks it is in, from the file's top.
    scope: Vec<String>,
}

/// An item's attributes, whatever its kind.
fn item_attrs(item: &Item) -> &[Attribute] {
    match item {
        Item::Const(i) => &i.attrs,
        Item::Enum(i) => &i.attrs,
        Item::ExternCrate(i) => &i.attrs,
        Item::Fn(i) => &i.attrs,
        Item::ForeignMod(i) => &i.attrs,
        Item::Impl(i) => &i.attrs,
        Item::Macro(i) => &i.attrs,
        Item::Mod(i) => &i.attrs,
        Item::Static(i) => &i.attrs,
        Item::Struct(i) => &i.attrs,
        Item::Trait(i) => &i.attrs,
        Item::TraitAlias(i) => &i.attrs,
        Item::Type(i) => &i.attrs,
        Item::Union(i) => &i.attrs,
        Item::Use(i) => &i.attrs,
        _ => &[],
    }
}

/// The file's process-wide statics: every static outside a `thread_local!` or `task_local!`.
struct Sites {
    out: Vec<Site>,
    test_depth: usize,
    test_file: bool,
    scope: Vec<String>,
}

impl Sites {
    fn push(&mut self, ident: &syn::Ident, ty: &Type, attrs: &[Attribute]) {
        self.out.push(Site {
            name: ident.to_string(),
            line: line_of(ident.span()),
            ty: ty.clone(),
            gated: self.test_file || self.test_depth > 0 || is_cfg_test(attrs),
            scope: self.scope.clone(),
        });
    }
}

impl<'ast> Visit<'ast> for Sites {
    fn visit_item(&mut self, item: &'ast Item) {
        // Every kind of item, a macro's too (#41523 F2): `#[cfg(test)] wrapped! { static .. }`
        // and `#[cfg(test)] const _: () = { static .. };` gate the statics they hold.
        let test = is_cfg_test(item_attrs(item));
        let inline = match item {
            Item::Mod(m) if m.content.is_some() => Some(m.ident.to_string()),
            _ => None,
        };
        self.test_depth += usize::from(test);
        self.scope.extend(inline.clone());
        visit::visit_item(self, item);
        if inline.is_some() {
            self.scope.pop();
        }
        self.test_depth -= usize::from(test);
    }
    fn visit_impl_item_fn(&mut self, i: &'ast syn::ImplItemFn) {
        let test = is_cfg_test(&i.attrs);
        self.test_depth += usize::from(test);
        visit::visit_impl_item_fn(self, i);
        self.test_depth -= usize::from(test);
    }
    fn visit_impl_item_macro(&mut self, i: &'ast syn::ImplItemMacro) {
        let test = is_cfg_test(&i.attrs);
        self.test_depth += usize::from(test);
        visit::visit_impl_item_macro(self, i);
        self.test_depth -= usize::from(test);
    }
    fn visit_stmt_macro(&mut self, i: &'ast syn::StmtMacro) {
        // `#[cfg(test)] wrapped! { static .. }` in a fn body (#41523 F2).
        let test = is_cfg_test(&i.attrs);
        self.test_depth += usize::from(test);
        visit::visit_stmt_macro(self, i);
        self.test_depth -= usize::from(test);
    }
    fn visit_item_static(&mut self, i: &'ast syn::ItemStatic) {
        self.push(&i.ident, &i.ty, &i.attrs);
        visit::visit_item_static(self, i);
    }
    fn visit_foreign_item_static(&mut self, i: &'ast syn::ForeignItemStatic) {
        self.push(&i.ident, &i.ty, &i.attrs);
    }
    fn visit_block(&mut self, b: &'ast Block) {
        self.scope.push(block_step(b));
        visit::visit_block(self, b);
        self.scope.pop();
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
    /// The crate, when the whole tree is judged ([`judge_tree`]); None for one file.
    krate: Option<&'a Crate>,
    /// This file's module path (empty for one file), and the module the names being read are
    /// written in (the file's, or an inline module of it).
    file: Vec<String>,
    module: Vec<String>,
    /// The inline modules and blocks of this file the names being read are written in: a block's
    /// own names ([`Layer`]) go before the file's.
    at: Vec<String>,
    memo: &'a Memo,
}

/// What a one-segment name stands for where it is read: a definition, or a `use` (its path, and
/// every `use` of the name there).
enum Named<'n> {
    Def(&'n Def),
    Use(&'n str, &'n [(String, Vec<String>)]),
}

/// What each generic-free definition of the crate holds, read once for the whole tree: its facts
/// and whether it is an `Option`. One read with no cycle cut short (`cuts`) is the same wherever
/// it is read from, so only those are kept.
#[derive(Default)]
struct Memo {
    done: RefCell<HashMap<String, (Facts, bool)>>,
    cuts: Cell<usize>,
}

impl<'a> Resolver<'a> {
    /// This resolver, reading names written in the inline modules and blocks `scope` of its file.
    /// A block is no module: `self::` and `super::` in it are its module's.
    fn within(&self, scope: &[String]) -> Resolver<'a> {
        Resolver {
            names: self.names,
            lines: self.lines,
            krate: self.krate,
            file: self.file.clone(),
            module: self
                .file
                .iter()
                .chain(scope.iter().filter(|s| !is_block_step(s)))
                .cloned()
                .collect(),
            at: scope.to_vec(),
            memo: self.memo,
        }
    }

    /// The blocks this resolver reads names in, innermost first.
    fn layers(&self) -> Vec<&'a Layer> {
        let names = self.names;
        (0..self.at.len())
            .rev()
            .filter(|&i| self.at.get(i).is_some_and(|s| is_block_step(s)))
            .filter_map(|i| names.blocks.get(&self.at.get(..=i).unwrap_or_default().join("::")))
            .collect()
    }

    /// What `name` stands for here: the innermost block's that defines or `use`s it, else the
    /// file's definition, else the file's `use`.
    fn named(&self, name: &str) -> Option<Named<'a>> {
        for layer in self.layers() {
            if let Some(def) = layer.defs.get(name) {
                return Some(Named::Def(def));
            }
            if let Some(uses) = layer.uses.get(name)
                && let Some((full, _)) = uses.last()
            {
                return Some(Named::Use(full, uses));
            }
        }
        let names = self.names;
        if let Some(def) = names.defs.get(name) {
            return Some(Named::Def(def));
        }
        let full = names.uses.get(name)?;
        Some(Named::Use(full, names.candidates.get(name).map_or(&[][..], Vec::as_slice)))
    }

    /// Every `use` of `name` here: the innermost block's that defines or `use`s it (none when it
    /// defines it), else the file's.
    fn uses_of(&self, name: &str) -> Option<&'a [(String, Vec<String>)]> {
        for layer in self.layers() {
            if layer.defs.contains_key(name) {
                return None;
            }
            if let Some(uses) = layer.uses.get(name) {
                return Some(uses);
            }
        }
        self.names.candidates.get(name).map(Vec::as_slice)
    }

    /// [`Names::local`], a block's `use` of the path's first name going first.
    fn is_local(&self, path: &str) -> bool {
        let root = path.split("::").next().unwrap_or("");
        if path.contains("::")
            && !matches!(root, "crate" | "super" | "self")
            && !self.names.mods.contains(root)
            && let Some((full, _)) =
                self.layers().into_iter().find_map(|l| l.uses.get(root)).and_then(|u| u.last())
        {
            return self.names.local(full, &mut vec![root.to_string()]);
        }
        self.names.local(path, &mut Vec::new())
    }

    /// The stack key of a definition of this file.
    fn key(&self, name: &str) -> String {
        if self.file.is_empty() {
            name.to_string()
        } else {
            format!("{}::{name}", self.file.join("::"))
        }
    }

    /// `path`, written in this resolver's module, as a path from `crate`: None when it does not
    /// start at `crate`, `self`, `super`, a module this file declares as a file there, or a `use`
    /// (one, not one per cfg) of one of those.
    fn absolute(&self, path: &str, depth: usize) -> Option<Vec<String>> {
        if depth > 8 {
            return None;
        }
        let mut parts = path.split("::").peekable();
        let first = parts.next()?;
        let mut out: Vec<String> = match first {
            "crate" => vec!["crate".to_string()],
            "self" => self.module.clone(),
            "super" => {
                let mut out = self.module.clone();
                out.pop();
                while parts.next_if_eq(&"super").is_some() {
                    out.pop();
                }
                out
            }
            m if self.file_mod(m) => self.module.iter().cloned().chain([m.to_string()]).collect(),
            u => {
                let [(full, scope)] = self.uses_of(u)? else {
                    return None;
                };
                self.within(scope).absolute(full, depth + 1)?
            }
        };
        if out.first().map(String::as_str) != Some("crate") {
            return None;
        }
        for part in parts {
            if matches!(part, "crate" | "self" | "super") {
                return None;
            }
            out.push(part.to_string());
        }
        Some(out)
    }

    /// Whether `m` is a module this file declares as a file (`mod m;`) in this resolver's module.
    fn file_mod(&self, m: &str) -> bool {
        let scope = self.module.get(self.file.len()..).unwrap_or_default();
        self.names
            .file_mods
            .contains(&scope.iter().map(String::as_str).chain([m]).collect::<Vec<_>>().join("::"))
    }

    /// Resolves the crate path `segs` (from `crate`) in the file that defines it, `caller` being
    /// where its arguments are written: None when the crate has no such file or the file's top
    /// neither defines nor `use`s the name.
    fn follow(
        &self,
        caller: &Resolver<'_>,
        segs: &[String],
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> Option<bool> {
        let krate = self.krate?;
        let (name, module) = segs.split_last()?;
        let file = krate.files.get(&module.join("::"))?;
        let lines: Vec<&str> = file.text.lines().collect();
        let target = Resolver {
            names: &file.names,
            lines: &lines,
            krate: Some(krate),
            file: module.to_vec(),
            module: module.to_vec(),
            at: Vec::new(),
            memo: self.memo,
        };
        if let Some(def) = file.names.top.get(name) {
            return Some(target.def(caller, name, def, args, env, stack, facts));
        }
        // A re-export at the file's top (`pub use x::Name;`).
        let at_top: Vec<&String> = file
            .names
            .candidates
            .get(name)?
            .iter()
            .filter(|(_, scope)| scope.is_empty())
            .map(|(full, _)| full)
            .collect();
        let [full] = at_top.as_slice() else {
            return None;
        };
        if !file.names.local(full, &mut Vec::new()) {
            let last = full.rsplit("::").next().unwrap_or(full);
            return Some(caller.foreign(last, args, env, stack, facts));
        }
        // Its own key: one `use` of a name in an inline module (`use super::Name`) comes back
        // to the top's `use` of it, which is no cycle.
        let key = target.key(&format!("pub use {name}"));
        if stack.contains(&key) {
            self.memo.cuts.set(self.memo.cuts.get().wrapping_add(1));
            return None;
        }
        stack.push(key);
        let option = target
            .absolute(full, 0)
            .and_then(|segs| target.follow(caller, &segs, args, env, stack, facts));
        stack.pop();
        option
    }

    /// Resolves `name`, which a `use` of this file names in this crate, in the file that defines
    /// it: every `use` of the name (one per cfg, say) is followed, and None when one cannot be.
    fn follow_use(
        &self,
        name: &str,
        candidates: &[(String, Vec<String>)],
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> Option<bool> {
        self.krate?;
        if candidates.is_empty() {
            return None;
        }
        let key = self.key(&format!("use {name}"));
        if stack.contains(&key) {
            self.memo.cuts.set(self.memo.cuts.get().wrapping_add(1));
            return None;
        }
        stack.push(key);
        let mut option = Some(false);
        for (full, scope) in candidates {
            let at = self.within(scope);
            let one = if at.is_local(full) {
                at.absolute(full, 0)
                    .and_then(|segs| self.follow(self, &segs, args, env, stack, facts))
            } else {
                let last = full.rsplit("::").next().unwrap_or(full);
                Some(self.foreign(last, args, env, stack, facts))
            };
            option = option.zip(one).map(|(a, b)| a || b);
            if option.is_none() {
                break;
            }
        }
        stack.pop();
        option
    }

    /// Reads definition `name` of this file: its parameters bound to `args` (written in `caller`,
    /// with `env`), then its body.
    #[allow(
        clippy::too_many_arguments,
        reason = "the resolver's walk state, as every step here takes it"
    )]
    fn def(
        &self,
        caller: &Resolver<'_>,
        name: &str,
        def: &Def,
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> bool {
        // A definition in an inline module is not the top one of the same name.
        let key = self.key(
            &def.scope.iter().map(String::as_str).chain([name]).collect::<Vec<_>>().join("::"),
        );
        if stack.contains(&key) {
            self.memo.cuts.set(self.memo.cuts.get().wrapping_add(1));
            caller.args(args, env, stack, facts);
            return false;
        }
        // Only a crate-wide read keeps a definition's facts: one file's read stays as it was.
        let memo = def.params.is_empty() && self.krate.is_some();
        if memo && let Some((done, option)) = self.memo.done.borrow().get(&key) {
            facts.merge(done);
            return *option;
        }
        let at = self.within(&def.scope);
        let given = at.bind(caller, &key, def, args, env, stack);
        let cuts = self.memo.cuts.get();
        let mut own = Facts::default();
        let into = if memo { &mut own } else { &mut *facts };
        stack.push(key.clone());
        let option = match &def.body {
            Body::Alias(ty) => at.ty(ty, &given, stack, into),
            Body::Fields(types) => {
                for ty in types {
                    at.ty(ty, &given, stack, into);
                }
                false
            }
            Body::Value => false,
        };
        stack.pop();
        if memo {
            facts.merge(&own);
            if cuts == self.memo.cuts.get() {
                self.memo.done.borrow_mut().insert(key, (own, option));
            }
        }
        option
    }

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
        if !leading && segs.len() == 2 && segs.first().is_some_and(|s| s.ident == "self") {
            segs.remove(0);
        }
        let Some((last, init)) = segs.split_last() else {
            return false;
        };
        if !leading && segs.len() == 1 {
            return self.name(&last.ident.to_string(), &last.arguments, env, stack, facts);
        }
        let idents: Vec<String> = segs.iter().map(|s| s.ident.to_string()).collect();
        for seg in init {
            self.args(&seg.arguments, env, stack, facts);
        }
        if !leading {
            if let Some(bound) = idents.first().and_then(|first| env.get(first)) {
                // A projection of a parameter (`T::Hook`): its argument stays in, what it names is unresolved.
                facts.merge(&bound.facts);
                facts.unresolved.insert(if bound.given {
                    format!("<{}>::{}", bound.text, idents.get(1..).unwrap_or_default().join("::"))
                } else {
                    idents.join("::")
                });
                self.args(&last.arguments, env, stack, facts);
                return false;
            }
            if self.is_local(&idents.join("::")) {
                if let Some(option) = self
                    .absolute(&idents.join("::"), 0)
                    .and_then(|segs| self.follow(self, &segs, &last.arguments, env, stack, facts))
                {
                    return option;
                }
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
        match self.named(name) {
            Some(Named::Def(def)) => return self.def(self, name, def, args, env, stack, facts),
            Some(Named::Use(full, candidates)) => {
                return self.use_name(name, full, candidates, args, env, stack, facts);
            }
            None => {}
        }
        if !is_cell(name) && !WELL_KNOWN.contains(&name) {
            facts.unresolved.insert(name.to_string());
        }
        self.foreign(name, args, env, stack, facts)
    }

    /// A one-segment name a `use` names (`full`, one of `candidates`): followed into the crate,
    /// or taken at its last name's word.
    #[allow(
        clippy::too_many_arguments,
        reason = "the resolver's walk state, as every step here takes it"
    )]
    fn use_name(
        &self,
        name: &str,
        full: &str,
        candidates: &[(String, Vec<String>)],
        args: &PathArguments,
        env: &Env,
        stack: &mut Vec<String>,
        facts: &mut Facts,
    ) -> bool {
        if self.is_local(full) {
            if let Some(option) = self.follow_use(name, candidates, args, env, stack, facts) {
                return option;
            }
            facts.unresolved.insert(name.to_string());
            self.args(args, env, stack, facts);
            return false;
        }
        let last = full.rsplit("::").next().unwrap_or(full);
        self.foreign(last, args, env, stack, facts)
    }

    /// The parameters of definition `name` bound in one ordered pass: the arguments given (read
    /// where they are written, in `env`), then each default in declaration order, read with the
    /// parameters bound before it.
    fn bind(
        &self,
        caller: &Resolver<'_>,
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
                    let option = caller.ty(ty, env, stack, &mut facts);
                    Bound { facts, option, text: caller.type_text(ty, env), given: true }
                }
                (Some(arg), _) => {
                    Bound { text: caller.snippet(arg.span()), given: true, ..Bound::default() }
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

    /// Whether `ty` is a `Mutex<()>`, std's or tokio's (through the file's aliases).
    fn is_serializer(&self, ty: &Type, depth: usize) -> bool {
        let Type::Path(p) = ty else {
            return false;
        };
        if p.qself.is_some() || depth > 8 {
            return false;
        }
        let idents: Vec<String> = p.path.segments.iter().map(|s| s.ident.to_string()).collect();
        let shape = match idents.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
            [name] if *name != "Mutex" => {
                return match self.named(name) {
                    Some(Named::Def(Def { params, body: Body::Alias(inner), scope }))
                        if params.is_empty() =>
                    {
                        self.within(scope).is_serializer(inner, depth + 1)
                    }
                    _ => false,
                };
            }
            ["Mutex"] => match self.named("Mutex") {
                Some(Named::Use(full, _)) => {
                    matches!(full, "std::sync::Mutex" | "tokio::sync::Mutex")
                }
                Some(Named::Def(_)) | None => true,
            },
            ["std" | "tokio", "sync", "Mutex"] => true,
            _ => false,
        };
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
