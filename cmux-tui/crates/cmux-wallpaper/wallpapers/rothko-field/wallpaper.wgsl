// Rothko Field: two or three stacked, soft-edged rectangles of deep color on a ground. The edge
// is the whole picture: each rectangle's boundary is feathered and pushed about by low-frequency
// noise plus a dry-brush streak running along the edge (horizontal on the long edges, vertical on
// the short ones), and a faint lighter halo sits where paint thins over the ground. Each field
// breathes in luminance and edge softness at about 6 a minute, every rectangle on its own phase
// and a slightly different period, so the whole never ticks like a metronome. The pointer near a
// rectangle warms it very slightly. Colors are authored in OKLCH, mixed in OKLab, and dithered.
//
// params[0]: x palette (0 Seagram, 1 No. 61, 2 Saffron), y breath, z feather, w brush
// params[1]: x warmth (pointer), y count (2 or 3 rectangles), z chroma, w canvas grain

const RK_TAU: f32 = 6.2831853;

fn rk_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn rk_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = rk_hash(i);
    let b = rk_hash(i + vec2<f32>(1.0, 0.0));
    let c = rk_hash(i + vec2<f32>(0.0, 1.0));
    let d = rk_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Three octaves: the edge wobble wants large, slow lumps, not fizz.
fn rk_fbm(p: vec2<f32>) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < 3; i = i + 1) {
        s = s + a * rk_noise(q);
        q = mat2x2<f32>(1.6, 1.2, -1.2, 1.6) * q + vec2<f32>(17.0, 9.2);
        a = a * 0.5;
    }
    return s / 0.875;
}

fn rk_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let r = radians(h);
    return vec3<f32>(l, c * cos(r), c * sin(r));
}

fn rk_lab_to_lin(c: vec3<f32>) -> vec3<f32> {
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

// Triangular-PDF dither of +-1/255 in a gamma-2.2 space (close to the sRGB the host encodes to),
// static in screen space so a held frame and a live one match and nothing shimmers.
fn rk_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = rk_hash(px) + rk_hash(px.yx + vec2<f32>(19.19, 7.73)) - 1.0;
    let s = pow(max(lin, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2)) + vec3<f32>(n / 255.0);
    return pow(max(s, vec3<f32>(0.0)), vec3<f32>(2.2));
}

// A palette color in OKLab. i: 0 ground, 1 top field, 2 bottom field, 3 the thin middle band.
// Dark and light share hue and chroma; light lifts the ground and keeps each field's relation to
// it (Seagram's fields sit darker than its ground, Saffron's glow lighter, in both themes).
fn rk_color(pal: f32, i: i32, dark: f32, chroma: f32) -> vec3<f32> {
    var d = vec3<f32>(0.0);
    var l = 0.0;
    if (pal < 0.5) {
        // Seagram: maroon ground, black-oxblood and oxblood fields.
        if (i == 0) { d = vec3<f32>(0.235, 0.075, 22.0); l = 0.86; }
        else if (i == 1) { d = vec3<f32>(0.165, 0.038, 17.0); l = 0.745; }
        else if (i == 2) { d = vec3<f32>(0.285, 0.088, 27.0); l = 0.81; }
        else { d = vec3<f32>(0.19, 0.05, 14.0); l = 0.775; }
    } else if (pal < 1.5) {
        // No. 61: deep blue ground, a glowing blue field over a rust one.
        if (i == 0) { d = vec3<f32>(0.215, 0.075, 262.0); l = 0.845; }
        else if (i == 1) { d = vec3<f32>(0.30, 0.10, 255.0); l = 0.785; }
        else if (i == 2) { d = vec3<f32>(0.29, 0.085, 42.0); l = 0.80; }
        else { d = vec3<f32>(0.25, 0.07, 270.0); l = 0.82; }
    } else {
        // Saffron: red ground, orange and yellow-ochre fields that glow from inside.
        if (i == 0) { d = vec3<f32>(0.27, 0.11, 28.0); l = 0.80; }
        else if (i == 1) { d = vec3<f32>(0.34, 0.115, 52.0); l = 0.85; }
        else if (i == 2) { d = vec3<f32>(0.375, 0.10, 80.0); l = 0.885; }
        else { d = vec3<f32>(0.30, 0.11, 40.0); l = 0.825; }
    }
    // A light ground reads paler at the same chroma, so light keeps 85% of it.
    let c = d.y * chroma * mix(0.85, 1.0, dark);
    return rk_lch(mix(l, d.x, dark), c, d.z);
}

