// Contours: a topographic map of a height field that is slowly thinking. The height is a
// 4-octave fbm of 3D value noise whose third axis is time (very slow, each finer octave a
// little faster), so hills swell, merge and part instead of sliding. Every contour is drawn
// at a constant width in pixels from the field's analytic gradient (the noise returns its
// derivatives), every 5th contour is a heavier index line, minor lines fade out where they
// would crowd below a few pixels (cartographic generalisation, and no moire), and the paper
// under them takes a faint hypsometric tint and hillshade. The pointer raises a gentle hill.
//
// params[0]: x contour lines per unit of height, y line width (points), z contrast, w speed
// params[1]: x pointer hill, y line -> accent, z paper tint, w tint hue turn (degrees)

// One unit of the field, in points.
const CT_UNIT_PT: f32 = 300.0;
// The pointer hill's radius, in field units (150 points).
const CT_HILL_R: f32 = 0.5;

fn ct_hash3(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q = q + dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

// 3D value noise with its analytic gradient (Quilez): x value 0..1, yz d/dx, d/dy.
fn ct_noised(x: vec3<f32>) -> vec3<f32> {
    let i = floor(x);
    let f = fract(x);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    let a = ct_hash3(i);
    let b = ct_hash3(i + vec3<f32>(1.0, 0.0, 0.0));
    let c = ct_hash3(i + vec3<f32>(0.0, 1.0, 0.0));
    let d = ct_hash3(i + vec3<f32>(1.0, 1.0, 0.0));
    let e = ct_hash3(i + vec3<f32>(0.0, 0.0, 1.0));
    let g = ct_hash3(i + vec3<f32>(1.0, 0.0, 1.0));
    let h = ct_hash3(i + vec3<f32>(0.0, 1.0, 1.0));
    let k = ct_hash3(i + vec3<f32>(1.0, 1.0, 1.0));
    let k1 = b - a;
    let k2 = c - a;
    let k3 = e - a;
    let k4 = a - b - c + d;
    let k5 = a - c - e + h;
    let k6 = a - b - e + g;
    let k7 = -a + b + c - d + e - g - h + k;
    let v = a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z
        + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
    let gx = du.x * (k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z);
    let gy = du.y * (k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x);
    return vec3<f32>(v, gx, gy);
}

// Color: palettes are mixed in OKLab (Ottosson 2020) and converted back to linear sRGB.
fn ct_lab(c: vec3<f32>) -> vec3<f32> {
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

fn ct_rgb(o: vec3<f32>) -> vec3<f32> {
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
fn ct_hue_dir(acc: vec3<f32>, deg: f32) -> vec2<f32> {
    let c = length(acc.yz);
    let d = select(vec2<f32>(1.0, 0.0), acc.yz / max(c, 1e-6), c > 1e-4);
    let a = radians(deg);
    let cs = cos(a);
    let sn = sin(a);
    return vec2<f32>(cs * d.x - sn * d.y, sn * d.x + cs * d.y);
}

fn ct_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Triangular-PDF dither of +-1 LSB in the encoded (sRGB) space the host writes, then back to
// linear. Static in time (keyed on the pixel only): it kills banding without animated grain.
fn ct_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = (ct_hash(px) + ct_hash(px + vec2<f32>(19.19, 47.31)) - 1.0) / 255.0;
    let s = max(enc + vec3<f32>(n), vec3<f32>(0.0));
    return select(pow((s + 0.055) / 1.055, vec3<f32>(2.4)), s / 12.92, s <= vec3<f32>(0.04045));
}

// Coverage of a line of half width `w` px at distance `d` px: a 1 px box filter, and a line
// thinner than a pixel keeps its ink by fading instead of breaking up.
fn ct_line(d: f32, w: f32) -> f32 {
    let wd = max(w, 0.5);
    return clamp(wd + 0.5 - d, 0.0, 1.0) * (w / wd);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pt = max(frame.size.z, 0.25);
    let seed = frame.size.w;
    let unit = CT_UNIT_PT * pt;
    let center = frame.size.xy * 0.5;
    let offset = vec2<f32>(seed * 53.1 + 11.3, seed * 17.7 + 5.9);
    let p = (px - center) / unit + offset;
    let z = frame.time.x * 0.011 * pa.w;

    // fbm: each octave rotated 37 degrees and scaled 2.03 (so the value grid never lines up),
    // its gradient carried back through the octave's matrix (d/dp = M^T d/dq).
    var h = 0.0;
    var g = vec2<f32>(0.0);
    var amp = 0.5;
    var m = mat2x2<f32>(0.955, 0.296, -0.296, 0.955);
    let step_m = mat2x2<f32>(1.6212, 1.2217, -1.2217, 1.6212);
    for (var i = 0; i < 4; i = i + 1) {
        let fi = f32(i);
        let n = ct_noised(vec3<f32>(m * p, z * (1.0 + 0.6 * fi) + fi * 7.31));
        h = h + amp * (2.0 * n.x - 1.0);
        g = g + amp * 2.0 * (transpose(m) * n.yz);
        m = step_m * m;
        amp = amp * 0.5;
    }

    // The pointer's hill: a Gaussian bump, eased in and out with presence.
    let pp = (frame.pointer.xy - center) / unit + offset;
    let dv = p - pp;
    let r2 = CT_HILL_R * CT_HILL_R;
    let bump = 0.45 * pb.x * frame.presence.x * exp(-dot(dv, dv) / r2);
    h = h + bump;
    g = g + bump * (-2.0 * dv / r2);

    // Contours in pixels: n counts contour intervals; its gradient is cycles per pixel.
    let levels = max(pa.x, 1.0);
    let n = h * levels;
    let gpx = max(length(g) * levels / unit, 1e-6);
    let k = round(n);
    let index = abs(k - 5.0 * round(k / 5.0)) < 0.5;
    let dist = abs(n - k) / gpx;
    let spacing = 1.0 / gpx;
    let w = 0.5 * pa.y * pt * select(1.0, 1.9, index);
    // Minor lines go before they crowd; index lines (5 intervals apart) hold on longer.
    let fade = select(smoothstep(3.0, 7.0, spacing), smoothstep(2.0, 4.5, spacing * 5.0), index);
    let cov = ct_line(dist, w) * fade;

    // Colors in OKLab: the theme's paper, tinted toward the accent's hue (turned), with a faint
    // hypsometric shift by height and a faint hillshade lit from the upper left.
    let contrast = pa.z;
    let acc = ct_lab(frame.accent.rgb);
    let dir = ct_hue_dir(acc, pb.w);
    var paper = ct_lab(frame.paper.rgb);
    paper = vec3<f32>(paper.x, paper.yz + dir * (0.05 * pb.z + 0.012 * pb.z * h));
    paper.x = paper.x + h * 0.06 * contrast;
    let shade = clamp(dot(g, vec2<f32>(-0.6, -0.8)), -2.5, 2.5);
    paper.x = paper.x + shade * 0.028 * contrast;
    // Static paper tooth: no time term, so it never shimmers.
    paper.x = paper.x + (ct_hash(px * 1.37 + seed * 91.0) - 0.5) * 0.008;

    let ink = mix(ct_lab(frame.ink.rgb), acc, pb.y);
    let alpha = select(contrast, min(contrast * 1.6, 0.9), index);
    let col = mix(paper, ink, cov * alpha);
    return vec4<f32>(ct_dither(max(ct_rgb(col), vec3<f32>(0.0)), px), 1.0);
}
