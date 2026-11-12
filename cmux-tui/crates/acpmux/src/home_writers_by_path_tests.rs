//! The detector for writers under the home that go by path (#41372 review: "three review rounds
//! have each found writers the last one missed, because the list is hand-kept. Make it
//! mechanical."). Every file operation under the home this daemon holds goes through `home_fs`,
//! which makes it through the folder the daemon locked: a home replaced after a writer's check
//! never gets the write. A `std::fs` or `tokio::fs` write by path does not, so this test reads
//! the crate's own sources and fails on any such write whose path comes from the home.
//!
//! What it reads: every module `src/lib.rs` declares, followed through `mod` and `#[path]`, with
//! anything under `#[cfg(test)]` or `#[test]` left out (a test writes its own scratch homes).
//!
//! A write (a "sink"): a call of `fs::create_dir`, `create_dir_all`, `write`, `rename`,
//! `remove_file`, `remove_dir`, `remove_dir_all`, `hard_link`, `copy`, `set_permissions`,
//! `symlink`, `chown` or `lchown` (`std::fs`, `tokio::fs`, `std::os::*::fs`, by any import or
//! alias); `File::create` and `create_new`; `.open(path)` on an `OpenOptions` that writes
//! (`write`, `append`, `create`, `create_new` or `truncate` anywhere on it); `.create(path)` on a
//! `DirBuilder`; and the Windows owner-only writers by path (`owner_only::create_new`,
//! `open_append`, `open_rw`, `open_rw_existing`, `create_dir_all`, `private_dir`, `restrict`).
//! Any path through `home_fs` is no sink.
//!
//! "Comes from the home" (taint, computed to a fixed point over the whole crate):
//! - The roots: `config::home()` and `config::default_home()`.
//! - A local binding (`let`, `if let`, `match`, `for`, an assignment, a closure's argument given
//!   a tainted receiver's items) whose value is tainted. Within one function, regardless of
//!   order.
//! - An expression that uses a tainted value: a method on it (`join`, `with_extension`,
//!   `parent`, ...), an outside function given it (`PathBuf::from`, `Some`, `format!`), a crate
//!   function given it that returns a path (`Path`, `PathBuf`, `OsStr`, `OsString` in its return
//!   type), and a crate function whose own return is tainted whatever its arguments
//!   (`file_uploads::root()`, `LocalStore::dir`).
//! - A parameter of a crate function (typed with `Path`, `PathBuf`, `OsStr`, `OsString` or a
//!   generic bound on `AsRef<Path>`) that any call site in the crate passes a tainted value.
//!   Calls resolve by name: a path call by its module or type, a method by its name (any type's,
//!   or the own type's on `self`), so two functions of one name share their taint.
//! - A struct field any struct literal or assignment in the crate gives a tainted value: read
//!   as `self.field` in that type's methods, and as `x.field` where `x`'s type is resolved (a
//!   parameter or a `let` typed with one of the crate's structs, or a local bound to a struct
//!   literal). Where it is not resolved, `x.field` is tainted when any struct's field of that
//!   name is: a name two types share is a hit, never a miss (#41462 review F2: the compaction's
//!   `StagedSegment.path` and `.tmp`).
//!
//! What it does not see: a write by path through a crate function whose path parameter is
//! not path-typed (a `&str`), through `libc` directly, inside a macro other than its
//! comma-separated arguments, or in another crate (`cmux_chat_index` takes its writer from
//! `home_fs`). Its taint is an over-approximation: a row it finds may be a path outside the home
//! (a user's file). Such a row is fixed by going through `home_fs` anyway (outside the home it
//! goes by path, as before), or allowlisted below with why.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use syn::spanned::Spanned;
use syn::visit::Visit;

/// The writes by path left as they are, each with why: (file, function, write, reason). `*`
/// matches any file or function; a write ending in `*` any write it starts.
const ALLOWED: &[(&str, &str, &str, &str)] = &[(
    "*",
    "*",
    "owner_only::*",
    "Windows owner-only creates (CreateFileW with an owner-only descriptor) go by path: Windows \
     has no *at calls. Each runs right after its own home check (`config::private_state_*`, \
     `store::open_private_append`), and a temporary file it makes is renamed through `home_fs`, \
     which checks the home's file id again (#41372).",
)];

/// Whether `pattern` (an `ALLOWED` field) matches `value`.
fn matches(pattern: &str, value: &str) -> bool {
    pattern == "*"
        || pattern == value
        || pattern.strip_suffix('*').is_some_and(|prefix| value.starts_with(prefix))
}

/// The write calls by path (`<module ending in fs>::<name>`).
const FS_WRITES: &[&str] = &[
    "create_dir",
    "create_dir_all",
    "write",
    "rename",
    "remove_file",
    "remove_dir",
    "remove_dir_all",
    "hard_link",
    "copy",
    "set_permissions",
    "symlink",
    "symlink_file",
    "symlink_dir",
    "chown",
    "lchown",
];

/// `OpenOptions` methods that make an open a write.
const WRITEISH: &[&str] = &["write", "append", "create", "create_new", "truncate"];

/// The Windows owner-only writers by path (`owner_only.rs`).
const OWNER_ONLY_WRITES: &[&str] = &[
    "create_new",
    "open_append",
    "open_rw",
    "open_rw_existing",
    "create_dir_all",
    "private_dir",
    "restrict",
];

/// Methods of std types (paths, strings, options, iterators, locks) a value passes through: never
/// resolved to a crate method of the same name, except on `self` in a type that has one.
const STD_METHODS: &[&str] = &[
    "join",
    "push",
    "pop",
    "with_extension",
    "with_file_name",
    "set_extension",
    "set_file_name",
    "parent",
    "file_name",
    "file_stem",
    "extension",
    "to_path_buf",
    "to_owned",
    "to_string",
    "to_string_lossy",
    "into_owned",
    "clone",
    "cloned",
    "copied",
    "as_ref",
    "as_mut",
    "as_path",
    "as_os_str",
    "display",
    "into",
    "unwrap",
    "expect",
    "unwrap_or",
    "unwrap_or_else",
    "unwrap_or_default",
    "ok",
    "err",
    "ok_or",
    "ok_or_else",
    "map",
    "map_err",
    "and_then",
    "or_else",
    "or",
    "filter",
    "iter",
    "iter_mut",
    "into_iter",
    "collect",
    "path",
    "components",
    "ancestors",
    "strip_prefix",
    "canonicalize",
    "as_deref",
    "as_str",
    "get",
    "first",
    "last",
    "chain",
    "flatten",
    "filter_map",
    "find",
    "find_map",
    "take",
    "skip",
    "rev",
    "borrow",
    "deref",
    "lock",
    "with_context",
    "context",
    "to_str",
    "to_os_string",
    "into_os_string",
    "into_boxed_path",
    "extend",
    "split_last",
    "entry",
    "or_insert",
    "or_insert_with",
    "iter_paths",
    "sort",
    "dedup",
    "concat",
    "unwrap_or_clone",
];

/// One parsed source file: its path under the crate (`src/...`) and its module.
struct Source {
    rel: String,
    module: Vec<String>,
    file: syn::File,
}

