// Ink: drops of ink blooming in still water. Three drops are alive at once, born a third of a
// lifetime apart at hashed places; each is a soft lobed blob with a darker rim and streaks of
// pigment, carried by a slow divergence-free flow (the curl of a gradient-noise stream function
// plus two small shear waves). Nothing is simulated: the pixel walks the flow backwards (6 Euler
// steps, one shared path for all three drops, since the field barely changes over a lifetime) and
// reads each drop's pigment where its water was when the drop was born. The flow conserves area,
// so a blob stretches into filaments instead of smearing. Sumi wash on the theme's paper in light;
// luminous pigment on it in dark. The pointer stirs: near it the water is dragged along the
// pointer's motion and turned a little, easing back once the pointer rests. Mixed in OKLab,
// dithered. Pure function of `frame` and `px`.
//
// params[0]: x palette (0 Sumi, 1 Indigo, 2 Vermilion), y flow speed, z ink density, w flow scale
// params[1]: x stir, y paper texture

const IK_TAU: f32 = 6.2831853;
// Seconds (at speed 1) one drop lives, from bloom to fading out.
const IK_LIFE: f32 = 54.0;
// Euler steps back through the flow over one lifetime.
const IK_STEPS: i32 = 6;

fn ik_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn ik_hash2(p: vec2<f32>) -> vec2<f32> {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

fn ik_vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = ik_hash(i);
    let b = ik_hash(i + vec2<f32>(1.0, 0.0));
    let c = ik_hash(i + vec2<f32>(0.0, 1.0));
    let d = ik_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Gradient noise and its analytic gradient: (value, d/dx, d/dy).
fn ik_gnoise(p: vec2<f32>) -> vec3<f32> {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    let ga = ik_hash2(i) * 2.0 - 1.0;
    let gb = ik_hash2(i + vec2<f32>(1.0, 0.0)) * 2.0 - 1.0;
    let gc = ik_hash2(i + vec2<f32>(0.0, 1.0)) * 2.0 - 1.0;
    let gd = ik_hash2(i + vec2<f32>(1.0, 1.0)) * 2.0 - 1.0;
    let va = dot(ga, f);
    let vb = dot(gb, f - vec2<f32>(1.0, 0.0));
    let vc = dot(gc, f - vec2<f32>(0.0, 1.0));
    let vd = dot(gd, f - vec2<f32>(1.0, 1.0));
    let k = va - vb - vc + vd;
    let v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
    let g = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
        + du * (u.yx * k + vec2<f32>(vb - va, vc - va));
    return vec3<f32>(v, g);
}

// The water's velocity at q (backdrop heights per second at speed 1): the curl of a stream
// function, so it has no sources or sinks. One octave of gradient noise (vortices about a third
// of the height across, many local directions, never one coherent flow) and two small shear
// waves at incommensurate angles that fray the filaments.
fn ik_vel(q: vec2<f32>, tau: f32, freq: f32) -> vec2<f32> {
    let n = ik_gnoise(q * freq + vec2<f32>(tau * 0.11, -tau * 0.07));
    var g = n.yz * freq * 0.5;
    let k1 = vec2<f32>(2.9, 1.7) * freq;
    let k2 = vec2<f32>(-1.1, 3.2) * freq;
    g = g + 0.045 * cos(dot(q, k1) + tau * 0.23) * k1;
    g = g + 0.040 * cos(dot(q, k2) - tau * 0.17 + 1.9) * k2;
    return vec2<f32>(g.y, -g.x) * 0.0065;
}

// Where drop `layer` of cycle `c` was born (backdrop heights; x within the width).
fn ik_center(c: f32, layer: f32, aspect: f32) -> vec2<f32> {
    let h = ik_hash2(vec2<f32>(c * 1.37 + layer * 19.1, layer * 7.3 + 3.1));
    return vec2<f32>((0.14 + 0.72 * h.x) * aspect, 0.14 + 0.72 * h.y);
}

// One drop's pigment at its birth-time position q0, at life fraction ph (0..1): a lobed soft
// body with a rim, streaked by noise that rides with the water (so the flow pulls it into
// filaments), blooming over the first 9% of its life (~5 s) and fading over the second half.
fn ik_drop(q0: vec2<f32>, center: vec2<f32>, ph: f32, seed: f32) -> f32 {
    let d = q0 - center;
    let ang = atan2(d.y, d.x);
    let lobes = 1.0 + 0.28 * sin(ang * 3.0 + seed * 5.1) + 0.12 * sin(ang * 5.0 - seed * 2.3);
    let r = 0.05 + 0.06 * ph;
    let rr = dot(d, d) / (r * r) * lobes;
    let rl = sqrt(rr);
    let body = exp(-rr);
    let rim = exp(-(rl - 0.85) * (rl - 0.85) * 7.0);
    let streak = smoothstep(0.25, 0.85, ik_vnoise(q0 * 17.0 + vec2<f32>(seed * 41.0, seed * 13.0)));
    let env = smoothstep(0.0, 0.09, ph) * (1.0 - smoothstep(0.5, 1.0, ph));
    return (0.6 * body + 0.5 * rim) * (0.35 + 0.95 * streak) * env;
}

fn ik_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let a = h * 0.017453293;
    return vec3<f32>(l, c * cos(a), c * sin(a));
}

fn ik_to_lab(c: vec3<f32>) -> vec3<f32> {
    let l = pow(max(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z, 0.0), 1.0 / 3.0);
    let m = pow(max(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z, 0.0), 1.0 / 3.0);
    let s = pow(max(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z, 0.0), 1.0 / 3.0);
    return vec3<f32>(
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    );
}

