// Afternoon: a sheet of paper on a desk with low sun coming through a window. The paper is
// fixed fiber noise (short strands at three angles, a fine tooth, a faint cockle); the light is
// a slanted, skewed pool of warm sun whose shape is the window's: the shadows of venetian blind
// slats, a sash's glazing bars, or leaves dappling it. Its penumbra widens with distance from
// the window edge that casts it (the far side of the pool is softer, as real sun is), and the
// raking light lifts the paper's grain where it falls. The shadow side leans faintly cool (sky
// fill), the lit side warm. The pool drifts and shears very slowly as the sun moves, thin
// clouds dim it now and then, leaves stir. Colors in OKLCH, mixed in OKLab, dithered.
//
// params[0]: x mode (0 blinds, 1 pane, 2 leaves), y light, z softness, w slats
// params[1]: x angle (shear), y grain, z drift, w warmth

const PL_TAU: f32 = 6.2831853;

fn pl_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn pl_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = pl_hash(i);
    let b = pl_hash(i + vec2<f32>(1.0, 0.0));
    let c = pl_hash(i + vec2<f32>(0.0, 1.0));
    let d = pl_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn pl_fbm(p: vec2<f32>) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < 4; i = i + 1) {
        s = s + a * pl_noise(q);
        q = mat2x2<f32>(1.6, 1.2, -1.2, 1.6) * q + vec2<f32>(17.0, 9.2);
        a = a * 0.5;
    }
    return s / 0.9375;
}

fn pl_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let r = radians(h);
    return vec3<f32>(l, c * cos(r), c * sin(r));
}

fn pl_lab_to_lin(c: vec3<f32>) -> vec3<f32> {
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

fn pl_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = pl_hash(px) + pl_hash(px.yx + vec2<f32>(19.19, 7.73)) - 1.0;
    let s = pow(max(lin, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2)) + vec3<f32>(n / 255.0);
    return pow(max(s, vec3<f32>(0.0)), vec3<f32>(2.2));
}

// Paper fibers: stretched noise at three angles (strands ~1 pt wide, 6 to 20 pt long), in
// points so the sheet looks the same on any screen. Fixed: there is no time term.
fn pl_fibers(q: vec2<f32>) -> f32 {
    let r1 = mat2x2<f32>(0.940, 0.342, -0.342, 0.940) * q;
    let r2 = mat2x2<f32>(0.174, -0.985, 0.985, 0.174) * q;
    let r3 = mat2x2<f32>(-0.643, 0.766, -0.766, -0.643) * q;
    let a = pl_noise(r1 * vec2<f32>(0.09, 0.9));
    let b = pl_noise(r2 * vec2<f32>(0.07, 0.8) + 13.0);
    let c = pl_noise(r3 * vec2<f32>(0.12, 1.1) + 29.0);
    // Fibers are the ridges of each field: bright thin strands, not blobs.
    let ra = 1.0 - abs(a * 2.0 - 1.0);
    let rb = 1.0 - abs(b * 2.0 - 1.0);
    let rc = 1.0 - abs(c * 2.0 - 1.0);
    return (ra * ra * ra + rb * rb * rb + rc * rc * rc) / 3.0;
}