/// The imports of one module: each name's full path (`crate::...` or an outside crate's), and
/// the modules it imports whole (`use super::*`).
#[derive(Default)]
struct Uses {
    alias: HashMap<String, Vec<String>>,
    globs: Vec<Vec<String>>,
}

/// One function of the crate.
struct Func<'a> {
    rel: String,
    module: Vec<String>,
    self_ty: Option<String>,
    name: String,
    has_self: bool,
    /// Each parameter but `self`: the names it binds, and whether it is path-typed.
    params: Vec<(Vec<String>, bool)>,
    /// Parameters that bind one name to a named type (`x: &T`): (name, `T`).
    typed: Vec<(String, String)>,
    returns_path: bool,
    body: &'a syn::Block,
}

impl Func<'_> {
    fn qualified(&self) -> String {
        match &self.self_ty {
            Some(ty) => format!("{ty}::{}", self.name),
            None => self.name.clone(),
        }
    }
}

/// A write by path whose path comes from the home.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Row {
    pub rel: String,
    pub line: usize,
    pub func: String,
    pub sink: String,
}

impl std::fmt::Display for Row {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{} {}: {}", self.rel, self.line, self.func, self.sink)
    }
}

/// The taint known so far, over the whole crate.
#[derive(Default, Clone, PartialEq, Eq)]
struct State {
    /// Functions whose return is tainted whatever their arguments.
    returns: BTreeSet<usize>,
    /// Tainted parameters: (function, index without `self`).
    params: BTreeSet<(usize, usize)>,
    /// Tainted fields: (struct, field).
    fields: BTreeSet<(String, String)>,
}

fn is_test_attr(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        let path = attr.path();
        if path.is_ident("test") || path.segments.last().is_some_and(|s| s.ident == "test") {
            return true;
        }
        if !path.is_ident("cfg") {
            return false;
        }
        let syn::Meta::List(list) = &attr.meta else { return false };
        let text: String = list.tokens.to_string().chars().filter(|c| !c.is_whitespace()).collect();
        if text == "test" {
            return true;
        }
        // `all(test, ...)`: test-only; `any(...)` and `not(test)` are not.
        text.strip_prefix("all(")
            .and_then(|rest| rest.strip_suffix(')'))
            .is_some_and(|inner| top_level(inner).iter().any(|part| part == "test"))
    })
}

/// `inner` split at its top-level commas.
fn top_level(inner: &str) -> Vec<String> {
    let (mut parts, mut depth, mut part) = (Vec::new(), 0, String::new());
    for c in inner.chars() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => {
                parts.push(std::mem::take(&mut part));
                continue;
            }
            _ => {}
        }
        part.push(c);
    }
    parts.push(part);
    parts
}

fn path_attr(attrs: &[syn::Attribute]) -> Option<String> {
    attrs.iter().find(|a| a.path().is_ident("path")).and_then(|a| match &a.meta {
        syn::Meta::NameValue(nv) => match &nv.value {
            syn::Expr::Lit(syn::ExprLit { lit: syn::Lit::Str(s), .. }) => Some(s.value()),
            _ => None,
        },
        _ => None,
    })
}

/// Reads the module at `file` (`module`) and every module it declares, into `out`. `dir` is
/// where its child modules' files are.
fn load(crate_dir: &Path, file: &Path, module: Vec<String>, dir: PathBuf, out: &mut Vec<Source>) {
    let text = std::fs::read_to_string(file).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
    let parsed = syn::parse_file(&text).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
    let rel = file.strip_prefix(crate_dir).unwrap_or(file).to_string_lossy().replace('\\', "/");
    load_items(crate_dir, &parsed.items, &module, &dir, file, out);
    out.push(Source { rel, module, file: parsed });
}

fn load_items(
    crate_dir: &Path,
    items: &[syn::Item],
    module: &[String],
    dir: &Path,
    file: &Path,
    out: &mut Vec<Source>,
) {
    for item in items {
        let syn::Item::Mod(m) = item else { continue };
        if is_test_attr(&m.attrs) {
            continue;
        }
        let name = m.ident.to_string();
        let mut child = module.to_vec();
        child.push(name.clone());
        if let Some((_, items)) = &m.content {
            load_items(crate_dir, items, &child, &dir.join(&name), file, out);
            continue;
        }
        let file_dir = file.parent().unwrap_or(Path::new("."));
        let found = if let Some(p) = path_attr(&m.attrs) {
            let p = file_dir.join(p);
            let child_dir = p.parent().map(|d| d.join(&name)).unwrap_or_default();
            Some((p, child_dir))
        } else {
            let flat = dir.join(format!("{name}.rs"));
            let nested = dir.join(&name).join("mod.rs");
            if flat.exists() {
                Some((flat, dir.join(&name)))
            } else if nested.exists() {
                Some((nested, dir.join(&name)))
            } else {
                None
            }
        };
        let Some((path, child_dir)) = found else {
            panic!("{}: mod {name} has no file", file.display());
        };
        // A `#[path]` module's own children: beside it, as a `mod.rs` when it is one.
        let child_dir = if path.file_name().is_some_and(|n| n == "mod.rs") {
            path.parent().unwrap_or(Path::new(".")).to_path_buf()
        } else {
            child_dir
        };
        load(crate_dir, &path, child, child_dir, out);
    }
}

/// The identifiers `visit` reaches.
fn idents_in(visit: impl FnOnce(&mut IdentNames)) -> Vec<String> {
    let mut names = IdentNames(Vec::new());
    visit(&mut names);
    names.0
}

struct IdentNames(Vec<String>);

impl<'ast> Visit<'ast> for IdentNames {
    fn visit_ident(&mut self, i: &'ast proc_macro2::Ident) {
        self.0.push(i.to_string());
    }
}

fn type_names(ty: &syn::Type) -> Vec<String> {
    idents_in(|v| v.visit_type(ty))
}

/// The names `pat` binds.
fn bound(pat: &syn::Pat) -> Vec<String> {
    struct Bound(Vec<String>);
    impl<'ast> Visit<'ast> for Bound {
        fn visit_pat_ident(&mut self, i: &'ast syn::PatIdent) {
            self.0.push(i.ident.to_string());
            syn::visit::visit_pat_ident(self, i);
        }
    }
    let mut b = Bound(Vec::new());
    b.visit_pat(pat);
    b.0
}

const PATHY: &[&str] = &["Path", "PathBuf", "OsStr", "OsString"];

/// The type `ty` names, through references: `T` for `T`, `&T`, `&mut T` (`Self` is `self_ty`).
fn named_type(ty: &syn::Type, self_ty: Option<&str>) -> Option<String> {
    match ty {
        syn::Type::Reference(r) => named_type(&r.elem, self_ty),
        syn::Type::Paren(p) => named_type(&p.elem, self_ty),
        syn::Type::Path(p) if p.qself.is_none() => {
            let name = p.path.segments.last()?.ident.to_string();
            if name == "Self" { self_ty.map(str::to_owned) } else { Some(name) }
        }
        _ => None,
    }
}