// Rounded box distance (units of the backdrop height) and which edge is nearer: 0 a long
// (horizontal) edge, 1 a short (vertical) one, blended softly at the corners.
fn rk_box(p: vec2<f32>, c: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    let r = 0.018;
    let q = abs(p - c) - b + r;
    let d = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
    return vec2<f32>(d, smoothstep(-0.03, 0.03, q.x - q.y));
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let h = max(frame.size.y, 1.0);
    let aspect = frame.size.x / h;
    let dark = frame.presence.w;
    let seed = frame.size.w;
    let t = frame.time.x;
    let pal = pa.x;
    let chroma = pb.z;

    // Height units, centered: x in +-aspect/2, y in -0.5 (top) .. 0.5.
    let p = (px - 0.5 * frame.size.xy) / h;
    let pp = (frame.pointer.xy - 0.5 * frame.size.xy) / h;

    // Layout: side and top margins, a narrow gap, the fields stacked top to bottom.
    let three = pb.y > 2.5;
    let mx = 0.075;
    let my = 0.072;
    let g = 0.048;
    let avail = 1.0 - 2.0 * my - select(1.0, 2.0, three) * g;
    let h1 = avail * select(0.57, 0.47, three);
    let hm = avail * select(0.0, 0.13, three);
    let h2 = avail - h1 - hm;
    let hw = max(0.5 * aspect - mx, 0.1);
    let top = -0.5 + my;
    let bottom = 0.5 - my;
    let c1 = vec2<f32>(0.0, top + 0.5 * h1);
    let b1 = vec2<f32>(hw, 0.5 * h1);
    let cm = vec2<f32>(0.0, top + h1 + g + 0.5 * hm);
    let bm = vec2<f32>(hw - 0.006, 0.5 * hm);
    let c2 = vec2<f32>(0.0, bottom - 0.5 * h2);
    let b2 = vec2<f32>(hw, 0.5 * h2);

    // One noise field serves every edge (they sit in different places): slow lumps that sway on
    // a 97 s circle so the edges seem to live without anything sliding, and a dry-brush streak
    // along each edge direction (fast across the stroke, slow along it).
    let sway = 0.09 * vec2<f32>(cos(RK_TAU * t / 97.0), sin(RK_TAU * t / 97.0));
    let o = vec2<f32>(seed * 31.0, seed * 17.0);
    let lump = rk_fbm(p * 3.1 + o + sway) - 0.5;
    let width_n = rk_noise(p * 5.3 + o.yx - sway);
    let streak_h = rk_noise(vec2<f32>(p.x * 7.0, p.y * 70.0) + o) - 0.5;
    let streak_v = rk_noise(vec2<f32>(p.x * 70.0, p.y * 7.0) + o.yx) - 0.5;
    let wash = rk_noise(p * 1.7 + o * 1.3 - sway * 0.5) - 0.5;

    let brush = pa.w;
    let feather = pa.z * 0.021 * (0.7 + 0.6 * width_n);

    // Breath: about 6 a minute, every field on its own period and phase.
    let bamt = pa.y;
    let ph = seed * RK_TAU;
    let br1 = sin(RK_TAU * t / 10.0 + ph);
    let br2 = sin(RK_TAU * t / 11.7 + ph + 2.1);
    let brm = sin(RK_TAU * t / 9.3 + ph + 4.0);
    let brg = sin(RK_TAU * t / 13.1 + ph + 1.0);

    // Ground: the deep wash every field floats on, darker toward the window's edges.
    var col = rk_color(pal, 0, dark, chroma);
    col.x = col.x + 0.012 * wash + 0.004 * bamt * brg;
    let vig = dot(p / vec2<f32>(max(aspect, 0.5), 1.0), p / vec2<f32>(max(aspect, 0.5), 1.0));
    col.x = col.x - mix(0.012, 0.03, dark) * vig;

    let warmth = pb.x * frame.presence.x;

    // The fields, top, then the thin band, then the bottom.
    for (var k = 0; k < 3; k = k + 1) {
        var c = c1;
        var b = b1;
        var br = br1;
        var idx = 1;
        if (k == 1) {
            c = cm;
            b = bm;
            br = brm;
            idx = 3;
        } else if (k == 2) {
            c = c2;
            b = b2;
            br = br2;
            idx = 2;
        }
        if (k == 1 && !three) {
            continue;
        }
        let e = rk_box(p, c, b);
        let streak = mix(streak_h, streak_v, e.y);
        let wob = brush * (0.017 * lump + 0.0075 * streak);
        let f = max(feather * (1.0 + 0.2 * bamt * br), 0.002);
        let dd = e.x + wob;
        let cov = 1.0 - smoothstep(-f, f, dd);

        var fc = rk_color(pal, idx, dark, chroma);
        // The field breathes in luminance (about 1% L) and its paint is never flat.
        fc.x = fc.x + 0.011 * bamt * br + 0.02 * brush * wash * (0.6 + 0.4 * f32(k));
        // The pointer near the field warms it: a touch toward orange and up, eased by presence.
        let dp = rk_box(pp, c, b).x;
        let warm = warmth * (1.0 - smoothstep(0.0, 0.2, dp));
        fc = fc + warm * vec3<f32>(0.007, 0.011, 0.009);

        // The scumbled edge: where the paint thins over the ground it reads a little lighter,
        // halfway between the two colors.
        let halo = exp(-(dd * dd) / (2.6 * f * f));
        let edge_c = mix(col, fc, 0.5) + vec3<f32>(mix(0.014, 0.02, dark), 0.0, 0.0);
        col = mix(col, edge_c, 0.55 * halo * (1.0 - cov) * brush);
        col = mix(col, fc, cov);
    }

    // Canvas: a fixed, faint tooth; no time term, so it never shimmers.
    let tooth = rk_noise(px * 0.9 / max(frame.size.z, 0.25)) - 0.5;
    col.x = col.x + pb.w * 0.007 * tooth;

    let lin = rk_lab_to_lin(col);
    return vec4<f32>(rk_dither(lin, px), 1.0);
}
