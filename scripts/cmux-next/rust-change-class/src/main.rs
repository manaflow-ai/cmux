//! Sorts a Rust change by what it needs compiled, from a syntax diff of every changed file.
//!
//!     rust-change-class --repo DIR BASE HEAD
//!
//! Prints one JSON object: the change's bucket (the heaviest of its files), and each file's
//! bucket, crate and reasons. The buckets, lightest first:
//!
//!   no-compile  nothing a compiler reads changed: comments, docs with no doctest, a file in a crate
//!               that no Rust source names
//!   test-only   only code the shipped binaries never contain: `#[cfg(test)]` items and modules,
//!               `#[test]` functions, doctests, `tests/`, `benches/` and `examples/`. The tests still
//!               compile and run; the product build does not change
//!   body-only   function bodies only, with every signature, type, trait, impl header, macro,
//!               attribute, `unsafe` block and FFI function as it was, and imports. An incremental
//!               `cargo check` proves the type and borrow side; the tests run on the patched build
//!   full        anything else: Cargo.toml, Cargo.lock, build.rs, the toolchain, a proc-macro crate,
//!               a new or deleted module file, a changed or added signature, type, trait, impl,
//!               const or static, macro_rules, extern block, crate attribute (`#![feature]`),
//!               `unsafe`, FFI (`extern "C"`, `#[no_mangle]`), or a file that does not parse
//!
//! Comments are not tokens, so they never reach the comparison. Doc comments are `#[doc]`
//! attributes: they are stripped before comparing and looked at on their own (a changed doc with a
//! code fence is a changed doctest). Everything is compared as token streams, never as text, so
//! formatting and comments cannot make a change look heavier or lighter than it is.
use quote::ToTokens;
use std::collections::{BTreeMap, BTreeSet};
use std::process::Command;
use syn::visit_mut::VisitMut;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Bucket {
    NoCompile,
    TestOnly,
    BodyOnly,
    Full,
}

impl Bucket {
    fn name(self) -> &'static str {
        match self {
            Bucket::NoCompile => "no-compile",
            Bucket::TestOnly => "test-only",
            Bucket::BodyOnly => "body-only",
            Bucket::Full => "full",
        }
    }
}

struct Verdict {
    bucket: Bucket,
    reasons: BTreeSet<String>,
}

impl Verdict {
    fn new() -> Self {
        Verdict { bucket: Bucket::NoCompile, reasons: BTreeSet::new() }
    }
    fn add(&mut self, bucket: Bucket, why: impl Into<String>) {
        self.bucket = self.bucket.max(bucket);
        self.reasons.insert(format!("{}: {}", bucket.name(), why.into()));
    }
}

// --- git -----------------------------------------------------------------------------------------

fn git(repo: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(repo).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn show(repo: &str, rev: &str, path: &str) -> Option<String> {
    git(repo, &["show", &format!("{rev}:{path}")])
}

// --- items ---------------------------------------------------------------------------------------

struct Entry {
    kind: &'static str,
    /// Everything about the item, docs stripped.
    tokens: String,
    /// For functions: attributes, visibility and signature (the part a caller sees).
    sig: Option<String>,
    in_test: bool,
    unsafe_or_ffi: Option<&'static str>,
}

fn tokens<T: ToTokens>(t: &T) -> String {
    t.to_token_stream().to_string()
}

fn attrs_tokens(attrs: &[syn::Attribute]) -> String {
    attrs.iter().map(tokens).collect::<Vec<_>>().join(" ")
}

fn is_test_attr(attr: &syn::Attribute) -> bool {
    let path = attr.path();
    if path.segments.last().is_some_and(|s| s.ident == "test" || s.ident == "bench") {
        return true;
    }
    if path.is_ident("cfg") {
        // cfg(test), and cfg(all(test, ...)): code only a test build has.
        let text = tokens(&attr.meta);
        return text.contains("( test") || text.contains("(test") || text.starts_with("cfg (test");
    }
    false
}

fn cfg_key(attrs: &[syn::Attribute]) -> String {
    attrs.iter().filter(|a| a.path().is_ident("cfg")).map(tokens).collect::<Vec<_>>().join(" ")
}

fn ffi_attr(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|a| {
        let text = tokens(a);
        text.contains("no_mangle") || text.contains("export_name") || text.contains("link_section")
    })
}

fn body_unsafe(text: &str) -> bool {
    text.split_whitespace().any(|t| t == "unsafe")
}

