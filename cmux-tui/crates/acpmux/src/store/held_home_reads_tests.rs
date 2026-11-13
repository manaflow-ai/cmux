//! The lint for existence and metadata checks in the store (#41721 review F1: "Use the held-handle
//! check on every platform, and add a lint that nothing in store/ calls the path-based form.").
//!
//! The store's files live under the home. A check of what is there, made by path, reads whatever
//! folder sits at the home's path now: after the home is replaced, a replacement without the file
//! answers "not there" while the held home still holds it (`rehydrate` read "not archived" and the
//! caller read the chat as empty). `home_fs::try_exists_nofollow` and `home_fs::symlink_metadata`
//! read the held home on every platform: on Unix through its descriptor, elsewhere between two
//! checks of its file id, so a lost home is an error there, never "not there".
//!
//! What it reads: `src/store.rs` and every module below it, followed through `mod` and `#[path]`,
//! on every `cfg` (a Windows-only arm too), with anything under `#[cfg(test)]` or `#[test]` left
//! out (a test makes its own scratch homes).
//!
//! A row: a call of `exists_nofollow` (any error, a lost home's too, reads as "not there"); a
//! call of std's `metadata`, `symlink_metadata`, `exists` or `try_exists` (`std::fs::`,
//! `Path::`), judged by the path the module's `use` imports resolve the call to (by name, an
//! alias, a group, a glob, `fs::` through `use std::fs;`; #41915 review F2), outside `home_fs`; a method `.exists()`,
//! `.try_exists()` or `.symlink_metadata()` (only a path has these); and `.metadata()`, `.is_file()`, `.is_dir()` or `.is_symlink()` on a
//! receiver that is a path by its shape (a `File`, a `Metadata` and a `FileType` have these too):
//! a path maker's value (`join`, `parent`, `path()`, `cold_path`, `Path::new`, ...), or a local
//! or parameter bound to one or typed as a path. A macro's comma-separated arguments are read
//! too (`ensure!(!path.exists(), ..)`).
//!
//! A call's path is resolved the way Rust does: through `use` imports (an alias, a group, a glob,
//! one written `self::`, `super::` or through another import), `crate::`, `self::` and `super::`
//! into modules in this file or another, through a type alias or a `const` bound to a path,
//! `Self` and `<T>::`, every glob a glob reaches, and down each `cfg` arm of a gated item. It fails
//! closed: a call it cannot settle to a known item that is not a read (a path into a module it
//! cannot read, a `super::` past the root, a loop of imports, or another crate's `metadata`,
//! `exists`, `try_exists` or `symlink_metadata`) is a row, never skipped (#42003 review).

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use syn::spanned::Spanned;
use syn::visit::Visit;

/// Functions and methods whose value is a path.
const PATH_MAKERS: &[&str] = &[
    "join",
    "with_extension",
    "with_file_name",
    "parent",
    "path",
    "to_path_buf",
    "as_path",
    "cold_path",
    "dir",
    "marker",
    "session_path",
    "session_dir",
    "new",
    "from",
];

/// Reads only a path has.
const PATH_ONLY: &[&str] = &["exists", "try_exists", "symlink_metadata"];

/// Reads a `File`, a `Metadata` or a `FileType` has too.
const SHARED: &[&str] = &["metadata", "is_file", "is_dir", "is_symlink"];

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
        text == "test" || text.starts_with("all(test,") || text.contains(",test)")
    })
}

/// Whether an item builds only under some `cfg`: `#[cfg(test)]`, `#[cfg(windows)]`,
/// `#[cfg(target_os = "..")]` or any other.
fn is_cfg_gated(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| attr.path().is_ident("cfg"))
}

fn path_attr(attrs: &[syn::Attribute]) -> Option<String> {
    attrs.iter().find_map(|attr| {
        let syn::Meta::NameValue(nv) = &attr.meta else { return None };
        if !nv.path.is_ident("path") {
            return None;
        }
        let syn::Expr::Lit(syn::ExprLit { lit: syn::Lit::Str(s), .. }) = &nv.value else {
            return None;
        };
        Some(s.value())
    })
}

/// Where `mod m;`, declared in `file` (whose `mod x;` finds `x.rs` in `dir`), finds its file, and
/// where that file's own `mod x;` finds `x.rs`.
fn mod_file(m: &syn::ItemMod, file: &Path, dir: &Path) -> (PathBuf, PathBuf) {
    let name = m.ident.to_string();
    match path_attr(&m.attrs) {
        Some(rel) => {
            let base = file.parent().unwrap_or(Path::new(""));
            (base.join(&rel), base.join(&rel).with_extension(""))
        }
        None if dir.join(format!("{name}.rs")).exists() => {
            (dir.join(format!("{name}.rs")), dir.join(&name))
        }
        None => (dir.join(&name).join("mod.rs"), dir.join(&name)),
    }
}

/// One loaded file: where it is, its module's path (`crate::store::cold`), and its syntax.
type Loaded = (PathBuf, Vec<String>, syn::File);

/// `file` and the files of the modules it declares (not under a test `cfg`), recursively. `dir`:
/// where its `mod x;` finds `x.rs`; `module`: its module's path.
fn load(file: &Path, dir: &Path, module: Vec<String>, out: &mut Vec<Loaded>) {
    let text = std::fs::read_to_string(file).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
    let parsed = syn::parse_file(&text).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
    load_items(&parsed.items, file, dir, &module, out);
    out.push((file.to_path_buf(), module, parsed));
}

fn load_items(
    items: &[syn::Item],
    file: &Path,
    dir: &Path,
    module: &[String],
    out: &mut Vec<Loaded>,
) {
    for item in items {
        let syn::Item::Mod(m) = item else { continue };
        if is_test_attr(&m.attrs) {
            continue;
        }
        let name = m.ident.to_string();
        let child_module = [module, std::slice::from_ref(&name)].concat();
        if let Some((_, inline)) = &m.content {
            load_items(inline, file, &dir.join(&name), &child_module, out);
            continue;
        }
        let (child, child_dir) = mod_file(m, file, dir);
        load(&child, &child_dir, child_module, out);
    }
}

/// The crate's `src` folder.
fn crate_src() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src")
}

/// The store's sources: `src/store.rs` and its modules, with their module paths.
fn store_sources() -> Vec<(String, Vec<String>, syn::File)> {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let src = crate_src();
    let mut out = Vec::new();
    load(&src.join("store.rs"), &src.join("store"), vec!["crate".into(), "store".into()], &mut out);
    out.into_iter()
        .map(|(path, module, file)| {
            let rel = path.strip_prefix(&crate_dir).unwrap_or(&path);
            (rel.to_string_lossy().replace('\\', "/"), module, file)
        })
        .collect()
}

/// Whether `ty` names a path (`Path`, `PathBuf`, `OsStr`, `OsString`, `impl AsRef<Path>`, ...).
fn names_a_path(ty: &syn::Type) -> bool {
    struct Names(bool);
    impl<'ast> Visit<'ast> for Names {
        fn visit_ident(&mut self, i: &'ast proc_macro2::Ident) {
            let name = i.to_string();
            self.0 |= matches!(name.as_str(), "Path" | "PathBuf" | "OsStr" | "OsString");
        }
    }
    let mut names = Names(false);
    names.visit_type(ty);
    names.0
}

/// What a name is bound to in one module or block.
#[derive(Clone, Debug)]
enum Binding {
    /// A `use` of this path, as written (`["self", "metadata"]` for `use self::metadata;`).
    Import(Vec<String>),
    /// A `mod` defined here.
    Module,
    /// Another name for a path, followed to what it names like an import: a type alias of a path
    /// type (`type Path = std::path::Path;`), or a `const` or `static` bound to a path
    /// (`const PROBE: fn(..) = std::fs::metadata;`; #42352 review F1).
    Alias(Vec<String>),
    /// A function, struct, enum, union, trait, or a type alias, const or static of anything but
    /// a path, defined here: this crate's own item.
    Item,
}

/// The path a type names (`std::path::Path` for `std::path::Path` or `(Path)`), if it is a
/// plain path.
fn type_path(ty: &syn::Type) -> Option<Vec<String>> {
    match ty {
        syn::Type::Paren(p) => type_path(&p.elem),
        syn::Type::Group(g) => type_path(&g.elem),
        syn::Type::Path(p) if p.qself.is_none() => {
            Some(p.path.segments.iter().map(|s| s.ident.to_string()).collect())
        }
        _ => None,
    }
}

/// The path an expression is (`std::fs::metadata`), if it is a plain path.
fn expr_path(expr: &syn::Expr) -> Option<Vec<String>> {
    match expr {
        syn::Expr::Paren(p) => expr_path(&p.expr),
        syn::Expr::Group(g) => expr_path(&g.expr),
        syn::Expr::Path(p) if p.qself.is_none() => {
            Some(p.path.segments.iter().map(|s| s.ident.to_string()).collect())
        }
        _ => None,
    }
}

