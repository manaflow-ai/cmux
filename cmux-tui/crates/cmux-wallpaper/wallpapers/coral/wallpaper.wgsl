// Coral: the look of Gray-Scott reaction-diffusion (labyrinth stripes and budding spots) with
// no simulation and no state. A Turing pattern is, to first order, a random superposition of
// the modes at one critical wavenumber, so the field here is exactly that: 12 plane waves of
// one wavelength in evenly spread directions with hashed phases, domain-warped by a slow
// 2-octave noise so the stripes bend and branch organically instead of reading as a
// quasicrystal. Thresholding it at 0 gives the labyrinth; thresholding it high gives isolated
// spots. A growth field sweeps that threshold: a slow wave radiating from a seed point (one
// cycle every `growth` minutes per place, the front moving about 1 point a second) turns bare
// spots into budding worms into a full labyrinth and, much later, thins it again. The phases
// creep at about 0.1 point a second, so stripes reconnect slowly. Shading: a deeper, more
// saturated rim and a lighter (in dark: glowing) core, a faint emboss from the field's analytic
// gradient, and a soft scattered halo just outside each stripe, so it reads as translucent
// tissue. The pointer feeds growth under it.
//
// params[0]: x wavelength (points), y contrast, z coral -> accent, w growth cycle (minutes)
// params[1]: x warp, y speed, z paper tint, w halo

const CO_PI: f32 = 3.14159265;
const CO_TAU: f32 = 6.2831853;
// Plane waves in the field.
const CO_WAVES: i32 = 12;
// The pointer's feeding radius, in points.
const CO_FEED_PT: f32 = 160.0;

fn co_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = co_hash(i);
    let b = co_hash(i + vec2<f32>(1.0, 0.0));
    let c = co_hash(i + vec2<f32>(0.0, 1.0));
    let d = co_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn co_fbm2(p: vec2<f32>) -> f32 {
    return 0.65 * co_noise(p) + 0.35 * co_noise(p * 2.03 + vec2<f32>(3.1, 7.7));
}

// Color: palettes are mixed in OKLab (Ottosson 2020) and converted back to linear sRGB.
fn co_lab(c: vec3<f32>) -> vec3<f32> {
    let l = dot(c, vec3<f32>(0.4122214708, 0.5363325363, 0.0514459929));
    let m = dot(c, vec3<f32>(0.2119034982, 0.6806995451, 0.1073969566));
    let s = dot(c, vec3<f32>(0.0883024619, 0.2817188376, 0.6299787005));
    let q = pow(max(vec3<f32>(l, m, s), vec3<f32>(1e-9)), vec3<f32>(1.0 / 3.0));
    return vec3<f32>(
        dot(q, vec3<f32>(0.2104542553, 0.7936177850, -0.0040720468)),
        dot(q, vec3<f32>(1.9779984951, -2.4285922050, 0.4505937099)),
        dot(q, vec3<f32>(0.0259040371, 0.7827717662, -0.8086757660)),
    );
}

fn co_rgb(o: vec3<f32>) -> vec3<f32> {
    let l1 = o.x + 0.3963377774 * o.y + 0.2158037573 * o.z;
    let m1 = o.x - 0.1055613458 * o.y - 0.0638541728 * o.z;
    let s1 = o.x - 0.0894841775 * o.y - 1.2914855480 * o.z;
    let l = l1 * l1 * l1;
    let m = m1 * m1 * m1;
    let s = s1 * s1 * s1;
    return vec3<f32>(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    );
}

// The accent's OKLab hue as a unit vector in the a/b plane, turned by `deg` degrees.
fn co_hue_dir(acc: vec3<f32>, deg: f32) -> vec2<f32> {
    let c = length(acc.yz);
    let d = select(vec2<f32>(1.0, 0.0), acc.yz / max(c, 1e-6), c > 1e-4);
    let a = radians(deg);
    let cs = cos(a);
    let sn = sin(a);
    return vec2<f32>(cs * d.x - sn * d.y, sn * d.x + cs * d.y);
}

fn co_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Triangular-PDF dither of +-1 LSB in the encoded (sRGB) space the host writes, then back to
// linear. Static in time (keyed on the pixel only): it kills banding without animated grain.
fn co_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = (co_hash(px) + co_hash(px + vec2<f32>(19.19, 47.31)) - 1.0) / 255.0;
    let s = max(enc + vec3<f32>(n), vec3<f32>(0.0));
    return select(pow((s + 0.055) / 1.055, vec3<f32>(2.4)), s / 12.92, s <= vec3<f32>(0.04045));
}