fn fn_entry(
    attrs: &[syn::Attribute],
    vis: Option<&syn::Visibility>,
    sig: &syn::Signature,
    whole: String,
    body: Option<String>,
    in_test: bool,
) -> Entry {
    let sig_text = format!("{} {} {}", attrs_tokens(attrs), vis.map(tokens).unwrap_or_default(), tokens(sig));
    let unsafe_or_ffi = if sig.unsafety.is_some() || body.as_deref().is_some_and(body_unsafe) {
        Some("unsafe")
    } else if sig.abi.is_some() || ffi_attr(attrs) {
        Some("FFI")
    } else {
        None
    };
    Entry { kind: "fn", tokens: whole, sig: Some(sig_text), in_test: in_test || attrs.iter().any(is_test_attr), unsafe_or_ffi }
}

fn plain(kind: &'static str, whole: String, attrs: &[syn::Attribute], in_test: bool) -> Entry {
    Entry { kind, tokens: whole, sig: None, in_test: in_test || attrs.iter().any(is_test_attr), unsafe_or_ffi: None }
}

fn collect(items: &[syn::Item], prefix: &str, in_test: bool, out: &mut BTreeMap<String, Entry>) {
    for item in items {
        match item {
            syn::Item::Fn(f) => {
                let key = format!("{prefix}fn {} {}", f.sig.ident, cfg_key(&f.attrs));
                out.insert(key, fn_entry(&f.attrs, Some(&f.vis), &f.sig, tokens(f), Some(tokens(&f.block)), in_test));
            }
            syn::Item::Mod(m) => {
                let test = in_test || m.attrs.iter().any(is_test_attr);
                let header = format!("{} {} mod {}", attrs_tokens(&m.attrs), tokens(&m.vis), m.ident);
                out.insert(format!("{prefix}mod {} {}", m.ident, cfg_key(&m.attrs)), plain("mod", header, &m.attrs, in_test));
                if let Some((_, inner)) = &m.content {
                    collect(inner, &format!("{prefix}{}::", m.ident), test, out);
                }
            }
            syn::Item::Impl(i) => {
                let test = in_test || i.attrs.iter().any(is_test_attr);
                let trait_part = i.trait_.as_ref().map(|(bang, path, _)| format!("{}{} for", if bang.is_some() { "!" } else { "" }, tokens(path)));
                let head = format!(
                    "{} {} impl {} {} {} {}",
                    attrs_tokens(&i.attrs),
                    i.unsafety.map(|_| "unsafe").unwrap_or(""),
                    tokens(&i.generics),
                    trait_part.unwrap_or_default(),
                    tokens(&i.self_ty),
                    i.generics.where_clause.as_ref().map(tokens).unwrap_or_default()
                );
                let ikey = format!("{prefix}impl {} {} {}", i.trait_.as_ref().map(|t| tokens(&t.1)).unwrap_or_default(), tokens(&i.self_ty), cfg_key(&i.attrs));
                let mut header = plain("impl header", head, &i.attrs, in_test);
                if i.unsafety.is_some() {
                    header.unsafe_or_ffi = Some("unsafe");
                }
                out.insert(ikey.clone(), header);
                for member in &i.items {
                    match member {
                        syn::ImplItem::Fn(f) => {
                            let key = format!("{ikey}::fn {} {}", f.sig.ident, cfg_key(&f.attrs));
                            out.insert(key, fn_entry(&f.attrs, Some(&f.vis), &f.sig, tokens(f), Some(tokens(&f.block)), test));
                        }
                        other => {
                            let key = format!("{ikey}::{}", tokens(other).split_whitespace().take(8).collect::<Vec<_>>().join(" "));
                            out.insert(key, plain("impl item", tokens(other), &[], test));
                        }
                    }
                }
            }
            syn::Item::Trait(t) => {
                let test = in_test || t.attrs.iter().any(is_test_attr);
                let mut head = t.clone();
                head.items.clear();
                let tkey = format!("{prefix}trait {} {}", t.ident, cfg_key(&t.attrs));
                out.insert(tkey.clone(), plain("trait", tokens(&head), &t.attrs, in_test));
                for member in &t.items {
                    match member {
                        syn::TraitItem::Fn(f) => {
                            let key = format!("{tkey}::fn {}", f.sig.ident);
                            out.insert(key, fn_entry(&f.attrs, None, &f.sig, tokens(f), f.default.as_ref().map(tokens), test));
                        }
                        other => {
                            out.insert(format!("{tkey}::{}", tokens(other)), plain("trait item", tokens(other), &[], test));
                        }
                    }
                }
            }
            syn::Item::Use(u) => {
                out.insert(format!("{prefix}use {}", tokens(u)), plain("use", tokens(u), &u.attrs, in_test));
            }
            other => {
                let (kind, attrs): (&'static str, &[syn::Attribute]) = match other {
                    syn::Item::Struct(s) => ("struct", &s.attrs),
                    syn::Item::Enum(e) => ("enum", &e.attrs),
                    syn::Item::Union(u) => ("union", &u.attrs),
                    syn::Item::Type(t) => ("type alias", &t.attrs),
                    syn::Item::Const(c) => ("const", &c.attrs),
                    syn::Item::Static(s) => ("static", &s.attrs),
                    syn::Item::Macro(m) => ("macro", &m.attrs),
                    syn::Item::ForeignMod(f) => ("extern block", &f.attrs),
                    syn::Item::ExternCrate(e) => ("extern crate", &e.attrs),
                    syn::Item::TraitAlias(t) => ("trait alias", &t.attrs),
                    _ => ("item", &[]),
                };
                let name = item_name(other);
                out.insert(format!("{prefix}{kind} {name} {}", cfg_key(attrs)), plain(kind, tokens(other), attrs, in_test));
            }
        }
    }
}

