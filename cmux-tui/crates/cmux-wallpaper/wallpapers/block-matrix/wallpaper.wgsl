// Block matrix: a fine, even matrix of faint dots, lit by one smooth field of light. The field is
// a glow centered on the pointer with a short trail behind it, a few large soft lights that drift
// and ease in and out, and the agents' output. Each dot's brightness is the field read on two
// coarse block grids and softly stepped, so light arrives in rectangular blocks that ease between
// levels, while the dots themselves still swell smoothly toward the pointer.
//
// params[0]: x dot pitch (points), y block size (dots), z glow radius (dots), w pointer glow
// params[1]: x matrix level, y ambient light, z accent tint, w activity response

const BM_STEPS: f32 = 8.0;

fn bm_hash(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q = q + dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

fn bm_gauss(d: vec2<f32>, r: f32) -> f32 {
    return exp(-dot(d, d) / (r * r));
}

// Flat-topped: level across most of its radius, then a quick falloff, so a drifting light lifts
// the dots under it by one even amount, like a block, instead of a long dim rim.
fn bm_flat(d: vec2<f32>, r: f32) -> f32 {
    let q = dot(d, d) / (r * r);
    return exp(-q * q);
}

// The light at `x` (in dots): the pointer and its trail, the drifting lights and the newest
// agent event, summed and clamped to 0..1.
fn bm_field(x: vec2<f32>, t: f32, grid: vec2<f32>, seed: f32) -> f32 {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pitch = max(pa.x * max(frame.size.z, 0.25), 2.5);
    let present = frame.presence.x;

    // The pointer, centered on the cursor; a dim, short trail where it was a moment ago, and a
    // fainter, wider afterglow behind that, so dots it leaves fade out instead of switching off.
    let r = max(pa.z, 2.0);
    let p = frame.pointer.xy / pitch;
    var back = frame.pointer.zw / pitch * 0.1;
    let backLen = length(back);
    if (backLen > r * 1.5) {
        back = back * (r * 1.5 / backLen);
    }
    var f = pa.w * present * (0.5 * (bm_gauss(x - p, r) + bm_flat(x - p, r)) + 0.2 * bm_gauss(x - (p - back), r * 1.2) + 0.08 * bm_gauss(x - (p - 2.5 * back), r * 1.5));

    // Faint background lights, like blocks of a store filling and draining: each slot, once per
    // period of 3.5 to 5.5 seconds, picks a new spot, eases in, holds a moment and eases out, then
    // stays dark for the rest of the period. About one slot per 450 dots of window, so the density
    // holds at any size.
    let count = i32(clamp(round(grid.x * grid.y / 450.0), 2.0, 12.0));
    for (var i = 0; i < 12; i = i + 1) {
        if (i >= count) {
            break;
        }
        let fi = f32(i);
        let h = bm_hash(vec3<f32>(fi, seed, 3.0));
        let period = 3.5 + 2.0 * h;
        let tt = t + period * bm_hash(vec3<f32>(fi, seed, 4.0));
        let epoch = floor(tt / period);
        let ph = tt / period - epoch;
        let ease = smoothstep(0.0, 0.2, ph) * (1.0 - smoothstep(0.35, 0.62, ph));
        let k = vec3<f32>(epoch, fi, seed);
        let c = grid * vec2<f32>(bm_hash(k + 1.0), bm_hash(k + 2.0));
        let amp = pb.y * (0.6 + 0.4 * bm_hash(k + 3.0));
        f = f + amp * ease * bm_flat(x - c, 5.25 + 6.25 * bm_hash(k + 4.0));
    }

    // The newest agent event: a dim light at a place set by its count, easing in and fading over
    // several seconds.
    var act = frame.activity;
    if (frame.time.w > 0.5) {
        act = vec4<f32>(0.5, 0.6, 7.0, 0.0);
    }
    let ev = act.z;
    let spot = vec2<f32>(bm_hash(vec3<f32>(ev, seed, 1.0)), bm_hash(vec3<f32>(ev, seed, 2.0))) * grid;
    f = f + pb.w * step(0.5, ev) * smoothstep(0.0, 0.8, act.y) * exp(-act.y * 0.45) * (0.3 + 0.2 * act.x) * bm_gauss(x - spot, r * 1.4);
    return clamp(f, 0.0, 1.0);
}

// Soft steps: a value holds at one of BM_STEPS levels and eases to the next over the second
// half of each step, so a block brightens a level at a time, smoothly, as light reaches it.
fn bm_steps(v: f32) -> f32 {
    let s = clamp(v, 0.0, 1.0) * BM_STEPS;
    return (floor(s) + smoothstep(0.5, 1.0, fract(s))) / BM_STEPS;
}

fn bm_disc(r: f32, radius: f32, aa: f32) -> f32 {
    return 1.0 - smoothstep(radius - aa, radius + aa, r);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let seed = frame.size.w;
    let t = frame.time.x;
    let pitch = max(pa.x * max(frame.size.z, 0.25), 2.5);
    let grid = frame.size.xy / pitch;
    let d = floor(px / pitch);
    let local = px / pitch - d - 0.5;
    let x = d + 0.5;

    // The field on two block grids, the second twice as coarse and offset, so block edges step
    // at more than one size; the dot's own reading keeps the swell smooth.
    let b = max(floor(pa.y), 1.0);
    let ca = (floor(d / b) + 0.5) * b;
    let b2 = b * 2.0;
    let cb = (floor((d + b) / b2) + 0.5) * b2 - b;
    let q = 0.5 * (bm_steps(bm_field(ca, t, grid, seed)) + bm_steps(bm_field(cb, t, grid, seed)));
    let fine = bm_field(x, t, grid, seed);
    // A hot core right under the cursor, smooth and not stepped: the brightest, largest dots.
    let core = pa.w * frame.presence.x * bm_gauss(x - frame.pointer.xy / pitch, max(pa.z, 2.0) * 0.6);
    let lit = clamp(0.7 * q + 0.3 * core + 0.15 * q * fine, 0.0, 1.0);

    // A faint, even matrix everywhere; a lit dot is brighter and larger. The level is how
    // bright a dot looks, so it goes through the display's gamma to the linear color we return.
    let base = pb.x;
    let level = base + (1.0 - base) * pow(lit, 0.75);
    let radius = mix(0.13, 0.32, sqrt(lit));
    let aa = 0.6 / pitch;
    let dotA = bm_disc(length(local), radius, aa);
    // Lit dots lean to the accent by the tint; the hottest ones go back to the ink.
    let tint = mix(frame.ink.rgb, frame.accent.rgb, pb.z * smoothstep(0.05, 0.4, lit) * (1.0 - 0.5 * smoothstep(0.5, 1.0, core)));
    let col = mix(frame.paper.rgb, tint, clamp(dotA * pow(level, 2.2), 0.0, 1.0));
    return vec4<f32>(col, 1.0);
}
