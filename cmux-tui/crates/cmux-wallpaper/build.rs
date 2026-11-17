//! Embeds the first-party wallpapers: every `wallpapers/<id>/` folder with a
//! `wallpaper.json` becomes one entry of `$OUT_DIR/first_party.rs` (sorted by
//! folder name), its manifest and `wallpaper.wgsl` read with `include_str!`.
//! `EMBEDDED` has every folder, `SHIPPED` every folder but `smoke` (the test
//! sample). A folder without its program gets an empty source, which the
//! `every_first_party_wallpaper_compiles` test refuses, so a half-written
//! folder fails a test instead of the build.

use std::fmt::Write as _;
use std::path::Path;

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("wallpapers");
    println!("cargo:rerun-if-changed={}", root.display());
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
        let program = dir.join("wallpaper.wgsl");
        println!("cargo:rerun-if-changed={}", dir.display());
        println!("cargo:rerun-if-changed={}", manifest.display());
        println!("cargo:rerun-if-changed={}", program.display());
        let source = if program.is_file() {
            format!("include_str!({:?})", program.display().to_string())
        } else {
            "\"\"".to_string()
        };
        let entry = format!(
            "    FirstParty {{ folder: {folder:?}, manifest_json: include_str!({:?}), source: {source} }},\n",
            manifest.display().to_string()
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
    let dest = Path::new(&std::env::var("OUT_DIR").unwrap_or_default()).join("first_party.rs");
    if let Err(e) = std::fs::write(&dest, out) {
        println!("cargo:warning=cannot write {}: {e}", dest.display());
    }
}