/// The names one module or block brings in: each name's bindings (`use` imports and the items it
/// defines) and its glob imports, each with whether it is under a `cfg`. A module is `opaque`: it
/// inherits nothing from the module around it; a block sees its enclosing scopes.
///
/// A binding under a `#[cfg(..)]` (`windows`, `target_os = ..`, any other but `test`) is in some
/// builds and not others, so the lint follows it and the name's meaning without it, and a call is
/// a row when either reads by path (#41970 review F1: a `#[cfg(test)] fn metadata` hid a
/// production `metadata(path)`; #42139 review F1: a gated import alias of a std::fs function was
/// not followed). One under `#[cfg(test)]` is only in test builds, which the lint leaves out.
#[derive(Clone, Default)]
struct Scope {
    opaque: bool,
    names: HashMap<String, Vec<(Binding, bool)>>,
    globs: Vec<(Vec<String>, bool)>,
}

impl Scope {
    fn of<'a>(items: impl IntoIterator<Item = &'a syn::Item>, opaque: bool) -> Self {
        let mut scope = Scope { opaque, ..Scope::default() };
        for item in items {
            let (attrs, ident, binding) = match item {
                syn::Item::Use(u) => {
                    if !is_test_attr(&u.attrs) {
                        scope.import(&mut Vec::new(), &u.tree, is_cfg_gated(&u.attrs));
                    }
                    continue;
                }
                syn::Item::ExternCrate(e) => {
                    let name = e.rename.as_ref().map_or(&e.ident, |(_, rename)| rename);
                    (&e.attrs, name, Binding::Import(vec![e.ident.to_string()]))
                }
                syn::Item::Mod(m) => (&m.attrs, &m.ident, Binding::Module),
                syn::Item::Fn(f) => (&f.attrs, &f.sig.ident, Binding::Item),
                syn::Item::Struct(s) => (&s.attrs, &s.ident, Binding::Item),
                syn::Item::Enum(e) => (&e.attrs, &e.ident, Binding::Item),
                syn::Item::Union(u) => (&u.attrs, &u.ident, Binding::Item),
                syn::Item::Trait(t) => (&t.attrs, &t.ident, Binding::Item),
                syn::Item::Type(t) => {
                    (&t.attrs, &t.ident, type_path(&t.ty).map_or(Binding::Item, Binding::Alias))
                }
                syn::Item::Const(c) => {
                    (&c.attrs, &c.ident, expr_path(&c.expr).map_or(Binding::Item, Binding::Alias))
                }
                syn::Item::Static(s) => {
                    (&s.attrs, &s.ident, expr_path(&s.expr).map_or(Binding::Item, Binding::Alias))
                }
                _ => continue,
            };
            if !is_test_attr(attrs) {
                scope.bind(ident.to_string(), binding, is_cfg_gated(attrs));
            }
        }
        scope
    }

    fn bind(&mut self, name: String, binding: Binding, gated: bool) {
        self.names.entry(name).or_default().push((binding, gated));
    }

    fn import(&mut self, prefix: &mut Vec<String>, tree: &syn::UseTree, gated: bool) {
        match tree {
            syn::UseTree::Path(p) => {
                prefix.push(p.ident.to_string());
                self.import(prefix, &p.tree, gated);
                prefix.pop();
            }
            syn::UseTree::Name(n) if n.ident == "self" => {
                if let Some(last) = prefix.last() {
                    self.bind(last.clone(), Binding::Import(prefix.clone()), gated);
                }
            }
            syn::UseTree::Name(n) => {
                let mut full = prefix.clone();
                full.push(n.ident.to_string());
                self.bind(n.ident.to_string(), Binding::Import(full), gated);
            }
            syn::UseTree::Rename(r) => {
                let mut full = prefix.clone();
                if r.ident != "self" {
                    full.push(r.ident.to_string());
                }
                self.bind(r.rename.to_string(), Binding::Import(full), gated);
            }
            syn::UseTree::Glob(_) => self.globs.push((prefix.clone(), gated)),
            syn::UseTree::Group(g) => {
                for tree in &g.items {
                    self.import(prefix, tree, gated);
                }
            }
        }
    }
}

/// The public items of `std::fs`: the only names a `use std::fs::*;` brings in (#41970 review
/// F2), `try_exists` too (#42003 review F1). Any other name under such a glob is looked up in the
/// scopes around it.
const STD_FS_ITEMS: &[&str] = &[
    "canonicalize",
    "copy",
    "create_dir",
    "create_dir_all",
    "exists",
    "hard_link",
    "metadata",
    "read",
    "read_dir",
    "read_link",
    "read_to_string",
    "remove_dir",
    "remove_dir_all",
    "remove_file",
    "rename",
    "set_permissions",
    "soft_link",
    "symlink_metadata",
    "try_exists",
    "write",
    "DirBuilder",
    "DirEntry",
    "File",
    "FileTimes",
    "FileType",
    "Metadata",
    "OpenOptions",
    "Permissions",
    "ReadDir",
    "TryLockError",
];

/// The names whose call reads by path when the lint cannot settle what it is.
const READS: &[&str] = &["exists", "try_exists", "symlink_metadata", "metadata", "exists_nofollow"];

/// One module's items as declared: the items, and where its `mod x;` finds its file.
struct Decl {
    items: Vec<syn::Item>,
    file: PathBuf,
    dir: PathBuf,
}

/// The crate's modules by path (`crate::store::cold`), read when a `self::`, `super::` or
/// `crate::` path reaches one (#42003 review F3: a `super::` into a parent module in another
/// file): from the crate's sources on disk, or a test's files by module path. A module declared
/// more than once (one `mod` per `cfg`) is all of its declarations.
struct Modules {
    files: HashMap<String, syn::File>,
    /// The root module's file on disk and the folder its `mod x;` finds `x.rs` in.
    disk: Option<(PathBuf, PathBuf)>,
    decls: RefCell<HashMap<Vec<String>, Rc<Vec<Decl>>>>,
    scopes: RefCell<HashMap<Vec<String>, Option<Rc<Scope>>>>,
}

impl Modules {
    /// The crate on disk: `src/lib.rs` and the modules it declares.
    fn crate_on_disk() -> Self {
        Modules::on_disk(&crate_src().join("lib.rs"), &crate_src())
    }

    /// The tree rooted at `root` (the module `crate`) on disk; its `mod x;` finds `x.rs` in `dir`.
    fn on_disk(root: &Path, dir: &Path) -> Self {
        Modules::new(HashMap::new(), Some((root.to_path_buf(), dir.to_path_buf())))
    }

    /// A test's files, each `(module path, file)`; `crate` is the root.
    fn of_files(files: impl IntoIterator<Item = (String, syn::File)>) -> Self {
        Modules::new(files.into_iter().collect(), None)
    }

    fn new(files: HashMap<String, syn::File>, disk: Option<(PathBuf, PathBuf)>) -> Self {
        Modules { files, disk, decls: RefCell::default(), scopes: RefCell::default() }
    }