fn item_name(item: &syn::Item) -> String {
    match item {
        syn::Item::Struct(s) => s.ident.to_string(),
        syn::Item::Enum(e) => e.ident.to_string(),
        syn::Item::Union(u) => u.ident.to_string(),
        syn::Item::Type(t) => t.ident.to_string(),
        syn::Item::Const(c) => c.ident.to_string(),
        syn::Item::Static(s) => s.ident.to_string(),
        syn::Item::Macro(m) => m.ident.as_ref().map(|i| i.to_string()).unwrap_or_else(|| tokens(&m.mac.path)),
        syn::Item::TraitAlias(t) => t.ident.to_string(),
        other => tokens(other).chars().take(60).collect(),
    }
}

/// Removes `#[doc]` attributes everywhere, keeping their text for the doctest check.
struct StripDocs(Vec<String>);

impl StripDocs {
    fn strip(&mut self, attrs: &mut Vec<syn::Attribute>) {
        attrs.retain(|a| {
            if a.path().is_ident("doc") {
                self.0.push(tokens(a));
                false
            } else {
                true
            }
        });
    }
}

// syn's VisitMut has no hook for "any attribute list", so every node that owns attributes strips its own.
struct DocStripper(StripDocs);

macro_rules! strip_on {
    ($($method:ident: $ty:ty),* $(,)?) => {
        $(fn $method(&mut self, node: &mut $ty) {
            self.0.strip(&mut node.attrs);
            syn::visit_mut::$method(self, node);
        })*
    };
}

impl VisitMut for DocStripper {
    strip_on!(
        visit_file_mut: syn::File, visit_item_fn_mut: syn::ItemFn, visit_item_mod_mut: syn::ItemMod,
        visit_item_struct_mut: syn::ItemStruct, visit_item_enum_mut: syn::ItemEnum,
        visit_item_union_mut: syn::ItemUnion, visit_item_trait_mut: syn::ItemTrait,
        visit_item_impl_mut: syn::ItemImpl, visit_item_const_mut: syn::ItemConst,
        visit_item_static_mut: syn::ItemStatic, visit_item_type_mut: syn::ItemType,
        visit_item_macro_mut: syn::ItemMacro, visit_item_use_mut: syn::ItemUse,
        visit_item_foreign_mod_mut: syn::ItemForeignMod, visit_impl_item_fn_mut: syn::ImplItemFn,
        visit_impl_item_const_mut: syn::ImplItemConst, visit_impl_item_type_mut: syn::ImplItemType,
        visit_trait_item_fn_mut: syn::TraitItemFn, visit_trait_item_const_mut: syn::TraitItemConst,
        visit_trait_item_type_mut: syn::TraitItemType, visit_field_mut: syn::Field,
        visit_variant_mut: syn::Variant, visit_foreign_item_fn_mut: syn::ForeignItemFn,
        visit_foreign_item_static_mut: syn::ForeignItemStatic,
    );
}

fn stripped(source: &str) -> Result<(syn::File, Vec<String>), String> {
    let mut file = syn::parse_file(source).map_err(|e| e.to_string())?;
    let mut stripper = DocStripper(StripDocs(Vec::new()));
    stripper.visit_file_mut(&mut file);
    Ok((file, stripper.0 .0))
}

