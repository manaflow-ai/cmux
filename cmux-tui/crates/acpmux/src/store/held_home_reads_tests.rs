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
//! call of a function named `metadata`, `symlink_metadata`, `exists` or `try_exists`
//! (`std::fs::`, `Path::`, by any import) outside `home_fs`; a method `.exists()`,
//! `.try_exists()` or `.symlink_metadata()` (only a path has these); and `.metadata()`, `.is_file()`, `.is_dir()` or `.is_symlink()` on a
//! receiver that is a path by its shape (a `File`, a `Metadata` and a `FileType` have these too):
//! a path maker's value (`join`, `parent`, `path()`, `cold_path`, `Path::new`, ...), or a local
//! or parameter bound to one or typed as a path. A macro's comma-separated arguments are read
//! too (`ensure!(!path.exists(), ..)`).

use std::collections::HashSet;
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

fn last_segment(path: &syn::Path) -> String {
    path.segments.last().map(|s| s.ident.to_string()).unwrap_or_default()
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

/// One function's checks: the names bound to a path in it.
struct Scan<'a> {
    rel: &'a str,
    paths: HashSet<String>,
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
            syn::visit::visit_item_mod(self, m);
        }
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
            let last = last_segment(&f.path);
            let through_home_fs = segments.iter().any(|s| s == "home_fs");
            let by_path = !through_home_fs
                && (PATH_ONLY.contains(&last.as_str()) || last == "metadata")
                && segments.len() > 1;
            if last == "exists_nofollow" || by_path {
                self.row(c.span(), format!("{}(..)", segments.join("::")));
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
    for item in &file.items {
        let mut scan = Scan { rel, paths: HashSet::new(), rows: Vec::new() };
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