    fn decls(&self, module: &[String]) -> Rc<Vec<Decl>> {
        if let Some(decls) = self.decls.borrow().get(module) {
            return Rc::clone(decls);
        }
        let mut out = Vec::new();
        let test_file = self.files.get(&module.join("::"));
        match module {
            [root] if root == "crate" => {
                if let Some(file) = test_file {
                    let items = file.items.clone();
                    out.push(Decl { items, file: PathBuf::new(), dir: PathBuf::new() });
                } else if let Some((root, dir)) = &self.disk
                    && let Some(file) = parse_file_at(root)
                {
                    out.push(Decl { items: file.items, file: root.clone(), dir: dir.clone() });
                }
            }
            [parent @ .., name] if !parent.is_empty() => {
                for decl in self.decls(parent).iter() {
                    for item in &decl.items {
                        let syn::Item::Mod(m) = item else { continue };
                        if m.ident != name || is_test_attr(&m.attrs) {
                            continue;
                        }
                        if let Some((_, inline)) = &m.content {
                            let dir = decl.dir.join(name);
                            out.push(Decl { items: inline.clone(), file: decl.file.clone(), dir });
                        } else if let Some(file) = test_file {
                            let items = file.items.clone();
                            out.push(Decl { items, file: PathBuf::new(), dir: PathBuf::new() });
                        } else if self.disk.is_some() {
                            let (child, dir) = mod_file(m, &decl.file, &decl.dir);
                            if let Some(file) = parse_file_at(&child) {
                                out.push(Decl { items: file.items, file: child, dir });
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        let decls = Rc::new(out);
        self.decls.borrow_mut().insert(module.to_vec(), Rc::clone(&decls));
        decls
    }

    /// The scope of the module at `module`, or `None` when no declaration of it can be read.
    fn scope(&self, module: &[String]) -> Option<Rc<Scope>> {
        if let Some(scope) = self.scopes.borrow().get(module) {
            return scope.clone();
        }
        let decls = self.decls(module);
        let scope = (!decls.is_empty())
            .then(|| Rc::new(Scope::of(decls.iter().flat_map(|d| d.items.iter()), true)));
        self.scopes.borrow_mut().insert(module.to_vec(), scope.clone());
        scope
    }
}

impl Modules {
    /// The variants of the enum at `path`, if `path` names one.
    fn enum_variants(&self, path: &[String]) -> Option<HashSet<String>> {
        let (name, parent) = path.split_last()?;
        if parent.is_empty() {
            return None;
        }
        self.decls(parent).iter().flat_map(|decl| decl.items.iter()).find_map(|item| match item {
            syn::Item::Enum(e) if e.ident == name => {
                Some(e.variants.iter().map(|v| v.ident.to_string()).collect())
            }
            _ => None,
        })
    }
}

fn parse_file_at(path: &Path) -> Option<syn::File> {
    syn::parse_file(&std::fs::read_to_string(path).ok()?).ok()
}

/// Where a call's path leads, in one build.
#[derive(Debug)]
enum Settled {
    /// A path in std, core or alloc.
    Std(Vec<String>),
    /// An item of this crate (one `crate::home_fs` path counts as one: the held-home reads).
    Own(Vec<String>),
    /// A name no scope here binds: another crate's item, the prelude's, a local variable.
    Outside(Vec<String>),
    /// A path into this crate the resolver cannot follow, and why.
    Lost(String),
}

/// What a name finds in a scope.
enum Found {
    Binding(Binding),
    Glob(Vec<String>),
    /// Nothing here: in a block or module, a name from outside the crate's sources.
    Nothing,
}

/// The place a path is written: its module's path and the scopes around it (innermost last).
#[derive(Clone)]
struct At {
    module: Vec<String>,
    scopes: Vec<Rc<Scope>>,
    /// What `Self` names here: the self type of the `impl` around it, if a path.
    self_ty: Option<Vec<String>>,
}

/// How many imports a path is followed through before it counts as a loop.
const STEPS: usize = 12;

/// Resolves a path the way Rust does: through `use` imports (an alias, a group, a glob, one
/// written `self::`, `super::` or relative to another import; #42003 review F2), into modules
/// in other files, and down every `cfg` arm.
struct Resolver<'m> {
    modules: &'m Modules,
}

impl Resolver<'_> {
    /// Where `path`, written at `at`, leads: one entry per build its `cfg`-gated bindings make.
    fn resolve(&self, at: &At, path: &[String], steps: usize) -> Vec<Settled> {
        let Some(steps) = steps.checked_sub(1) else {
            return vec![Settled::Lost("a loop of imports".into())];
        };
        let Some(first) = path.first() else {
            return vec![Settled::Lost("an empty path".into())];
        };
        match first.as_str() {
            "std" | "core" | "alloc" => vec![Settled::Std(path.to_vec())],
            // `Self` is the impl's self type, followed like any path (an impl for std's `Path`
            // too); with none known (a trait's default method) it is no item of this crate.
            "Self" => match &at.self_ty {
                Some(ty) if ty.first().is_some_and(|s| s != "Self") => {
                    self.resolve(at, &[&ty[..], &path[1..]].concat(), steps)
                }
                _ => vec![Settled::Outside(path.to_vec())],
            },
            "crate" => self.in_module(&["crate".into()], &path[1..], steps),
            "self" | "super" => {
                let lead = path.iter().take_while(|s| *s == "self" || *s == "super").count();
                let mut module = at.module.clone();
                for (i, segment) in path[..lead].iter().enumerate() {
                    if (segment == "self" && i > 0) || (segment == "super" && module.len() <= 1) {
                        return vec![Settled::Lost(path.join("::"))];
                    }
                    if segment == "super" {
                        module.pop();
                    }
                }
                self.in_module(&module, &path[lead..], steps)
            }
            name => {
                let rest = &path[1..];
                let mut out = Vec::new();
                for found in self.lookup(at, name, steps) {
                    out.extend(match found {
                        Found::Binding(Binding::Import(full) | Binding::Alias(full)) => {
                            self.resolve(at, &[&full[..], rest].concat(), steps)
                        }
                        Found::Binding(Binding::Module) => {
                            let module = [&at.module[..], &path[..1]].concat();
                            self.in_module(&module, rest, steps)
                        }
                        Found::Binding(Binding::Item) => {
                            vec![Settled::Own([&at.module[..], path].concat())]
                        }
                        Found::Glob(glob) => self.resolve(at, &[&glob[..], path].concat(), steps),
                        Found::Nothing => vec![Settled::Outside(path.to_vec())],
                    });
                }
                out
            }
        }
    }

    /// Where `rest` leads inside the module at `module`.
    fn in_module(&self, module: &[String], rest: &[String], steps: usize) -> Vec<Settled> {
        let full = [module, rest].concat();
        if full.len() >= 2 && full[0] == "crate" && full[1] == "home_fs" {
            return vec![Settled::Own(full)];
        }
        let Some(name) = rest.first() else { return vec![Settled::Own(full)] };
        let Some(scope) = self.modules.scope(module) else {
            return vec![Settled::Lost(full.join("::"))];
        };
        let at = At { module: module.to_vec(), scopes: vec![scope], self_ty: None };
        // In a module path, a name that only some builds bind is in every build that compiles
        // the call: the build without it does not compile, so it is no fallthrough.
        let mut found = self.lookup(&at, name, steps);
        if found.len() > 1 {
            found.retain(|f| !matches!(f, Found::Nothing));
        }
        let mut out = Vec::new();
        for found in found {
            out.extend(match found {
                Found::Binding(Binding::Import(path) | Binding::Alias(path)) => {
                    self.resolve(&at, &[&path[..], &rest[1..]].concat(), steps)
                }
                Found::Binding(Binding::Module) => {
                    self.in_module(&[module, &rest[..1]].concat(), &rest[1..], steps)
                }
                Found::Binding(Binding::Item) => vec![Settled::Own(full.clone())],
                Found::Glob(glob) => self.resolve(&at, &[&glob[..], rest].concat(), steps),
                Found::Nothing => vec![Settled::Lost(full.join("::"))],
            });
        }
        out
    }

    /// What `name` means at `at`: the innermost scope that binds it by name or by a glob that
    /// has it, each binding of it there (a gated one also the meaning without it, from the
    /// scopes further out), and `Nothing` when no scope settles it.
    fn lookup(&self, at: &At, name: &str, steps: usize) -> Vec<Found> {
        let mut found = Vec::new();
        for scope in at.scopes.iter().rev() {
            let mut settled = false;
            for (binding, gated) in scope.names.get(name).into_iter().flatten() {
                found.push(Found::Binding(binding.clone()));
                settled |= !gated;
            }
            if !settled {
                for (glob, gated) in &scope.globs {
                    if self.glob_has(at, glob, name, steps, &mut HashSet::new()) {
                        found.push(Found::Glob(glob.clone()));
                        settled |= !gated;
                    }
                }
            }
            if settled {
                return found;
            }
            if scope.opaque {
                break;
            }
        }
        found.push(Found::Nothing);
        found
    }

    /// Whether `use glob::*;`, written at `at`, brings in `name`, followed through every glob it
    /// reaches (#42352 review F2: `pub use crate::a::*;` of a module that re-exports
    /// `std::fs::metadata as probe`). std::fs's public items and std::path's `Path` and `PathBuf`;
    /// a crate module's names and those of the globs in it; an enum's variants; another crate's,
    /// any name it reads by. A glob the lint cannot follow into this crate brings in any name, so
    /// a call through it is unresolved (fail closed). `seen`: the modules already asked, so a
    /// cycle of globs ends.
    fn glob_has(
        &self,
        at: &At,
        glob: &[String],
        name: &str,
        steps: usize,
        seen: &mut HashSet<Vec<String>>,
    ) -> bool {
        if let Some(has) = std_glob_has(glob, name) {
            return has;
        }
        let Some(steps) = steps.checked_sub(1) else { return true };
        self.resolve(at, glob, steps).into_iter().any(|settled| match settled {
            Settled::Std(path) => std_glob_has(&path, name).unwrap_or(false),
            Settled::Own(path) => self.module_has(&path, name, steps, seen),
            Settled::Outside(_) => READS.contains(&name),
            Settled::Lost(_) => true,
        })
    }

    /// Whether the module (or enum) at `module` has `name`: by name, or through its globs.
    fn module_has(
        &self,
        module: &[String],
        name: &str,
        steps: usize,
        seen: &mut HashSet<Vec<String>>,
    ) -> bool {
        if !seen.insert(module.to_vec()) {
            return false;
        }
        let Some(scope) = self.modules.scope(module) else {
            return self
                .modules
                .enum_variants(module)
                .is_none_or(|variants| variants.contains(name));
        };
        if scope.names.contains_key(name) {
            return true;
        }
        let at = At { module: module.to_vec(), scopes: vec![Rc::clone(&scope)], self_ty: None };
        scope.globs.iter().any(|(glob, _)| self.glob_has(&at, glob, name, steps, seen))
    }
}

/// Whether a glob of a std module brings in `name`; `None` for a path not in std.
fn std_glob_has(glob: &[String], name: &str) -> Option<bool> {
    let glob: Vec<&str> = glob.iter().map(String::as_str).collect();
    match glob.as_slice() {
        ["std", "fs"] => Some(STD_FS_ITEMS.contains(&name)),
        ["std", "path"] => Some(matches!(name, "Path" | "PathBuf")),
        ["std" | "core" | "alloc", ..] => Some(false),
        _ => None,
    }
}

/// Whether `path` is std's existence or metadata read by path: `std::fs::x` or
/// `std::path::Path::x` / `PathBuf::x`.
fn std_read_by_path(path: &[String]) -> bool {
    let Some((last, head)) = path.split_last() else { return false };
    if !(PATH_ONLY.contains(&last.as_str()) || last == "metadata") {
        return false;
    }
    let head: Vec<&str> = head.iter().map(String::as_str).collect();
    matches!(head.as_slice(), ["std", "fs"] | ["std", "path", "Path" | "PathBuf"])
}

/// What makes a call that leads to `settled` a row, if it is one: std's read by path, a
/// `home_fs::exists_nofollow`, a name it reads by that the lint cannot settle (another crate's,
/// or not bound here), or a path into this crate it cannot follow. A call is a row unless every
/// build of it settles on a known item that is not a read by path (fail closed).
fn offends(settled: &Settled) -> Option<String> {
    fn last(path: &[String]) -> &str {
        path.last().map(String::as_str).unwrap_or_default()
    }
    match settled {
        Settled::Std(path) if std_read_by_path(path) => Some(path.join("::")),
        Settled::Own(path) if last(path) == "exists_nofollow" => Some(path.join("::")),
        Settled::Outside(path) if READS.contains(&last(path)) => Some(path.join("::")),
        Settled::Lost(why) => Some(format!("unresolved: {why}")),
        _ => None,
    }
}

/// The attributes on `e`, whatever kind of expression it is.
fn expr_attrs(e: &syn::Expr) -> &[syn::Attribute] {
    use syn::Expr as E;
    match e {
        E::Array(x) => &x.attrs,
        E::Assign(x) => &x.attrs,
        E::Async(x) => &x.attrs,
        E::Await(x) => &x.attrs,
        E::Binary(x) => &x.attrs,
        E::Block(x) => &x.attrs,
        E::Break(x) => &x.attrs,
        E::Call(x) => &x.attrs,
        E::Cast(x) => &x.attrs,
        E::Closure(x) => &x.attrs,
        E::Const(x) => &x.attrs,
        E::Continue(x) => &x.attrs,
        E::Field(x) => &x.attrs,
        E::ForLoop(x) => &x.attrs,
        E::Group(x) => &x.attrs,
        E::If(x) => &x.attrs,
        E::Index(x) => &x.attrs,
        E::Infer(x) => &x.attrs,
        E::Let(x) => &x.attrs,
        E::Lit(x) => &x.attrs,
        E::Loop(x) => &x.attrs,
        E::Macro(x) => &x.attrs,
        E::Match(x) => &x.attrs,
        E::MethodCall(x) => &x.attrs,
        E::Paren(x) => &x.attrs,
        E::Path(x) => &x.attrs,
        E::Range(x) => &x.attrs,
        E::RawAddr(x) => &x.attrs,
        E::Reference(x) => &x.attrs,
        E::Repeat(x) => &x.attrs,
        E::Return(x) => &x.attrs,
        E::Struct(x) => &x.attrs,
        E::Try(x) => &x.attrs,
        E::TryBlock(x) => &x.attrs,
        E::Tuple(x) => &x.attrs,
        E::Unary(x) => &x.attrs,
        E::Unsafe(x) => &x.attrs,
        E::While(x) => &x.attrs,
        E::Yield(x) => &x.attrs,
        _ => &[],
    }
}

/// One function's checks: the names bound to a path in it, and the scopes its names resolve in.
struct Scan<'a> {
    rel: &'a str,
    paths: HashSet<String>,
    module: Vec<String>,
    scopes: Vec<Rc<Scope>>,
    self_ty: Option<Vec<String>>,
    resolver: Resolver<'a>,
    rows: Vec<String>,
}

impl Scan<'_> {
    /// Whether `expr` is a path by its shape.
    fn path_shaped(&self, expr: &syn::Expr) -> bool {
        match expr {
            syn::Expr::Reference(r) => self.path_shaped(&r.expr),
            syn::Expr::Paren(p) => self.path_shaped(&p.expr),
            syn::Expr::Unary(u) => self.path_shaped(&u.expr),
            syn::Expr::Path(p) => {
                p.path.get_ident().is_some_and(|i| self.paths.contains(&i.to_string()))
            }
            syn::Expr::MethodCall(m) => {
                let method = m.method.to_string();
                (PATH_MAKERS.contains(&method.as_str()) && method != "new" && method != "from")
                    || (matches!(method.as_str(), "clone" | "as_ref" | "to_owned")
                        && self.path_shaped(&m.receiver))
            }
            syn::Expr::Call(c) => {
                let syn::Expr::Path(f) = &*c.func else { return false };
                let segments: Vec<String> =
                    f.path.segments.iter().map(|s| s.ident.to_string()).collect();
                let last = segments.last().map(String::as_str).unwrap_or_default();
                let typed = segments.iter().any(|s| s == "Path" || s == "PathBuf");
                (typed && matches!(last, "new" | "from"))
                    || (!typed && PATH_MAKERS.contains(&last) && last != "new" && last != "from")
            }
            _ => false,
        }
    }

    fn row(&mut self, span: proc_macro2::Span, what: String) {
        self.rows.push(format!("{}:{} {what}", self.rel, span.start().line));
    }
}

impl<'ast> Visit<'ast> for Scan<'_> {
    fn visit_item_fn(&mut self, f: &'ast syn::ItemFn) {
        if !is_test_attr(&f.attrs) {
            // A fresh scope per function: a local's path shape stays in it.
            let outer = std::mem::take(&mut self.paths);
            syn::visit::visit_item_fn(self, f);
            self.paths = outer;
        }
    }
    fn visit_impl_item_fn(&mut self, f: &'ast syn::ImplItemFn) {
        if !is_test_attr(&f.attrs) {
            let outer = std::mem::take(&mut self.paths);
            syn::visit::visit_impl_item_fn(self, f);
            self.paths = outer;
        }
    }
    fn visit_item_mod(&mut self, m: &'ast syn::ItemMod) {
        if !is_test_attr(&m.attrs) {
            let items = m.content.as_ref().map_or(&[][..], |(_, items)| &items[..]);
            self.scopes.push(Rc::new(Scope::of(items.iter(), true)));
            self.module.push(m.ident.to_string());
            syn::visit::visit_item_mod(self, m);
            self.module.pop();
            self.scopes.pop();
        }
    }
    fn visit_block(&mut self, b: &'ast syn::Block) {
        let items = b.stmts.iter().filter_map(|s| match s {
            syn::Stmt::Item(item) => Some(item),
            _ => None,
        });
        self.scopes.push(Rc::new(Scope::of(items, false)));
        syn::visit::visit_block(self, b);
        self.scopes.pop();
    }
    fn visit_item_impl(&mut self, i: &'ast syn::ItemImpl) {
        if !is_test_attr(&i.attrs) {
            let outer = std::mem::replace(&mut self.self_ty, type_path(&i.self_ty));
            syn::visit::visit_item_impl(self, i);
            self.self_ty = outer;
        }
    }
    fn visit_item_trait(&mut self, t: &'ast syn::ItemTrait) {
        if !is_test_attr(&t.attrs) {
            let outer = self.self_ty.take();
            syn::visit::visit_item_trait(self, t);
            self.self_ty = outer;
        }
    }
    fn visit_stmt(&mut self, s: &'ast syn::Stmt) {
        let attrs = match s {
            syn::Stmt::Local(l) => &l.attrs[..],
            syn::Stmt::Macro(m) => &m.attrs[..],
            _ => &[][..],
        };
        if !is_test_attr(attrs) {
            syn::visit::visit_stmt(self, s);
        }
    }
    fn visit_expr(&mut self, e: &'ast syn::Expr) {
        // Test-only code of any kind (`#[cfg(test)] if .. { .. }` too) is left out.
        if !is_test_attr(expr_attrs(e)) {
            syn::visit::visit_expr(self, e);
        }
    }
    fn visit_macro(&mut self, m: &'ast syn::Macro) {
        use syn::punctuated::Punctuated;
        if let Ok(args) =
            m.parse_body_with(Punctuated::<syn::Expr, syn::Token![,]>::parse_terminated)
        {
            for arg in &args {
                self.visit_expr(arg);
            }
        }
        syn::visit::visit_macro(self, m);
    }
    fn visit_fn_arg(&mut self, arg: &'ast syn::FnArg) {
        if let syn::FnArg::Typed(t) = arg
            && let syn::Pat::Ident(i) = &*t.pat
            && names_a_path(&t.ty)
        {
            self.paths.insert(i.ident.to_string());
        }
        syn::visit::visit_fn_arg(self, arg);
    }
    fn visit_local(&mut self, l: &'ast syn::Local) {
        let ident = match &l.pat {
            syn::Pat::Ident(i) => Some(&i.ident),
            syn::Pat::Type(t) => match &*t.pat {
                syn::Pat::Ident(i) => {
                    if names_a_path(&t.ty) {
                        self.paths.insert(i.ident.to_string());
                    }
                    Some(&i.ident)
                }
                _ => None,
            },
            _ => None,
        };
        if let (Some(ident), Some(init)) = (ident, &l.init)
            && self.path_shaped(&init.expr)
        {
            self.paths.insert(ident.to_string());
        }
        syn::visit::visit_local(self, l);
    }
    fn visit_expr_call(&mut self, c: &'ast syn::ExprCall) {
        if let syn::Expr::Path(f) = &*c.func {
            let mut segments: Vec<String> =
                f.path.segments.iter().map(|s| s.ident.to_string()).collect();
            let mut written = segments.join("::");
            // `<T>::f`: `T`'s `f`, `T` followed like any path (#42352 review F1's class).
            if let Some(q) = &f.qself
                && q.position == 0
                && let Some(ty) = type_path(&q.ty)
            {
                written = format!("<{}>::{written}", ty.join("::"));
                segments = [ty, segments].concat();
            }
            // Judged by where the path leads in every build: `metadata(p)` after
            // `use std::fs::metadata;` is std's, after a local `fn metadata` it is not, and one
            // the resolver cannot settle is a row (fail closed).
            let at = At {
                module: self.module.clone(),
                scopes: self.scopes.clone(),
                self_ty: self.self_ty.clone(),
            };
            let settled = self.resolver.resolve(&at, &segments, STEPS);
            if let Some(shown) = settled.iter().find_map(offends) {
                let what = if shown.starts_with("unresolved: ")
                    || segments.len() == 1
                    || matches!(segments.first().map(String::as_str), Some("self" | "super"))
                {
                    format!("{written}(..) ({shown})")
                } else {
                    format!("{written}(..)")
                };
                self.row(c.span(), what);
            }
        }
        syn::visit::visit_expr_call(self, c);
    }
    fn visit_expr_method_call(&mut self, m: &'ast syn::ExprMethodCall) {
        let method = m.method.to_string();
        if m.args.is_empty() {
            if PATH_ONLY.contains(&method.as_str()) {
                self.row(m.span(), format!(".{method}()"));
            } else if SHARED.contains(&method.as_str()) && self.path_shaped(&m.receiver) {
                self.row(m.span(), format!(".{method}() on a path"));
            }
        }
        syn::visit::visit_expr_method_call(self, m);
    }
}

/// The rows of one file, the root module of a crate of just that file.
fn rows_in(rel: &str, file: &syn::File) -> Vec<String> {
    let modules = Modules::of_files([("crate".to_string(), file.clone())]);
    rows_in_module(rel, &["crate".into()], file, &modules)
}

/// The rows of one file, the module at `module` among `modules`: a `self::`, `super::` or
/// `crate::` path in it resolves through the modules it names, in this file or another.
fn rows_in_module(
    rel: &str,
    module: &[String],
    file: &syn::File,
    modules: &Modules,
) -> Vec<String> {
    let mut rows = Vec::new();
    let root = Rc::new(Scope::of(file.items.iter(), true));
    for item in &file.items {
        let mut scan = Scan {
            rel,
            paths: HashSet::new(),
            module: module.to_vec(),
            scopes: vec![Rc::clone(&root)],
            self_ty: None,
            resolver: Resolver { modules },
            rows: Vec::new(),
        };
        scan.visit_item(item);
        rows.append(&mut scan.rows);
    }
    rows
}

#[test]
fn nothing_in_the_store_checks_a_file_by_path() {
    let sources = store_sources();
    assert!(
        sources.iter().any(|(rel, ..)| rel == "src/store/cold.rs")
            && sources.iter().any(|(rel, ..)| rel == "src/store/journal_store/meta.rs"),
        "the lint reads the store's modules: {:?}",
        sources.iter().map(|(rel, ..)| rel).collect::<Vec<_>>()
    );
    assert!(
        !sources.iter().any(|(rel, ..)| rel.ends_with("_tests.rs")),
        "a test module is left out"
    );
    let modules = Modules::crate_on_disk();
    let rows: Vec<String> = sources
        .iter()
        .flat_map(|(rel, module, file)| rows_in_module(rel, module, file, &modules))
        .collect();
    assert!(
        rows.is_empty(),
        "{} existence or metadata check(s) by path in the store: read each in the held home \
         through `home_fs::try_exists_nofollow` or `home_fs::symlink_metadata` (#41721 review \
         F1):\n  {}",
        rows.len(),
        rows.join("\n  ")
    );
}

/// The lint itself, on a small file: each shape is a row, the held-home forms and a `File`'s or
/// `Metadata`'s own reads are none, a Windows-only arm is read, a test is not.
#[test]
fn the_lint_finds_each_shape_of_a_check_by_path() {
    let fixture = r#"
        use std::path::{Path, PathBuf};
        impl LocalStore {
            fn a(&self, id: &str) -> bool {
                crate::home_fs::exists_nofollow(self.cold_path(id))
            }
            fn b(&self, id: &str) -> bool {
                std::fs::symlink_metadata(self.cold_path(id)).is_ok()
            }
            fn c(&self, id: &str) -> bool {
                let archive = self.dir(id).join("cold.zst");
                archive.exists()
            }
            fn d(path: &Path) -> bool {
                path.is_file()
            }
            fn e(&self, id: &str) -> u64 {
                self.cold_path(id).metadata().map_or(0, |m| m.len())
            }
            #[cfg(windows)]
            fn f(&self, id: &str) -> bool {
                fs::metadata(self.cold_path(id)).is_ok()
            }
            fn g(&self, id: &str) -> bool {
                Path::exists(&self.cold_path(id))
            }
            fn h(pass: &Path) -> anyhow::Result<()> {
                anyhow::ensure!(!pass.exists(), "{} is there", pass.display());
                Ok(())
            }
            fn held(&self, id: &str) -> std::io::Result<bool> {
                let file = std::fs::File::open("x")?;
                let meta = file.metadata()?;
                let _ = meta.is_file() && meta.file_type().is_dir();
                let _ = crate::home_fs::symlink_metadata(self.cold_path(id))?;
                crate::home_fs::try_exists_nofollow(self.cold_path(id))
            }
            #[cfg(test)]
            fn in_a_test(&self, id: &str) -> bool {
                std::fs::symlink_metadata(self.cold_path(id)).is_ok()
            }
        }
        #[cfg(all(test, unix))]
        mod tests {
            fn t(p: &std::path::Path) -> bool { p.exists() }
        }
    "#;
    let file = syn::parse_file(fixture).unwrap();
    let rows: Vec<String> = rows_in("x.rs", &file)
        .into_iter()
        .map(|row| row.split_once(' ').map(|(_, what)| what.to_string()).unwrap_or(row))
        .collect();
    assert_eq!(
        rows,
        [
            "crate::home_fs::exists_nofollow(..)",
            "std::fs::symlink_metadata(..)",
            ".exists()",
            ".is_file() on a path",
            ".metadata() on a path",
            "fs::metadata(..)",
            "Path::exists(..)",
            ".exists()",
        ],
    );
}

/// The lint judges a call by the path its `use` imports resolve it to, per module (#41915 review
/// F2): a std function imported by name, under an alias, in a group, by a glob or in a block is a
/// row, as is `fs::` through `use std::fs;`. A function of the same name that is not std's (a
/// local fn, an import from this crate, an `fs` that is another module, a name an inner module
/// does not inherit) and the held-home forms are not.
#[test]
fn the_lint_resolves_imported_fs_functions() {
    let fixture = r#"
        mod store {
            pub mod disk {
                pub struct Probe;
                pub fn exists(_: &Path) -> bool { true }
                pub fn metadata(_: &Path) -> Option<u64> { None }
            }
        }
        mod direct {
            use std::fs::symlink_metadata;
            fn a(p: &Path) -> bool { symlink_metadata(p).is_ok() }
        }
        mod aliased {
            use std::fs::symlink_metadata as sm;
            fn a(p: &Path) -> bool { sm(p).is_ok() }
        }
        mod grouped {
            use std::{fs::{self, metadata}, path::Path};
            fn a(p: &Path) -> bool { metadata(p).is_ok() }
            fn b(p: &Path) -> bool { fs::symlink_metadata(p).is_ok() }
            fn c(p: &Path) -> bool { Path::exists(p) }
        }
        mod module_import {
            use std::fs;
            fn a(p: &Path) -> bool { fs::metadata(p).is_ok() }
        }
        mod globbed {
            use std::fs::*;
            fn a(p: &Path) -> bool { exists(p).unwrap_or(false) }
        }
        mod in_a_block {
            fn a(p: &Path) -> bool {
                use std::fs::metadata as m;
                m(p).is_ok()
            }
        }
        mod local_fn {
            fn metadata(_: &Path) -> Option<u64> { None }
            fn a(p: &Path) -> bool { metadata(p).is_some() }
        }
        mod local_import {
            use crate::store::disk::{exists, metadata as meta};
            fn a(p: &Path) -> bool { exists(p) && meta(p).is_some() }
        }
        mod local_fs {
            use crate::store::disk as fs;
            fn a(p: &Path) -> bool { fs::metadata(p).is_some() }
        }
        mod glob_shadowed {
            use std::fs::*;
            fn exists(_: &Path) -> bool { true }
            fn a(p: &Path) -> bool { exists(p) }
        }
        mod not_inherited {
            use std::fs::metadata;
            mod inner {
                fn metadata(_: &Path) -> bool { true }
                fn a(p: &Path) -> bool { metadata(p) }
            }
        }
        mod held {
            use crate::home_fs::{self as hfs, symlink_metadata};
            fn a(p: &Path) -> bool { symlink_metadata(p).is_ok() && hfs::metadata(p).is_ok() }
        }
        mod test_only_fn {
            use std::fs::*;
            #[cfg(test)]
            fn metadata(_: &Path) -> Option<u64> { None }
            fn a(p: &Path) -> bool { metadata(p).is_ok() }
        }
        mod platform_fn {
            use std::fs::*;
            #[cfg(windows)]
            fn exists(_: &Path) -> bool { true }
            fn a(p: &Path) -> bool { exists(p).unwrap_or(false) }
        }
        mod platform_mod {
            #[cfg(target_os = "macos")]
            mod fs {
                pub fn metadata(_: &Path) -> Option<u64> { None }
            }
            fn a(p: &Path) -> bool { fs::metadata(p).is_ok() }
        }
        mod platform_import {
            #[cfg(windows)]
            use crate::store::disk as fs;
            fn a(p: &Path) -> bool { fs::metadata(p).is_ok() }
        }
        mod platform_std_import {
            #[cfg(unix)]
            use std::fs::symlink_metadata;
            fn a(p: &Path) -> bool { symlink_metadata(p).is_ok() }
        }
    "#;
    let file = syn::parse_file(fixture).unwrap();
    let rows: Vec<String> = rows_in("x.rs", &file)
        .into_iter()
        .map(|row| row.split_once(' ').map(|(_, what)| what.to_string()).unwrap_or(row))
        .collect();
    assert_eq!(
        rows,
        [
            "symlink_metadata(..) (std::fs::symlink_metadata)",
            "sm(..) (std::fs::symlink_metadata)",
            "metadata(..) (std::fs::metadata)",
            "fs::symlink_metadata(..)",
            "Path::exists(..)",
            "fs::metadata(..)",
            "exists(..) (std::fs::exists)",
            "m(..) (std::fs::metadata)",
            "metadata(..) (std::fs::metadata)",
            "exists(..) (std::fs::exists)",
            "fs::metadata(..)",
            "fs::metadata(..)",
            "symlink_metadata(..) (std::fs::symlink_metadata)",
        ],
    );
}

/// `self::` and `super::` resolve through the module's own imports (the parent module's for
/// `super`), and a glob of `std::fs` claims only the names std::fs exports: any other name is
/// looked up in the scopes around it (#41970 review F1, F2).
#[test]
fn the_lint_resolves_self_super_and_std_fs_glob_names() {
    let fixture = r#"
        mod store {
            pub mod disk {
                pub struct Probe;
                pub fn exists(_: &Path) -> bool { true }
                pub fn metadata(_: &Path) -> Option<u64> { None }
            }
        }
        mod through_self {
            use std::fs::symlink_metadata;
            fn a(p: &Path) -> bool { self::symlink_metadata(p).is_ok() }
        }
        mod parent {
            use std::fs::metadata;
            mod child {
                fn a(p: &Path) -> bool { super::metadata(p).is_ok() }
            }
        }
        mod glob_in_a_block {
            use std::path::Path;
            fn a(p: &Path) -> bool {
                use std::fs::*;
                Path::exists(p)
            }
        }
        mod self_local {
            fn metadata(_: &Path) -> bool { true }
            fn a(p: &Path) -> bool {
                use std::fs::metadata;
                self::metadata(p)
            }
        }
        mod glob_falls_through {
            use crate::store::disk::Probe;
            fn a(p: &Path) -> bool {
                use std::fs::*;
                Probe::exists(p) && Probe::metadata(p).is_some()
            }
        }
    "#;
    let file = syn::parse_file(fixture).unwrap();
    let rows: Vec<String> = rows_in("x.rs", &file)
        .into_iter()
        .map(|row| row.split_once(' ').map(|(_, what)| what.to_string()).unwrap_or(row))
        .collect();
    assert_eq!(
        rows,
        [
            "self::symlink_metadata(..) (std::fs::symlink_metadata)",
            "super::metadata(..) (std::fs::metadata)",
            "Path::exists(..)",
        ],
    );
}

/// A `self::`/`super::` path an alias names resolves on (`use self::symlink_metadata as sm;`),
/// and a file-backed child module's `super::` sees the module that declares it: one class, "a
/// `self::`/`super::` resolution stops early" (#42003 review). A parent's `metadata` that is a
/// local fn is not std's.
#[test]
fn the_lint_resolves_self_super_through_aliases() {
    let fixture = r#"
        mod self_alias {
            use std::fs::symlink_metadata;
            use self::symlink_metadata as sm;
            fn a(p: &Path) -> bool { sm(p).is_ok() }
        }
        mod super_alias {
            use std::fs::metadata;
            mod child {
                use super::metadata as m;
                fn a(p: &Path) -> bool { m(p).is_ok() }
            }
        }
        mod self_alias_local {
            fn metadata(_: &Path) -> bool { true }
            use self::metadata as m;
            fn a(p: &Path) -> bool { m(p) }
        }
    "#;
    let file = syn::parse_file(fixture).unwrap();
    let rows: Vec<String> = rows_in("x.rs", &file)
        .into_iter()
        .map(|row| row.split_once(' ').map(|(_, what)| what.to_string()).unwrap_or(row))
        .collect();
    assert_eq!(rows, ["sm(..) (std::fs::symlink_metadata)", "m(..) (std::fs::metadata)"],);
}

/// A `#[cfg(test)]` or `#[test]` fn (or module) is not built outside tests, so it shadows no
/// import there: `metadata(p)` and a child's `super::metadata(p)` under `use std::fs::metadata;`
/// are std's although a test-only `fn metadata` sits beside the import (#42026 review). A plain
/// local `fn metadata` still shadows.
#[test]
fn the_lint_ignores_test_only_items_that_shadow_an_import() {
    let fixture = r#"
        mod own_cfg_test {
            use std::fs::metadata;
            #[cfg(test)]
            fn metadata(_: &Path) -> bool { true }
            fn a(p: &Path) -> bool { metadata(p).is_ok() }
        }
        mod own_test_attr {
            use std::fs::metadata;
            #[test]
            fn metadata() {}
            fn a(p: &Path) -> bool { metadata(p).is_ok() }
        }
        mod parent_cfg_test {
            use std::fs::metadata;
            #[cfg(test)]
            fn metadata(_: &Path) -> bool { true }
            mod child {
                fn a(p: &Path) -> bool { super::metadata(p).is_ok() }
            }
        }
        mod parent_test_mod {
            use std::fs::metadata;
            #[cfg(test)]
            mod metadata {}
            mod child {
                fn a(p: &Path) -> bool { super::metadata(p).is_ok() }
            }
        }
        mod own_local {
            fn metadata(_: &Path) -> bool { true }
            fn a(p: &Path) -> bool { metadata(p) }
        }
        mod parent_local {
            fn metadata(_: &Path) -> bool { true }
            mod child {
                fn a(p: &Path) -> bool { super::metadata(p) }
            }
        }
    "#;
    let file = syn::parse_file(fixture).unwrap();
    let rows: Vec<String> = rows_in("x.rs", &file)
        .into_iter()
        .map(|row| row.split_once(' ').map(|(_, what)| what.to_string()).unwrap_or(row))
        .collect();
    assert_eq!(
        rows,
        [
            "metadata(..) (std::fs::metadata)",
            "metadata(..) (std::fs::metadata)",
            "super::metadata(..) (std::fs::metadata)",
            "super::metadata(..) (std::fs::metadata)",
        ],
    );
}

/// The rows of the tree rooted at `src/store.rs` under `src`, sorted.
fn tree_rows(src: &Path) -> Vec<String> {
    let mut out = Vec::new();
    load(&src.join("store.rs"), &src.join("store"), vec!["crate".into()], &mut out);
    let modules = Modules::on_disk(&src.join("store.rs"), &src.join("store"));
    let mut rows: Vec<String> = out
        .iter()
        .flat_map(|(path, module, file)| {
            let rel = path.strip_prefix(src).unwrap_or(path).to_string_lossy().replace('\\', "/");
            rows_in_module(&rel, module, file, &modules)
        })
        .collect();
    rows.sort();
    rows
}

/// A file-backed child module (`mod child;`) is read inside the modules that declare it: its
/// `super::metadata(p)` resolves through the parent's `use std::fs::metadata;`, through an inline
/// parent too, and `super::super::` two modules out. A parent whose `metadata` is a local fn
/// gives no row.
#[test]
fn the_lint_reads_a_file_backed_child_in_its_parent() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path();
    let files = [
        (
            "store.rs",
            "use std::fs::metadata;\nmod child;\nmod shadowed;\n\
             mod inline {\n    use std::fs::symlink_metadata;\n    mod deep;\n}\n",
        ),
        ("store/child.rs", "fn a(p: &Path) -> bool {\n    super::metadata(p).is_ok()\n}\n"),
        ("store/shadowed.rs", "fn metadata(_: &Path) -> bool { true }\nmod grandchild;\n"),
        (
            "store/shadowed/grandchild.rs",
            "fn a(p: &Path) -> bool {\n    super::metadata(p)\n}\n\
             fn b(p: &Path) -> bool {\n    super::super::metadata(p).is_ok()\n}\n",
        ),
        (
            "store/inline/deep.rs",
            "fn a(p: &Path) -> bool {\n    super::symlink_metadata(p).is_ok()\n}\n",
        ),
    ];
    for (rel, text) in files {
        let path = src.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, text).unwrap();
    }
    assert_eq!(
        tree_rows(src),
        [
            "store/child.rs:2 super::metadata(..) (std::fs::metadata)",
            "store/inline/deep.rs:2 super::symlink_metadata(..) (std::fs::symlink_metadata)",
            "store/shadowed/grandchild.rs:5 super::super::metadata(..) (std::fs::metadata)",
        ],
    );
}

