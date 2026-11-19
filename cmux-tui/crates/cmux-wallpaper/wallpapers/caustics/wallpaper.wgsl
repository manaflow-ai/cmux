// Pool: the floor of a pool at noon, under light focused by a slowly rippling surface. The
// caustic network is two layers of cellular edges (Worley F2 - F1, the bright seams between
// cells, with each feature point circling slowly on its own phase) at different scales and
// angles, both seen through the same gentle surface swell, so the seams curve and the two nets
// interlace; where they cross the light is brightest, as in a real pool. Each color channel takes
// a slightly different line width, so the bright seams carry a soft chromatic fringe. The floor
// (tiles with grout, or rippled sand) is seen through the water, refracted less than the light.
// When the pointer comes to rest a slow ring spreads from it and bends the light as it passes.
// Light is applied in linear light (the floor's albedo times ambient plus caustic light); the
// palettes are authored in OKLCH. Dithered. Pure function of `frame` and `px`.
//
// params[0]: x palette (0 Noon, 1 Night Pool, 2 Shallows), y caustic scale, z speed, w caustic strength
// params[1]: x chromatic fringe, y ring ripple

const CA_TAU: f32 = 6.2831853;

fn ca_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn ca_hash2(p: vec2<f32>) -> vec2<f32> {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

fn ca_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = ca_hash(i);
    let b = ca_hash(i + vec2<f32>(1.0, 0.0));
    let c = ca_hash(i + vec2<f32>(0.0, 1.0));
    let d = ca_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Distance to the nearest cell seam (F2 - F1) of a 3 x 3 Worley search whose feature points
// circle slowly, each with its own rate and phase.
fn ca_seam(p: vec2<f32>, t: f32) -> f32 {
    let i = floor(p);
    let f = fract(p);
    var f1 = 9.0;
    var f2 = 9.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            let g = vec2<f32>(f32(x), f32(y));
            let hh = ca_hash2(i + g);
            let o = 0.5 + 0.4 * sin(vec2<f32>(t) * (0.5 + 0.5 * hh.yx) + CA_TAU * hh);
            let d = g + o - f;
            let dd = dot(d, d);
            if (dd < f1) {
                f2 = f1;
                f1 = dd;
            } else if (dd < f2) {
                f2 = dd;
            }
        }
    }
    return sqrt(f2) - sqrt(f1);
}

fn ca_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let a = h * 0.017453293;
    return vec3<f32>(l, c * cos(a), c * sin(a));
}