/// The doc lines inside code fences (a doctest), fences included. Each `///` line is its own
/// `#[doc]` attribute, so the fence is tracked across attributes.
fn fenced(docs: &[String]) -> Vec<String> {
    let mut inside = false;
    let mut out = Vec::new();
    for line in docs {
        let fence = line.contains("```");
        if inside || fence {
            out.push(line.clone());
        }
        if fence {
            inside = !inside;
        }
    }
    out
}

fn compare_rust(old: &str, new: &str, in_test_dir: bool, v: &mut Verdict) {
    let (old_file, old_docs) = match stripped(old) {
        Ok(x) => x,
        Err(e) => return v.add(Bucket::Full, format!("the base file does not parse ({e})")),
    };
    let (new_file, new_docs) = match stripped(new) {
        Ok(x) => x,
        Err(e) => return v.add(Bucket::Full, format!("does not parse ({e})")),
    };
    if old_docs != new_docs {
        if fenced(&old_docs) != fenced(&new_docs) {
            v.add(Bucket::TestOnly, "a doctest changed");
        } else {
            v.add(Bucket::NoCompile, "docs");
        }
    }
    if tokens(&old_file) == tokens(&new_file) {
        if old != new && old_docs == new_docs {
            v.add(Bucket::NoCompile, "comments or formatting");
        }
        return;
    }
    if in_test_dir {
        return v.add(Bucket::TestOnly, "integration test, bench or example code");
    }
    if attrs_tokens(&old_file.attrs) != attrs_tokens(&new_file.attrs) {
        v.add(Bucket::Full, "crate or module attributes (#![...])");
    }
    let (mut a, mut b) = (BTreeMap::new(), BTreeMap::new());
    collect(&old_file.items, "", false, &mut a);
    collect(&new_file.items, "", false, &mut b);
    let keys: BTreeSet<&String> = a.keys().chain(b.keys()).collect();
    for key in keys {
        let label = key.split_whitespace().collect::<Vec<_>>().join(" ");
        match (a.get(key), b.get(key)) {
            (Some(x), Some(y)) if x.tokens == y.tokens => {}
            (Some(x), Some(y)) => {
                if x.in_test || y.in_test {
                    v.add(Bucket::TestOnly, format!("test code: {label}"));
                } else if x.kind == "use" {
                    v.add(Bucket::BodyOnly, "imports");
                } else if x.kind == "fn" && x.sig == y.sig {
                    match x.unsafe_or_ffi.or(y.unsafe_or_ffi) {
                        Some(what) => v.add(Bucket::Full, format!("{what} function body: {label}")),
                        None => v.add(Bucket::BodyOnly, format!("fn body: {label}")),
                    }
                } else if x.kind == "fn" {
                    v.add(Bucket::Full, format!("signature: {label}"));
                } else {
                    v.add(Bucket::Full, format!("{} changed: {label}", x.kind));
                }
            }
            (Some(x), None) | (None, Some(x)) => {
                let verb = if a.contains_key(key) { "removed" } else { "added" };
                if x.in_test {
                    v.add(Bucket::TestOnly, format!("test code {verb}: {label}"));
                } else if x.kind == "use" {
                    v.add(Bucket::BodyOnly, "imports");
                } else {
                    v.add(Bucket::Full, format!("{} {verb}: {label}", x.kind));
                }
            }
            (None, None) => unreachable!(),
        }
    }
}

// --- files ---------------------------------------------------------------------------------------

const FULL_NAMES: &[&str] = &["Cargo.toml", "Cargo.lock", "build.rs", "rust-toolchain", "rust-toolchain.toml"];

struct Crates {
    /// crate directory ("" for the repo root) -> (package name, proc-macro)
    dirs: BTreeMap<String, (String, bool)>,
}

impl Crates {
    fn load(repo: &str, revs: &[&str]) -> Crates {
        let mut dirs = BTreeMap::new();
        for rev in revs {
            let listing = git(repo, &["ls-tree", "-r", "--name-only", rev]).unwrap_or_default();
            for path in listing.lines().filter(|p| *p == "Cargo.toml" || p.ends_with("/Cargo.toml")) {
                let dir = path.trim_end_matches("Cargo.toml").trim_end_matches('/').to_string();
                if dirs.contains_key(&dir) {
                    continue;
                }
                let text = show(repo, rev, path).unwrap_or_default();
                if !text.contains("[package]") {
                    continue;
                }
                let name = text
                    .lines()
                    .skip_while(|l| l.trim() != "[package]")
                    .find_map(|l| l.trim().strip_prefix("name").map(|r| r.trim_start_matches([' ', '=']).trim_matches('"').to_string()))
                    .unwrap_or_else(|| dir.clone());
                let proc_macro = text.contains("proc-macro = true") || text.contains("proc_macro = true");
                dirs.insert(dir, (name, proc_macro));
            }
        }
        Crates { dirs }
    }