/// The rows of `fixture`, read as a crate's root module, without their locations.
fn rows_of(fixture: &str) -> Vec<String> {
    rows_in("x.rs", &syn::parse_file(fixture).unwrap())
        .into_iter()
        .map(|row| row.split_once(' ').map(|(_, what)| what.to_string()).unwrap_or(row))
        .collect()
}

/// #42003 review F1: "STD_FS_ITEMS lacks std::fs::try_exists (glob import misses it)".
#[test]
fn the_lint_reads_try_exists_through_a_std_fs_glob() {
    let rows = rows_of(
        r#"
        mod globbed {
            use std::fs::*;
            fn a(p: &Path) -> bool { try_exists(p).unwrap_or(false) }
        }
        "#,
    );
    assert_eq!(rows, ["try_exists(..) (std::fs::try_exists)"]);
}

/// #42139 review F1: an import under a `#[cfg(..)]` that aliases a std::fs function is followed
/// when it is written through another import (`fs::`) or `self::`, not only when it starts with
/// `std`.
#[test]
fn the_lint_follows_a_cfg_gated_import_alias() {
    let rows = rows_of(
        r#"
        mod gated_alias {
            use std::fs;
            #[cfg(unix)]
            use fs::symlink_metadata as sm;
            #[cfg(windows)]
            use self::fs::metadata as m;
            fn a(p: &Path) -> bool { sm(p).is_ok() }
            fn b(p: &Path) -> bool { m(p).is_ok() }
        }
        "#,
    );
    assert_eq!(rows, ["sm(..) (std::fs::symlink_metadata)", "m(..) (std::fs::metadata)"]);
}

