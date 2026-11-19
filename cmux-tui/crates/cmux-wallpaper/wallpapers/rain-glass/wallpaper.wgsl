// Rain: a rainy window seen from a warm room. Behind the glass a city is out of focus: a sky to
// street gradient and two layers of bokeh (soft discs with a slightly brighter rim, from a hash
// grid, each light breathing on its own minutes-long period). On the glass: a fine mist of
// condensation drops and larger static drops, each growing in over seconds and evaporating over
// its long life, and in a few columns a drop that slides down in stick-slip steps, wiping a
// clear wet trail of tiny droplets behind it. Every drop is a small lens: it shows the city
// minified and inverted (one background lookup at the refracted point), with a dark rim and a warm
// glint from the room's lamp. Fog on the glass softens everything else, and a lamp's reflection
// warms the lower right. Everything is analytic and deterministic in time. Background mixed in
// OKLab, lights added in linear light, dithered. Pure function of `frame` and `px`.
//
// params[0]: x palette (0 City, 1 Neon, 2 Dawn), y rain (drop density), z speed, w lights
// params[1]: x fog, y warmth

const RG_TAU: f32 = 6.2831853;
// Width of a sliding-drop column (heights).
const RG_COL: f32 = 0.11;
// Distance a sliding drop travels in one cycle (heights): from above the window to well below
// it, so its trail has faded before the column's next drop starts.
const RG_TRAVEL: f32 = 2.9;

fn rg_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn rg_hash2(p: vec2<f32>) -> vec2<f32> {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

fn rg_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = rg_hash(i);
    let b = rg_hash(i + vec2<f32>(1.0, 0.0));
    let c = rg_hash(i + vec2<f32>(0.0, 1.0));
    let d = rg_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn rg_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let a = h * 0.017453293;
    return vec3<f32>(l, c * cos(a), c * sin(a));
}

fn rg_to_lin(c: vec3<f32>) -> vec3<f32> {
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

fn rg_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = rg_hash(px) + rg_hash(px + vec2<f32>(37.1, 91.7)) - 1.0;
    let s = max(sqrt(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0))) + vec3<f32>(n / 255.0), vec3<f32>(0.0));
    return s * s;
}

// A city light's color (linear), picked by k in 0..1, per palette.
fn rg_light(pal: i32, k: f32) -> vec3<f32> {
    if (pal == 1) {
        // Neon: magenta, cyan, violet, and a little sodium.
        if (k < 0.35) { return vec3<f32>(0.90, 0.10, 0.60); }
        if (k < 0.65) { return vec3<f32>(0.10, 0.70, 1.00); }
        if (k < 0.88) { return vec3<f32>(0.45, 0.15, 1.00); }
        return vec3<f32>(1.00, 0.45, 0.12);
    }
    if (pal == 2) {
        // Dawn: warm whites and amber, a few cool street lights.
        if (k < 0.45) { return vec3<f32>(1.00, 0.80, 0.55); }
        if (k < 0.80) { return vec3<f32>(1.00, 0.55, 0.22); }
        return vec3<f32>(0.60, 0.75, 1.00);
    }
    // City: sodium amber, warm white, tail-light red, a teal sign.
    if (k < 0.45) { return vec3<f32>(1.00, 0.45, 0.12); }
    if (k < 0.75) { return vec3<f32>(1.00, 0.85, 0.65); }
    if (k < 0.92) { return vec3<f32>(1.00, 0.08, 0.05); }
    return vec3<f32>(0.15, 0.65, 0.75);
}

// One bokeh layer: the 2 x 2 cells nearest the point (disc radius plus jitter stays within one
// cell, so no other cell can reach it). Lights sit below a soft horizon.
fn rg_bokeh(uv: vec2<f32>, cells: f32, rmax: f32, seed: f32, t: f32, pal: i32) -> vec3<f32> {
    let g = uv * cells;
    let base = floor(g - 0.5);
    var acc = vec3<f32>(0.0);
    for (var j = 0; j < 2; j = j + 1) {
        for (var i = 0; i < 2; i = i + 1) {
            let cell = base + vec2<f32>(f32(i), f32(j));
            let h1 = rg_hash2(cell + vec2<f32>(seed, seed * 1.7));
            let h2 = rg_hash2(cell + vec2<f32>(seed + 31.7, 11.3));
            let yy = (cell.y + 0.5) / cells;
            if (h1.x < 0.65 * smoothstep(0.2, 0.55, yy)) {
                let c = cell + 0.5 + (h2 - 0.5) * 0.5;
                let r = rmax * (0.55 + 0.45 * h2.x);
                let d = length(g - c) / r;
                let disc = 1.0 - smoothstep(0.82, 1.0, d);
                let shape = disc * (0.7 + 0.45 * smoothstep(0.5, 0.95, d));
                let breathe = 0.6 + 0.4 * sin(t * (0.04 + 0.07 * h2.y) + RG_TAU * h1.y);
                acc = acc + rg_light(pal, h2.y) * (shape * breathe * (0.45 + 0.55 * h1.y));
            }
        }
    }
    return acc;
}

