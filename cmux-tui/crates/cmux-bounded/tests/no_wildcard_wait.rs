//! Every `impl BoundedMachine` writes its `wait` as an exhaustive `match` with no catch-all arm,
//! so a new state that declares no bound does not compile.
//!
//! The scan parses every `.rs` file under `cmux-tui/crates` that names `BoundedMachine` (with
//! `syn`, never a hand tokenizer) and, in each `fn wait` of an `impl BoundedMachine for ..`,
//! fails on a `_` arm, a lowercase binding arm (`other =>`), or a `wait` with no `match` at all.
//! There is no allowlist: give the state its own arm.

use std::path::{Path, PathBuf};

use syn::visit::Visit;

fn catch_all(pat: &syn::Pat) -> bool {
    match pat {
        syn::Pat::Wild(_) => true,
        // `other =>`; an uppercase name is a unit variant or a constant.
        syn::Pat::Ident(ident) => {
            ident.subpat.is_none()
                && ident
                    .ident
                    .to_string()
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_lowercase() || c == '_')
        }
        syn::Pat::Or(or) => or.cases.iter().any(catch_all),
        syn::Pat::Paren(paren) => catch_all(&paren.pat),
        syn::Pat::Reference(reference) => catch_all(&reference.pat),
        _ => false, // wait-scan: a pattern kind, not a wait arm
    }
}

#[derive(Default)]
struct WaitBody {
    matches: usize,
    catch_alls: Vec<usize>,
}

impl<'ast> Visit<'ast> for WaitBody {
    fn visit_expr_match(&mut self, node: &'ast syn::ExprMatch) {
        self.matches += 1;
        for arm in &node.arms {
            if catch_all(&arm.pat) {
                self.catch_alls.push(syn::spanned::Spanned::span(&arm.pat).start().line);
            }
        }
        syn::visit::visit_expr_match(self, node);
    }
}

/// The findings in one file, as `line: what`, and how many `wait`s it read.
fn findings(source: &str) -> (usize, Vec<String>) {
    let Ok(file) = syn::parse_file(source) else { return (0, Vec::new()) };
    let mut read = 0;
    let mut bad = Vec::new();
    let mut items: Vec<&syn::Item> = file.items.iter().collect();
    while let Some(item) = items.pop() {
        let impl_ = match item {
            syn::Item::Impl(impl_) => impl_,
            syn::Item::Mod(module) => {
                items.extend(module.content.iter().flat_map(|(_, items)| items));
                continue;
            }
            syn::Item::Fn(function) => {
                // Machines declared inside a test function.
                items.extend(function.block.stmts.iter().filter_map(|stmt| match stmt {
                    syn::Stmt::Item(item) => Some(item),
                    _ => None, // wait-scan: statements that are not items
                }));
                continue;
            }
            _ => continue, // wait-scan: other items
        };
        let Some((_, trait_path, _)) = &impl_.trait_ else { continue };
        if trait_path.segments.last().is_none_or(|s| s.ident != "BoundedMachine") {
            continue;
        }
        for member in &impl_.items {
            let syn::ImplItem::Fn(function) = member else { continue };
            if function.sig.ident != "wait" {
                continue;
            }
            read += 1;
            let line = syn::spanned::Spanned::span(&function.sig).start().line;
            let mut body = WaitBody::default();
            body.visit_block(&function.block);
            if body.matches == 0 && !delegates(&function.block) {
                bad.push(format!("{line}: `wait` has no match on its state"));
            }
            for arm in body.catch_alls {
                bad.push(format!("{arm}: a catch-all arm in `wait`; give each state its own arm"));
            }
        }
    }
    (read, bad)
}

/// A `wait` that is one call to another machine's `wait` (a test wrapper) is that one's match.
fn delegates(block: &syn::Block) -> bool {
    let [syn::Stmt::Expr(syn::Expr::Call(call), None)] = block.stmts.as_slice() else {
        return false;
    };
    let syn::Expr::Path(path) = &*call.func else { return false };
    path.path.segments.last().is_some_and(|s| s.ident == "wait")
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if entry.file_name() != "target" {
                rust_files(&path, out);
            }
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn every_bounded_machine_declares_each_states_wait() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = Vec::new();
    rust_files(crates, &mut files);
    let this = Path::new(file!()).file_name().unwrap();
    let (mut read, mut bad) = (0, Vec::new());
    for file in files {
        if file.file_name() == Some(this) {
            continue;
        }
        let Ok(source) = std::fs::read_to_string(&file) else { continue };
        if !source.contains("BoundedMachine") {
            continue;
        }
        let (n, found) = findings(&source);
        read += n;
        bad.extend(found.into_iter().map(|f| format!("{}:{f}", file.display())));
    }
    assert!(read > 0, "no `impl BoundedMachine` found: the scan read nothing");
    assert!(bad.is_empty(), "a wait that can hide a new state:\n{}", bad.join("\n"));
}

#[test]
fn the_scan_finds_a_catch_all_and_passes_an_exhaustive_match() {
    let bad = r#"
        impl BoundedMachine for M {
            fn wait(s: &S) -> Wait<E> {
                match s {
                    S::A => Wait::Settled,
                    _ => Wait::Settled,
                }
            }
        }
        impl cmux_bounded::BoundedMachine for N {
            fn wait(s: &S) -> Wait<E> { match s { S::A => Wait::Settled, other => Wait::Settled } }
        }
        impl BoundedMachine for O {
            fn wait(s: &S) -> Wait<E> { Wait::Settled }
        }
    "#;
    let (read, found) = findings(bad);
    assert_eq!((read, found.len()), (3, 3), "{found:?}");

    let good = r#"
        impl BoundedMachine for M {
            fn wait(s: &S) -> Wait<E> {
                match s {
                    S::A | S::B { .. } => Wait::Settled,
                    S::C(n) if *n > 3 => Wait::OnPerson { action: "Retry" },
                    S::C(_) => Wait::bounded(D, E::T, "x"),
                    None => Wait::Settled,
                }
            }
        }
        impl Other for M { fn wait(s: &S) { match s { _ => {} } } }
    "#;
    let (read, found) = findings(good);
    assert_eq!((read, found), (1, Vec::<String>::new()));
}