/// The resolver fails closed (#42003 review: "a call the resolver can't settle to a known
/// non-fs path is reported, not skipped"): a `super::` past the crate root, another crate's
/// `metadata`, a module the lint cannot read, an import into one and a loop of imports are rows,
/// and a `crate::` path is followed to what it names. A call it settles on a known item that is
/// not a read (the prelude's, another crate's other functions, a local fn, `Self::`,
/// `crate::home_fs`, a fn or module defined once per `cfg` arm) is none, and so is test-only
/// code (`#[cfg(test)] if ..`).
#[test]
fn the_lint_reports_a_call_it_cannot_resolve() {
    let rows = rows_of(
        r#"
        mod gone;
        mod inner {
            pub use std::fs::metadata;
        }
        fn a(p: &Path) -> bool { super::metadata(p).is_ok() }
        fn b(p: &Path) -> bool { tokio::fs::metadata(p).is_ok() }
        fn c(p: &Path) -> bool { gone::probe(p) }
        fn d(p: &Path) -> bool {
            use self::gone::probe as q;
            q(p)
        }
        fn e(p: &Path) -> bool { crate::inner::metadata(p).is_ok() }
        mod cycle {
            use self::b as a;
            use self::a as b;
            fn c(p: &Path) -> bool { a(p) }
        }
        struct Store;
        impl Store {
            fn known(&self, p: &Path) -> bool {
                let _ = Vec::<u8>::new();
                let _ = String::from("x");
                let _ = serde_json::from_str::<u8>("1");
                let _ = crate::home_fs::metadata(p);
                Self::helper(p) && helper(p) && Some(1).is_some()
            }
            fn helper(_: &Path) -> bool { true }
        }
        fn helper(_: &Path) -> bool { true }
        mod arms {
            #[cfg(unix)]
            pub fn probe(_: &Path) -> bool { true }
            #[cfg(not(unix))]
            pub fn probe(_: &Path) -> bool { false }
        }
        #[cfg(windows)]
        mod win {
            pub fn open(_: &Path) -> bool { true }
        }
        fn per_platform(p: &Path) -> bool { crate::arms::probe(p) && crate::win::open(p) }
        fn test_only(p: &Path) {
            #[cfg(test)]
            if p.is_absolute() {
                gone::probe(p);
            }
        }
        "#,
    );
    assert_eq!(
        rows,
        [
            "super::metadata(..) (unresolved: super::metadata)",
            "tokio::fs::metadata(..)",
            "gone::probe(..) (unresolved: crate::gone::probe)",
            "q(..) (unresolved: crate::gone::probe)",
            "crate::inner::metadata(..)",
            "a(..) (unresolved: a loop of imports)",
        ],
    );
}

