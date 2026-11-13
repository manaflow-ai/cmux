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

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
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

/// `file` and the files of the modules it declares (not under a test `cfg`), recursively. `dir`:
/// where its `mod x;` finds `x.rs`.
fn load(file: &Path, dir: &Path, out: &mut Vec<(PathBuf, syn::File)>) {
    let text = std::fs::read_to_string(file).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
    let parsed = syn::parse_file(&text).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
    load_items(&parsed.items, file, dir, out);
    out.push((file.to_path_buf(), parsed));
}

fn load_items(items: &[syn::Item], file: &Path, dir: &Path, out: &mut Vec<(PathBuf, syn::File)>) {
    for item in items {
        let syn::Item::Mod(m) = item else { continue };
        if is_test_attr(&m.attrs) {
            continue;
        }
        let name = m.ident.to_string();
        if let Some((_, inline)) = &m.content {
            load_items(inline, file, &dir.join(&name), out);
            continue;
        }
        let (child, child_dir) = match path_attr(&m.attrs) {
            Some(rel) => {
                let base = file.parent().unwrap_or(Path::new(""));
                (base.join(&rel), base.join(&rel).with_extension(""))
            }
            None if dir.join(format!("{name}.rs")).exists() => {
                (dir.join(format!("{name}.rs")), dir.join(&name))
            }
            None => (dir.join(&name).join("mod.rs"), dir.join(&name)),
        };
        load(&child, &child_dir, out);
    }
}

