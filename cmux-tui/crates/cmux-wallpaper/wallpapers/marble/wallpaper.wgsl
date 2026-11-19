// Marble: polished stone that breathes. A double domain warp (Quilez's "warping" construction:
// fbm of p warped by fbm of p warped by fbm of p) makes the stone's body; its warped level lines
// are the veins. Each vein is a sharp core with a wide, faint halo of the same mineral, which
// reads as color seen a little way into the stone (subsurface); a second network of hairlines
// comes from the middle warp. The warp's inner offsets drift a few points a second, so the veins
// slowly creep and re-route; the halos breathe at ~10 s with a jittered period. A broad soft
// sheen (a polished slab is flat, so the reflection needs no normals) sits at rest upper left
// and eases to the pointer while it is over the window. Mixed in OKLab, dithered. Pure function
// of `frame` and `px`.
//
// params[0]: x palette (0 Calacatta, 1 Nero, 2 Verde), y vein scale, z drift speed, w vein contrast
// params[1]: x sheen, y warp strength

fn mb_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn mb_hash2(p: vec2<f32>) -> vec2<f32> {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

fn mb_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mb_hash(i);
    let b = mb_hash(i + vec2<f32>(1.0, 0.0));
    let c = mb_hash(i + vec2<f32>(0.0, 1.0));
    let d = mb_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two independent value noises on one lattice (one pass of hashes).
fn mb_noise2(p: vec2<f32>) -> vec2<f32> {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mb_hash2(i);
    let b = mb_hash2(i + vec2<f32>(1.0, 0.0));
    let c = mb_hash2(i + vec2<f32>(0.0, 1.0));
    let d = mb_hash2(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Octave step: rotate ~37 degrees and double, so lattice axes never line up.
fn mb_next(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.02 + vec2<f32>(3.1, 1.7);
}

// 3-octave vector fbm, centered on 0 (about -0.5..0.5).
fn mb_fbm2(p0: vec2<f32>) -> vec2<f32> {
    var p = p0;
    var s = vec2<f32>(0.0);
    var a = 0.5;
    for (var i = 0; i < 3; i = i + 1) {
        s = s + a * mb_noise2(p);
        p = mb_next(p);
        a = a * 0.5;
    }
    return s / 0.875 - 0.5;
}

// 4-octave scalar fbm, about 0..1 around 0.5.
fn mb_fbm(p0: vec2<f32>) -> f32 {
    var p = p0;
    var s = 0.0;
    var a = 0.5;
    for (var i = 0; i < 4; i = i + 1) {
        s = s + a * mb_noise(p);
        p = mb_next(p);
        a = a * 0.5;
    }
    return s / 0.9375;
}

fn mb_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let a = h * 0.017453293;
    return vec3<f32>(l, c * cos(a), c * sin(a));
}

fn mb_to_lin(c: vec3<f32>) -> vec3<f32> {
    let l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;
    return vec3<f32>(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );
}

fn mb_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = mb_hash(px) + mb_hash(px + vec2<f32>(37.1, 91.7)) - 1.0;
    let s = max(sqrt(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0))) + vec3<f32>(n / 255.0), vec3<f32>(0.0));
    return s * s;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pal = i32(round(pa.x));
    let scale = max(pa.y, 0.3);
    let drift = pa.z;
    let contrast = pa.w;
    let sheen_amt = pb.x;
    let warp = pb.y;
    let dark = frame.presence.w;
    let h = frame.size.y;
    let aspect = frame.size.x / h;
    let uv = px / h;
    let now = frame.time.x;
    let seed = frame.size.w;

    // The warp. Only the inner offsets move (a few points a second), so the stone re-routes
    // its veins slowly instead of sliding.
    let tau = now * drift * 0.006;
    let p = uv * scale + vec2<f32>(seed * 31.0, seed * 17.0);
    let q = mb_fbm2(p + vec2<f32>(0.0, tau));
    let r = mb_fbm2(p + warp * 2.2 * q + vec2<f32>(1.7 + tau * 0.6, 9.2 - tau * 0.4));
    let s = mb_fbm(p + warp * 2.6 * r + vec2<f32>(8.3 - tau * 0.3, 2.8));

    // Veins: the warped level s = 0.5 (main, with a halo of the same mineral under the polish),
    // a fainter second level, and hairlines where the middle warp crosses zero.
    let breath = 1.0 + 0.12 * sin(now * 0.598 + 0.8 * sin(now * 0.031) + seed * 6.0);
    let m1 = abs(s - 0.5 + 0.10 * q.x);
    let core = exp(-(m1 * m1) / 0.00012);
    let halo = exp(-(m1 * m1) / 0.0030) * breath;
    let m2 = abs(s - 0.63);
    let core2 = exp(-(m2 * m2) / 0.00004) * 0.6;
    let m3 = abs(r.y + 0.08 * q.y);
    // Hairlines only in part of the slab, so the stone has quiet passages.
    let hair = exp(-(m3 * m3) / 0.00003) * 0.55 * smoothstep(-0.08, 0.2, q.y - 0.3 * r.x);
    let cloud = smoothstep(-0.3, 0.3, q.x + r.x);

    // Palettes (OKLCH): body, clouded body, halo, vein, hairline; light then dark.
    // The palette index is uniform, so only one branch runs.
    var body = vec3<f32>(0.0);
    var body2 = vec3<f32>(0.0);
    var halo_c = vec3<f32>(0.0);
    var vein = vec3<f32>(0.0);
    var hair_c = vec3<f32>(0.0);
    if (pal <= 0) {
        body = mix(mb_lch(0.955, 0.006, 85.0), mb_lch(0.235, 0.006, 80.0), dark);
        body2 = mix(mb_lch(0.915, 0.010, 80.0), mb_lch(0.205, 0.008, 75.0), dark);
        halo_c = mix(mb_lch(0.885, 0.022, 80.0), mb_lch(0.275, 0.022, 78.0), dark);
        vein = mix(mb_lch(0.70, 0.075, 78.0), mb_lch(0.46, 0.070, 80.0), dark);
        hair_c = mix(mb_lch(0.75, 0.012, 250.0), mb_lch(0.33, 0.010, 250.0), dark);
    } else if (pal == 1) {
        body = mix(mb_lch(0.80, 0.004, 260.0), mb_lch(0.165, 0.004, 260.0), dark);
        body2 = mix(mb_lch(0.765, 0.005, 262.0), mb_lch(0.145, 0.005, 270.0), dark);
        halo_c = mix(mb_lch(0.725, 0.006, 260.0), mb_lch(0.205, 0.006, 260.0), dark);
        vein = mix(mb_lch(0.52, 0.006, 260.0), mb_lch(0.47, 0.008, 250.0), dark);
        hair_c = mix(mb_lch(0.62, 0.004, 260.0), mb_lch(0.31, 0.005, 250.0), dark);
    } else {
        body =mix(mb_lch(0.88, 0.030, 165.0), mb_lch(0.235, 0.045, 168.0), dark);
        body2 = mix(mb_lch(0.84, 0.040, 170.0), mb_lch(0.200, 0.050, 175.0), dark);
        halo_c = mix(mb_lch(0.80, 0.040, 165.0), mb_lch(0.280, 0.050, 165.0), dark);
        vein = mix(mb_lch(0.52, 0.075, 170.0), mb_lch(0.50, 0.040, 155.0), dark);
        hair_c = mix(mb_lch(0.70, 0.030, 150.0), mb_lch(0.40, 0.020, 140.0), dark);
    }

    var lab = mix(body, body2, cloud);
    lab = mix(lab, halo_c, clamp(halo * 0.55 * contrast, 0.0, 1.0));
    lab = mix(lab, hair_c, clamp(hair * contrast, 0.0, 1.0));
    lab = mix(lab, vein, clamp((core + core2) * 0.9 * contrast, 0.0, 1.0));

    // Sheen: a broad reflection plus a tighter one, at rest upper left, easing to the pointer
    // with presence; the veins are a little less polished than the body.
    let rest = vec2<f32>(aspect * 0.28, 0.22);
    let lp = mix(rest, frame.pointer.xy / h, frame.presence.x);
    let dl = uv - lp;
    let d2 = dot(dl, dl);
    let gloss = (0.7 * exp(-d2 / 0.22) + 0.35 * exp(-d2 / 0.02)) * (1.0 - 0.45 * core) * sheen_amt;
    lab.x = lab.x + gloss * mix(0.028, 0.045, dark);
    lab = vec3<f32>(lab.x, lab.yz * (1.0 - 0.25 * gloss));

    return vec4<f32>(mb_dither(mb_to_lin(lab), px), 1.0);
}
