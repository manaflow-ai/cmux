// Fireflies: up to 24 soft glowing motes over a dusky field with a faint low mist. Each mote
// drifts on its own slow Lissajous path (incommensurate frequencies, so the swarm never visibly
// repeats) about a home spread evenly over the window, glows on and off over 5..11 s, and is a
// little nearer or farther (nearer is larger, softer and dimmer, like bokeh). When agents work
// (Frame.activity.x, eased), the motes brighten, stay lit longer and gather a little toward a
// hearth low in the window. The pointer draws the nearby ones to circle it: they follow a point
// that lags the pointer by about half a second (a smooth weighting of Frame.trail), so they drift
// after you rather than jump.
//
// params[0]: x count (6..24), y core radius (points), z glow, w speed
// params[1]: x attract (0..0.8), y agent response, z mist, w hue spread (degrees)

const FF_MAX: i32 = 24;
const FF_PI: f32 = 3.14159265;

fn ff_hash12(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn ff_hash42(p: vec2<f32>) -> vec4<f32> {
    var q = fract(vec4<f32>(p.x, p.y, p.x, p.y) * vec4<f32>(0.1031, 0.1030, 0.0973, 0.1099));
    q = q + dot(q, q.wzxy + 33.33);
    return fract((q.xxyz + q.yzzw) * q.zywx);
}

fn ff_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = ff_hash12(i);
    let b = ff_hash12(i + vec2<f32>(1.0, 0.0));
    let c = ff_hash12(i + vec2<f32>(0.0, 1.0));
    let d = ff_hash12(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn ff_oklab(c: vec3<f32>) -> vec3<f32> {
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

fn ff_linear(c: vec3<f32>) -> vec3<f32> {
    let l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    let q = vec3<f32>(l * l * l, m * m * m, s * s * s);
    return max(vec3<f32>(
        4.0767416621 * q.x - 3.3077115913 * q.y + 0.2309699292 * q.z,
        -1.2684380046 * q.x + 2.6097574011 * q.y - 0.3413193965 * q.z,
        -0.0041960863 * q.x - 0.7034186147 * q.y + 1.7076147010 * q.z,
    ), vec3<f32>(0.0));
}

fn ff_rot(ab: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(c * ab.x - s * ab.y, s * ab.x + c * ab.y);
}

fn ff_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(lin, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = ff_hash12(px + 0.5) + ff_hash12(px.yx + 71.3) - 1.0;
    let e = clamp(enc + n / 255.0, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(pow((e + 0.055) / 1.055, vec3<f32>(2.4)), e / 12.92, e <= vec3<f32>(0.04045));
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let seed = frame.size.w;
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;
    let t = frame.time.x;
    let ppt = max(frame.size.z, 0.1);
    let size = max(frame.size.xy, vec2<f32>(1.0));
    let uv = px / size;

    let count = clamp(pa.x, 1.0, f32(FF_MAX));
    let core_r = max(pa.y * ppt, 0.6);
    let glow = pa.z;
    let speed = pa.w;
    let attract = pb.x;
    let resp = pb.y;
    let mist_k = pb.z;
    let spread = pb.w * FF_PI / 180.0;

    // Agent activity, eased by the host; a still shows a window with agents at work.
    let act = clamp(select(frame.activity.x, 0.45, still), 0.0, 1.0) * resp;

    // The point the motes follow: the trail weighted by sin^2(pi * age / 0.75 s), so a point enters at the
    // head and has no weight by 0.75 s, before the full ring drops it at ~0.8 s (nothing jumps), plus the pointer itself at a small
    // fixed weight, which is all that is left once the pointer rests. The trail is uniform, so
    // this is the same for every pixel.
    var wsum = 0.35;
    var tsum = frame.pointer.xy * 0.35;
    for (var i = 0; i < 16; i = i + 1) {
        let r = frame.trail[i];
        if (r.w > 0.5) {
            let s = sin(FF_PI * clamp(r.z / 0.75, 0.0, 1.0));
            tsum = tsum + r.xy * s * s;
            wsum = wsum + s * s;
        }
    }
    let lag = tsum / wsum;
    let inside = select(frame.presence.x, 1.0, still) * attract;
    let hearth = vec2<f32>(0.5, 0.66) * size;

    // The motes. Light adds up in four sums: core and halo, for each end of the hue spread.
    var core_a = 0.0;
    var core_b = 0.0;
    var halo_a = 0.0;
    var halo_b = 0.0;
    for (var i = 0; i < FF_MAX; i = i + 1) {
        let fi = f32(i);
        if (fi >= count) {
            break;
        }
        let h = ff_hash42(vec2<f32>(fi * 1.618 + 3.7, seed * 13.0 + 1.3));
        let g = fract(h.yzwx * 7.13 + h * 3.11);
        // A home on an R2 low-discrepancy sequence, so the swarm covers the window evenly; homes
        // sit mostly in the lower two thirds, over the meadow.
        let home0 = vec2<f32>(fract(0.31 + fi * 0.7548777 + seed), 0.22 + 0.72 * fract(0.17 + fi * 0.5698403));
        let home = mix(home0 * size, hearth, 0.3 * act);
        // A Lissajous path at 0.02..0.07 rad/s with a second harmonic: under 0.012 widths a
        // second at speed 1.
        let f = (0.02 + 0.05 * h) * speed;
        let ph = g * 6.2831853;
        let w = vec2<f32>(
            sin(f.x * t + ph.x) * 0.75 + sin(f.z * t + ph.z) * 0.25,
            sin(f.y * t + ph.y) * 0.75 + sin(f.w * t + ph.w) * 0.25,
        );
        var pos = home + w * vec2<f32>(0.17, 0.12) * size.x * (1.0 - 0.3 * act);
        // Drawn to the pointer: a mote near the lagged pointer leans toward a small circle around
        // it, by up to `attract`, less the farther it is.
        if (inside > 0.0) {
            let ang = t * (0.1 + 0.08 * g.x) * select(-1.0, 1.0, g.y > 0.5) + h.x * 6.2831853;
            let orbit = lag + vec2<f32>(cos(ang), sin(ang)) * (28.0 + 60.0 * g.z) * ppt;
            let dv = (pos - lag) / size.x;
            let pull = inside * (0.4 + 0.6 * h.z) * exp(-dot(dv, dv) / 0.09);
            pos = mix(pos, orbit, pull);
        }
        // Depth: a nearer mote is larger, softer and dimmer.
        let depth = g.w;
        let r = core_r * (0.7 + 1.1 * depth * depth);
        let dimmer = mix(1.0, 0.5, depth);
        // The glow cycle: 5..11 s, eased so a mote rests lit and rests dark (never a blink);
        // working agents keep more of them lit.
        let period = 5.0 + 6.0 * g.x;
        let p = 0.5 + 0.5 * sin(t * 6.2831853 / period + h.w * 40.0);
        let pulse = p * p * (3.0 - 2.0 * p);
        let lit = mix(pulse, max(pulse, 0.75), clamp(act, 0.0, 1.0));
        let b = (0.12 + 0.88 * lit) * dimmer * (0.7 + 0.5 * act);
        // Light: a sharp-ish core (Lorentzian squared) and a wide halo (Lorentzian at 6 radii)
        // that bleeds into the dusk, so the motes light the air around them.
        let d = px - pos;
        let dd = dot(d, d);
        let q = 1.0 / (1.0 + dd / (r * r));
        let qh = 1.0 / (1.0 + dd / (r * r * 36.0));
        let c = b * q * q;
        let hl = b * qh * glow;
        core_a = core_a + c * (1.0 - h.y);
        core_b = core_b + c * h.y;
        halo_a = halo_a + hl * (1.0 - h.y);
        halo_b = halo_b + hl * h.y;
    }

    // Colors in OKLab: the accent (at least a little chroma, so a gray theme accent still reads
    // as light), turned -spread and +spread for the two ends; a hot core is paler.
    let acc = ff_oklab(frame.accent.rgb);
    let ac = length(acc.yz);
    let acc_ab = select(vec2<f32>(0.08, 0.1), acc.yz * max(1.0, 0.09 / max(ac, 1e-4)), ac > 0.01);
    let ab_a = ff_rot(acc_ab, -spread);
    let ab_b = ff_rot(acc_ab, spread);
    let acc_l = clamp(acc.x, 0.55, 0.9);

    // The dusk: the theme's paper, a little deeper at the top, with a faint mist low in the
    // window, drifting about 0.002 widths a second, leaning toward the accent; agents at work warm
    // it a little.
    let paper = ff_oklab(frame.paper.rgb);
    let m = ff_noise(vec2<f32>(uv.x * 3.0 + t * 0.006, uv.y * 7.0) + seed * 9.0) * 0.65
        + ff_noise(vec2<f32>(uv.x * 7.0 - t * 0.004, uv.y * 15.0) + seed * 5.0) * 0.35;
    let low = smoothstep(0.35, 1.0, uv.y);
    let mist = mist_k * low * smoothstep(0.25, 0.85, m) * (1.0 + 0.4 * act);
    let top = 1.0 - uv.y;
    var base = vec3<f32>(paper.x - mix(0.0, 0.03, dark) * top * top, paper.yz);
    let haze = vec3<f32>(base.x + mix(-0.025, 0.04, dark), mix(base.yz, acc_ab * 0.35, 0.5));
    base = mix(base, haze, clamp(mist * 0.6, 0.0, 1.0));

    var lin = ff_linear(base);
    let core_k = (core_a + core_b);
    let halo_k = (halo_a + halo_b);
    if (dark > 0.5) {
        let hot_a = ff_linear(vec3<f32>(mix(acc_l, 0.97, 0.55), ab_a * 0.55));
        let hot_b = ff_linear(vec3<f32>(mix(acc_l, 0.97, 0.55), ab_b * 0.55));
        let air_a = ff_linear(vec3<f32>(acc_l, ab_a));
        let air_b = ff_linear(vec3<f32>(acc_l, ab_b));
        lin = lin + (hot_a * core_a + hot_b * core_b) * 0.75 + (air_a * halo_a + air_b * halo_b) * 0.045;
    } else {
        // On a light paper a mote is a soft tint: deeper and fuller than the accent, a pale wash
        // for the halo.
        let mixk = (core_b + 0.3 * halo_b) / max(core_k + 0.3 * halo_k, 1e-4);
        let tint = vec3<f32>(acc_l * 0.78, mix(ab_a, ab_b, mixk) * 1.2);
        let k = clamp(core_k * 0.55 + halo_k * 0.06, 0.0, 0.75);
        lin = ff_linear(mix(base, tint, k));
    }
    return vec4<f32>(ff_dither(lin, px), 1.0);
}
