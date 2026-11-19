// Comet Dust: a fine, jittered square field of ~1 pt dots, almost invisible at rest. Where the
// pointer passes (Frame.trail), the dots along its path light up: hot at the head, cooling through
// the accent to an afterglow of a shifted hue (an OKLab gradient by age), a little light bleeding
// onto the paper around them (a wider Gaussian of the same path), a slight sparkle on a few dots
// near the head, and a slow fade that uses the whole 1 s of trail and lingers before it lets go.
// No motion of its own: a frame at rest is the same frame whenever it is drawn.
//
// params[0]: x pitch (points), y dot radius (points), z trail radius (points), w linger (0..0.9)
// params[1]: x glow, y afterglow hue shift (degrees), z field contrast, w jitter (0..0.25 cell)

const DT_SEGMENTS: i32 = 15;
const DT_PI: f32 = 3.14159265;

fn dt_hash12(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn dt_hash22(p: vec2<f32>) -> vec2<f32> {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

// Linear sRGB to OKLab and back (Ottosson 2020).
fn dt_oklab(c: vec3<f32>) -> vec3<f32> {
    let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    let q = pow(max(vec3<f32>(l, m, s), vec3<f32>(0.0)), vec3<f32>(1.0 / 3.0));
    return vec3<f32>(
        0.2104542553 * q.x + 0.7936177850 * q.y - 0.0040720468 * q.z,
        1.9779984951 * q.x - 2.4285922050 * q.y + 0.4505937099 * q.z,
        0.0259040371 * q.x + 0.7827717662 * q.y - 0.8086757660 * q.z,
    );
}

fn dt_linear(c: vec3<f32>) -> vec3<f32> {
    let l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    let q = vec3<f32>(l * l * l, m * m * m, s * s * s);
    return vec3<f32>(
        4.0767416621 * q.x - 3.3077115913 * q.y + 0.2309699292 * q.z,
        -1.2684380046 * q.x + 2.6097574011 * q.y - 0.3413193965 * q.z,
        -0.0041960863 * q.x - 0.7034186147 * q.y + 1.7076147010 * q.z,
    );
}

fn dt_rot(ab: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(c * ab.x - s * ab.y, s * ab.x + c * ab.y);
}

// A triangular (TPDF) dither of +-1 LSB in the encoded space the host writes, so slow gradients
// and soft glows never band. No time term: a held frame stays exactly the frame it was.
fn dt_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(lin, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = dt_hash12(px + 0.5) + dt_hash12(px.yx + 71.3) - 1.0;
    let e = clamp(enc + n / 255.0, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(pow((e + 0.055) / 1.055, vec3<f32>(2.4)), e / 12.92, e <= vec3<f32>(0.04045));
}

// Row `i` of the trail: (x px, y px, age s, valid). A still has no pointer history, so it draws a
// long, gentle arc of 16 points ending at the still's pointer, newest first, ages 0..0.95 s: the
// cover shows the whole gradient, head to afterglow.
fn dt_row(i: i32, still: bool) -> vec4<f32> {
    if (still) {
        let s = f32(i) / f32(DT_SEGMENTS);
        let a = frame.size.y * 0.42;
        let t0 = 1.35;
        let center = frame.pointer.xy - a * vec2<f32>(cos(t0), sin(t0));
        let t = t0 + s * 1.9;
        return vec4<f32>(center + a * vec2<f32>(cos(t), sin(t)), s * 0.95, 1.0);
    }
    return frame.trail[i];
}

// The trail's color at a point of age x (0 at the head, 1 when it is gone), in OKLab: hot at the
// head (toward white on a dark paper, deeper and fuller on a light one), the accent through the
// first third, then cooling to the accent's hue turned by `shift` and dimmed: the afterglow.
fn dt_gradient(acc: vec3<f32>, x: f32, shift: f32, dark: f32) -> vec3<f32> {
    let hot_d = vec3<f32>(mix(acc.x, 0.97, 0.5), acc.yz * 0.7);
    let hot_l = vec3<f32>(acc.x * 0.82, acc.yz * 1.1);
    let hot = mix(hot_l, hot_d, dark);
    let cool_ab = dt_rot(acc.yz, shift) * 0.85;
    let cool = vec3<f32>(acc.x * mix(0.95, 0.6, dark), cool_ab);
    let a = smoothstep(0.0, 0.3, x);
    let b = smoothstep(0.3, 1.0, x);
    return mix(mix(hot, acc, a), cool, b);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let seed = frame.size.w;
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;
    let ppt = max(frame.size.z, 0.25);

    let pitch = max(pa.x * ppt, 3.0);
    let dot_r = max(pa.y * ppt, 0.2);
    let rad = max(pa.z * ppt, 4.0);
    let linger = clamp(pa.w, 0.0, 0.9);
    let glow = pb.x;
    let shift = pb.y * DT_PI / 180.0;
    let contrast = pb.z;
    let jitter = clamp(pb.w, 0.0, 0.25);

    // The field: one dot per square cell, nudged by up to `jitter` of a cell so the grid reads as
    // dust, not graph paper. The nudge and the dot's radius (a Gaussian of at most ~3 px) keep it
    // inside its own cell, so one cell is enough.
    let cell = floor(px / pitch);
    let h = dt_hash22(cell + seed * 97.0);
    let center = (cell + 0.5 + (h - 0.5) * 2.0 * jitter) * pitch;
    let hv = dt_hash12(cell * 1.37 + 11.0 + seed * 53.0);

    // The trail, per pixel: for each segment the distance to it and the age along it. `core` is a
    // tube of radius `rad` that widens as it cools; `wide` is the same path at twice the radius
    // (the core's Gaussian to the 1/4), the light that bleeds onto the paper. The fade uses the
    // trail window: it holds until `linger` and lets go with a smoothstep that reaches zero at 0.88 s,
    // just before a full ring drops its oldest point (~0.8 s) or a row expires at 1 s, so nothing
    // pops. Rows are uniform, so skipping an empty segment is a uniform branch.
    let inv_r2 = 1.0 / (rad * rad);
    var core = 0.0;
    var wide = 0.0;
    var age_w = 1.0;
    var head = 0.0;
    var a = dt_row(0, still);
    if (a.w > 0.5) {
        let d = px - a.xy;
        let x = clamp(a.z, 0.0, 1.0);
        let f = 1.0 - smoothstep(linger * 0.88, 0.88, x);
        let g = exp(-dot(d, d) * inv_r2 / 0.5625);
        core = g * f;
        wide = sqrt(sqrt(g)) * f;
        age_w = x;
        head = exp(-dot(d, d) * inv_r2 * 1.6) * f;
    }
    for (var i = 0; i < DT_SEGMENTS; i = i + 1) {
        let b = dt_row(i + 1, still);
        if (a.w * b.w > 0.5) {
            let ab = b.xy - a.xy;
            let t = clamp(dot(px - a.xy, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
            let d = px - (a.xy + ab * t);
            let x = clamp(mix(a.z, b.z, t), 0.0, 1.0);
            let spread = 0.75 + 0.75 * x;
            let g = exp(-dot(d, d) * inv_r2 / (spread * spread));
            let f = 1.0 - smoothstep(linger * 0.88, 0.88, x);
            core = max(core, g * f);
            let w = sqrt(sqrt(g)) * f;
            if (w > wide) {
                wide = w;
                age_w = x;
            }
        }
        a = b;
    }
    let inside = select(frame.presence.x, 1.0, still);
    let lit = clamp(core * inside * glow, 0.0, 1.0);
    let bloom = wide * inside * glow;
    head = head * inside;

    // Awareness: around a resting pointer the field shows a little more, so the room keeps
    // noticing where you are after the trail has gone.
    let dp = px - frame.pointer.xy;
    let aware = inside * exp(-dot(dp, dp) * inv_r2 / 6.25);

    // A few dots near the head sparkle: a slow per-dot shimmer (about 1 Hz), only while the head
    // is there, so it is gone with the trail.
    let tw = 0.5 + 0.5 * sin(frame.time.x * 6.5 + hv * 40.0);
    let sparkle = head * smoothstep(0.78, 0.92, hv) * tw;

    // The dot: a Gaussian whose energy is kept when it is smaller than a pixel (so a 1 pt dot
    // never aliases, it just gets fainter), grown when lit.
    let r = dot_r * (1.0 + 1.4 * lit + 1.4 * sparkle);
    let sigma = max(r, 0.6);
    let dd = px - center;
    let cov = exp(-dot(dd, dd) / (sigma * sigma)) * min(1.0, (r * r) / (sigma * sigma));

    // Ink at very low contrast at rest (more of it on a light paper for the same apparent
    // contrast), with a fixed per-dot variation; lit dots go to the trail's color.
    let rest = contrast * mix(1.7, 1.0, dark) * (0.55 + 0.45 * hv) * (1.0 + 1.2 * aware);
    let peak = mix(0.85, 0.78, dark);
    let alpha = clamp(rest + (peak - rest) * smoothstep(0.0, 0.9, lit) + 0.25 * sparkle, 0.0, 1.0);

    let paper = dt_oklab(frame.paper.rgb);
    let ink = dt_oklab(frame.ink.rgb);
    let acc = dt_oklab(frame.accent.rgb);
    let trail = dt_gradient(acc, age_w, shift, dark);
    let spark = mix(vec3<f32>(trail.x * 0.8, trail.yz * 1.15), vec3<f32>(0.99, trail.yz * 0.2), dark);
    let tone = mix(mix(ink, trail, smoothstep(0.03, 0.5, lit)), spark, clamp(sparkle, 0.0, 1.0));

    // Bleed: on a light paper the path tints the paper; on a dark one it adds light.
    let tinted = mix(paper, trail, bloom * 0.09 * (1.0 - dark));
    let lab = mix(tinted, tone, cov * alpha);
    var lin = max(dt_linear(lab), vec3<f32>(0.0));
    lin = lin + max(dt_linear(trail), vec3<f32>(0.0)) * (bloom * 0.05 + head * 0.03) * dark;
    return vec4<f32>(dt_dither(lin, px), 1.0);
}
