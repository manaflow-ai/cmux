
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

// The tritone grade over every program (src/grade.rs is the same arithmetic, with its tests): the
// pixel's lightness (the square root of its luminance), measured from the shadow's (the darker of
// paper and ink) to the highlight's (the lighter), on a ramp from the shadow through the accent
// to the highlight, mixed in by frame.grade.x. The theme's own paper and ink keep their color.
fn cmux_luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn cmux_tritone(c: vec3<f32>) -> vec3<f32> {
    let ink = frame.ink.rgb;
    let paper = frame.paper.rgb;
    let ink_lighter = cmux_luma(ink) >= cmux_luma(paper);
    let shadow = select(ink, paper, ink_lighter);
    let highlight = select(paper, ink, ink_lighter);
    let lo_l = sqrt(clamp(cmux_luma(shadow), 0.0, 1.0));
    let span = max(sqrt(clamp(cmux_luma(highlight), 0.0, 1.0)) - lo_l, 1.0e-4);
    let t = clamp((sqrt(clamp(cmux_luma(c), 0.0, 1.0)) - lo_l) / span, 0.0, 1.0);
    let lo = mix(shadow, frame.accent.rgb, min(t * 2.0, 1.0));
    let hi = mix(frame.accent.rgb, highlight, max(t * 2.0 - 1.0, 0.0));
    return mix(c, select(hi, lo, t < 0.5), frame.grade.x);
}

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = wallpaper(pos.xy);
    let a = clamp(c.a, 0.0, 1.0);
    var rgb = select(c.rgb / a, vec3<f32>(0.0), a <= 0.0);
    // Off (0, the default): a uniform branch, so an ungraded wallpaper runs none of it.
    if frame.grade.x > 0.0 {
        rgb = cmux_tritone(rgb);
    }
    return vec4<f32>(cmux_encode_srgb(rgb) * a, a);
}