    fn owner(&self, path: &str) -> Option<(&String, &(String, bool))> {
        self.dirs.iter().filter(|(dir, _)| dir.is_empty() || path.starts_with(&format!("{dir}/"))).max_by_key(|(dir, _)| dir.len())
    }
}

fn classify_file(repo: &str, base: &str, head: &str, status: char, path: &str, crates: &Crates) -> (Option<String>, Verdict) {
    let mut v = Verdict::new();
    let owner = crates.owner(path);
    let crate_name = owner.map(|(_, (name, _))| name.clone());
    let base_name = path.rsplit('/').next().unwrap_or(path);
    let rel = owner.map(|(dir, _)| path.strip_prefix(&format!("{dir}/")).unwrap_or(path)).unwrap_or(path);
    let test_dir = ["tests/", "benches/", "examples/"].iter().any(|d| rel.starts_with(d));
    if FULL_NAMES.contains(&base_name) || path.contains(".cargo/config") {
        v.add(Bucket::Full, format!("{base_name}: a build input"));
        return (crate_name, v);
    }
    if owner.is_some_and(|(_, (_, proc_macro))| *proc_macro) && !test_dir {
        v.add(Bucket::Full, "a proc-macro crate");
        return (crate_name, v);
    }
    if !path.ends_with(".rs") {
        // A non-Rust file: what reads it? include_str!/include_bytes! compile it in; anything
        // else (a fixture a test opens) is read at run time.
        let Some((dir, _)) = owner else {
            v.add(Bucket::NoCompile, "not in a crate");
            return (crate_name, v);
        };
        let hits = git(repo, &["grep", "-n", "-F", base_name, head, "--", &format!("{dir}/*.rs")]).unwrap_or_default();
        if hits.lines().any(|l| l.contains("include_str") || l.contains("include_bytes") || l.contains("include!")) {
            v.add(Bucket::BodyOnly, format!("{base_name} is compiled in (include_str!/include_bytes!)"));
        } else if hits.is_empty() {
            v.add(Bucket::NoCompile, format!("{base_name}: no Rust source names it"));
        } else {
            v.add(Bucket::NoCompile, format!("{base_name}: read at run time"));
        }
        return (crate_name, v);
    }
    match status {
        'A' | 'D' if test_dir => v.add(Bucket::TestOnly, "integration test, bench or example file"),
        'A' | 'D' => v.add(Bucket::Full, if status == 'A' { "a new module file" } else { "a deleted module file" }),
        _ => {
            let old = show(repo, base, path).unwrap_or_default();
            let new = show(repo, head, path).unwrap_or_default();
            compare_rust(&old, &new, test_dir, &mut v);
        }
    }
    (crate_name, v)
}

