// The host's half of every live wallpaper (plans/cmux-next/live-wallpapers.md): the Frame
// uniform and its binding. The program's source follows this text, then epilogue.wgsl.
struct Frame {
    time: vec4<f32>,
    size: vec4<f32>,
    pointer: vec4<f32>,
    presence: vec4<f32>,
    ink: vec4<f32>,
    paper: vec4<f32>,
    accent: vec4<f32>,
    params: array<vec4<f32>, 2>,
}

@group(0) @binding(0) var<uniform> frame: Frame;