/// A function's locals whose type is known: a `let x: T`, or a `let x = T { .. }`. A name bound
/// twice with different types (or once without one) is left out: its type is not resolved.
fn local_types(func: &Func<'_>) -> HashMap<String, String> {
    struct Locals<'f> {
        self_ty: Option<&'f str>,
        known: HashMap<String, Option<String>>,
    }
    impl Locals<'_> {
        fn bind(&mut self, name: String, ty: Option<String>) {
            let entry = self.known.entry(name).or_insert_with(|| ty.clone());
            if *entry != ty {
                *entry = None;
            }
        }
    }
    impl<'ast> Visit<'ast> for Locals<'_> {
        fn visit_local(&mut self, l: &'ast syn::Local) {
            let (pat, ty) = match &l.pat {
                syn::Pat::Type(t) => (&*t.pat, named_type(&t.ty, self.self_ty)),
                pat => {
                    let literal = l.init.as_ref().and_then(|init| match &*init.expr {
                        syn::Expr::Struct(s) => {
                            let name = s.path.segments.last()?.ident.to_string();
                            if name == "Self" {
                                self.self_ty.map(str::to_owned)
                            } else {
                                Some(name)
                            }
                        }
                        _ => None,
                    });
                    (pat, literal)
                }
            };
            if let syn::Pat::Ident(i) = pat {
                self.bind(i.ident.to_string(), ty);
            } else {
                for name in bound(pat) {
                    self.bind(name, None);
                }
            }
            syn::visit::visit_local(self, l);
        }
        fn visit_expr_let(&mut self, l: &'ast syn::ExprLet) {
            for name in bound(&l.pat) {
                self.bind(name, None);
            }
            syn::visit::visit_expr_let(self, l);
        }
        fn visit_expr_for_loop(&mut self, l: &'ast syn::ExprForLoop) {
            for name in bound(&l.pat) {
                self.bind(name, None);
            }
            syn::visit::visit_expr_for_loop(self, l);
        }
        fn visit_expr_closure(&mut self, c: &'ast syn::ExprClosure) {
            for name in c.inputs.iter().flat_map(bound) {
                self.bind(name, None);
            }
            syn::visit::visit_expr_closure(self, c);
        }
        fn visit_arm(&mut self, a: &'ast syn::Arm) {
            for name in bound(&a.pat) {
                self.bind(name, None);
            }
            syn::visit::visit_arm(self, a);
        }
        fn visit_item(&mut self, _: &'ast syn::Item) {}
    }
    let mut locals = Locals { self_ty: func.self_ty.as_deref(), known: HashMap::new() };
    for (name, ty) in &func.typed {
        locals.bind(name.clone(), Some(ty.clone()));
    }
    locals.visit_block(func.body);
    locals.known.into_iter().filter_map(|(name, ty)| Some((name, ty?))).collect()
}

fn is_pathy(names: &[String], generic_paths: &HashSet<String>) -> bool {
    names.iter().any(|n| PATHY.contains(&n.as_str()) || generic_paths.contains(n))
}

/// The crate's functions, structs' field names, and imports, indexed.
struct Index<'a> {
    funcs: Vec<Func<'a>>,
    by_name: HashMap<String, Vec<usize>>,
    uses: HashMap<Vec<String>, Uses>,
    /// The crate's structs, by name.
    structs: HashSet<String>,
}

impl<'a> Index<'a> {
    fn new(sources: &'a [Source]) -> Self {
        let mut index = Index {
            funcs: Vec::new(),
            by_name: HashMap::new(),
            uses: HashMap::new(),
            structs: HashSet::new(),
        };
        for source in sources {
            index.items(&source.rel, &source.module, &source.file.items);
        }
        for (i, f) in index.funcs.iter().enumerate() {
            index.by_name.entry(f.name.clone()).or_default().push(i);
        }
        index
    }