// The city behind the glass at uv (linear).
fn rg_scene(uv: vec2<f32>, t: f32, pal: i32, dark: f32, lights: f32, seed: f32) -> vec3<f32> {
    var top = vec3<f32>(0.0);
    var bottom = vec3<f32>(0.0);
    if (pal == 1) {
        top = mix(rg_lch(0.88, 0.020, 300.0), rg_lch(0.18, 0.040, 290.0), dark);
        bottom = mix(rg_lch(0.85, 0.030, 340.0), rg_lch(0.23, 0.050, 330.0), dark);
    } else if (pal == 2) {
        top = mix(rg_lch(0.90, 0.020, 235.0), rg_lch(0.22, 0.030, 250.0), dark);
        bottom = mix(rg_lch(0.88, 0.040, 60.0), rg_lch(0.30, 0.050, 45.0), dark);
    } else {
        top = mix(rg_lch(0.86, 0.012, 250.0), rg_lch(0.20, 0.020, 260.0), dark);
        bottom = mix(rg_lch(0.82, 0.022, 70.0), rg_lch(0.25, 0.035, 55.0), dark);
    }
    let sky = rg_to_lin(mix(top, bottom, smoothstep(-0.1, 1.1, uv.y)));
    let k = lights * mix(0.10, 0.14, dark);
    let far = rg_bokeh(uv, 9.0, 0.7, seed * 100.0, t, pal);
    let near = rg_bokeh(uv, 3.6, 0.72, seed * 100.0 + 57.0, t * 0.8, pal);
    return sky + (far + near * 0.55) * k;
}

// The x of column cx's sliding path at height y: a fixed meander, so the trail follows the drop.
fn rg_path(cx: f32, ch: vec2<f32>, y: f32) -> f32 {
    return (cx + 0.5) * RG_COL + (ch.y - 0.5) * 0.25 * RG_COL
        + 0.011 * sin(y * 11.0 + ch.x * RG_TAU) + 0.005 * sin(y * 27.0 + ch.y * RG_TAU);
}

