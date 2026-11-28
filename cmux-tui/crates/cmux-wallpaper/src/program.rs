//! The program: the sandbox and the translation (plans/cmux-next/live-wallpapers.md,
//! "The program" and "Translation").
//!
//! The host's half (`prelude.wgsl`: the `Frame` struct and its binding;
//! `epilogue.wgsl`: the full-screen triangle and `fs_main`) is wrapped around
//! the author's source. The source alone may define only constants, types,
//! `alias`es and functions, one of which is `fn wallpaper(vec2<f32>) -> vec4<f32>`:
//! no binding, entry point, texture, sampler, storage buffer, `override`,
//! `var<workgroup>` or `var<private>`. The checks run on the module of
//! prelude + source, so every global or entry point past the prelude's one
//! `frame` is the author's. The assembled module is then validated with no
//! optional capability and written as Metal Shading Language (`vs_main`,
//! `fs_main`, `frame` in buffer 0) and as a GLSL ES 3.00 fragment shader.
//!
//! [`compile_scene_engine`] is the same for the one first-party scene engine
//! (plans/cmux-next/motion-scenes.md): `scene_prelude.wgsl` follows the
//! prelude, and the sandbox also lets it read the prelude's `scene` (binding
//! 1), `scene_image` (binding 2) and `scene_sampler` (binding 3). Authored
//! programs never get that prelude, so declaring or reading them stays refused.

use naga::back::{glsl, msl};
use naga::valid::{Capabilities, ValidationFlags, Validator};
use naga::{
    AddressSpace, Module, ResourceBinding, ScalarKind, ShaderStage, Span, TypeInner, VectorSize,
};
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// The host's half before the program: `Frame` and `frame`.
pub const PRELUDE: &str = include_str!("prelude.wgsl");
/// The host's half after the program: `vs_main`, `fs_main` and the color encoding.
pub const EPILOGUE: &str = include_str!("epilogue.wgsl");
/// The scene engine's half, after [`PRELUDE`]: `Scene`, `scene` and the image slot.
pub const SCENE_PRELUDE: &str = include_str!("scene_prelude.wgsl");
/// The largest program accepted.
pub const MAX_SOURCE_BYTES: usize = 64 * 1024;
/// The Metal Shading Language version of the MSL (Metal 2.1, macOS 10.14 and later).
pub const MSL_VERSION: (u8, u8) = (2, 1);
/// The Metal buffer index of `frame` in both stages.
pub const MSL_FRAME_BUFFER: u8 = 0;
/// The scene engine's Metal buffer index of `scene` (fragment buffer 1).
pub const MSL_SCENE_BUFFER: u8 = 1;
/// The scene engine's Metal texture index of `scene_image`.
pub const MSL_SCENE_TEXTURE: u8 = 0;
/// The scene engine's Metal sampler index of `scene_sampler`.
pub const MSL_SCENE_SAMPLER: u8 = 0;
/// The host's globals: what each prelude declares, by name and binding. Only
/// these, and only where the prelude declares them, pass the sandbox.
const HOST_GLOBALS: &[(&str, u32)] = &[("frame", 0)];
const SCENE_HOST_GLOBALS: &[(&str, u32)] =
    &[("frame", 0), ("scene", 1), ("scene_image", 2), ("scene_sampler", 3)];
/// Names the host's half uses; a program may not define them.
const RESERVED_FUNCTIONS: &[&str] = &["vs_main", "fs_main", "main"];
const RESERVED_PREFIX: &str = "cmux_";

/// What a program check refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProgramErrorKind {
    /// Longer than [`MAX_SOURCE_BYTES`].
    TooLarge,
    /// Not WGSL naga can parse.
    Parse,
    /// A resource binding (`@group`/`@binding`, `var<uniform>`).
    Binding,
    /// An `@vertex`, `@fragment` or `@compute` function.
    EntryPoint,
    /// `var<workgroup>`.
    Workgroup,
    /// `var<private>`.
    Private,
    /// A texture (or other opaque handle) global.
    Texture,
    /// A sampler global.
    Sampler,
    /// `var<storage>`.
    Storage,
    /// A global in an address space no wallpaper uses (immediates, task or ray payloads).
    OtherGlobal,
    /// A pipeline-overridable constant (`override`).
    Override,
    /// A function named like one of the host's (`vs_main`, `fs_main`, `main`, `cmux_*`).
    ReservedName,
    /// No `fn wallpaper`.
    MissingWallpaper,
    /// `fn wallpaper` with another signature than `(vec2<f32>) -> vec4<f32>`.
    WallpaperSignature,
    /// naga's validator refused the module (types, uniformity, capabilities).
    Validation,
    /// Metal or GLSL output failed.
    Translation,
    /// naga itself failed (a panic caught at this boundary).
    Internal,
}