    fn items(&mut self, rel: &str, module: &[String], items: &'a [syn::Item]) {
        for item in items {
            match item {
                syn::Item::Mod(m) if !is_test_attr(&m.attrs) => {
                    if let Some((_, items)) = &m.content {
                        let mut child = module.to_vec();
                        child.push(m.ident.to_string());
                        self.items(rel, &child, items);
                    }
                }
                syn::Item::Use(u) if !is_test_attr(&u.attrs) => {
                    let uses = self.uses.entry(module.to_vec()).or_default();
                    use_tree(module, Vec::new(), &u.tree, uses);
                }
                syn::Item::Struct(s) => {
                    self.structs.insert(s.ident.to_string());
                }
                syn::Item::Fn(f) if !is_test_attr(&f.attrs) => {
                    self.func(rel, module, None, &f.sig, &f.block);
                }
                syn::Item::Impl(imp) if !is_test_attr(&imp.attrs) => {
                    let ty = match &*imp.self_ty {
                        syn::Type::Path(p) => p.path.segments.last().map(|s| s.ident.to_string()),
                        _ => None,
                    };
                    for item in &imp.items {
                        if let syn::ImplItem::Fn(f) = item
                            && !is_test_attr(&f.attrs)
                        {
                            self.func(rel, module, ty.clone(), &f.sig, &f.block);
                        }
                    }
                }
                syn::Item::Trait(t) if !is_test_attr(&t.attrs) => {
                    for item in &t.items {
                        if let syn::TraitItem::Fn(f) = item
                            && let Some(block) = &f.default
                            && !is_test_attr(&f.attrs)
                        {
                            self.func(rel, module, None, &f.sig, block);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    fn func(
        &mut self,
        rel: &str,
        module: &[String],
        self_ty: Option<String>,
        sig: &syn::Signature,
        body: &'a syn::Block,
    ) {
        let mut generic_paths = HashSet::new();
        for param in &sig.generics.params {
            if let syn::GenericParam::Type(t) = param {
                let bounds: Vec<String> = t
                    .bounds
                    .iter()
                    .flat_map(|b| idents_in(|v| v.visit_type_param_bound(b)))
                    .collect();
                if is_pathy(&bounds, &HashSet::new()) {
                    generic_paths.insert(t.ident.to_string());
                }
            }
        }
        if let Some(clause) = &sig.generics.where_clause {
            for predicate in &clause.predicates {
                if let syn::WherePredicate::Type(p) = predicate {
                    let bounds: Vec<String> = p
                        .bounds
                        .iter()
                        .flat_map(|b| idents_in(|v| v.visit_type_param_bound(b)))
                        .collect();
                    if is_pathy(&bounds, &HashSet::new()) {
                        generic_paths.extend(type_names(&p.bounded_ty));
                    }
                }
            }
        }
        let mut has_self = false;
        let mut params = Vec::new();
        let mut typed = Vec::new();
        for input in &sig.inputs {
            match input {
                syn::FnArg::Receiver(_) => has_self = true,
                syn::FnArg::Typed(t) => {
                    let names = type_names(&t.ty);
                    if let syn::Pat::Ident(i) = &*t.pat
                        && let Some(ty) = named_type(&t.ty, self_ty.as_deref())
                    {
                        typed.push((i.ident.to_string(), ty));
                    }
                    params.push((bound(&t.pat), is_pathy(&names, &generic_paths)));
                }
            }
        }
        let returns_path = match &sig.output {
            syn::ReturnType::Default => false,
            syn::ReturnType::Type(_, ty) => is_pathy(&type_names(ty), &generic_paths),
        };
        self.funcs.push(Func {
            rel: rel.to_owned(),
            module: module.to_vec(),
            self_ty,
            name: sig.ident.to_string(),
            has_self,
            params,
            typed,
            returns_path,
            body,
        });
        // Functions declared inside this one's body.
        struct Nested<'a>(Vec<&'a syn::ItemFn>);
        impl<'a> Visit<'a> for Nested<'a> {
            fn visit_item_fn(&mut self, f: &'a syn::ItemFn) {
                self.0.push(f);
            }
            fn visit_item_impl(&mut self, _: &'a syn::ItemImpl) {}
            fn visit_item_mod(&mut self, _: &'a syn::ItemMod) {}
        }
        let mut nested = Nested(Vec::new());
        for stmt in &body.stmts {
            if let syn::Stmt::Item(item) = stmt {
                nested.visit_item(item);
            }
        }
        for f in nested.0 {
            if !is_test_attr(&f.attrs) {
                self.func(rel, module, None, &f.sig, &f.block);
            }
        }
    }

    /// The function `segments` names, from `module` (an import, a module path, a type's path).
    fn resolve(&self, module: &[String], self_ty: Option<&str>, segments: &[String]) -> Vec<usize> {
        let Some((name, qualifier)) = segments.split_last() else { return Vec::new() };
        let Some(candidates) = self.by_name.get(name) else { return Vec::new() };
        let expanded = self.expand(module, segments);
        let free_in = |m: &[String]| -> Vec<usize> {
            candidates
                .iter()
                .copied()
                .filter(|&i| self.funcs[i].module == m && self.funcs[i].self_ty.is_none())
                .collect()
        };
        let method_of = |ty: &str| -> Vec<usize> {
            candidates
                .iter()
                .copied()
                .filter(|&i| self.funcs[i].self_ty.as_deref() == Some(ty))
                .collect()
        };
        if qualifier.is_empty() {
            let mut found = free_in(module);
            if found.is_empty()
                && let Some(full) = &expanded
                && full.first().is_some_and(|s| s == "crate")
            {
                found = free_in(&full[1..full.len() - 1]);
            }
            if found.is_empty() {
                for glob in self.globs(module) {
                    found.extend(free_in(&glob));
                }
            }
            return found;
        }
        if qualifier.len() == 1 && qualifier[0] == "Self" {
            return self_ty.map(method_of).unwrap_or_default();
        }
        let mut found = Vec::new();
        if let Some(full) = &expanded
            && full.first().is_some_and(|s| s == "crate")
        {
            let (_, q) = full[1..].split_last().unwrap_or((name, &[]));
            found.extend(free_in(q));
            if let Some(ty) = q.last() {
                found.extend(method_of(ty));
            }
        }
        if found.is_empty() {
            // A child module of this one, a type, or a module named by its last parts.
            let mut child = module.to_vec();
            child.extend(qualifier.iter().cloned());
            found.extend(free_in(&child));
            if let Some(ty) = qualifier.last() {
                found.extend(method_of(ty));
            }
            if found.is_empty() && expanded.as_ref().is_none_or(|f| f[0] == "crate") {
                found.extend(candidates.iter().copied().filter(|&i| {
                    let f = &self.funcs[i];
                    f.self_ty.is_none() && f.module.ends_with(qualifier)
                }));
            }
        }
        found
    }

    /// The modules `module` imports whole, and theirs.
    fn globs(&self, module: &[String]) -> Vec<Vec<String>> {
        let mut out = Vec::new();
        let mut todo = vec![module.to_vec()];
        while let Some(m) = todo.pop() {
            for g in self.uses.get(&m).map(|u| u.globs.clone()).unwrap_or_default() {
                if g.first().is_some_and(|s| s == "crate") {
                    let g = g[1..].to_vec();
                    if !out.contains(&g) && g != module {
                        out.push(g.clone());
                        todo.push(g);
                    }
                }
            }
        }
        out
    }

    /// `segments` with its first part replaced by what it imports, when it is an import of
    /// `module` (or of a module it imports whole); a `crate::`, `self::` or `super::` path made
    /// whole. `None`: not an import.
    fn expand(&self, module: &[String], segments: &[String]) -> Option<Vec<String>> {
        let first = segments.first()?;
        let rest = &segments[1..];
        match first.as_str() {
            "crate" => return Some(segments.to_vec()),
            "self" => {
                let mut out = vec!["crate".to_owned()];
                out.extend(module.iter().cloned());
                out.extend(rest.iter().cloned());
                return Some(out);
            }
            "super" => {
                let mut base = module.to_vec();
                let mut rest = segments;
                while rest.first().is_some_and(|s| s == "super") {
                    base.pop();
                    rest = &rest[1..];
                }
                let mut out = vec!["crate".to_owned()];
                out.extend(base);
                out.extend(rest.iter().cloned());
                return Some(out);
            }
            _ => {}
        }
        let mut modules = vec![module.to_vec()];
        modules.extend(self.globs(module));
        for m in modules {
            if let Some(full) = self.uses.get(&m).and_then(|u| u.alias.get(first)) {
                let mut out = full.clone();
                out.extend(rest.iter().cloned());
                return Some(out);
            }
        }
        None
    }
}

fn use_tree(module: &[String], prefix: Vec<String>, tree: &syn::UseTree, uses: &mut Uses) {
    let absolute = |mut path: Vec<String>| -> Vec<String> {
        match path.first().map(String::as_str) {
            Some("crate") => path,
            Some("self") => {
                let mut out = vec!["crate".to_owned()];
                out.extend(module.iter().cloned());
                out.extend(path.drain(1..));
                out
            }
            Some("super") => {
                let mut base = module.to_vec();
                let mut i = 0;
                while path.get(i).is_some_and(|s| s == "super") {
                    base.pop();
                    i += 1;
                }
                let mut out = vec!["crate".to_owned()];
                out.extend(base);
                out.extend(path.drain(i..));
                out
            }
            _ => path,
        }
    };
    match tree {
        syn::UseTree::Path(p) => {
            let mut prefix = prefix;
            prefix.push(p.ident.to_string());
            use_tree(module, prefix, &p.tree, uses);
        }
        syn::UseTree::Name(n) => {
            let name = n.ident.to_string();
            let mut path = prefix;
            if name != "self" {
                path.push(name.clone());
            }
            let key = path.last().cloned().unwrap_or(name);
            uses.alias.insert(key, absolute(path));
        }
        syn::UseTree::Rename(r) => {
            let mut path = prefix;
            if r.ident != "self" {
                path.push(r.ident.to_string());
            }
            uses.alias.insert(r.rename.to_string(), absolute(path));
        }
        syn::UseTree::Glob(_) => uses.globs.push(absolute(prefix)),
        syn::UseTree::Group(g) => {
            for item in &g.items {
                use_tree(module, prefix.clone(), item, uses);
            }
        }
    }
}

fn path_segments(path: &syn::Path) -> Vec<String> {
    path.segments.iter().map(|s| s.ident.to_string()).collect()
}

/// A function's local bindings: the names each binds and the value it binds them to, with
/// whether the names are the items of that value (a closure's argument on an iterator).
struct Bindings<'a>(Vec<(Vec<String>, &'a syn::Expr)>);

impl<'a> Visit<'a> for Bindings<'a> {
    fn visit_local(&mut self, l: &'a syn::Local) {
        if let Some(init) = &l.init {
            self.0.push((bound(&l.pat), &init.expr));
        }
        syn::visit::visit_local(self, l);
    }
    fn visit_expr_let(&mut self, l: &'a syn::ExprLet) {
        self.0.push((bound(&l.pat), &l.expr));
        syn::visit::visit_expr_let(self, l);
    }
    fn visit_expr_for_loop(&mut self, l: &'a syn::ExprForLoop) {
        self.0.push((bound(&l.pat), &l.expr));
        syn::visit::visit_expr_for_loop(self, l);
    }
    fn visit_expr_match(&mut self, m: &'a syn::ExprMatch) {
        for arm in &m.arms {
            self.0.push((bound(&arm.pat), &m.expr));
        }
        syn::visit::visit_expr_match(self, m);
    }
    fn visit_expr_assign(&mut self, a: &'a syn::ExprAssign) {
        if let syn::Expr::Path(p) = &*a.left
            && let Some(ident) = p.path.get_ident()
        {
            self.0.push((vec![ident.to_string()], &a.right));
        }
        syn::visit::visit_expr_assign(self, a);
    }
    fn visit_expr_method_call(&mut self, m: &'a syn::ExprMethodCall) {
        for arg in &m.args {
            if let syn::Expr::Closure(c) = arg {
                let names = c.inputs.iter().flat_map(bound).collect();
                self.0.push((names, &m.receiver));
            }
        }
        syn::visit::visit_expr_method_call(self, m);
    }
    fn visit_item(&mut self, _: &'a syn::Item) {}
}

/// Where a function is read: its module, type and taint so far.
struct Scope<'i, 'a> {
    index: &'i Index<'a>,
    state: &'i State,
    func: &'i Func<'a>,
    env: HashSet<String>,
    /// Locals and parameters whose type is one of the crate's structs.
    types: HashMap<String, String>,
    /// Locals bound to an `OpenOptions` (true) or a `DirBuilder` (false), and the methods called
    /// on them anywhere in the function.
    builders: HashMap<String, (bool, HashSet<String>)>,
}

/// What a builder chain's receiver is: an `OpenOptions` (true) or a `DirBuilder` (false), and
/// the methods called on the chain.
fn builder_root(scope: &Scope<'_, '_>, mut expr: &syn::Expr) -> Option<(bool, HashSet<String>)> {
    let mut methods = HashSet::new();
    loop {
        match expr {
            syn::Expr::MethodCall(m) => {
                methods.insert(m.method.to_string());
                expr = &m.receiver;
            }
            syn::Expr::Reference(r) => expr = &r.expr,
            syn::Expr::Paren(p) => expr = &p.expr,
            syn::Expr::Call(c) => {
                let syn::Expr::Path(p) = &*c.func else { return None };
                let segments = path_segments(&p.path);
                let full = scope.index.expand(&scope.func.module, &segments).unwrap_or(segments);
                if full.iter().any(|s| s == "home_fs") {
                    return None;
                }
                let n = full.len();
                let tail: Vec<&str> =
                    full[n.saturating_sub(2)..].iter().map(String::as_str).collect();
                return match tail.as_slice() {
                    ["OpenOptions", "new"] | ["File", "options"] => Some((true, methods)),
                    ["DirBuilder", "new"] => Some((false, methods)),
                    _ => None,
                };
            }
            syn::Expr::Path(p) => {
                let ident = p.path.get_ident()?.to_string();
                let (open, more) = scope.builders.get(&ident)?;
                methods.extend(more.iter().cloned());
                return Some((*open, methods));
            }
            _ => return None,
        }
    }
}

impl Scope<'_, '_> {
    fn methods_of(&self, name: &str, on_self: bool) -> Vec<usize> {
        let Some(candidates) = self.index.by_name.get(name) else { return Vec::new() };
        let methods: Vec<usize> =
            candidates.iter().copied().filter(|&i| self.index.funcs[i].has_self).collect();
        if on_self && let Some(ty) = &self.func.self_ty {
            let own: Vec<usize> = methods
                .iter()
                .copied()
                .filter(|&i| self.index.funcs[i].self_ty.as_ref() == Some(ty))
                .collect();
            if !own.is_empty() {
                return own;
            }
        }
        if STD_METHODS.contains(&name) { Vec::new() } else { methods }
    }

    fn is_self(expr: &syn::Expr) -> bool {
        matches!(expr, syn::Expr::Path(p) if p.path.is_ident("self"))
    }

    fn call_targets(&self, func: &syn::Expr) -> Option<Vec<usize>> {
        let syn::Expr::Path(p) = func else { return None };
        let segments = path_segments(&p.path);
        Some(self.index.resolve(&self.func.module, self.func.self_ty.as_deref(), &segments))
    }

    /// Whether `expr`'s value comes from the home.
    fn taint(&self, expr: &syn::Expr) -> bool {
        use syn::Expr as E;
        match expr {
            E::Path(p) => p.path.get_ident().is_some_and(|i| self.env.contains(&i.to_string())),
            E::Field(f) => {
                let syn::Member::Named(name) = &f.member else { return self.taint(&f.base) };
                let name = name.to_string();
                if Self::is_self(&f.base) {
                    return self
                        .func
                        .self_ty
                        .as_ref()
                        .is_some_and(|ty| self.state.fields.contains(&(ty.clone(), name)));
                }
                if self.taint(&f.base) {
                    return true;
                }
                // The receiver's type, when it is resolved: that type's field, and no other.
                if let syn::Expr::Path(p) = &*f.base
                    && let Some(ident) = p.path.get_ident()
                    && let Some(ty) = self.types.get(&ident.to_string())
                {
                    return self.state.fields.contains(&(ty.clone(), name));
                }
                // Not resolved: any type's field of that name.
                self.state.fields.iter().any(|(_, field)| *field == name)
            }
            E::Call(c) => {
                if let E::Path(p) = &*c.func
                    && let Some(ident) = p.path.get_ident()
                    && self.env.contains(&ident.to_string())
                {
                    return true;
                }
                let any = c.args.iter().any(|a| self.taint(a));
                match self.call_targets(&c.func) {
                    Some(targets) => {
                        targets.iter().any(|t| self.state.returns.contains(t))
                            || (any
                                && (targets.is_empty()
                                    || targets.iter().any(|&t| self.index.funcs[t].returns_path)))
                    }
                    None => any || self.taint(&c.func),
                }
            }
            E::MethodCall(m) => {
                let targets = self.methods_of(&m.method.to_string(), Self::is_self(&m.receiver));
                if targets.iter().any(|t| self.state.returns.contains(t)) {
                    return true;
                }
                let any = self.taint(&m.receiver) || m.args.iter().any(|a| self.taint(a));
                any && (targets.is_empty()
                    || targets.iter().any(|&t| self.index.funcs[t].returns_path))
            }
            E::Reference(r) => self.taint(&r.expr),
            E::Paren(p) => self.taint(&p.expr),
            E::Group(g) => self.taint(&g.expr),
            E::Unary(u) => self.taint(&u.expr),
            E::Cast(c) => self.taint(&c.expr),
            E::Try(t) => self.taint(&t.expr),
            E::Await(a) => self.taint(&a.base),
            E::Index(i) => self.taint(&i.expr),
            E::Macro(m) => self.taint_macro(&m.mac),
            E::Block(b) => self.taint_block(&b.block),
            E::Unsafe(b) => self.taint_block(&b.block),
            E::Async(b) => self.taint_block(&b.block),
            E::If(i) => {
                self.taint_block(&i.then_branch)
                    || i.else_branch.as_ref().is_some_and(|(_, e)| self.taint(e))
            }
            E::Match(m) => m.arms.iter().any(|arm| self.taint(&arm.body)),
            E::Closure(c) => self.taint(&c.body),
            E::Struct(s) => s.fields.iter().any(|f| self.taint(&f.expr)),
            E::Tuple(t) => t.elems.iter().any(|e| self.taint(e)),
            E::Array(a) => a.elems.iter().any(|e| self.taint(e)),
            E::Binary(b) => self.taint(&b.left) || self.taint(&b.right),
            _ => false,
        }
    }

    fn taint_block(&self, block: &syn::Block) -> bool {
        match block.stmts.last() {
            Some(syn::Stmt::Expr(e, None)) => self.taint(e),
            _ => false,
        }
    }

    fn taint_macro(&self, mac: &syn::Macro) -> bool {
        let Ok(args) = mac.parse_body_with(
            syn::punctuated::Punctuated::<syn::Expr, syn::Token![,]>::parse_terminated,
        ) else {
            return false;
        };
        args.iter().any(|arg| {
            self.taint(arg)
                || matches!(arg, syn::Expr::Lit(syn::ExprLit { lit: syn::Lit::Str(s), .. })
                    if captures(&s.value()).iter().any(|c| self.env.contains(c)))
        })
    }
}

/// The names a format string captures inline (`{home}`, `{dir:?}`).
fn captures(format: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = format;
    while let Some(start) = rest.find('{') {
        rest = &rest[start + 1..];
        if rest.starts_with('{') {
            rest = &rest[1..];
            continue;
        }
        let end = rest.find(['}', ':']).unwrap_or(rest.len());
        let name = &rest[..end];
        if !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_') {
            out.push(name.to_owned());
        }
    }
    out
}

/// What reading one function adds: tainted parameters of the functions it calls, tainted
/// fields, whether its return is tainted, and its writes by path from the home.
#[derive(Default)]
struct Found {
    params: Vec<(usize, usize)>,
    fields: Vec<(String, String)>,
    returns: bool,
    rows: Vec<Row>,
}

struct Walk<'s, 'i, 'a> {
    scope: &'s Scope<'i, 'a>,
    found: Found,
}

impl Walk<'_, '_, '_> {
    fn row(&mut self, at: proc_macro2::Span, sink: String) {
        self.found.rows.push(Row {
            rel: self.scope.func.rel.clone(),
            line: at.start().line,
            func: self.scope.func.qualified(),
            sink,
        });
    }

    fn flow(&mut self, targets: &[usize], args: &[&syn::Expr], path_call: bool) {
        for (i, arg) in args.iter().enumerate() {
            if !self.scope.taint(arg) {
                continue;
            }
            for &t in targets {
                let f = &self.scope.index.funcs[t];
                let j = if path_call && f.has_self {
                    match i.checked_sub(1) {
                        Some(j) => j,
                        None => continue,
                    }
                } else {
                    i
                };
                if f.params.get(j).is_some_and(|(_, pathy)| *pathy) {
                    self.found.params.push((t, j));
                }
            }
        }
    }
}

impl<'ast> Visit<'ast> for Walk<'_, '_, '_> {
    fn visit_item(&mut self, _: &'ast syn::Item) {}

    fn visit_expr_call(&mut self, c: &'ast syn::ExprCall) {
        let args: Vec<&syn::Expr> = c.args.iter().collect();
        if let syn::Expr::Path(p) = &*c.func {
            let segments = path_segments(&p.path);
            let full = self
                .scope
                .index
                .expand(&self.scope.func.module, &segments)
                .unwrap_or_else(|| segments.clone());
            let n = full.len();
            let tail: Vec<&str> = full[n.saturating_sub(2)..].iter().map(String::as_str).collect();
            let by_path = !full.iter().any(|s| s == "home_fs");
            let sink = match tail.as_slice() {
                ["fs", op] if by_path && FS_WRITES.contains(op) => Some(format!("fs::{op}")),
                ["File", op @ ("create" | "create_new")] if by_path => Some(format!("File::{op}")),
                _ => None,
            };
            let targets = self.scope.index.resolve(
                &self.scope.func.module,
                self.scope.func.self_ty.as_deref(),
                &segments,
            );
            let owner_only = targets.iter().any(|&t| {
                let f = &self.scope.index.funcs[t];
                f.module.last().is_some_and(|m| m == "owner_only")
                    && OWNER_ONLY_WRITES.contains(&f.name.as_str())
            });
            let sink = sink.or_else(|| {
                owner_only.then(|| {
                    format!("owner_only::{}", segments.last().cloned().unwrap_or_default())
                })
            });
            if let Some(sink) = sink
                && args.iter().any(|a| self.scope.taint(a))
            {
                self.row(c.span(), sink);
            }
            self.flow(&targets, &args, true);
        }
        syn::visit::visit_expr_call(self, c);
    }

    fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
        let method = m.method.to_string();
        if matches!(method.as_str(), "open" | "create")
            && let Some((open, methods)) = builder_root(self.scope, &m.receiver)
            && m.args.first().is_some_and(|a| self.scope.taint(a))
        {
            if open && method == "open" && methods.iter().any(|x| WRITEISH.contains(&x.as_str())) {
                self.row(m.span(), "OpenOptions::open".to_owned());
            } else if !open && method == "create" {
                self.row(m.span(), "DirBuilder::create".to_owned());
            }
        }
        let targets = self.scope.methods_of(&method, Scope::is_self(&m.receiver));
        let args: Vec<&syn::Expr> = m.args.iter().collect();
        self.flow(&targets, &args, false);
        syn::visit::visit_expr_method_call(self, m);
    }

