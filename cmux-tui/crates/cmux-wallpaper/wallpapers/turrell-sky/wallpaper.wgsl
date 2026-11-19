// Skyspace: a knife-edged, rounded aperture of luminous sky in a flat ceiling, after Turrell. The
// sky is a nearly flat gradient (zenith to a faint horizon glow across it) whose color walks a
// slow dusk cycle over minutes: afternoon blue, sunset violet over peach, dusk indigo over rose,
// night, and back (a ping-pong, so there is no seam). The ceiling is the theme's paper, tinted by
// the sky's own light, a little more near the opening; that boundary is the trick that makes the
// sky read as a solid plane of color. With the frame at 0 it is a Ganzfeld: the whole window is
// the field, with a soft center bloom and edge falloff. Keys in OKLCH, mixed in OKLab, dithered.
//
// params[0]: x cycle (minutes), y aperture (fraction of the height), z roundness, w frame
// params[1]: x palette (0 Dusk, 1 Blue Hour, 2 Ganzfeld), y spill, z edge softness, w vignette

const TS_TAU: f32 = 6.2831853;

fn ts_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn ts_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = ts_hash(i);
    let b = ts_hash(i + vec2<f32>(1.0, 0.0));
    let c = ts_hash(i + vec2<f32>(0.0, 1.0));
    let d = ts_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn ts_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let r = radians(h);
    return vec3<f32>(l, c * cos(r), c * sin(r));
}

fn ts_lab_to_lin(c: vec3<f32>) -> vec3<f32> {
    let l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;
    return vec3<f32>(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    );
}

fn ts_lin_to_lab(c: vec3<f32>) -> vec3<f32> {
    let l = 0.4122214708 * c.x + 0.5363020883 * c.y + 0.0514459929 * c.z;
    let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z;
    let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z;
    let lms = pow(max(vec3<f32>(l, m, s), vec3<f32>(0.0)), vec3<f32>(1.0 / 3.0));
    return vec3<f32>(
        0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
        1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
        0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z,
    );
}

// Triangular-PDF dither of +-1/255 in a gamma-2.2 space, static in screen space.
fn ts_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = ts_hash(px) + ts_hash(px.yx + vec2<f32>(19.19, 7.73)) - 1.0;
    let s = pow(max(lin, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2)) + vec3<f32>(n / 255.0);
    return pow(max(s, vec3<f32>(0.0)), vec3<f32>(2.2));
}

// Key k (0..3) of a palette: zenith (xyz = L, C, hue) for `horizon` false, horizon glow for true.
// L is authored for dark; ts_sky maps it for light.
fn ts_key(pal: f32, k: i32, horizon: bool) -> vec3<f32> {
    if (pal < 0.5) {
        // Dusk: afternoon blue, sunset violet over peach, dusk indigo over rose, night.
        if (k == 0) { return select(vec3<f32>(0.42, 0.085, 244.0), vec3<f32>(0.47, 0.05, 222.0), horizon); }
        if (k == 1) { return select(vec3<f32>(0.37, 0.09, 268.0), vec3<f32>(0.45, 0.075, 48.0), horizon); }
        if (k == 2) { return select(vec3<f32>(0.29, 0.11, 284.0), vec3<f32>(0.37, 0.10, 355.0), horizon); }
        return select(vec3<f32>(0.205, 0.08, 266.0), vec3<f32>(0.27, 0.085, 300.0), horizon);
    }
    if (pal < 1.5) {
        // Blue Hour: the long minutes after sunset, all in blues.
        if (k == 0) { return select(vec3<f32>(0.39, 0.08, 236.0), vec3<f32>(0.46, 0.05, 205.0), horizon); }
        if (k == 1) { return select(vec3<f32>(0.33, 0.105, 252.0), vec3<f32>(0.41, 0.07, 228.0), horizon); }
        if (k == 2) { return select(vec3<f32>(0.27, 0.12, 263.0), vec3<f32>(0.34, 0.09, 248.0), horizon); }
        return select(vec3<f32>(0.22, 0.10, 274.0), vec3<f32>(0.29, 0.08, 290.0), horizon);
    }
    // Ganzfeld: saturated fields of light, magenta, blue, rose.
    if (k == 0) { return select(vec3<f32>(0.33, 0.12, 300.0), vec3<f32>(0.37, 0.10, 310.0), horizon); }
    if (k == 1) { return select(vec3<f32>(0.30, 0.13, 262.0), vec3<f32>(0.35, 0.11, 272.0), horizon); }
    if (k == 2) { return select(vec3<f32>(0.34, 0.12, 18.0), vec3<f32>(0.39, 0.10, 30.0), horizon); }
    return select(vec3<f32>(0.31, 0.115, 332.0), vec3<f32>(0.36, 0.10, 342.0), horizon);
}

