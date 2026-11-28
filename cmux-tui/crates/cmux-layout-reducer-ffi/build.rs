//! Writes `$OUT_DIR/dispatch.rs`: the `mod` line of every module in `src/` and the dispatch of
//! every op module.
//!
//! Every slice that added a module used to add one `mod` line (and, for an op module, one
//! dispatch arm) to `src/lib.rs`, so each one that merged conflicted with every other open
//! slice. Now adding a module is adding its file; `src/lib.rs` declares none of them.
//!
//! Every file directly in `src/` (not `lib.rs`, and not one another file includes with
//! `#[path = ...]`) is a module. It is an op module when it has a line that starts with
//! `pub(crate) fn handles(operation: &[u8]) -> bool`; it then also has
//! `pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32>`, is
//! declared `mod`, and answers the JSON channel's ops its `handles` accepts. Every other module
//! (a typed C ABI such as `focus`, a helper such as `typed`) is declared `pub mod`. Op modules
//! are asked in name order, and no two may answer the same op (the `op_modules_are_disjoint`
//! test), so the order never decides which module answers.
//!
//! A `#[path]` module's own `mod x;` resolves next to its file (`src/x.rs`), not in
//! `src/<name>/`: a module with a directory names each child's file (`#[path = "focus/codec.rs"]`).
//!
//! Each `mod` line carries `#[path]`, so rustc resolves a module's own submodules from `src/`,
//! not `src/NAME/`: a module with submodules in `src/NAME/` declares each one
//! `#[path = "NAME/sub.rs"] mod sub;` (as `focus` and `window_close_selection` do).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

const HANDLES: &str = "pub(crate) fn handles(operation: &[u8]) -> bool";

fn main() {
    let manifest =
        PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let src = manifest.join("src");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src");

    let mut files: Vec<(String, PathBuf, String)> = Vec::new();
    for entry in std::fs::read_dir(&src).unwrap_or_else(|e| panic!("read {}: {e}", src.display())) {
        let path = entry.expect("src entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") || !path.is_file() {
            continue;
        }
        let name = path.file_stem().and_then(|s| s.to_str()).expect("utf-8 file name").to_owned();
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
        files.push((name, path, text));
    }

    // Files another file includes as its own submodule (`#[path = "window_rules_desktop.rs"]`).
    let mut included: Vec<String> = Vec::new();
    for (_, _, text) in &files {
        for line in text.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("#[path = \"")
                && let Some(target) = rest.split('"').next()
            {
                included.push(target.trim_end_matches(".rs").to_owned());
            }
        }
    }

    // build.rs declares every module with `#[path = ...]`, and rustc reads a file declared that way
    // as a `mod.rs`: its own `mod codec;` is looked for in `src/codec.rs`, not `src/focus/codec.rs`
    // (cmux#60470 broke `focus` and `window_close_selection` that way, E0583). A submodule in a
    // module's own folder names its path, so the next one fails here with the fix, not in rustc.
    for (name, path, text) in &files {
        if !src.join(name).is_dir() {
            continue;
        }
        let mut previous = "";
        for line in text.lines() {
            let line = line.trim();
            let declared = ["mod ", "pub mod ", "pub(crate) mod ", "pub(super) mod "]
                .iter()
                .find_map(|prefix| line.strip_prefix(prefix))
                .and_then(|rest| rest.strip_suffix(';'));
            if let Some(child) = declared
                && !previous.starts_with("#[path")
            {
                panic!(
                    "{}: `{line}` needs `#[path = \"{name}/{child}.rs\"]` on the line above: build.rs \
                     declares `{name}` with #[path], so rustc looks for `{child}` in src/, not src/{name}/",
                    path.display()
                );
            }
            previous = line;
        }
    }

    let lib = files
        .iter()
        .find(|(name, _, _)| name == "lib")
        .map(|(_, _, text)| text.clone())
        .expect("src/lib.rs");
    // Every module in src/, and whether it is an op module, in name order.
    let mut all: Vec<(String, PathBuf, bool)> = files
        .into_iter()
        .filter(|(name, _, _)| name != "lib" && !included.contains(name))
        .map(|(name, path, text)| {
            let op = text.lines().any(|line| line.starts_with(HANDLES));
            (name, path, op)
        })
        .collect();
    all.sort();

    for (name, _, _) in &all {
        for declared in [format!("mod {name};"), format!("pub mod {name};")] {
            if lib.lines().any(|line| line.trim() == declared) {
                panic!(
                    "src/lib.rs declares `{declared}`, but build.rs writes the `mod` line of \
                     every file in src/: drop the line from src/lib.rs"
                );
            }
        }
    }

    let mut out = String::new();
    out.push_str("// @generated by build.rs from the files in src/. Do not edit.\n\n");
    for (name, path, op) in &all {
        let visibility = if *op { "" } else { "pub " };
        if src.join(name).is_dir() {
            // A module with its own directory (`focus.rs` and `focus/codec.rs`). rustc treats a
            // file named by `#[path]` like a `mod.rs`, so its `mod codec;` would look for
            // `src/codec.rs`. Declared without `#[path]` inside an inline module whose `#[path]`
            // is `src/`, it is an ordinary `focus.rs` again and finds `src/focus/codec.rs`.
            let dir = src.to_str().expect("utf-8 path");
            writeln!(
                out,
                "#[path = {dir:?}]\nmod {name}_dir {{\n    pub mod {name};\n}}\n{visibility}use {name}_dir::{name};"
            )
            .unwrap();
        } else {
            let path = path.to_str().expect("utf-8 path");
            writeln!(out, "#[path = {path:?}]\n{visibility}mod {name};").unwrap();
        }
    }
    let modules: Vec<&String> =
        all.iter().filter(|(_, _, op)| *op).map(|(name, _, _)| name).collect();
    out.push_str(
        "\n/// An op module's `handles`.\n#[cfg(test)]\ntype OpHandles = fn(&[u8]) -> bool;\n",
    );
    out.push_str(
        "\n/// The op modules, in name order: each one's name and `handles`.\n\
         #[cfg(test)]\n\
         const OP_MODULES: &[(&str, OpHandles)] = &[\n",
    );
    for name in &modules {
        writeln!(out, "    ({name:?}, {name}::handles),").unwrap();
    }
    out.push_str(
        "];\n\n\
         /// The answer of the op module that handles `operation`, or None when none does.\n\
         fn respond_op_module(operation: &[u8], request: &[u8]) -> Option<Result<Vec<u8>, i32>> {\n",
    );
    for name in &modules {
        writeln!(
            out,
            "    if {name}::handles(operation) {{\n        return Some({name}::respond(operation, request));\n    }}"
        )
        .unwrap();
    }
    out.push_str("    None\n}\n");

    let dest = Path::new(&std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("dispatch.rs");
    std::fs::write(&dest, out).unwrap_or_else(|e| panic!("write {}: {e}", dest.display()));
}