    fn visit_expr_struct(&mut self, s: &'ast syn::ExprStruct) {
        let ty = s.path.segments.last().map(|seg| seg.ident.to_string());
        let ty = if ty.as_deref() == Some("Self") { self.scope.func.self_ty.clone() } else { ty };
        if let Some(ty) = ty {
            for field in &s.fields {
                if let syn::Member::Named(name) = &field.member
                    && self.scope.taint(&field.expr)
                {
                    self.found.fields.push((ty.clone(), name.to_string()));
                }
            }
        }
        syn::visit::visit_expr_struct(self, s);
    }

    fn visit_expr_assign(&mut self, a: &'ast syn::ExprAssign) {
        if let syn::Expr::Field(f) = &*a.left
            && Scope::is_self(&f.base)
            && let syn::Member::Named(name) = &f.member
            && let Some(ty) = &self.scope.func.self_ty
            && self.scope.taint(&a.right)
        {
            self.found.fields.push((ty.clone(), name.to_string()));
        }
        syn::visit::visit_expr_assign(self, a);
    }

    fn visit_expr_return(&mut self, r: &'ast syn::ExprReturn) {
        if r.expr.as_ref().is_some_and(|e| self.scope.taint(e)) {
            self.found.returns = true;
        }
        syn::visit::visit_expr_return(self, r);
    }

    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        if let Ok(args) = mac.parse_body_with(
            syn::punctuated::Punctuated::<syn::Expr, syn::Token![,]>::parse_terminated,
        ) {
            for arg in &args {
                <Self as Visit<'_>>::visit_expr(self, arg);
            }
        }
    }
}

