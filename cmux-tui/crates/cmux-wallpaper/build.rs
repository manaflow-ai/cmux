//! Embeds the first-party wallpapers: every `wallpapers/<id>/` folder with a
//! `wallpaper.json` becomes one entry of `$OUT_DIR/first_party.rs` (sorted by
//! folder name): its manifest, its `wallpaper.wgsl`, and the program's Metal
//! Shading Language, translated here by src/program.rs (the same sandbox and
//! translation as the `compile` feature). A first-party program that the
//! sandbox or naga refuses fails the build, so shipped binaries carry Metal
//! source and no shader compiler. `EMBEDDED` has every folder, `SHIPPED`
//! every folder but `smoke` (the test sample).

use std::fmt::Write as _;
use std::path::Path;

#[allow(dead_code)]
#[path = "src/program.rs"]
mod program;

fn fail(message: &str) -> ! {
    println!("cargo::error={message}");
    eprintln!("{message}");
    std::process::exit(1)
}

/// The prelude's `Frame` is 416 bytes (src/frame.rs packs 104 floats).
fn check_frame_layout() {
    let Ok(module) = naga::front::wgsl::parse_str(program::PRELUDE) else {
        fail("src/prelude.wgsl does not parse")
    };
    let mut layouter = naga::proc::Layouter::default();
    if layouter.update(module.to_ctx()).is_err() {
        fail("src/prelude.wgsl: no layout for Frame");
    }
    let size = module
        .types
        .iter()
        .find(|(_, t)| t.name.as_deref() == Some("Frame"))
        .map(|(h, _)| layouter[h].size);
    if size != Some(416) {
        fail(&format!("src/prelude.wgsl: Frame is {size:?} bytes, not 416 (src/frame.rs)"));
    }
}

fn main() {
    let here = Path::new(env!("CARGO_MANIFEST_DIR"));
    let root = here.join("wallpapers");
    println!("cargo:rerun-if-changed={}", root.display());
    for f in ["src/program.rs", "src/prelude.wgsl", "src/epilogue.wgsl"] {
        println!("cargo:rerun-if-changed={}", here.join(f).display());
    }
    check_frame_layout();
    let out_dir = std::env::var("OUT_DIR").unwrap_or_default();
    let out_dir = Path::new(&out_dir);
    let mut folders: Vec<_> = std::fs::read_dir(&root)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.join("wallpaper.json").is_file())
                .collect()
        })
        .unwrap_or_default();
    folders.sort();
    let mut embedded = String::new();
    let mut shipped = String::new();
    for dir in folders {
        let Some(folder) = dir.file_name().and_then(|n| n.to_str()) else { continue };
        let manifest = dir.join("wallpaper.json");
        let program_path = dir.join("wallpaper.wgsl");
        println!("cargo:rerun-if-changed={}", dir.display());
        println!("cargo:rerun-if-changed={}", manifest.display());
        println!("cargo:rerun-if-changed={}", program_path.display());
        let Ok(source) = std::fs::read_to_string(&program_path) else {
            fail(&format!("wallpapers/{folder}: no wallpaper.wgsl"))
        };
        let compiled = match program::compile(&source) {
            Ok(c) => c,
            Err(e) => fail(&format!("wallpapers/{folder}/wallpaper.wgsl:{e}")),
        };
        let msl = out_dir.join(format!("{folder}.metal"));
        if let Err(e) = std::fs::write(&msl, compiled.msl) {
            fail(&format!("cannot write {}: {e}", msl.display()));
        }
        let entry = format!(
            "    FirstParty {{ folder: {folder:?}, manifest_json: include_str!({:?}), source: include_str!({:?}), msl: include_str!({:?}) }},\n",
            manifest.display().to_string(),
            program_path.display().to_string(),
            msl.display().to_string(),
        );
        embedded.push_str(&entry);
        if folder != "smoke" {
            shipped.push_str(&entry);
        }
    }
    let mut out = String::new();
    let _ = writeln!(
        out,
        "/// Every folder under `wallpapers/` with a `wallpaper.json`, sorted by name."
    );
    let _ = writeln!(out, "pub const EMBEDDED: &[FirstParty] = &[\n{embedded}];");
    let _ = writeln!(out, "/// The shipped set: [`EMBEDDED`] without `smoke`.");
    let _ = writeln!(out, "pub const SHIPPED: &[FirstParty] = &[\n{shipped}];");
    let dest = out_dir.join("first_party.rs");
    if let Err(e) = std::fs::write(&dest, out) {
        fail(&format!("cannot write {}: {e}", dest.display()));
    }
}