/// Why a program was refused. `line`/`column` (1-based, columns in
/// characters) point into the author's source when the cause is there.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramError {
    pub kind: ProgramErrorKind,
    pub message: String,
    pub location: Option<(u32, u32)>,
}

impl fmt::Display for ProgramError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.location {
            Some((line, column)) => write!(f, "{line}:{column}: {}", self.message),
            None => write!(f, "{}", self.message),
        }
    }
}

impl std::error::Error for ProgramError {}

/// A program that passed every check, in both target languages.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Compiled {
    /// Metal: `vertex vs_main` and `fragment fs_main`, `frame` at buffer index 0.
    pub msl: String,
    /// GLSL ES 3.00, `fs_main` as the fragment shader's `main`; `frame` is
    /// the module's one uniform block (binding point 0 is the caller's choice).
    pub glsl: String,
}

/// Where the author's source sits in the assembled text.
struct Layout<'a> {
    source: &'a str,
    start: usize,
}

impl Layout<'_> {
    /// The author's line and column for a span of the assembled text.
    fn locate(&self, span: Span) -> Option<(u32, u32)> {
        let range = span.to_range()?;
        let offset = range.start.checked_sub(self.start)?;
        if offset > self.source.len() {
            return None;
        }
        let before = self.source.get(..offset)?;
        let line = before.matches('\n').count().saturating_add(1);
        let line_start = before.rfind('\n').map_or(0, |i| i.saturating_add(1));
        let column = before.get(line_start..)?.chars().count().saturating_add(1);
        Some((u32::try_from(line).ok()?, u32::try_from(column).ok()?))
    }
}

fn error(
    kind: ProgramErrorKind,
    message: impl Into<String>,
    location: Option<(u32, u32)>,
) -> ProgramError {
    ProgramError { kind, message: message.into(), location }
}

/// `e` and every `source()` under it, joined: naga's validation errors nest.
fn chain(e: &dyn std::error::Error) -> String {
    let mut out = e.to_string();
    let mut next = e.source();
    while let Some(inner) = next {
        let text = inner.to_string();
        if !out.contains(&text) {
            out.push_str(": ");
            out.push_str(&text);
        }
        next = inner.source();
    }
    out
}

fn parse(text: &str, layout: &Layout<'_>) -> Result<Module, ProgramError> {
    naga::front::wgsl::parse_str(text).map_err(|e| {
        let location = e.labels().next().and_then(|(span, _)| layout.locate(span));
        error(ProgramErrorKind::Parse, e.message().to_string(), location)
    })
}

/// The first `@vertex`/`@fragment`/`@compute` in the source, for a location.
fn entry_point_location(source: &str) -> Option<(u32, u32)> {
    let at = ["@vertex", "@fragment", "@compute"].iter().filter_map(|a| source.find(a)).min()?;
    let layout = Layout { source, start: 0 };
    let end = u32::try_from(at.saturating_add(1)).ok()?;
    layout.locate(Span::new(u32::try_from(at).ok()?, end))
}

