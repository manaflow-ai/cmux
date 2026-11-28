//! Embeds the first-party wallpapers: every `wallpapers/<id>/` folder with a
//! `wallpaper.json` becomes one entry of `$OUT_DIR/first_party.rs` (sorted by
//! folder name): its manifest, its `wallpaper.wgsl`, and the program's Metal
//! Shading Language, translated here by src/program.rs (the same sandbox and
//! translation as the `compile` feature). A first-party program that the
//! sandbox or naga refuses fails the build, so shipped binaries carry Metal
//! source and no shader compiler. `EMBEDDED` has every folder, `SHIPPED`
//! every folder but `smoke` (the test sample).
//!
//! The scene engine (`wallpapers/scene-engine/engine.wgsl`, no `wallpaper.json`,
//! so not a wallpaper by itself) is translated once, with the scene prelude
//! (plans/cmux-next/motion-scenes.md), into `SCENE_ENGINE_MSL` and
//! `SCENE_ENGINE_GLSL`. A folder whose manifest names a `scene` (or `lottie`)
//! file embeds that file's bytes and the engine's program instead of a
//! `wallpaper.wgsl` of its own.

use std::fmt::Write as _;
use std::path::Path;

#[allow(dead_code)]
#[path = "src/program.rs"]
mod program;

/// The engine, relative to `wallpapers/`.
const SCENE_ENGINE: &str = "scene-engine/engine.wgsl";

fn fail(message: &str) -> ! {
    println!("cargo::error={message}");
    eprintln!("{message}");
    std::process::exit(1)
}

/// `name`'s size in `wgsl`, laid out by naga.
fn struct_size(wgsl: &str, file: &str, name: &str) -> Option<u32> {
    let Ok(module) = naga::front::wgsl::parse_str(wgsl) else {
        fail(&format!("{file} does not parse"))
    };
    let mut layouter = naga::proc::Layouter::default();
    if layouter.update(module.to_ctx()).is_err() {
        fail(&format!("{file}: no layout for {name}"));
    }
    module
        .types
        .iter()
        .find(|(_, t)| t.name.as_deref() == Some(name))
        .map(|(h, _)| layouter[h].size)
}

/// The prelude's `Frame` is 432 bytes (src/frame.rs packs 108 floats).
fn check_frame_layout() {
    let size = struct_size(program::PRELUDE, "src/prelude.wgsl", "Frame");
    if size != Some(432) {
        fail(&format!("src/prelude.wgsl: Frame is {size:?} bytes, not 432 (src/frame.rs)"));
    }
}

/// The scene prelude's `Scene` is 2048 bytes (src/scene/mod.rs packs 128 rows).
fn check_scene_layout() {
    let text = format!("{}\n{}", program::PRELUDE, program::SCENE_PRELUDE);
    let size = struct_size(&text, "src/scene_prelude.wgsl", "Scene");
    if size != Some(2048) {
        fail(&format!(
            "src/scene_prelude.wgsl: Scene is {size:?} bytes, not 2048 (src/scene/mod.rs)"
        ));
    }
}

fn write(path: &Path, text: &str) {
    if let Err(e) = std::fs::write(path, text) {
        fail(&format!("cannot write {}: {e}", path.display()));
    }
}

/// The file a scene wallpaper's manifest names (`scene`, else `lottie`), if any.
fn scene_file(manifest: &Path) -> Option<String> {
    let text = std::fs::read_to_string(manifest).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    ["scene", "lottie"].iter().find_map(|k| v.get(*k)?.as_str().map(str::to_string))
}