fn ca_to_lin(c: vec3<f32>) -> vec3<f32> {
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

fn ca_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = ca_hash(px) + ca_hash(px + vec2<f32>(37.1, 91.7)) - 1.0;
    let s = max(sqrt(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0))) + vec3<f32>(n / 255.0), vec3<f32>(0.0));
    return s * s;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pal = i32(round(pa.x));
    let cscale = max(pa.y, 0.3);
    let speed = pa.z;
    let strength = pa.w;
    let fringe = pb.x;
    let ripple = pb.y;
    let dark = frame.presence.w;
    let h = frame.size.y;
    let aspect = frame.size.x / h;
    let uv = px / h;
    let t = frame.time.x * speed + frame.size.w * 300.0;
    let still = frame.time.w > 0.5;

    // The surface swell: a smooth, slow warp of where each pixel's light came from.
    var w = 0.035 * vec2<f32>(
        sin(uv.y * 5.1 + t * 0.37 + sin(uv.x * 3.3 - t * 0.23)),
        sin(uv.x * 4.7 - t * 0.31 + sin(uv.y * 2.9 + t * 0.19))
    );

    // A ring from where the pointer came to rest: radius grows 0.045 heights a second, the ring
    // fades in over 0.5 s and out over ~5 s. (While the pointer moves, presence.y stays near 0
    // and the ring has no amplitude.)
    let age = select(frame.presence.y, 0.0, still);
    let ring_amp = ripple * frame.presence.x * smoothstep(0.0, 0.5, age) * exp(-age * 0.4);
    let rc = uv - frame.pointer.xy / h;
    let rd = length(rc);
    let dr = rd - (0.02 + 0.045 * age);
    let ring = exp(-dr * dr / 0.0025) * ring_amp;
    w = w + (rc / max(rd, 1e-4)) * (sin(dr * 60.0) * ring * 0.012);

    // Two caustic nets through the same surface.
    let pw = uv + w;
    let cells = 3.0 * cscale;
    let p1 = pw * cells;
    let p2 = vec2<f32>(0.80 * pw.x - 0.60 * pw.y, 0.60 * pw.x + 0.80 * pw.y) * cells * 1.55 + vec2<f32>(7.3, 2.1);
    let e1 = ca_seam(p1, t * 0.30);
    let e2 = ca_seam(p2, t * 0.36 + 3.0);
    // Line widths per channel (red widest), so seams carry a soft chromatic fringe.
    let wv = 0.075 * vec3<f32>(1.0 + 0.30 * fringe, 1.0, 1.0 - 0.25 * fringe);
    let w2 = wv * wv;
    let i1 = exp(-vec3<f32>(e1 * e1) / w2);
    let i2 = exp(-vec3<f32>(e2 * e2) / (w2 * 0.8));
    var light = (i1 + 0.7 * i2 + 1.2 * i1 * i2) / 2.9;
    // Large, slow dapple (the surface is never even) and the ring's own glint.
    let dapple = 0.75 + 0.25 * sin(uv.x * 1.3 + t * 0.05) * sin(uv.y * 1.1 - t * 0.04 + 1.0);
    light = light * dapple + vec3<f32>(ring * 0.12);

    // The floor, refracted less than the light.
    let fc = uv + 0.4 * w;
    var floor_lab = vec3<f32>(0.0);
    var grout_lab = vec3<f32>(0.0);
    var tint = vec3<f32>(1.0);
    var amb = 0.0;
    var gain = 0.0;
    var tiles = true;
    if (pal <= 0) {
        floor_lab = mix(ca_lch(0.86, 0.045, 205.0), ca_lch(0.27, 0.060, 228.0), dark);
        grout_lab = mix(ca_lch(0.80, 0.035, 210.0), ca_lch(0.23, 0.050, 230.0), dark);
        tint = vec3<f32>(1.0, 0.98, 0.92);
        amb = mix(0.90, 0.78, dark);
        gain = mix(0.50, 1.6, dark);
    } else if (pal == 1) {
        floor_lab = mix(ca_lch(0.80, 0.040, 195.0), ca_lch(0.19, 0.045, 200.0), dark);
        grout_lab = mix(ca_lch(0.75, 0.035, 200.0), ca_lch(0.16, 0.040, 205.0), dark);
        tint = vec3<f32>(0.55, 1.0, 0.92);
        amb = mix(0.88, 0.70, dark);
        gain = mix(0.45, 2.4, dark);
    } else {
        floor_lab = mix(ca_lch(0.88, 0.035, 80.0), ca_lch(0.27, 0.035, 75.0), dark);
        grout_lab = floor_lab;
        tint = vec3<f32>(1.0, 0.97, 0.88);
        amb = mix(0.90, 0.78, dark);
        gain = mix(0.50, 1.6, dark);
        tiles = false;
    }

    var albedo = floor_lab;
    if (tiles) {
        // Tiles 7 to a height, each a touch different, with soft grout.
        let tp = fc * 7.0;
        let ed = abs(fract(tp) - 0.5);
        let edge = 0.5 - max(ed.x, ed.y);
        let grout = 1.0 - smoothstep(0.02, 0.05, edge);
        albedo.x = albedo.x + (ca_hash(floor(tp)) - 0.5) * 0.012;
        albedo = mix(albedo, grout_lab, grout * 0.8);
    } else {
        // Sand: soft wind ripples and a fixed fine grain.
        let rp = sin(dot(fc, vec2<f32>(0.45, 0.89)) * 38.0 + 2.5 * ca_noise(fc * 2.5));
        albedo.x = albedo.x + rp * 0.012 + (ca_hash(floor(px * 0.75)) - 0.5) * 0.010;
    }

    // Night Pool: one lamp low on the left wall lights the water; caustics are strongest near it.
    var lamp = 0.0;
    if (pal == 1) {
        let ld = uv - vec2<f32>(aspect * 0.12, 1.05);
        lamp = exp(-dot(ld, ld) / 0.6);
        gain = gain * (0.35 + 0.9 * lamp);
    }

    let base = ca_to_lin(albedo);
    var col = base * (vec3<f32>(amb) + gain * strength * light * tint);
    col = col + tint * lamp * mix(0.0, 0.018, dark);
    return vec4<f32>(ca_dither(col, px), 1.0);
}