/// The sandbox, on the module of prelude + source. `host` names the
/// prelude's globals: the only ones the program may read.
fn check_sandbox(
    module: &Module,
    layout: &Layout<'_>,
    host: &[(&str, u32)],
) -> Result<(), ProgramError> {
    if let Some(ep) = module.entry_points.first() {
        return Err(error(
            ProgramErrorKind::EntryPoint,
            format!(
                "`{}` is an entry point; a wallpaper defines only `fn wallpaper` and its helpers (the host adds the entry points)",
                ep.name
            ),
            entry_point_location(layout.source),
        ));
    }
    for (handle, global) in module.global_variables.iter() {
        // The prelude's own globals (`frame`; the engine's `scene` and image
        // slot): the only ones a program may read. One the source declares
        // has a span in the source, so it never matches.
        let is_host = host.iter().any(|&(name, binding)| {
            global.name.as_deref() == Some(name)
                && global.binding == Some(ResourceBinding { group: 0, binding })
        });
        if is_host && layout.locate(module.global_variables.get_span(handle)).is_none() {
            continue;
        }
        let name = global.name.as_deref().unwrap_or("a global");
        let location = layout.locate(module.global_variables.get_span(handle));
        let ty = module.types.get_handle(global.ty).map(|t| &t.inner).ok();
        let (kind, what) = match global.space {
            AddressSpace::WorkGroup => (ProgramErrorKind::Workgroup, "var<workgroup> state"),
            AddressSpace::Private => (ProgramErrorKind::Private, "var<private> state"),
            AddressSpace::Storage { .. } => (ProgramErrorKind::Storage, "a storage buffer"),
            AddressSpace::Handle => match ty {
                Some(TypeInner::Sampler { .. }) => (ProgramErrorKind::Sampler, "a sampler"),
                _ => (ProgramErrorKind::Texture, "a texture"),
            },
            AddressSpace::Uniform => (ProgramErrorKind::Binding, "a uniform binding"),
            _ => (ProgramErrorKind::OtherGlobal, "a resource global"),
        };
        let kind = if global.binding.is_some() && kind == ProgramErrorKind::OtherGlobal {
            ProgramErrorKind::Binding
        } else {
            kind
        };
        return Err(error(
            kind,
            format!(
                "`{name}` is {what}; a wallpaper reads only `frame` and keeps no state between pixels or frames"
            ),
            location,
        ));
    }
    if let Some((handle, o)) = module.overrides.iter().next() {
        return Err(error(
            ProgramErrorKind::Override,
            format!(
                "`{}` is an override constant; use `const`, or a manifest param read from frame.params",
                o.name.as_deref().unwrap_or("an override")
            ),
            layout.locate(module.overrides.get_span(handle)),
        ));
    }
    let mut wallpaper = None;
    for (handle, f) in module.functions.iter() {
        let Some(name) = f.name.as_deref() else { continue };
        let location = layout.locate(module.functions.get_span(handle));
        if RESERVED_FUNCTIONS.contains(&name) || name.starts_with(RESERVED_PREFIX) {
            return Err(error(
                ProgramErrorKind::ReservedName,
                format!("`{name}` is a name the host uses (vs_main, fs_main, main and cmux_*)"),
                location,
            ));
        }
        if name == "wallpaper" {
            wallpaper = Some((f, location));
        }
    }
    let Some((f, location)) = wallpaper else {
        return Err(error(
            ProgramErrorKind::MissingWallpaper,
            "no `fn wallpaper(px: vec2<f32>) -> vec4<f32>`",
            None,
        ));
    };
    let is_vec = |ty: naga::Handle<naga::Type>, size: VectorSize| {
        matches!(
            module.types.get_handle(ty).map(|t| &t.inner),
            Ok(TypeInner::Vector { size: s, scalar })
                if *s == size && scalar.kind == ScalarKind::Float && scalar.width == 4
        )
    };
    let args_ok = matches!(f.arguments.as_slice(), [a] if is_vec(a.ty, VectorSize::Bi));
    let result_ok = f.result.as_ref().is_some_and(|r| is_vec(r.ty, VectorSize::Quad));
    if !args_ok || !result_ok {
        return Err(error(
            ProgramErrorKind::WallpaperSignature,
            "`wallpaper` must be `fn wallpaper(px: vec2<f32>) -> vec4<f32>`",
            location,
        ));
    }
    Ok(())
}

fn translate(module: &Module, scene: bool) -> Result<Compiled, ProgramError> {
    let info = Validator::new(ValidationFlags::all(), Capabilities::empty())
        .validate(module)
        .map_err(|e| {
            // Validation runs on the assembled text; the span is mapped by the caller.
            error(ProgramErrorKind::Validation, chain(&e), None)
        })?;

    let at = |binding| ResourceBinding { group: 0, binding };
    let mut targets =
        vec![(at(0), msl::BindTarget { buffer: Some(MSL_FRAME_BUFFER), ..Default::default() })];
    if scene {
        targets.extend([
            (at(1), msl::BindTarget { buffer: Some(MSL_SCENE_BUFFER), ..Default::default() }),
            (at(2), msl::BindTarget { texture: Some(MSL_SCENE_TEXTURE), ..Default::default() }),
            (
                at(3),
                msl::BindTarget {
                    sampler: Some(msl::BindSamplerTarget::Resource(MSL_SCENE_SAMPLER)),
                    ..Default::default()
                },
            ),
        ]);
    }
    let resources =
        msl::EntryPointResources { resources: targets.into_iter().collect(), ..Default::default() };
    let msl_options = msl::Options {
        lang_version: MSL_VERSION,
        per_entry_point_map: [
            ("vs_main".to_string(), resources.clone()),
            ("fs_main".to_string(), resources),
        ]
        .into_iter()
        .collect(),
        fake_missing_bindings: false,
        ..Default::default()
    };
    let pipeline = msl::PipelineOptions::default();
    let (msl_text, translation) = msl::write_string(module, &info, &msl_options, &pipeline)
        .map_err(|e| error(ProgramErrorKind::Translation, format!("Metal: {}", chain(&e)), None))?;
    let names: Vec<&str> =
        translation.entry_point_names.iter().filter_map(|n| n.as_deref().ok()).collect();
    if names != ["vs_main", "fs_main"] {
        return Err(error(
            ProgramErrorKind::Translation,
            format!("Metal entry points came out as {names:?}, not vs_main and fs_main"),
            None,
        ));
    }

    let glsl_options =
        glsl::Options { version: glsl::Version::new_gles(300), ..Default::default() };
    let glsl_pipeline = glsl::PipelineOptions {
        shader_stage: ShaderStage::Fragment,
        entry_point: "fs_main".to_string(),
        multiview: None,
    };
    let mut glsl_text = String::new();
    glsl::Writer::new(
        &mut glsl_text,
        module,
        &info,
        &glsl_options,
        &glsl_pipeline,
        naga::proc::BoundsCheckPolicies::default(),
    )
    .and_then(|mut w| w.write().map(|_| ()))
    .map_err(|e| error(ProgramErrorKind::Translation, format!("GLSL: {}", chain(&e)), None))?;

    Ok(Compiled { msl: msl_text, glsl: glsl_text })
}