/// Reads `func` with its tainted parameters (`with_params`) or none.
fn read_func<'a>(index: &Index<'a>, state: &State, at: usize, with_params: bool) -> Found {
    let func = &index.funcs[at];
    let mut env = HashSet::new();
    if with_params {
        for (j, (names, _)) in func.params.iter().enumerate() {
            if state.params.contains(&(at, j)) {
                env.extend(names.iter().cloned());
            }
        }
    }
    let mut bindings = Bindings(Vec::new());
    bindings.visit_block(func.body);
    let types =
        local_types(func).into_iter().filter(|(_, ty)| index.structs.contains(ty)).collect();
    let mut scope = Scope { index, state, func, env, types, builders: HashMap::new() };
    // Builder locals, and every method called on them.
    for (names, value) in &bindings.0 {
        if let [name] = names.as_slice()
            && let Some((open, methods)) = builder_root(&scope, value)
        {
            scope.builders.insert(name.clone(), (open, methods));
        }
    }
    if !scope.builders.is_empty() {
        // A method anywhere on a chain that starts at the local counts, not only one called on
        // the local itself: `options.read(true).write(true)` writes (#41462 review F2).
        struct OnLocal<'b>(&'b mut HashMap<String, (bool, HashSet<String>)>);
        impl<'ast> Visit<'ast> for OnLocal<'_> {
            fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
                let mut root = &*m.receiver;
                while let syn::Expr::MethodCall(inner) = root {
                    root = &inner.receiver;
                }
                if let syn::Expr::Path(p) = root
                    && let Some(ident) = p.path.get_ident()
                    && let Some((_, methods)) = self.0.get_mut(&ident.to_string())
                {
                    methods.insert(m.method.to_string());
                }
                syn::visit::visit_expr_method_call(self, m);
            }
        }
        OnLocal(&mut scope.builders).visit_block(func.body);
    }
    loop {
        let before = scope.env.len();
        for (names, value) in &bindings.0 {
            if names.iter().any(|n| !scope.env.contains(n)) && scope.taint(value) {
                scope.env.extend(names.iter().cloned());
            }
        }
        if scope.env.len() == before {
            break;
        }
    }
    let mut walk = Walk { scope: &scope, found: Found::default() };
    walk.visit_block(func.body);
    let mut found = walk.found;
    found.returns |= scope.taint_block(func.body);
    found
}

