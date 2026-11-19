// Truchet: quarter-circle Truchet tiles whose arcs join across tile edges into continuous
// rivers, drawn as two thin banks with a faint water between them. Every tile turns a
// quarter turn on its own long clock, so the pattern rearranges while you are not looking:
// tile c has a phase from a smooth noise over the grid (plus a little hash), and with period P
// its state at time t is the count floor(t / P + phase) of quarter turns so far, the newest one
// easing through its first few seconds. All of it is a pure function of time: no state. Since
// neighbours' phases are close, turns travel across the field as a slow front, a few tiles at
// a time. A turning tile rotates in its slot (its corners clip at the cell edge) and its banks
// warm toward the accent for the turn. A slow, faint glow drifts through the water; the
// pointer adds a soft pool of it.
//
// params[0]: x tile size (points), y line width (points), z river half-width (tile), w contrast
// params[1]: x turns per minute per 100 tiles, y glow, z line -> accent, w water fill

const TR_PI: f32 = 3.14159265;
// Seconds a quarter turn takes.
const TR_TURN_S: f32 = 3.6;
// The pointer's glow pool radius, in tiles.
const TR_POOL_TILES: f32 = 3.5;

fn tr_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = tr_hash(i);
    let b = tr_hash(i + vec2<f32>(1.0, 0.0));
    let c = tr_hash(i + vec2<f32>(0.0, 1.0));
    let d = tr_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Color: palettes are mixed in OKLab (Ottosson 2020) and converted back to linear sRGB.
fn tr_lab(c: vec3<f32>) -> vec3<f32> {
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

fn tr_rgb(o: vec3<f32>) -> vec3<f32> {
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
fn tr_hue_dir(acc: vec3<f32>, deg: f32) -> vec2<f32> {
    let c = length(acc.yz);
    let d = select(vec2<f32>(1.0, 0.0), acc.yz / max(c, 1e-6), c > 1e-4);
    let a = radians(deg);
    let cs = cos(a);
    let sn = sin(a);
    return vec2<f32>(cs * d.x - sn * d.y, sn * d.x + cs * d.y);
}

fn tr_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Triangular-PDF dither of +-1 LSB in the encoded (sRGB) space the host writes, then back to
// linear. Static in time (keyed on the pixel only): it kills banding without animated grain.
fn tr_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = (tr_hash(px) + tr_hash(px + vec2<f32>(19.19, 47.31)) - 1.0) / 255.0;
    let s = max(enc + vec3<f32>(n), vec3<f32>(0.0));
    return select(pow((s + 0.055) / 1.055, vec3<f32>(2.4)), s / 12.92, s <= vec3<f32>(0.04045));
}

// Coverage of a line of half width `w` px at distance `d` px: a 1 px box filter, and a line
// thinner than a pixel keeps its ink by fading instead of breaking up.
fn tr_line(d: f32, w: f32) -> f32 {
    let wd = max(w, 0.5);
    return clamp(wd + 0.5 - d, 0.0, 1.0) * (w / wd);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pt = max(frame.size.z, 0.25);
    let seed = frame.size.w;
    let t = frame.time.x;
    let tile = max(pa.x, 8.0) * pt;
    let q = px / tile + vec2<f32>(seed * 37.0, seed * 59.0);
    let cell = floor(q);
    let uv = fract(q) - 0.5;

    // This tile's clock: a base orientation, a smooth phase (so turns travel as a front) and a
    // period from the turn rate.
    let h1 = tr_hash(cell + vec2<f32>(0.37, 0.71));
    let h2 = tr_hash(cell * 1.31 + vec2<f32>(7.7, 3.1));
    let phase = fract(tr_noise(cell * 0.09 + vec2<f32>(seed * 29.0, 1.7)) * 2.3 + h2 * 0.06);
    let period = 6000.0 / max(pb.x, 0.05);
    let s = t / period + phase;
    let f = fract(s) * period / TR_TURN_S;
    let turning = f < 1.0;
    let fc = clamp(f, 0.0, 1.0);
    let ease = fc * fc * fc * (fc * (fc * 6.0 - 15.0) + 10.0);
    let rot = floor(s) + step(0.5, h1) + select(0.0, ease - 1.0, turning);
    let ang = rot * 0.5 * TR_PI;
    let cs = cos(ang);
    let sn = sin(ang);
    let r = vec2<f32>(cs * uv.x + sn * uv.y, -sn * uv.x + cs * uv.y);

    // Two quarter arcs about opposite corners; the river runs along them.
    let d1 = abs(length(r - vec2<f32>(-0.5)) - 0.5);
    let d2 = abs(length(r - vec2<f32>(0.5)) - 0.5);
    let d = min(d1, d2);
    let river = clamp(pa.z, 0.0, 0.3);
    let w = 0.5 * pa.y * pt;
    let bank = tr_line(abs(d - river) * tile, w);
    let water = 1.0 - smoothstep(river * tile - 0.5, river * tile + 0.5, d * tile);
    // A turning tile's corners leave its slot: clip at the rotated tile's edge (1 px soft).
    let inside = clamp((0.5 - max(abs(r.x), abs(r.y))) * tile + 1.0, 0.0, 1.0);

    // The glow: two octaves of value noise drifting about 1 point a second, gated soft; the
    // pointer adds a pool, eased with presence.
    let gq = q / 7.0 + vec2<f32>(t * 0.0045, -t * 0.0031);
    let gn = 0.65 * tr_noise(gq) + 0.35 * tr_noise(gq * 2.07 + vec2<f32>(4.3, 8.1));
    let pq = frame.pointer.xy / tile + vec2<f32>(seed * 37.0, seed * 59.0);
    let pd = (q - pq) / TR_POOL_TILES;
    let pool = frame.presence.x * exp(-dot(pd, pd));
    let glow = clamp(smoothstep(0.42, 0.85, gn) + 0.6 * pool, 0.0, 1.0) * pb.y;
    let turn_lit = select(0.0, sin(TR_PI * fc), turning) * 0.6;

    // Colors in OKLab.
    let contrast = pa.w;
    let acc = tr_lab(frame.accent.rgb);
    let paper = tr_lab(frame.paper.rgb);
    let line = mix(tr_lab(frame.ink.rgb), acc, pb.z);
    let lit = mix(line, acc, clamp(0.55 * glow + turn_lit, 0.0, 1.0));
    var col = paper;
    // The empty slot a turning tile leaves: a faint shadow.
    col = mix(col, line, (1.0 - inside) * contrast * 0.35);
    let water_c = mix(paper, acc, 0.5);
    col = mix(col, water_c, water * inside * pb.w * (0.05 + 0.16 * glow) * (contrast / 0.2));
    col = mix(col, lit, bank * inside * min(contrast * (1.0 + 0.6 * glow + turn_lit), 0.9));
    col.x = col.x + (tr_hash(px * 1.37 + seed * 91.0) - 0.5) * 0.006;
    return vec4<f32>(tr_dither(max(tr_rgb(col), vec3<f32>(0.0)), px), 1.0);
}