// Coverage of a line of half width `w` px at distance `d` px: a 1 px box filter, and a line
// thinner than a pixel keeps its ink by fading instead of breaking up.
fn co_line(d: f32, w: f32) -> f32 {
    let wd = max(w, 0.5);
    return clamp(wd + 0.5 - d, 0.0, 1.0) * (w / wd);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pt = max(frame.size.z, 0.25);
    let seed = frame.size.w;
    let dark = frame.presence.w;
    let center = frame.size.xy * 0.5;
    let q = (px - center) / pt;
    let t = frame.time.x * pb.y;
    let lam = max(pa.x, 4.0);

    // The warp: two slow 2-octave noises, about 2 wavelengths deep.
    let wq = q / (lam * 8.0) + vec2<f32>(seed * 13.0, seed * 7.0);
    let warp = vec2<f32>(
        co_fbm2(wq + vec2<f32>(t * 0.0015, 0.0)),
        co_fbm2(wq + vec2<f32>(5.2, 1.3) - vec2<f32>(0.0, t * 0.0012)),
    ) - 0.5;
    let p = q + warp * (lam * 4.0 * pb.x);

    // The Turing field: 12 waves of wavelength lam, RMS 1, with its gradient (per point).
    let k0 = CO_TAU / lam;
    var n = 0.0;
    var gv = vec2<f32>(0.0);
    for (var i = 0; i < CO_WAVES; i = i + 1) {
        let fi = f32(i);
        let ha = co_hash(vec2<f32>(fi * 7.13 + 0.5, seed * 31.0 + 2.0));
        let hp = co_hash(vec2<f32>(fi * 3.71 + 9.2, seed * 17.0 + 4.0));
        let ang = (fi + 0.6 * ha) * (CO_PI / f32(CO_WAVES));
        let dir = vec2<f32>(cos(ang), sin(ang));
        let creep = (hp - 0.5) * 0.08 * t;
        let arg = k0 * dot(dir, p) + hp * CO_TAU + creep;
        n = n + cos(arg);
        gv = gv - sin(arg) * dir;
    }
    let norm = inverseSqrt(f32(CO_WAVES) * 0.5);
    n = n * norm;
    let grad = gv * (k0 * norm);

    // Growth: a slow wave from a seed point, roughened by noise, plus the pointer's feeding.
    let origin = (vec2<f32>(seed, fract(seed * 7.31)) - 0.5) * frame.size.xy / pt;
    let rho = length(q - origin) / 600.0 + 0.35 * co_noise(q / 400.0 + vec2<f32>(seed * 3.0, 9.0));
    let cycle = max(pa.w, 1.0) * 60.0;
    var grow = 0.5 + 0.5 * sin(CO_TAU * (t / cycle - 0.9 * rho) + seed * CO_TAU);
    let fd = (q - (frame.pointer.xy - center) / pt) / CO_FEED_PT;
    grow = clamp(grow + 0.35 * frame.presence.x * exp(-dot(fd, fd)), 0.0, 1.0);
    let thr = mix(1.3, -0.1, grow);

    let v = n - thr;
    let aa = max(length(grad) / pt, 1e-4);
    let body = smoothstep(-aa, aa, v);
    let core = smoothstep(0.0, 0.9, v);
    let halo = exp(-max(-v, 0.0) * 2.5) * (1.0 - body);
    let emboss = dot(grad / max(length(grad), 1e-4), vec2<f32>(-0.6, -0.8)) * (1.0 - core) * body;

    // Colors in OKLab: the paper tinted toward the accent; a rim deeper and more saturated than
    // the core; in light the core goes lighter (translucent), in dark it glows.
    let contrast = pa.y;
    let acc = co_lab(frame.accent.rgb);
    let dir = co_hue_dir(acc, 0.0);
    var paper = co_lab(frame.paper.rgb);
    paper = vec3<f32>(paper.x, paper.yz + dir * 0.04 * pb.z);
    let target_c = mix(co_lab(frame.ink.rgb), acc, pa.z);
    let rim = mix(paper, target_c, min(contrast * 1.25, 1.0));
    let core_c = mix(paper, target_c, min(contrast * mix(0.7, 1.5, dark), 1.0));
    let tissue = mix(rim, core_c, sqrt(core));
    var col = mix(paper, tissue, body);
    col = mix(col, rim, halo * pb.w * 0.3);
    col.x = col.x + emboss * 0.025 * contrast / 0.25;
    col.x = col.x + (co_hash(px * 1.37 + seed * 91.0) - 0.5) * 0.006;
    return vec4<f32>(co_dither(max(co_rgb(col), vec3<f32>(0.0)), px), 1.0);
}
