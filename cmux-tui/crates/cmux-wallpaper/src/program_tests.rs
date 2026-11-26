use super::*;

const SMOKE: &str = include_str!("../wallpapers/smoke/wallpaper.wgsl");

fn refused(source: &str) -> ProgramError {
    match compile(source) {
        Ok(_) => panic!("accepted:\n{source}"),
        Err(e) => e,
    }
}

const OK_FN: &str = "fn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n";

#[test]
fn smoke_compiles_to_metal_and_glsl() {
    let c = compile(SMOKE).unwrap();
    assert!(c.msl.contains("vertex"), "{}", c.msl);
    assert!(c.msl.contains("vs_main"));
    assert!(c.msl.contains("fragment"));
    assert!(c.msl.contains("fs_main"));
    assert!(c.msl.contains("[[buffer(0)]]"), "{}", c.msl);
    assert!(c.glsl.starts_with("#version 300 es"), "{}", c.glsl);
    assert!(c.glsl.contains("void main()"));
    assert!(c.glsl.contains("uniform"));
}

#[test]
fn a_minimal_program_compiles() {
    compile(OK_FN).unwrap();
}

#[test]
fn helpers_constants_and_structs_are_allowed() {
    let src = "const TAU: f32 = 6.2831853;\nstruct P { a: f32 }\nalias V = vec2<f32>;\n\
                   fn h(p: V) -> f32 { let q = P(p.x); return sin(q.a * TAU) * frame.params[0].x; }\n\
                   fn wallpaper(px: vec2<f32>) -> vec4<f32> { var c = frame.paper; c.r += h(px); for (var i = 0; i < 4; i++) { c.g += 0.01; } return c; }\n";
    compile(src).unwrap();
}