// A static drop layer: one drop per cell at most, radius and jitter kept inside the cell. Each
// grows in over ~5% of its life and evaporates over the last 20%. Returns (d.x, d.y, mask, r):
// d is the offset from the center in radii, r the radius in heights.
fn rg_drops(uv: vec2<f32>, cells: f32, rmin: f32, rspan: f32, prob: f32, life: f32, t: f32, salt: f32, px_h: f32) -> vec4<f32> {
    let g = uv * cells;
    let ci = floor(g);
    let f = fract(g) - 0.5;
    let h1 = rg_hash2(ci + vec2<f32>(salt, salt * 0.37));
    let h2 = rg_hash2(ci + vec2<f32>(salt + 9.1, 5.3));
    let ph = fract(t / (life * (0.7 + 0.6 * h2.x)) + h2.y);
    let grow = smoothstep(0.0, 0.05, ph) * (1.0 - smoothstep(0.8, 1.0, ph));
    let r = (rmin + rspan * h1.x) * grow * select(0.0, 1.0, h1.y < prob);
    let jit = (h2 - 0.5) * (0.9 - 2.0 * (rmin + rspan));
    let d = (f - jit) / max(r, 1e-4);
    let dl = length(d);
    let aa = 1.5 / max(r * px_h / cells, 1e-3);
    let m = select(0.0, 1.0 - smoothstep(1.0 - aa, 1.0, dl), r > 1e-4);
    return vec4<f32>(d, m, r / cells);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pal = i32(round(pa.x));
    let rain = pa.y;
    let speed = pa.z;
    let lights = pa.w;
    let fog = pb.x;
    let warmth = pb.y;
    let dark = frame.presence.w;
    let h = frame.size.y;
    let aspect = frame.size.x / h;
    let uv = px / h;
    let seed = frame.size.w;
    let t = frame.time.x * speed + seed * 500.0;

    // The sliding drop of this column, and its trail.
    let cx = floor(uv.x / RG_COL);
    let ch = rg_hash2(vec2<f32>(cx, 17.0 + seed * 13.0));
    let phase = t * 0.034 / RG_TRAVEL + ch.x;
    let cyc = floor(phase);
    let f = fract(phase);
    // Stick-slip: seven pauses per cycle, never moving backwards (slope >= 0.1).
    let fy = f - 0.9 * sin(RG_TAU * 7.0 * f) / (RG_TAU * 7.0);
    let yd = -0.15 + fy * RG_TRAVEL;
    let live = select(0.0, 1.0, rg_hash(vec2<f32>(cx, cyc)) < 0.5 * clamp(rain, 0.0, 2.0));
    let xd = rg_path(cx, ch, yd);
    let sr = 0.016 + 0.007 * ch.y;
    let dv = uv - vec2<f32>(xd, yd);
    let sd = vec2<f32>(dv.x / sr, dv.y / (sr * select(1.35, 0.95, dv.y > 0.0)));
    let sl = length(sd);
    let saa = 1.5 / (sr * h);
    var bm = live * (1.0 - smoothstep(1.0 - saa, 1.0, sl));
    var bd = sd;
    var br = sr;
    var bc = vec2<f32>(xd, yd);

    // The wet trail behind it: clear of fog and mist, beaded with tiny droplets that evaporate
    // as the trail fades.
    let behind = yd - uv.y;
    let tstr = live * select(0.0, exp(-behind / 0.45), behind > 0.0);
    let tx = rg_path(cx, ch, uv.y);
    let tw = sr * 0.45;
    let clear = tstr * (1.0 - smoothstep(tw * 0.6, tw * 1.8, abs(uv.x - tx)));
    {
        let ty = uv.y / 0.018;
        let ti = floor(ty);
        let th = rg_hash2(vec2<f32>(cx * 13.0 + ti, cyc));
        let cy = (ti + 0.5 + (th.x - 0.5) * 0.4) * 0.018;
        let tb = yd - cy;
        let tstr_c = live * select(0.0, exp(-tb / 0.45), tb > 0.0);
        let dr = (0.0035 + 0.003 * th.x) * smoothstep(0.05, 0.4, tstr_c) * select(0.0, 1.0, th.y < 0.7);
        let dc = vec2<f32>(rg_path(cx, ch, cy) + (th.y - 0.35) * tw * 0.8, cy);
        let dd = (uv - dc) / max(dr, 1e-4);
        let dl = length(dd);
        let m = select(0.0, 1.0 - smoothstep(1.0 - 1.5 / max(dr * h, 1e-3), 1.0, dl), dr > 1e-4);
        if (m > bm) {
            bm = m;
            bd = dd;
            br = dr;
            bc = dc;
        }
    }

    // Static drops (wiped where a trail has passed) and the fine mist.
    let big = rg_drops(uv, 10.0, 0.10, 0.20, 0.38 * rain, 140.0, t, 3.0, h);
    let bigm = big.z * (1.0 - clear);
    if (bigm > bm) {
        bm = bigm;
        bd = big.xy;
        br = big.w;
        bc = uv - big.xy * big.w;
    }
    let mist = rg_drops(uv, 46.0, 0.12, 0.18, 0.55 * rain, 100.0, t, 7.0, h);
    let mistm = mist.z * (1.0 - clear);
    if (mistm > bm) {
        bm = mistm;
        bd = mist.xy;
        br = mist.w;
        bc = uv - mist.xy * mist.w;
    }

    // One lookup of the city: through a drop, at the minified, inverted point it sees.
    let lens = bc - bd * br * 5.0;
    let suv = mix(uv, lens, bm);
    var col = rg_scene(suv, t, pal, dark, lights, seed);

    // Fog on the glass (uneven, fixed), except in drops and wiped trails.
    let fog_lab = mix(rg_lch(0.90, 0.010, 70.0), rg_lch(0.30, 0.012, 60.0), dark);
    let fog_amt = fog * (0.22 + 0.10 * rg_noise(uv * 3.0 + vec2<f32>(seed * 40.0, 0.0))) * (1.0 - bm) * (1.0 - clear);
    col = mix(col, rg_to_lin(fog_lab), clamp(fog_amt, 0.0, 1.0));

    // Drop shading: a dark rim and a warm glint from the lamp in the room (upper left).
    let rl = length(bd);
    col = col * (1.0 - mix(0.25, 0.45, dark) * smoothstep(0.55, 1.0, rl) * bm);
    let gl = bd - vec2<f32>(-0.32, -0.40);
    let glint = exp(-dot(gl, gl) * 14.0) * bm;
    let warm = vec3<f32>(1.0, 0.72, 0.42);
    col = col + warm * glint * mix(0.10, 0.05, dark);

    // The lamp's reflection on the glass, low right, and a soft vignette.
    let lr = uv - vec2<f32>(aspect * 0.86, 1.12);
    let lamp = exp(-dot(lr, lr) / 0.45) * warmth;
    col = col + warm * lamp * mix(0.025, 0.035, dark);
    let vc = uv - vec2<f32>(aspect * 0.5, 0.5);
    col = col * (1.0 - 0.18 * dark * smoothstep(0.3, 1.2, length(vc)));

    return vec4<f32>(rg_dither(col, px), 1.0);
}
