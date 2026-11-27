// The scene engine's half of the host (plans/cmux-next/motion-scenes.md, "The packed block"): the
// Scene block Rust packs each frame (src/scene/mod.rs) and the one image slot. Added after
// prelude.wgsl for the first-party scene-engine program only; authored programs never see it.
struct Scene {
    rows: array<vec4<f32>, 128>,
}

@group(0) @binding(1) var<uniform> scene: Scene;
@group(0) @binding(2) var scene_image: texture_2d<f32>;
@group(0) @binding(3) var scene_sampler: sampler;
