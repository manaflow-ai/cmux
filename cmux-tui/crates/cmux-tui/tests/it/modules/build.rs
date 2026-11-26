//! Writes `$OUT_DIR/modules.rs`: the `modules!` macro, with one `#[path = "..."] mod NAME;` for
//! each `tests/NAME.rs` of cmux-tui that has no `[[test]]` of its own in cmux-tui's
//! `Cargo.toml`. Reruns when anything under `tests/` or that manifest changes; this package is
//! tiny, so a rerun costs about a second and never rebuilds the cmux-tui library.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

fn main() {
    let here = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    // tests/it/modules -> tests
    let tests = here.join("../..").canonicalize().expect("cmux-tui's tests folder");
    let manifest = tests.join("../Cargo.toml");
    println!("cargo:rerun-if-changed={}", tests.display());
    println!("cargo:rerun-if-changed={}", manifest.display());

    let own = own_test_targets(&std::fs::read_to_string(&manifest).expect("cmux-tui's Cargo.toml"));
    let mut files: Vec<PathBuf> = std::fs::read_dir(&tests)
        .expect("read tests/")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.is_file() && path.extension().is_some_and(|ext| ext == "rs"))
        .collect();
    files.sort();

    let mut out = String::from("/// One `#[path] mod` per test file (build.rs).\n");
    out.push_str("#[macro_export]\nmacro_rules! modules {\n    () => {\n");
    for path in &files {
        let name = path.file_stem().and_then(|stem| stem.to_str()).expect("a UTF-8 file name");
        if own.contains(&format!("tests/{name}.rs")) {
            continue;
        }
        let text = std::fs::read_to_string(path).expect("read a test file");
        if let Some(why) = needs_own_process(&text) {
            panic!(
                "tests/{name}.rs {why}, which changes the whole test process: give it a \
                 binary of its own with a `[[test]] name = \"{name}\"` entry in \
                 cmux-tui/crates/cmux-tui/Cargo.toml (see tests/it/main.rs)"
            );
        }
        writeln!(out, "        #[path = {:?}]\n        mod {name};", path.display().to_string())
            .unwrap();
    }
    out.push_str("    };\n}\n");

    let target = Path::new(&std::env::var_os("OUT_DIR").expect("OUT_DIR")).join("modules.rs");
    if std::fs::read_to_string(&target).ok().as_deref() != Some(out.as_str()) {
        std::fs::write(&target, out).expect("write modules.rs");
    }
}

/// The `path`s of the manifest's `[[test]]` entries: those files are binaries of their own.
fn own_test_targets(manifest: &str) -> BTreeSet<String> {
    let mut own = BTreeSet::new();
    let mut in_test = false;
    for line in manifest.lines().map(str::trim) {
        if line.starts_with('[') {
            in_test = line == "[[test]]";
            continue;
        }
        if in_test
            && let Some(value) = line.strip_prefix("path").map(str::trim_start)
            && let Some(value) = value.strip_prefix('=')
        {
            own.insert(value.trim().trim_matches('"').to_owned());
        }
    }
    own
}

/// Why a test file needs a process of its own, if it does.
fn needs_own_process(text: &str) -> Option<&'static str> {
    if text.contains("const HERMETIC") {
        Some("installs daemon_env's hermetic environment before main (`const HERMETIC`)")
    } else if text.contains("env::set_var(") || text.contains("env::remove_var(") {
        Some("sets the process environment (`std::env::set_var`/`remove_var`)")
    } else {
        None
    }
}