/// #42352 review F1: "a type alias is treated as the item's own path. With `type Path =
/// std::path::Path`, `Path::exists(p)` settles as Own and gives no row." The class: a name bound
/// to another path (a type alias, a `const` or `static` bound to a function, `Self` in an impl, a
/// `<T>::` qualified path) is followed to what it names, never settled as this crate's own item.
/// An alias of this crate's own type gives no row.
#[test]
fn the_lint_follows_type_aliases_and_other_names_for_a_path() {
    let rows = rows_of(
        r#"
        mod aliased {
            type Path = std::path::Path;
            fn a(p: &Path) -> bool { Path::exists(p) }
        }
        mod relative {
            use std::path;
            pub type P = path::PathBuf;
        }
        mod through_import {
            use crate::relative::P;
            fn a(p: &std::path::Path) -> bool { P::try_exists(p).unwrap_or(false) }
        }
        mod fn_const {
            const PROBE: fn(&std::path::Path) -> std::io::Result<std::fs::Metadata> =
                std::fs::metadata;
            fn a(p: &std::path::Path) -> bool { PROBE(p).is_ok() }
        }
        mod self_type {
            trait Probe { fn probe(&self) -> bool; }
            impl Probe for std::path::Path {
                fn probe(&self) -> bool { Self::exists(self) }
            }
        }
        mod qualified {
            type P = std::path::Path;
            fn a(p: &std::path::Path) -> bool { <P>::exists(p) }
        }
        mod own_alias {
            struct LocalStore;
            impl LocalStore { fn exists(_: &str) -> bool { true } }
            type Store = LocalStore;
            fn a() -> bool { Store::exists("x") && Self_::ok() }
            struct Self_;
            impl Self_ { fn ok() -> bool { Self::exists_here() } fn exists_here() -> bool { true } }
        }
        "#,
    );
    assert_eq!(
        rows,
        [
            "Path::exists(..)",
            "P::try_exists(..)",
            "PROBE(..) (std::fs::metadata)",
            "Self::exists(..)",
            "<P>::exists(..)",
        ],
    );
}