/// The taint of the whole crate at its fixed point, and the writes by path it finds.
fn analyze(sources: &[Source]) -> Vec<Row> {
    let index = Index::new(sources);
    let mut state = State::default();
    for (i, f) in index.funcs.iter().enumerate() {
        if f.module == ["config"] && matches!(f.name.as_str(), "home" | "default_home") {
            state.returns.insert(i);
        }
    }
    let rows = loop {
        let mut next = state.clone();
        let mut rows = BTreeSet::new();
        for at in 0..index.funcs.len() {
            // Its return with no tainted parameter: tainted whatever its arguments.
            if read_func(&index, &state, at, false).returns {
                next.returns.insert(at);
            }
            let found = read_func(&index, &state, at, true);
            next.params.extend(found.params);
            next.fields.extend(found.fields);
            rows.extend(found.rows);
        }
        if next == state {
            break rows;
        }
        state = next;
    };
    rows.into_iter().collect()
}

fn crate_sources() -> Vec<Source> {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut sources = Vec::new();
    let lib = crate_dir.join("src").join("lib.rs");
    load(&crate_dir, &lib, Vec::new(), crate_dir.join("src"), &mut sources);
    sources
}

/// The crate's writes by path from the home, outside `home_fs.rs`.
pub(crate) fn rows() -> Vec<Row> {
    analyze(&crate_sources()).into_iter().filter(|row| row.rel != "src/home_fs.rs").collect()
}

#[test]
fn no_writer_under_the_home_goes_by_path() {
    let rows = rows();
    let allowed = |row: &Row| {
        ALLOWED.iter().any(|(rel, func, sink, _)| {
            matches(rel, &row.rel) && matches(func, &row.func) && matches(sink, &row.sink)
        })
    };
    let red: Vec<String> = rows.iter().filter(|r| !allowed(r)).map(ToString::to_string).collect();
    let stale: Vec<String> = ALLOWED
        .iter()
        .filter(|(rel, func, sink, _)| {
            !rows
                .iter()
                .any(|r| matches(rel, &r.rel) && matches(func, &r.func) && matches(sink, &r.sink))
        })
        .map(|(rel, func, sink, _)| format!("{rel} {func}: {sink}"))
        .collect();
    let allowed_rows: Vec<String> =
        rows.iter().filter(|r| allowed(r)).map(ToString::to_string).collect();
    println!("allowed ({}):\n  {}", allowed_rows.len(), allowed_rows.join("\n  "));
    assert!(
        red.is_empty() && stale.is_empty(),
        "{} write(s) by path from the home, outside home_fs.rs: make each through `home_fs` \
         (`home_fs::OpenOptions`, `create_dir_all`, `rename`, `remove_file`, `remove_dir_all`, \
         `hard_link`, `set_mode`, ...), or add it to ALLOWED with why it cannot \
         (home_writers_by_path_tests.rs says how a path is read as the home's):\n  {}\n\
         {} ALLOWED entr(ies) that match nothing (remove them):\n  {}",
        red.len(),
        red.join("\n  "),
        stale.len(),
        stale.join("\n  "),
    );
}