/// The store's sources: `src/store.rs` and its modules.
fn store_sources() -> Vec<(String, syn::File)> {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let src = crate_dir.join("src");
    let mut out = Vec::new();
    load(&src.join("store.rs"), &src.join("store"), &mut out);
    out.into_iter()
        .map(|(path, file)| {
            let rel = path.strip_prefix(&crate_dir).unwrap_or(&path);
            (rel.to_string_lossy().replace('\\', "/"), file)
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

/// The names one module or block brings in: `use` imports (name to full path), glob imports
/// (their paths), and the functions and modules it defines (which shadow a glob). A module is
/// `opaque`: it inherits nothing from the module around it; a block sees its enclosing scopes.
///
/// A definition or an import under a `#[cfg(..)]` (`test`, `windows`, `target_os = ..`, any
/// other) may be absent from the build that runs a production call, so it shadows nothing
/// there (#41970 review F1: a `#[cfg(test)] fn metadata` hid a production `metadata(path)`). A
/// gated import still binds its name when it imports std's, whose call is a row in the build
/// that has it.
#[derive(Clone, Default)]
struct Scope {
    opaque: bool,
    imports: HashMap<String, Vec<String>>,
    globs: Vec<Vec<String>>,
    defined: HashSet<String>,
}

impl Scope {
    fn of<'a>(items: impl IntoIterator<Item = &'a syn::Item>, opaque: bool) -> Self {
        let mut scope = Scope { opaque, ..Scope::default() };
        for item in items {
            match item {
                syn::Item::Use(u) if is_test_attr(&u.attrs) => {}
                syn::Item::Use(u) if is_cfg_gated(&u.attrs) => {
                    let mut gated = Scope::default();
                    gated.import(&mut Vec::new(), &u.tree);
                    let std = |path: &Vec<String>| path.first().is_some_and(|s| s == "std");
                    scope.imports.extend(gated.imports.into_iter().filter(|(_, p)| std(p)));
                    scope.globs.extend(gated.globs.into_iter().filter(std));
                }
                syn::Item::Use(u) => scope.import(&mut Vec::new(), &u.tree),
                syn::Item::Fn(f) if !is_cfg_gated(&f.attrs) => {
                    scope.defined.insert(f.sig.ident.to_string());
                }
                syn::Item::Mod(m) if !is_cfg_gated(&m.attrs) => {
                    scope.defined.insert(m.ident.to_string());
                }
                _ => {}
            }
        }
        scope
    }

    fn import(&mut self, prefix: &mut Vec<String>, tree: &syn::UseTree) {
        match tree {
            syn::UseTree::Path(p) => {
                prefix.push(p.ident.to_string());
                self.import(prefix, &p.tree);
                prefix.pop();
            }
            syn::UseTree::Name(n) if n.ident == "self" => {
                if let Some(last) = prefix.last() {
                    self.imports.insert(last.clone(), prefix.clone());
                }
            }
            syn::UseTree::Name(n) => {
                let mut full = prefix.clone();
                full.push(n.ident.to_string());
                self.imports.insert(n.ident.to_string(), full);
            }
            syn::UseTree::Rename(r) => {
                let mut full = prefix.clone();
                if r.ident != "self" {
                    full.push(r.ident.to_string());
                }
                self.imports.insert(r.rename.to_string(), full);
            }
            syn::UseTree::Glob(_) => self.globs.push(prefix.clone()),
            syn::UseTree::Group(g) => {
                for tree in &g.items {
                    self.import(prefix, tree);
                }
            }
        }
    }
}

/// The public items of `std::fs`: the only names a `use std::fs::*;` brings in (#41970 review
/// F2). Any other name under such a glob is looked up in the scopes around it.
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

/// What a name means in `scopes` (innermost last): `Some(path)` an import's full path, `None`
/// a name defined here or not imported. A glob (`use std::fs::*;`) counts only for a name
/// std::fs exports that nothing in its scope defines or imports by name.
fn lookup(scopes: &[Scope], name: &str) -> Option<Vec<String>> {
    for scope in scopes.iter().rev() {
        if scope.defined.contains(name) {
            return None;
        }
        if let Some(full) = scope.imports.get(name) {
            return Some(full.clone());
        }
        if STD_FS_ITEMS.contains(&name) && scope.globs.iter().any(|glob| is_std_fs(glob)) {
            return Some(vec!["std".into(), "fs".into(), name.to_string()]);
        }
        if scope.opaque {
            break;
        }
    }
    None
}

/// The scopes a path's leading `self::` / `super::` names start from, and how many leading
/// names they are: `self` is the innermost module (not a block), each `super` one module out
/// (#41970 review F1). `None`: no leading `self`/`super`, or more `super`s than modules here.
fn module_scopes<'s>(scopes: &'s [Scope], segments: &[String]) -> Option<(&'s [Scope], usize)> {
    let lead = segments.iter().take_while(|s| *s == "self" || *s == "super").count();
    if lead == 0 || segments.iter().skip(1).take(lead - 1).any(|s| s == "self") {
        return None;
    }
    let outward = segments.iter().take(lead).filter(|s| *s == "super").count();
    let modules: Vec<usize> = (0..scopes.len()).rev().filter(|&i| scopes[i].opaque).collect();
    let module = *modules.get(outward)?;
    Some((&scopes[..=module], lead))
}

/// `segments` with its first name replaced by what it imports, again while that is an import
/// of another local name (`use std::fs; use fs::metadata;`), a few steps at most.
fn resolve(scopes: &[Scope], segments: &[String]) -> Vec<String> {
    resolve_within(scopes, segments, 4)
}

/// [`resolve`], following a `self::`/`super::` import (`use self::x as y;`) at most `steps`
/// times.
fn resolve_within(scopes: &[Scope], segments: &[String], steps: usize) -> Vec<String> {
    let mut path = segments.to_vec();
    // `self::x` / `super::x`: `x` as that module's imports name it; a name it defines (or one
    // it does not name) is not std's and is left as written.
    if let Some((module, lead)) = module_scopes(scopes, &path) {
        let Some(name) = path.get(lead) else { return path };
        let Some(full) = lookup(module, name) else { return path };
        path.splice(..=lead, full);
        return match steps.checked_sub(1) {
            Some(left) => resolve_within(module, &path, left),
            None => path,
        };
    }
    for _ in 0..4 {
        let Some(first) = path.first() else { break };
        if matches!(first.as_str(), "std" | "core" | "crate" | "self" | "super") {
            break;
        }
        let Some(full) = lookup(scopes, first) else { break };
        if full.first() == Some(first) && full.len() == 1 {
            break;
        }
        path.splice(0..1, full);
    }
    path
}

fn is_std_fs(path: &[String]) -> bool {
    path.len() == 2 && path[0] == "std" && path[1] == "fs"
}

/// Whether a call of `resolved` (its function's path, imports resolved) is std's existence or
/// metadata read by path: `std::fs::x`, `std::path::Path::x` / `PathBuf::x`, or an `fs::x`,
/// `Path::x` or `PathBuf::x` whose first name no import here names (an import the lint cannot
/// see, which in this crate is std's).
fn std_read_by_path(resolved: &[String]) -> bool {
    let Some((last, head)) = resolved.split_last() else { return false };
    if !(PATH_ONLY.contains(&last.as_str()) || last == "metadata") {
        return false;
    }
    let head: Vec<&str> = head.iter().map(String::as_str).collect();
    matches!(
        head.as_slice(),
        ["std", "fs"]
            | ["std", "path", "Path" | "PathBuf"]
            | ["fs"]
            | ["Path" | "PathBuf"]
            | ["path", "Path" | "PathBuf"]
    )
}

/// One function's checks: the names bound to a path in it, and the scopes its names resolve in.
struct Scan<'a> {
    rel: &'a str,
    paths: HashSet<String>,
    scopes: Vec<Scope>,
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
            self.scopes.push(Scope::of(items.iter(), true));
            syn::visit::visit_item_mod(self, m);
            self.scopes.pop();
        }
    }
    fn visit_block(&mut self, b: &'ast syn::Block) {
        let items = b.stmts.iter().filter_map(|s| match s {
            syn::Stmt::Item(item) => Some(item),
            _ => None,
        });
        self.scopes.push(Scope::of(items, false));
        syn::visit::visit_block(self, b);
        self.scopes.pop();
    }
    fn visit_item_impl(&mut self, i: &'ast syn::ItemImpl) {
        if !is_test_attr(&i.attrs) {
            syn::visit::visit_item_impl(self, i);
        }
    }
    fn visit_stmt(&mut self, s: &'ast syn::Stmt) {
        if let syn::Stmt::Local(l) = s
            && is_test_attr(&l.attrs)
        {
            return;
        }
        syn::visit::visit_stmt(self, s);
    }
    fn visit_expr(&mut self, e: &'ast syn::Expr) {
        let attrs = match e {
            syn::Expr::Block(b) => &b.attrs[..],
            syn::Expr::Call(c) => &c.attrs[..],
            syn::Expr::MethodCall(m) => &m.attrs[..],
            _ => &[][..],
        };
        if !is_test_attr(attrs) {
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
            let segments: Vec<String> =
                f.path.segments.iter().map(|s| s.ident.to_string()).collect();
            // Judged by the path the imports resolve it to: `metadata(p)` after
            // `use std::fs::metadata;` is std's, after a local `fn metadata` it is not.
            let resolved = resolve(&self.scopes, &segments);
            let last = resolved.last().cloned().unwrap_or_default();
            let through_home_fs = resolved.iter().any(|s| s == "home_fs");
            let by_path = !through_home_fs && std_read_by_path(&resolved);
            if last == "exists_nofollow" || by_path {
                let written = segments.join("::");
                let what = if segments.len() == 1
                    || matches!(segments.first().map(String::as_str), Some("self" | "super"))
                {
                    format!("{written}(..) ({})", resolved.join("::"))
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

/// The rows of one file.
fn rows_in(rel: &str, file: &syn::File) -> Vec<String> {
    let mut rows = Vec::new();
    let root = Scope::of(file.items.iter(), true);
    for item in &file.items {
        let mut scan =
            Scan { rel, paths: HashSet::new(), scopes: vec![root.clone()], rows: Vec::new() };
        scan.visit_item(item);
        rows.append(&mut scan.rows);
    }
    rows
}

#[test]
fn nothing_in_the_store_checks_a_file_by_path() {
    let sources = store_sources();
    assert!(
        sources.iter().any(|(rel, _)| rel == "src/store/cold.rs")
            && sources.iter().any(|(rel, _)| rel == "src/store/journal_store/meta.rs"),
        "the lint reads the store's modules: {:?}",
        sources.iter().map(|(rel, _)| rel).collect::<Vec<_>>()
    );
    assert!(
        !sources.iter().any(|(rel, _)| rel.ends_with("_tests.rs")),
        "a test module is left out"
    );
    let rows: Vec<String> = sources.iter().flat_map(|(rel, file)| rows_in(rel, file)).collect();
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