#[test]
fn a_binding_is_refused() {
    let e = refused(&format!("@group(0) @binding(1) var<uniform> extra: vec4<f32>;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Binding);
    assert_eq!(e.location.map(|l| l.0), Some(1), "{e}");
}

#[test]
fn an_entry_point_is_refused() {
    let e = refused(&format!(
        "{OK_FN}\n@fragment\nfn mine(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {{ return wallpaper(p.xy); }}\n"
    ));
    assert_eq!(e.kind, ProgramErrorKind::EntryPoint);
    assert_eq!(e.location, Some((3, 1)), "{e}");
    let e = refused(&format!("{OK_FN}@compute @workgroup_size(1) fn c() {{}}\n"));
    assert_eq!(e.kind, ProgramErrorKind::EntryPoint);
}

#[test]
fn workgroup_state_is_refused() {
    let e = refused(&format!("var<workgroup> shared_v: f32;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Workgroup);
    assert_eq!(e.location.map(|l| l.0), Some(1));
}

#[test]
fn private_state_is_refused() {
    let e = refused(&format!("var<private> counter: f32 = 0.0;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Private);
}

#[test]
fn a_texture_is_refused() {
    let e = refused(&format!("@group(0) @binding(1) var tex: texture_2d<f32>;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Texture);
}

#[test]
fn a_sampler_is_refused() {
    let e = refused(&format!("@group(0) @binding(2) var smp: sampler;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Sampler);
}

#[test]
fn storage_is_refused() {
    let e =
        refused(&format!("@group(0) @binding(3) var<storage, read> data: array<f32>;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Storage);
}

#[test]
fn an_override_is_refused() {
    let e = refused(&format!("override speed: f32 = 1.0;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Override);
}

#[test]
fn host_names_are_refused() {
    for name in ["vs_main", "fs_main", "cmux_mix", "main"] {
        let e = refused(&format!("fn {name}() -> f32 {{ return 1.0; }}\n{OK_FN}"));
        // `vs_main`/`fs_main` may also be reported as a redefinition by naga.
        assert!(
            matches!(e.kind, ProgramErrorKind::ReservedName | ProgramErrorKind::Parse),
            "{name}: {e:?}"
        );
    }
    let e = refused(&format!("fn cmux_mix() -> f32 {{ return 1.0; }}\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::ReservedName);
}

#[test]
fn redeclaring_frame_is_refused() {
    let e = refused(&format!("struct Frame {{ a: f32 }}\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Parse);
}

#[test]
fn a_missing_or_wrong_wallpaper_is_refused() {
    assert_eq!(refused("fn other() {}\n").kind, ProgramErrorKind::MissingWallpaper);
    let e = refused("fn wallpaper(px: vec2<f32>) -> vec3<f32> { return vec3<f32>(0.0); }\n");
    assert_eq!(e.kind, ProgramErrorKind::WallpaperSignature);
    let e =
        refused("fn wallpaper(px: vec2<f32>, t: f32) -> vec4<f32> { return vec4<f32>(0.0); }\n");
    assert_eq!(e.kind, ProgramErrorKind::WallpaperSignature);
}

#[test]
fn parse_errors_point_into_the_source() {
    let e = refused("fn wallpaper(px: vec2<f32>) -> vec4<f32> {\n    return frame.paper\n}\n");
    assert_eq!(e.kind, ProgramErrorKind::Parse);
    let (line, _) = e.location.expect("a location");
    assert!((2..=3).contains(&line), "{e}");
}

#[test]
fn validation_errors_are_reported() {
    let e = refused(
        "fn wallpaper(px: vec2<f32>) -> vec4<f32> { let x: f32 = 1.0; return vec4<f32>(x); }\nfn bad() -> f32 { }\n",
    );
    assert!(matches!(e.kind, ProgramErrorKind::Validation | ProgramErrorKind::Parse), "{e:?}");
}

#[test]
fn an_unclosed_comment_cannot_swallow_the_epilogue() {
    let e = refused(&format!("{OK_FN}/* open"));
    assert_eq!(e.kind, ProgramErrorKind::Parse);
}

#[test]
fn a_large_program_is_refused() {
    let big = format!("{OK_FN}{}", "//".repeat(MAX_SOURCE_BYTES));
    assert_eq!(refused(&big).kind, ProgramErrorKind::TooLarge);
}

/// An authored program gets no `scene`: reading it is an unknown name,
/// and declaring it (or the image slot) at the engine's bindings is refused
/// like any other binding.
#[test]
fn an_authored_program_cannot_reach_the_scene() {
    let read = "fn wallpaper(px: vec2<f32>) -> vec4<f32> { return scene.rows[0]; }\n";
    assert_eq!(refused(read).kind, ProgramErrorKind::Parse);
    let declared = "struct Scene { rows: array<vec4<f32>, 128> }\n\
             @group(0) @binding(1) var<uniform> scene: Scene;\n\
             fn wallpaper(px: vec2<f32>) -> vec4<f32> { return scene.rows[0]; }\n";
    let e = refused(declared);
    assert_eq!(e.kind, ProgramErrorKind::Binding);
    assert_eq!(e.location.map(|l| l.0), Some(2), "{e}");
    let e = refused(&format!("@group(0) @binding(2) var scene_image: texture_2d<f32>;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Texture);
    let e = refused(&format!("@group(0) @binding(3) var scene_sampler: sampler;\n{OK_FN}"));
    assert_eq!(e.kind, ProgramErrorKind::Sampler);
}

/// The engine's own source may add no global of its own.
#[test]
fn the_scene_engine_may_not_add_globals() {
    let e = compile_scene_engine(&format!(
        "@group(0) @binding(4) var extra: texture_2d<f32>;\n{OK_FN}"
    ))
    .unwrap_err();
    assert_eq!(e.kind, ProgramErrorKind::Texture);
    let e = compile_scene_engine(&format!("var<private> n: f32;\n{OK_FN}")).unwrap_err();
    assert_eq!(e.kind, ProgramErrorKind::Private);
}

#[test]
fn the_scene_engine_compiles_with_its_bindings() {
    let c = compile_scene_engine(include_str!("../wallpapers/scene-engine/engine.wgsl")).unwrap();
    assert!(c.msl.contains("[[buffer(0)]]"), "{}", c.msl);
    assert!(c.msl.contains("[[buffer(1)]]"), "{}", c.msl);
    assert!(c.msl.contains("[[texture(0)]]"), "{}", c.msl);
    assert!(c.msl.contains("[[sampler(0)]]"), "{}", c.msl);
    assert!(c.glsl.starts_with("#version 300 es"), "{}", c.glsl);
    assert!(c.glsl.contains("sampler2D"), "{}", c.glsl);
    // A plain wallpaper still translates under the engine's prelude.
    compile_scene_engine(OK_FN).unwrap();
}

#[test]
fn bytes_that_are_not_utf8_are_refused() {
    assert_eq!(compile_bytes(&[0xff, 0xfe]).unwrap_err().kind, ProgramErrorKind::Parse);
    compile_bytes(OK_FN.as_bytes()).unwrap();
}