fn compile_inner(source: &str, scene: bool) -> Result<Compiled, ProgramError> {
    // Prelude (and the engine's scene prelude) and source first: the sandbox's module.
    let extra = if scene { SCENE_PRELUDE } else { "" };
    let mut text = String::with_capacity(
        PRELUDE
            .len()
            .saturating_add(extra.len())
            .saturating_add(source.len())
            .saturating_add(EPILOGUE.len())
            .saturating_add(3),
    );
    text.push_str(PRELUDE);
    text.push('\n');
    if scene {
        text.push_str(SCENE_PRELUDE);
        text.push('\n');
    }
    let layout = Layout { source, start: text.len() };
    text.push_str(source);
    text.push('\n');
    let user = parse(&text, &layout)?;
    check_sandbox(&user, &layout, if scene { SCENE_HOST_GLOBALS } else { HOST_GLOBALS })?;

    // Then the whole program, with the host's entry points.
    text.push_str(EPILOGUE);
    let module = parse(&text, &layout)?;
    let entries: Vec<&str> = module.entry_points.iter().map(|e| e.name.as_str()).collect();
    if entries != ["vs_main", "fs_main"] {
        // Only a source that swallows the epilogue (an open block comment) gets here.
        return Err(error(
            ProgramErrorKind::Parse,
            "the program does not end cleanly (an unclosed comment or declaration?)",
            None,
        ));
    }
    translate(&module, scene).map_err(|mut e| {
        if e.kind == ProgramErrorKind::Validation && e.location.is_none() {
            // Re-run for the span: the error value above is consumed by `chain`.
            if let Err(v) =
                Validator::new(ValidationFlags::all(), Capabilities::empty()).validate(&module)
            {
                e.location = v.spans().find_map(|(span, _)| layout.locate(*span));
            }
        }
        e
    })
}

/// Checks a wallpaper program against the sandbox and translates it.
///
/// Never panics: a panic inside naga is caught here and reported as
/// [`ProgramErrorKind::Internal`].
pub fn compile(source: &str) -> Result<Compiled, ProgramError> {
    compile_checked(source, false)
}

/// [`compile`] for the first-party scene engine (`wallpapers/scene-engine/engine.wgsl`):
/// `scene_prelude.wgsl` follows the prelude, and the program may read `scene`,
/// `scene_image` and `scene_sampler` besides `frame`. Metal: `frame` at buffer
/// 0, `scene` at buffer 1, `scene_image` at texture 0, `scene_sampler` at
/// sampler 0. GLSL: two uniform blocks (named after the `Frame` and `Scene`
/// structs) and one `sampler2D`.
pub fn compile_scene_engine(source: &str) -> Result<Compiled, ProgramError> {
    compile_checked(source, true)
}

fn compile_checked(source: &str, scene: bool) -> Result<Compiled, ProgramError> {
    if source.len() > MAX_SOURCE_BYTES {
        return Err(error(
            ProgramErrorKind::TooLarge,
            format!(
                "the program is {} bytes; the limit is {} KiB",
                source.len(),
                MAX_SOURCE_BYTES / 1024
            ),
            None,
        ));
    }
    catch_unwind(AssertUnwindSafe(|| compile_inner(source, scene))).unwrap_or_else(|_| {
        Err(error(ProgramErrorKind::Internal, "the WGSL translator failed on this program", None))
    })
}

/// [`compile`] for bytes that may not be UTF-8.
pub fn compile_bytes(source: &[u8]) -> Result<Compiled, ProgramError> {
    if source.len() > MAX_SOURCE_BYTES {
        return compile(&String::from_utf8_lossy(source));
    }
    match std::str::from_utf8(source) {
        Ok(s) => compile(s),
        Err(e) => {
            Err(error(ProgramErrorKind::Parse, format!("the program is not UTF-8: {e}"), None))
        }
    }
}

#[cfg(test)]
#[path = "program_tests.rs"]
mod tests;