fn pl_box(p: vec2<f32>, b: vec2<f32>, r: f32) -> f32 {
    let q = abs(p) - b + r;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let h = max(frame.size.y, 1.0);
    let aspect = frame.size.x / h;
    let pt = max(frame.size.z, 0.25);
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;
    let seed = select(frame.size.w, 0.0, still);
    let t = frame.time.x;
    let mode = pa.x;

    // The sun's slow walk: the pool's center and shear move on incommensurate periods of about
    // ten minutes (drift scales them), far under a point a second.
    let tau = t * max(pb.z, 0.0) / 600.0 + seed;
    let p = px / h;
    let c = vec2<f32>(
        aspect * (0.6 + 0.07 * sin(PL_TAU * tau)),
        0.5 + 0.045 * cos(PL_TAU * tau * 0.71 + 1.3),
    );
    let shear = pb.x * 0.55 + 0.06 * sin(PL_TAU * tau * 0.83 + 0.4);
    let d0 = p - c;
    // Pool coordinates: a slight rotation, then the shear of a window projected by low sun.
    let rot = mat2x2<f32>(0.993, -0.118, 0.118, 0.993) * d0;
    let q = vec2<f32>(rot.x - shear * rot.y, rot.y);
    let b = select(vec2<f32>(0.40, 0.33), vec2<f32>(0.62, 0.46), mode > 1.5);

    // Penumbra: wider toward the pool's far (lower) side, set by softness.
    let soft = max(pa.z, 0.05);
    let far = clamp(q.y / b.y * 0.5 + 0.5, 0.0, 1.0);
    let w = soft * 0.011 * (0.6 + 1.3 * far) * select(1.0, 3.0, mode > 1.5);
    let pool = 1.0 - smoothstep(-w, w, pl_box(q, b, 0.006));

    var pattern = 1.0;
    if (mode < 0.5) {
        // Venetian blinds: slats across the pool, slightly out of parallel, sagging a little in
        // the middle, swaying a hair in a breath of air.
        let slats = max(pa.w, 2.0);
        let sway = 0.012 * sin(PL_TAU * t / 23.0 + seed * 9.0);
        let u = (q.y + b.y) / (2.0 * b.y) * slats + 0.35 * q.x - 0.9 * q.x * q.x + sway * slats;
        let f = fract(u);
        let duty = 0.6;
        let e = select(-min(f - duty, 1.0 - f), min(f, duty - f), f < duty);
        let ws = min(w / (2.0 * b.y) * slats, 0.42);
        pattern = smoothstep(-ws, ws, e);
    } else if (mode < 1.5) {
        // A sash window: one upright bar and two glazing bars across, each a soft shadow.
        let bw = 0.0085;
        let vx = smoothstep(bw - w, bw + w, abs(q.x));
        let hy1 = smoothstep(bw - w, bw + w, abs(q.y - 0.333 * b.y));
        let hy2 = smoothstep(bw - w, bw + w, abs(q.y + 0.333 * b.y));
        pattern = vx * hy1 * hy2;
    } else {
        // Leaves: dappled sun through foliage, the clusters stirring on their own small orbits
        // (many directions at once, never one coherent flow).
        let stir = 0.035 * vec2<f32>(
            sin(PL_TAU * t / 6.1 + q.y * 4.0 + seed * 7.0),
            cos(PL_TAU * t / 7.9 + q.x * 3.0),
        );
        let n = pl_fbm(q * 4.2 + stir + seed * 19.0);
        let dap = smoothstep(0.47, 0.6, n);
        let clusters = smoothstep(0.32, 0.55, pl_noise(q * 1.6 + 5.0 + stir * 0.3));
        pattern = dap * mix(0.35, 1.0, clusters);
    }

    // Thin clouds dim the sun now and then (half a minute or more to come and go).
    let cl = pl_noise(vec2<f32>(t / 37.0 + seed * 50.0, 3.7));
    let cloud = 0.86 + 0.14 * smoothstep(0.2, 0.7, cl);
    let lit = pool * pattern * cloud;
    // Bounce: a broad, faint glow around the pool, light scattered off the desk.
    let glow = 1.0 - smoothstep(-0.05, 0.35, pl_box(q, b, 0.05));

    // Paper and its grain (fixed, in points), lifted by the raking light where it falls.
    let qp = px / pt;
    let fib = pl_fibers(qp) - 0.3;
    let tooth = pl_hash(floor(px)) - 0.5;
    let cockle = pl_noise(p * 2.3 + 41.0) - 0.5;
    let grain = pb.y * (1.0 + 1.6 * lit);

    var col = mix(pl_lch(0.925, 0.016, 84.0), pl_lch(0.205, 0.015, 68.0), dark);
    // Shadow side: a breath of cool sky fill.
    col = col + vec3<f32>(0.0, -0.0015, -0.004) * (1.0 - lit);
    col.x = col.x + grain * (0.011 * fib + 0.004 * tooth) + 0.006 * cockle;

    // Sun: warm, a little stronger in dark (a low sun in a dim room), plus the bounce.
    let warm = pb.w;
    let amt = pa.y;
    let sun = pl_lch(mix(0.055, 0.06, dark), 0.032 * warm, 72.0);
    col = col + sun * amt * (lit + 0.12 * glow);

    let lin = pl_lab_to_lin(col);
    return vec4<f32>(pl_dither(lin, px), 1.0);
}