fn json_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (repo, rest) = match args.iter().position(|a| a == "--repo") {
        Some(i) => (args[i + 1].clone(), args.iter().enumerate().filter(|(j, _)| *j != i && *j != i + 1).map(|(_, a)| a.clone()).collect::<Vec<_>>()),
        None => (".".to_string(), args.clone()),
    };
    let [base, head] = rest.as_slice() else {
        eprintln!("usage: rust-change-class [--repo DIR] BASE HEAD");
        std::process::exit(2);
    };
    let Some(listing) = git(&repo, &["diff", "--name-status", "--no-renames", base, head]) else {
        eprintln!("rust-change-class: git diff {base} {head} failed");
        std::process::exit(2);
    };
    let crates = Crates::load(&repo, &[head, base]);
    let mut overall = Bucket::NoCompile;
    let mut files = Vec::new();
    let mut by_crate: BTreeMap<String, Bucket> = BTreeMap::new();
    for line in listing.lines() {
        let mut parts = line.split('\t');
        let (Some(st), Some(path)) = (parts.next(), parts.next()) else { continue };
        let in_rust = path.ends_with(".rs") || crates.owner(path).is_some_and(|(dir, _)| !dir.is_empty()) || FULL_NAMES.contains(&path.rsplit('/').next().unwrap_or(""));
        if !in_rust {
            continue;
        }
        let (krate, v) = classify_file(&repo, base, head, st.chars().next().unwrap_or('M'), path, &crates);
        overall = overall.max(v.bucket);
        if let Some(k) = &krate {
            let e = by_crate.entry(k.clone()).or_insert(Bucket::NoCompile);
            *e = (*e).max(v.bucket);
        }
        let reasons: Vec<String> = v.reasons.iter().map(|r| json_str(r)).collect();
        files.push(format!(
            "{{\"path\":{},\"crate\":{},\"bucket\":\"{}\",\"reasons\":[{}]}}",
            json_str(path),
            krate.as_deref().map(json_str).unwrap_or_else(|| "null".into()),
            v.bucket.name(),
            reasons.join(",")
        ));
    }
    let crates_json: Vec<String> = by_crate.iter().map(|(k, b)| format!("{}:\"{}\"", json_str(k), b.name())).collect();
    println!(
        "{{\"bucket\":\"{}\",\"rust_files\":{},\"crates\":{{{}}},\"files\":[{}]}}",
        if files.is_empty() { "none" } else { overall.name() },
        files.len(),
        crates_json.join(","),
        files.join(",")
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bucket(old: &str, new: &str) -> Bucket {
        let mut v = Verdict::new();
        compare_rust(old, new, false, &mut v);
        v.bucket
    }

    #[test]
    fn comments_and_formatting_need_no_compile() {
        assert_eq!(bucket("fn a() -> u8 { 1 }", "// hi\nfn a()   -> u8 {\n    1 // one\n}"), Bucket::NoCompile);
    }

    #[test]
    fn docs_need_no_compile_but_a_doctest_is_a_test() {
        assert_eq!(bucket("/// one\nfn a() {}", "/// two\nfn a() {}"), Bucket::NoCompile);
        assert_eq!(bucket("/// ```\n/// a();\n/// ```\nfn a() {}", "/// ```\n/// b();\n/// ```\nfn a() {}"), Bucket::TestOnly);
    }

    #[test]
    fn a_function_body_is_body_only() {
        assert_eq!(bucket("fn a() -> u8 { 1 }", "fn a() -> u8 { 2 }"), Bucket::BodyOnly);
        assert_eq!(bucket("impl S { pub fn a(&self) -> u8 { 1 } }", "impl S { pub fn a(&self) -> u8 { 2 } }"), Bucket::BodyOnly);
        assert_eq!(bucket("use a::b;\nfn a() {}", "use a::{b, c};\nfn a() { c() }"), Bucket::BodyOnly);
    }

    #[test]
    fn signatures_types_and_new_items_need_a_full_build() {
        assert_eq!(bucket("fn a() -> u8 { 1 }", "fn a() -> u16 { 1 }"), Bucket::Full);
        assert_eq!(bucket("struct S { a: u8 }", "struct S { a: u8, b: u8 }"), Bucket::Full);
        assert_eq!(bucket("fn a() {}", "fn a() {}\nfn b() {}"), Bucket::Full);
        assert_eq!(bucket("#[repr(C)] struct S(u8);", "#[repr(u8)] struct S(u8);"), Bucket::Full);
        assert_eq!(bucket("fn a() {}", "#![feature(x)]\nfn a() {}"), Bucket::Full);
        assert_eq!(bucket("const N: usize = 1;", "const N: usize = 2;"), Bucket::Full);
    }

    #[test]
    fn unsafe_and_ffi_bodies_need_a_full_build() {
        assert_eq!(bucket("fn a() { unsafe { x() } }", "fn a() { unsafe { y() } }"), Bucket::Full);
        assert_eq!(bucket("extern \"C\" fn a() { x() }", "extern \"C\" fn a() { y() }"), Bucket::Full);
        assert_eq!(bucket("#[no_mangle] fn a() { x() }", "#[no_mangle] fn a() { y() }"), Bucket::Full);
    }

    #[test]
    fn cfg_test_code_is_test_only() {
        let old = "fn a() {}\n#[cfg(test)]\nmod tests { #[test] fn t() { assert!(true) } }";
        let new = "fn a() {}\n#[cfg(test)]\nmod tests { #[test] fn t() { assert!(1 == 1) }\n#[test] fn u() {} }";
        assert_eq!(bucket(old, new), Bucket::TestOnly);
    }

    #[test]
    fn a_file_that_does_not_parse_needs_a_full_build() {
        assert_eq!(bucket("fn a() {}", "fn a( {}"), Bucket::Full);
    }
}