/// #42352 review F2: "nested glob re-exports aren't followed. `mod a { pub use std::fs::metadata
/// as probe; } mod b { pub use crate::a::*; } use b::*;` then `probe(p)` gives no row." A glob is
/// followed through the globs it reaches, an `as` rename too; a glob into a module the lint
/// cannot read brings in any name, so the call is unresolved; a cycle of globs ends.
#[test]
fn the_lint_follows_nested_glob_re_exports() {
    let rows = rows_of(
        r#"
        mod a { pub use std::fs::metadata as probe; }
        mod b { pub use crate::a::*; }
        use b::*;
        fn review(p: &Path) -> bool { probe(p).is_ok() }
        mod c { pub use super::b::*; }
        mod deeper {
            use crate::c::*;
            fn f(p: &Path) -> bool { probe(p).is_ok() }
        }
        mod gone;
        mod into_unreadable {
            use crate::gone::*;
            fn f(p: &Path) -> bool { look(p) }
        }
        mod x { pub use super::y::*; }
        mod y { pub use super::x::*; }
        mod cycle {
            use crate::x::*;
            fn f(p: &Path) -> Result<bool, ()> { Ok(p.is_absolute()) }
        }
        "#,
    );
    assert_eq!(
        rows,
        [
            "probe(..) (std::fs::metadata)",
            "probe(..) (std::fs::metadata)",
            "look(..) (unresolved: crate::gone::look)",
        ],
    );
}