// The sky color at cycle position x (0..3 along the keys), in OKLab, for the theme.
fn ts_sky(pal: f32, x: f32, horizon: bool, dark: f32) -> vec3<f32> {
    var c = ts_key(pal, 0, horizon);
    var lab = ts_lch(c.x, c.y, c.z);
    for (var k = 1; k < 4; k = k + 1) {
        let w = smoothstep(0.0, 1.0, clamp(x - f32(k - 1), 0.0, 1.0));
        c = ts_key(pal, k, horizon);
        lab = mix(lab, ts_lch(c.x, c.y, c.z), w);
    }
    // Light: the same sky, lifted so dark text still reads on it, a little less chroma.
    let light = vec3<f32>(0.56 + 0.7 * lab.x, lab.yz * 0.85);
    return mix(light, lab, dark);
}

fn ts_box(p: vec2<f32>, b: vec2<f32>, r: f32) -> f32 {
    let q = abs(p) - b + r;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let h = max(frame.size.y, 1.0);
    let aspect = frame.size.x / h;
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;
    let seed = select(frame.size.w, 0.0, still);
    let t = frame.time.x;
    let pal = pb.x;

    // The cycle: a ping-pong over the four keys, one full there-and-back per `cycle` minutes,
    // started at a per-window place so two windows are at different hours.
    let period = max(pa.x, 1.0) * 60.0;
    let s01 = 0.5 - 0.5 * cos(TS_TAU * (t / period + seed));
    let x = s01 * 3.0;

    let p = (px - 0.5 * frame.size.xy) / h;
    let zen = ts_sky(pal, x, false, dark);
    let hor = ts_sky(pal, x, true, dark);

    // Aperture geometry (height units): a square opening with rounded corners up to a circle.
    let frame_amt = clamp(pa.w, 0.0, 1.0);
    let hs = clamp(pa.y, 0.2, 0.95) * 0.5;
    let b = vec2<f32>(hs, hs);
    let d = ts_box(p, b, clamp(pa.z, 0.0, 1.0) * hs);

    // Sky: zenith at the upper left of the opening, the horizon's glow at the lower right, eased.
    // In a Ganzfeld the gradient spans the whole window, top to bottom.
    let span = mix(vec2<f32>(0.5 * aspect, 0.5), b, frame_amt);
    let gdir = normalize(mix(vec2<f32>(0.0, 1.0), vec2<f32>(0.55, 0.83), frame_amt));
    let g = clamp(0.5 + 0.5 * dot(p / span, gdir) * 0.9, 0.0, 1.0);
    var sky = mix(zen, hor, g * g * (3.0 - 2.0 * g));
    // Air: a very low, very slow swell of light, so the plane is not dead flat.
    let air = ts_noise(p * 1.3 + vec2<f32>(t * 0.0031, -t * 0.0023) + seed * 40.0) - 0.5;
    sky.x = sky.x + 0.008 * air;
    // Ganzfeld: a soft bloom at the center, falling off toward the window's edges.
    let r2 = dot(p / vec2<f32>(max(aspect, 0.5), 1.0), p / vec2<f32>(max(aspect, 0.5), 1.0));
    sky.x = sky.x + (1.0 - frame_amt) * (0.025 * exp(-r2 * 3.0) - 0.035 * pb.w * r2);

    // Ceiling: the theme's paper, tinted by the sky's light everywhere a little and near the
    // opening more, with a faint brightening by the opening (light spills over the lip).
    var roof = ts_lin_to_lab(frame.paper.rgb);
    let outside = max(d, 0.0);
    let near = exp(-outside / 0.16);
    let spill = pb.y;
    let tint = mix(hor, zen, 0.4);
    roof = vec3<f32>(
        roof.x + spill * near * mix(-0.012, 0.018, dark) - pb.w * 0.02 * r2,
        roof.yz + tint.yz * spill * (0.1 + 0.22 * near),
    );

    // The knife edge: one rendered pixel of antialiasing at softness 0, up to a soft rim.
    let aa = mix(1.0, 0.04 * h, clamp(pb.z, 0.0, 1.0));
    let inside = clamp(0.5 - d * h / aa, 0.0, 1.0);
    let cov = mix(1.0, inside, frame_amt);
    let col = mix(roof, sky, cov);

    let lin = ts_lab_to_lin(col);
    return vec4<f32>(ts_dither(lin, px), 1.0);
}