/// The detector itself, on a small crate: each writer the #41372 review rounds found, in the
/// shape it had, is a row; the same write through `home_fs`, or of a path not from the home, is
/// none.
#[test]
fn the_detector_finds_each_shape_of_a_home_write_by_path() {
    let source = |rel: &str, module: &[&str], text: &str| Source {
        rel: rel.to_owned(),
        module: module.iter().map(|s| (*s).to_owned()).collect(),
        file: syn::parse_file(text).unwrap(),
    };
    let sources = vec![
        source(
            "src/config.rs",
            &["config"],
            r#"
            use std::path::{Path, PathBuf};
            pub fn home() -> PathBuf { PathBuf::from(std::env::var("ACPMUX_HOME").unwrap()) }
            pub fn start() {
                let home = home();
                let _ = crate::sender_token::ensure(&home);
            }
            pub fn write_atomic(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
                let tmp = path.with_extension("tmp");
                std::fs::write(&tmp, bytes)?;
                std::fs::rename(&tmp, path)?;
                Ok(())
            }
            "#,
        ),
        source(
            "src/sender_token.rs",
            &["sender_token"],
            r#"
            use std::path::{Path, PathBuf};
            pub fn path_in(home: &Path) -> PathBuf { home.join("sender-token") }
            pub fn ensure(home: &Path) -> anyhow::Result<()> {
                let path = path_in(home);
                let tmp = home.join(format!(".t.tmp-{}", 1));
                let mut f = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
                std::fs::hard_link(&tmp, &path)?;
                let _ = std::fs::remove_file(&tmp);
                Ok(())
            }
            "#,
        ),
        source(
            "src/store.rs",
            &["store"],
            r#"
            use std::path::{Path, PathBuf};
            pub struct LocalStore { root: PathBuf }
            impl LocalStore {
                pub fn new(root: PathBuf) -> Self { Self { root } }
                fn dir(&self, id: &str) -> PathBuf { self.root.join(id) }
            }
            pub fn open() -> LocalStore { LocalStore::new(crate::config::home().join("sessions")) }
            "#,
        ),
        source(
            "src/store/cold.rs",
            &["store", "cold"],
            r#"
            use super::*;
            impl LocalStore {
                pub fn rehydrate(&self, id: &str) -> anyhow::Result<()> {
                    let dir = self.dir(id);
                    for entry in std::fs::read_dir(&dir)? {
                        let _ = std::fs::remove_file(entry?.path());
                    }
                    std::fs::rename(dir.join("thaw"), dir.join("events"))?;
                    crate::home_fs::rename(&dir.join("a"), &dir.join("b"))?;
                    Ok(())
                }
            }
            "#,
        ),
        // #41462 review F2: fields whose names another struct shares (`path`, `tmp`), read
        // through a closure's argument and a loop's binding, whose types are not resolved.
        source(
            "src/store/compact.rs",
            &["store", "compact"],
            r#"
            use super::*;
            struct Staged { segments: Vec<StagedSegment> }
            struct StagedSegment { path: PathBuf, len: u64, tmp: Option<PathBuf> }
            struct Elsewhere { path: PathBuf, tmp: Option<PathBuf> }
            impl Drop for Staged {
                fn drop(&mut self) {
                    for tmp in self.segments.iter().filter_map(|s| s.tmp.as_ref()) {
                        let _ = std::fs::remove_file(tmp);
                    }
                }
            }
            impl LocalStore {
                fn stage(&self, id: &str) -> Staged {
                    let mut staged = Staged { segments: Vec::new() };
                    let path = self.dir(id).join("events").join("000001.ndjson");
                    let tmp = Some(path.with_extension("compact"));
                    staged.segments.push(StagedSegment { path: path.clone(), len: 0, tmp });
                    staged
                }
                fn commit(&self, staged: &mut Staged) -> std::io::Result<()> {
                    for segment in &mut staged.segments {
                        if let Some(tmp) = segment.tmp.take() {
                            std::fs::rename(&tmp, &segment.path)?;
                        }
                    }
                    Ok(())
                }
            }
            // Its type resolved, `Elsewhere`'s fields never came from the home: no row.
            fn elsewhere(other: &Elsewhere) {
                let _ = std::fs::remove_file(&other.path);
            }
            "#,
        ),
        source(
            "src/hub/file_uploads.rs",
            &["hub", "file_uploads"],
            r#"
            use std::path::{Path, PathBuf};
            use std::fs;
            fn root() -> PathBuf { crate::config::home().join("uploads") }
            pub fn finish(id: &str) {
                let dir = root().join(id);
                let _ = fs::rename(dir.join(".part"), dir.join("f"));
                let _ = std::fs::write("/tmp/not-the-home", b"x");
            }
            "#,
        ),
        // #41462 review F2: a builder local whose write flags follow another method in one
        // chain (`options.read(true).write(true)`): the chain's receiver is a method call, not
        // the local. A local that only reads is no row.
        source(
            "src/workflow_runs.rs",
            &["workflow_runs"],
            r#"
            use std::fs::OpenOptions;
            use std::path::Path;
            fn lock(dir: &Path) -> std::io::Result<std::fs::File> {
                let mut options = OpenOptions::new();
                options.read(true).write(true).create(true).truncate(false);
                options.open(dir.join("record.lock"))
            }
            fn read(path: &Path) -> std::io::Result<std::fs::File> {
                let mut options = OpenOptions::new();
                options.read(true);
                options.open(path)
            }
            pub fn start(id: &str) {
                let dir = crate::config::home().join("workflows").join(id);
                let _ = lock(&dir);
                let _ = read(&dir.join("record.json"));
            }
            "#,
        ),
    ];
    let rows: Vec<String> =
        analyze(&sources).iter().map(|r| format!("{} {}: {}", r.rel, r.func, r.sink)).collect();
    let want = [
        "src/hub/file_uploads.rs finish: fs::rename",
        "src/sender_token.rs ensure: OpenOptions::open",
        "src/sender_token.rs ensure: fs::hard_link",
        "src/sender_token.rs ensure: fs::remove_file",
        "src/store/cold.rs LocalStore::rehydrate: fs::remove_file",
        "src/store/cold.rs LocalStore::rehydrate: fs::rename",
        "src/store/compact.rs Staged::drop: fs::remove_file",
        "src/store/compact.rs LocalStore::commit: fs::rename",
        "src/workflow_runs.rs lock: OpenOptions::open",
    ];
    // `write_atomic` is no row: nothing here calls it with a path from the home.
    let mut rows = rows;
    rows.dedup();
    assert_eq!(rows, want, "rows");
}

/// #41462 review F1: every `OpenOptions` chain in `home_fs.rs` names its mode (`.mode(..)`), so
/// no helper there makes a file with the default 0666 (less the umask) and narrows it after its
/// bytes are in. `std::fs::OpenOptions` there is its Windows arm, which has no mode: the
/// owner-only creates (`owner_only`) give those files their access list.
#[test]
fn every_open_in_home_fs_names_its_mode() {
    struct Opens(Vec<(usize, String)>);
    impl<'ast> Visit<'ast> for Opens {
        fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
            if m.method == "open" {
                let mut methods = HashSet::new();
                let mut expr = &*m.receiver;
                while let syn::Expr::MethodCall(inner) = expr {
                    methods.insert(inner.method.to_string());
                    expr = &inner.receiver;
                }
                if let syn::Expr::Call(c) = expr
                    && let syn::Expr::Path(p) = &*c.func
                    && path_segments(&p.path) == ["OpenOptions", "new"]
                    && !methods.contains("mode")
                {
                    let chain = methods.into_iter().collect::<BTreeSet<_>>();
                    self.0.push((m.span().start().line, format!("{chain:?}")));
                }
            }
            syn::visit::visit_expr_method_call(self, m);
        }
        fn visit_item_mod(&mut self, m: &'ast syn::ItemMod) {
            if !is_test_attr(&m.attrs) {
                syn::visit::visit_item_mod(self, m);
            }
        }
        fn visit_item_fn(&mut self, f: &'ast syn::ItemFn) {
            if !is_test_attr(&f.attrs) {
                syn::visit::visit_item_fn(self, f);
            }
        }
    }
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/home_fs.rs");
    let file = syn::parse_file(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let mut opens = Opens(Vec::new());
    opens.visit_file(&file);
    let rows: Vec<String> =
        opens.0.iter().map(|(line, chain)| format!("  src/home_fs.rs:{line} {chain}")).collect();
    assert!(
        rows.is_empty(),
        "{} OpenOptions chain(s) in home_fs.rs name no mode: give each `.mode(..)` (0600, or the \
         source's mode narrowed to it), set before any byte is written:\n{}",
        rows.len(),
        rows.join("\n")
    );
}