/// A read bound to a local is still a read: `let f = std::fs::metadata; f(p)`, and `let f =
/// metadata;` after `use std::fs::metadata;`, are rows at the binding (a read as a value) and at
/// the call. A local bound later does not hide an earlier call of the import it shadows, and
/// locals named like a read (`exists`, `metadata`, a closure's `try_exists`) are none.
#[test]
fn the_lint_follows_a_read_bound_to_a_local() {
    let rows = rows_of(
        r#"
        mod direct {
            fn a(p: &Path) -> bool {
                let f = std::fs::metadata;
                f(p).is_ok()
            }
        }
        mod imported {
            use std::fs::metadata;
            fn a(p: &Path) -> bool {
                let f = metadata;
                f(p).is_ok()
            }
        }
        mod shadowed_later {
            use std::fs::metadata;
            fn a(p: &Path) -> bool {
                let ok = metadata(p).is_ok();
                let metadata = 1;
                ok && metadata == 1
            }
        }
        mod plain_locals {
            fn a(exists: bool, p: &Path) -> bool {
                let metadata = p.as_os_str().len();
                let f = |try_exists: bool| try_exists;
                exists && metadata > 0 && f(exists)
            }
        }
        "#,
    );
    assert_eq!(
        rows,
        [
            "std::fs::metadata as a value",
            "f(..) (std::fs::metadata)",
            "metadata as a value (std::fs::metadata)",
            "f(..) (std::fs::metadata)",
            "metadata(..) (std::fs::metadata)",
        ],
    );
}

/// A read passed as a value is a read: `.map(std::fs::metadata)`, `.and_then(fs::symlink_metadata)`,
/// `.map(Path::exists)`, a struct field set to `fs::metadata`, `home_fs::exists_nofollow` as an
/// argument. Functions that are not reads (`Result::is_ok`, `Path::to_path_buf`, a local fn) and a
/// parameter called as a function are none.
#[test]
fn the_lint_reports_a_read_passed_as_a_value() {
    let rows = rows_of(
        r#"
        use std::fs;
        use std::path::Path;
        struct Probe { read: fn(&Path) -> std::io::Result<fs::Metadata> }
        fn a(paths: Vec<&Path>) -> usize {
            paths.into_iter().map(std::fs::metadata).filter(Result::is_ok).count()
        }
        fn b(p: Option<&Path>) -> bool {
            p.map(Path::exists).unwrap_or(false)
        }
        fn c(p: &Path) -> bool {
            Some(p).ok_or(()).and_then(fs::symlink_metadata).is_ok()
        }
        fn d() -> Probe { Probe { read: fs::metadata } }
        fn e(p: &Path) -> bool { run(crate::home_fs::exists_nofollow, p) }
        fn run(f: fn(&Path) -> bool, p: &Path) -> bool { f(p) }
        fn known(p: &Path) -> bool { Some(p).map(Path::to_path_buf).is_some() && run(own, p) }
        fn own(_: &Path) -> bool { true }
        "#,
    );
    assert_eq!(
        rows,
        [
            "std::fs::metadata as a value",
            "Path::exists as a value",
            "fs::symlink_metadata as a value",
            "fs::metadata as a value",
            "crate::home_fs::exists_nofollow as a value",
        ],
    );
}

/// Every operation in `home_fs.rs` whose Unix arm goes through the held home's descriptor
/// (`unix::...`) checks the held home in its other arms too (`held` or `held_read`): no
/// `home_fs` function that the store's reads go through is path-based on any platform (#41721
/// review F1: `exists_nofollow`'s Windows arm read by path with no check).
#[test]
fn every_home_fs_operation_checks_the_held_home_on_every_platform() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/home_fs.rs");
    let file = syn::parse_file(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let red = unheld_arms(&file);
    assert!(
        red.is_empty(),
        "{} function(s) in home_fs.rs reach the held home on Unix and go by path elsewhere with \
         no check of the home: call `held` (a write) or `held_read` (a read) in that arm:\n  {}",
        red.len(),
        red.join("\n  ")
    );
}

/// The functions of `file` with a `#[cfg(unix)]` arm that calls `unix::...` and another `cfg`
/// arm that calls neither `held` nor `held_read`.
fn unheld_arms(file: &syn::File) -> Vec<String> {
    #[derive(Default)]
    struct Calls(HashSet<String>);
    impl<'ast> Visit<'ast> for Calls {
        fn visit_expr_call(&mut self, c: &'ast syn::ExprCall) {
            if let syn::Expr::Path(f) = &*c.func {
                let segments: Vec<String> =
                    f.path.segments.iter().map(|s| s.ident.to_string()).collect();
                self.0.insert(segments.join("::"));
            }
            syn::visit::visit_expr_call(self, c);
        }
    }
    fn cfg_text(attrs: &[syn::Attribute]) -> Option<String> {
        attrs.iter().find(|a| a.path().is_ident("cfg")).and_then(|a| match &a.meta {
            syn::Meta::List(list) => {
                Some(list.tokens.to_string().chars().filter(|c| !c.is_whitespace()).collect())
            }
            _ => None,
        })
    }
    let mut red = Vec::new();
    for item in &file.items {
        let syn::Item::Fn(f) = item else { continue };
        let mut arms: Vec<(String, Calls)> = Vec::new();
        for stmt in &f.block.stmts {
            let syn::Stmt::Expr(syn::Expr::Block(block), _) = stmt else { continue };
            let Some(cfg) = cfg_text(&block.attrs) else { continue };
            let mut calls = Calls::default();
            calls.visit_expr_block(block);
            arms.push((cfg, calls));
        }
        let via_descriptor = arms
            .iter()
            .any(|(cfg, calls)| cfg == "unix" && calls.0.iter().any(|c| c.starts_with("unix::")));
        if !via_descriptor {
            continue;
        }
        for (cfg, calls) in &arms {
            if cfg != "unix" && !calls.0.contains("held") && !calls.0.contains("held_read") {
                red.push(format!("{} (#[cfg({cfg})])", f.sig.ident));
            }
        }
    }
    red
}

/// The home_fs lint on a small file: an arm by path with no check is a row.
#[test]
fn the_home_fs_lint_finds_an_arm_by_path() {
    let fixture = r#"
        pub(crate) fn exists_nofollow(path: &Path) -> bool {
            #[cfg(unix)]
            { unix::exists_nofollow(path) }
            #[cfg(not(unix))]
            { std::fs::symlink_metadata(path).is_ok() }
        }
        pub(crate) fn remove_file(path: &Path) -> io::Result<()> {
            #[cfg(unix)]
            { unix::remove(path, 0) }
            #[cfg(not(unix))]
            { held(path)?; std::fs::remove_file(path) }
        }
        pub(crate) fn symlink_metadata(path: &Path) -> io::Result<Metadata> {
            #[cfg(unix)]
            { unix::symlink_metadata(path) }
            #[cfg(not(unix))]
            { held_read(path, || std::fs::symlink_metadata(path)) }
        }
        pub(crate) fn sync_dir(dir: &Path) -> io::Result<()> {
            #[cfg(unix)]
            { open(dir)?.sync_all() }
            #[cfg(not(unix))]
            { Ok(()) }
        }
    "#;
    let file = syn::parse_file(fixture).unwrap();
    assert_eq!(unheld_arms(&file), ["exists_nofollow (#[cfg(not(unix))])"]);
}
