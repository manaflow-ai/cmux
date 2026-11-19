// Current (after Bridget Riley): dense, near-horizontal parallel stripes bent by two slow
// travelling waves under a slow envelope, so the stripe spacing tightens and opens across the
// field and the eye reads a vibration that the geometry barely makes. The stripes are a
// square wave in a phase field whose gradient is known analytically, and each pixel takes the
// exact 1 px box-filtered coverage of that square wave (the integral of the stripe across the
// pixel's footprint), fading to the flat mean before stripes get finer than about 2 px: no
// moire, no shimmer. Luminance contrast stays low (it sits under text; Riley's own seasickness
// reports and the photosensitivity guidance both say so). The pointer is a soft lens: stripes
// bow apart around it, eased with presence.
//
// params[0]: x stripe period (points), y duty (dark share), z contrast, w wave amplitude (points)
// params[1]: x wavelength (points), y speed, z two-tone chroma, w pointer bow

const RW_TAU: f32 = 6.2831853;
// The pointer lens radius, in points.
const RW_LENS_PT: f32 = 120.0;

// The integral of the stripe (1 where fract(x) < duty) from 0 to x.
fn rw_stripe_int(x: f32, duty: f32) -> f32 {
    return floor(x) * duty + min(fract(x), duty);
}

// Color: palettes are mixed in OKLab (Ottosson 2020) and converted back to linear sRGB.
fn rw_lab(c: vec3<f32>) -> vec3<f32> {
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

fn rw_rgb(o: vec3<f32>) -> vec3<f32> {
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
fn rw_hue_dir(acc: vec3<f32>, deg: f32) -> vec2<f32> {
    let c = length(acc.yz);
    let d = select(vec2<f32>(1.0, 0.0), acc.yz / max(c, 1e-6), c > 1e-4);
    let a = radians(deg);
    let cs = cos(a);
    let sn = sin(a);
    return vec2<f32>(cs * d.x - sn * d.y, sn * d.x + cs * d.y);
}

fn rw_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Triangular-PDF dither of +-1 LSB in the encoded (sRGB) space the host writes, then back to
// linear. Static in time (keyed on the pixel only): it kills banding without animated grain.
fn rw_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = (rw_hash(px) + rw_hash(px + vec2<f32>(19.19, 47.31)) - 1.0) / 255.0;
    let s = max(enc + vec3<f32>(n), vec3<f32>(0.0));
    return select(pow((s + 0.055) / 1.055, vec3<f32>(2.4)), s / 12.92, s <= vec3<f32>(0.04045));
}

// Coverage of a line of half width `w` px at distance `d` px: a 1 px box filter, and a line
// thinner than a pixel keeps its ink by fading instead of breaking up.
fn rw_line(d: f32, w: f32) -> f32 {
    let wd = max(w, 0.5);
    return clamp(wd + 0.5 - d, 0.0, 1.0) * (w / wd);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pt = max(frame.size.z, 0.25);
    let seed = frame.size.w;
    let center = frame.size.xy * 0.5;
    let q = (px - center) / pt;
    let t = frame.time.x * pb.y;

    // Two waves (one along x, one oblique, travelling opposite ways) and an envelope down the
    // field. Their y-slopes stay well under 1, so the stripes never fold.
    let lam = max(pb.x, 60.0);
    let amp = pa.w;
    let k1 = (RW_TAU / lam) * vec2<f32>(1.0, 0.18);
    let k2 = (RW_TAU / (lam * 1.618)) * vec2<f32>(0.8, -0.6);
    let ke = RW_TAU / (lam * 2.3);
    let th1 = dot(k1, q) + 0.05 * t + seed * RW_TAU;
    let th2 = dot(k2, q) - 0.031 * t + seed * 11.0;
    let the = ke * q.y + 0.021 * t + seed * 5.0;
    let s1 = sin(th1);
    let c1 = cos(th1);
    let s2 = sin(th2);
    let c2 = cos(th2);
    let env = 0.6 + 0.4 * sin(the);
    let env_y = 0.4 * ke * cos(the);
    let d = amp * (env * s1 + 0.45 * s2);
    let dx = amp * (env * c1 * k1.x + 0.45 * c2 * k2.x);
    let dy = amp * (env_y * s1 + env * c1 * k1.y + 0.45 * c2 * k2.y);

    // The pointer lens: y' = y - bow * (y - py) * E pushes stripes apart around it.
    let pq = (frame.pointer.xy - center) / pt;
    let dv = q - pq;
    let r2 = RW_LENS_PT * RW_LENS_PT;
    let e = clamp(pb.w, 0.0, 0.7) * frame.presence.x * exp(-dot(dv, dv) / r2);
    let b = -dv.y * e;
    let bx = 2.0 * dv.x * dv.y * e / r2;
    let by = -e * (1.0 - 2.0 * dv.y * dv.y / r2);

    // The phase field in stripes, and its gradient in stripes per pixel.
    let period = max(pa.x, 1.5);
    let phi = (q.y + d + b) / period + seed * 3.7;
    let grad = vec2<f32>(dx + bx, 1.0 + dy + by) / (period * pt);
    let fw = max(length(grad) * 1.1, 1e-4);
    let duty = clamp(pa.y, 0.1, 0.9);
    var cov = (rw_stripe_int(phi + 0.5 * fw, duty) - rw_stripe_int(phi - 0.5 * fw, duty)) / fw;
    // Finer than ~2 px: fade to the flat mean instead of aliasing.
    cov = mix(cov, duty, smoothstep(0.35, 0.75, fw));

    // Colors in OKLab: the light stripe is the paper, the dark one leans to the ink by
    // `contrast`; two-tone pushes them apart in hue (warm accent vs its opposite), not in L.
    let acc = rw_lab(frame.accent.rgb);
    let dir = rw_hue_dir(acc, 0.0);
    let chroma = 0.05 * pb.z;
    let paper = rw_lab(frame.paper.rgb);
    let ink = rw_lab(frame.ink.rgb);
    let light = vec3<f32>(paper.x, paper.yz + dir * chroma);
    let darkc = mix(paper, ink, pa.z);
    let dark_s = vec3<f32>(darkc.x, darkc.yz - dir * chroma);
    let col = mix(light, dark_s, cov);
    return vec4<f32>(rw_dither(max(rw_rgb(col), vec3<f32>(0.0)), px), 1.0);
}
