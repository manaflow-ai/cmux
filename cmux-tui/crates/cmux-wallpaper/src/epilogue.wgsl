
// The host's entry points: a full-screen triangle, and the fragment that calls the program and
// encodes its linear color to sRGB for an 8-bit, non-sRGB drawable.
@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let xy = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4<f32>(xy * 2.0 - 1.0, 0.0, 1.0);
}

fn cmux_encode_srgb(c: vec3<f32>) -> vec3<f32> {
    let v = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    let lo = v * 12.92;
    let hi = 1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(hi, lo, v <= vec3<f32>(0.0031308));
}

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = wallpaper(pos.xy);
    let a = clamp(c.a, 0.0, 1.0);
    let rgb = select(c.rgb / a, vec3<f32>(0.0), a <= 0.0);
    return vec4<f32>(cmux_encode_srgb(rgb) * a, a);
}