fn ik_to_lin(c: vec3<f32>) -> vec3<f32> {
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

// Triangular dither of about +-1/255 in a gamma-2 space (close to the sRGB step), fixed per pixel.
fn ik_dither(c: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = ik_hash(px) + ik_hash(px + vec2<f32>(37.1, 91.7)) - 1.0;
    let s = max(sqrt(clamp(c, vec3<f32>(0.0), vec3<f32>(1.0))) + vec3<f32>(n / 255.0), vec3<f32>(0.0));
    return s * s;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pal = i32(round(pa.x));
    let speed = max(pa.y, 0.0);
    let density = max(pa.z, 0.0);
    let freq = max(pa.w, 0.3);
    let stir = pb.x;
    let tex_amt = pb.y;
    let dark = frame.presence.w;
    let h = frame.size.y;
    let aspect = frame.size.x / h;
    let q = px / h;
    let t = frame.time.x * speed + frame.size.w * 977.0;
    let tau = t * 0.02;
    let still = frame.time.w > 0.5;

    // Stir: near the pointer the water is dragged along its motion and turned a little; the
    // amount follows the host's smoothed velocity and eases out over ~2 s once it rests.
    let pt = frame.pointer.xy / h;
    let vel = frame.pointer.zw / h;
    let spd = length(vel);
    let since = select(frame.presence.y, 99.0, still);
    let amt = stir * frame.presence.x * exp(-since * 0.6) * min(spd * 0.12, 0.05);
    let dp = q - pt;
    let fall = exp(-dot(dp, dp) / 0.018);
    let dir = vel / max(spd, 1e-4);
    let p = q - dir * amt * fall - vec2<f32>(-dp.y, dp.x) * (amt * 6.0 * fall);

    // Three drops a third of a lifetime apart; walk the flow back once and pick up each drop's
    // birth-time position at its own age along the same path.
    let life = t / IK_LIFE + vec3<f32>(0.0, 1.0 / 3.0, 2.0 / 3.0);
    let ph = fract(life);
    let cyc = floor(life);
    let ages = ph * IK_LIFE;
    let dt = IK_LIFE / f32(IK_STEPS);
    var cur = p;
    var qa = p;
    var qb = p;
    var qc = p;
    for (var k = 0; k < IK_STEPS; k = k + 1) {
        let nxt = cur - ik_vel(cur, tau, freq) * dt;
        let lo = f32(k) * dt;
        let w = clamp((ages - vec3<f32>(lo)) / dt, vec3<f32>(0.0), vec3<f32>(1.0));
        qa = select(qa, mix(cur, nxt, w.x), ages.x >= lo);
        qb = select(qb, mix(cur, nxt, w.y), ages.y >= lo);
        qc = select(qc, mix(cur, nxt, w.z), ages.z >= lo);
        cur = nxt;
    }
    let ink = ik_drop(qa, ik_center(cyc.x, 0.0, aspect), ph.x, fract(cyc.x * 0.618))
        + ik_drop(qb, ik_center(cyc.y, 1.0, aspect), ph.y, fract(cyc.y * 0.618 + 0.3))
        + ik_drop(qc, ik_center(cyc.z, 2.0, aspect), ph.z, fract(cyc.z * 0.618 + 0.6));
    let a = 1.0 - exp(-ink * density * 1.6);

    // Palettes (OKLCH): thin wash and dense pigment, light and dark; a small paper tint.
    // The palette index is uniform, so only one branch runs.
    var thin = vec3<f32>(0.0);
    var deep = vec3<f32>(0.0);
    var tint = vec2<f32>(0.0);
    if (pal <= 0) {
        thin = mix(ik_lch(0.64, 0.006, 250.0), ik_lch(0.29, 0.012, 250.0), dark);
        deep = mix(ik_lch(0.46, 0.010, 260.0), ik_lch(0.40, 0.018, 235.0), dark);
        tint = mix(vec2<f32>(0.002, 0.010), vec2<f32>(0.0, -0.004), dark);
    } else if (pal == 1) {
        thin = mix(ik_lch(0.68, 0.060, 262.0), ik_lch(0.29, 0.070, 266.0), dark);
        deep = mix(ik_lch(0.44, 0.120, 266.0), ik_lch(0.42, 0.105, 252.0), dark);
        tint = mix(vec2<f32>(-0.002, -0.004), vec2<f32>(-0.002, -0.010), dark);
    } else {
        thin = mix(ik_lch(0.74, 0.085, 40.0), ik_lch(0.31, 0.080, 33.0), dark);
        deep = mix(ik_lch(0.56, 0.165, 32.0), ik_lch(0.46, 0.125, 48.0), dark);
        tint = mix(vec2<f32>(0.004, 0.012), vec2<f32>(0.004, 0.004), dark);
    }

    // The theme's paper, tinted, with fixed washi fibers (no time term, so they never shimmer).
    var paper = ik_to_lab(frame.paper.rgb);
    paper.x = clamp(paper.x, 0.14, 0.97);
    paper = paper + vec3<f32>(0.0, tint);
    let fiber = ik_vnoise(q * vec2<f32>(160.0, 48.0) + vec2<f32>(frame.size.w * 50.0, 0.0)) - 0.5;
    paper.x = paper.x + fiber * tex_amt * mix(0.012, 0.006, dark);

    let pigment = mix(thin, deep, smoothstep(0.15, 0.85, a));
    let lab = mix(paper, pigment, a * 0.85);
    return vec4<f32>(ik_dither(ik_to_lin(lab), px), 1.0);
}