fn main() {
    // Read at run time, not with env!(): a build-script binary reused from another checkout (a shared
    // target dir, a build cache) keeps the path it was compiled at, and that tree may be gone
    // ("wallpapers/scene-engine/engine.wgsl: missing" under a deleted temp tree).
    let here = std::env::var_os("CARGO_MANIFEST_DIR").unwrap_or_default();
    let here = Path::new(&here);
    let root = here.join("wallpapers");
    println!("cargo:rerun-if-changed={}", root.display());
    for f in ["src/program.rs", "src/prelude.wgsl", "src/scene_prelude.wgsl", "src/epilogue.wgsl"] {
        println!("cargo:rerun-if-changed={}", here.join(f).display());
    }
    check_frame_layout();
    check_scene_layout();
    let out_dir = std::env::var("OUT_DIR").unwrap_or_default();
    let out_dir = Path::new(&out_dir);

    // The scene engine, once.
    let engine_path = root.join(SCENE_ENGINE);
    println!("cargo:rerun-if-changed={}", engine_path.display());
    let Ok(engine_source) = std::fs::read_to_string(&engine_path) else {
        fail(&format!("wallpapers/{SCENE_ENGINE}: missing"))
    };
    let engine = match program::compile_scene_engine(&engine_source) {
        Ok(c) => c,
        Err(e) => fail(&format!("wallpapers/{SCENE_ENGINE}:{e}")),
    };
    let engine_msl = out_dir.join("scene-engine.metal");
    let engine_glsl = out_dir.join("scene-engine.frag");
    write(&engine_msl, &engine.msl);
    write(&engine_glsl, &engine.glsl);

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
        println!("cargo:rerun-if-changed={}", dir.display());
        println!("cargo:rerun-if-changed={}", manifest.display());
        let manifest_lit = format!("{:?}", manifest.display().to_string());
        let entry = if let Some(file) = scene_file(&manifest) {
            // A scene: its file's bytes, drawn by the engine.
            let scene_path = dir.join(&file);
            println!("cargo:rerun-if-changed={}", scene_path.display());
            if !scene_path.is_file() {
                fail(&format!("wallpapers/{folder}: no {file}"));
            }
            format!(
                "    FirstParty {{ folder: {folder:?}, manifest_json: include_str!({manifest_lit}), source: SCENE_ENGINE_SOURCE, msl: SCENE_ENGINE_MSL, scene_json: Some(include_str!({:?})) }},\n",
                scene_path.display().to_string(),
            )
        } else {
            let program_path = dir.join("wallpaper.wgsl");
            println!("cargo:rerun-if-changed={}", program_path.display());
            let Ok(source) = std::fs::read_to_string(&program_path) else {
                fail(&format!("wallpapers/{folder}: no wallpaper.wgsl"))
            };
            let compiled = match program::compile(&source) {
                Ok(c) => c,
                Err(e) => fail(&format!("wallpapers/{folder}/wallpaper.wgsl:{e}")),
            };
            let msl = out_dir.join(format!("{folder}.metal"));
            write(&msl, &compiled.msl);
            format!(
                "    FirstParty {{ folder: {folder:?}, manifest_json: include_str!({manifest_lit}), source: include_str!({:?}), msl: include_str!({:?}), scene_json: None }},\n",
                program_path.display().to_string(),
                msl.display().to_string(),
            )
        };
        embedded.push_str(&entry);
        if folder != "smoke" && folder != "scene-sample" {
            shipped.push_str(&entry);
        }
    }
    let mut out = String::new();
    let _ = writeln!(out, "/// `wallpapers/{SCENE_ENGINE}`: the scene engine's WGSL.");
    let _ = writeln!(
        out,
        "pub const SCENE_ENGINE_SOURCE: &str = include_str!({:?});",
        engine_path.display().to_string()
    );
    let _ = writeln!(
        out,
        "/// The scene engine in Metal Shading Language 2.1: `vertex vs_main`, `fragment fs_main`; `frame` at buffer 0, `scene` at buffer 1, `scene_image` at texture 0, `scene_sampler` at sampler 0."
    );
    let _ = writeln!(
        out,
        "pub const SCENE_ENGINE_MSL: &str = include_str!({:?});",
        engine_msl.display().to_string()
    );
    let _ = writeln!(
        out,
        "/// The scene engine as a GLSL ES 3.00 fragment shader (the gallery): the `Frame` and `Scene` uniform blocks and one `sampler2D`."
    );
    let _ = writeln!(
        out,
        "pub const SCENE_ENGINE_GLSL: &str = include_str!({:?});",
        engine_glsl.display().to_string()
    );
    let _ = writeln!(
        out,
        "/// Every folder under `wallpapers/` with a `wallpaper.json`, sorted by name."
    );
    let _ = writeln!(out, "pub const EMBEDDED: &[FirstParty] = &[\n{embedded}];");
    let _ = writeln!(
        out,
        "/// The shipped set: [`EMBEDDED`] without the samples (`smoke`, `scene-sample`)."
    );
    let _ = writeln!(out, "pub const SHIPPED: &[FirstParty] = &[\n{shipped}];");
    write(&out_dir.join("first_party.rs"), &out);
}
