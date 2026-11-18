// Block matrix: a fine, even matrix of faint dots, lit by one smooth field of light. The field is
// a glow centered on the pointer with a short trail behind it, a few large soft lights that drift
// and ease in and out, and the agents' output. Each dot's brightness is the field read on two
// coarse block grids and softly stepped, so light arrives in rectangular blocks that ease between
// levels, while the dots themselves still swell smoothly toward the pointer.
//
// params[0]: x dot pitch (points), y block size (dots), z glow radius (dots), w pointer glow
// params[1]: x matrix level, y ambient light, z accent tint, w activity response

const BM_STEPS: f32 = 4.0;

fn bm_hash(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q = q + dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

fn bm_gauss(d: vec2<f32>, r: f32) -> f32 {
    return exp(-dot(d, d) / (r * r));
}

// The light at `x` (in dots): the pointer and its trail, the drifting lights and the newest
// agent event, summed and clamped to 0..1.
fn bm_field(x: vec2<f32>, t: f32, grid: vec2<f32>, seed: f32) -> f32 {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let pitch = max(pa.x * max(frame.size.z, 0.25), 2.5);
    let present = frame.presence.x;

    // The pointer, centered on the cursor; the trail sits where it was a moment ago.
    let r = max(pa.z, 2.0);
    let p = frame.pointer.xy / pitch;
    var back = frame.pointer.zw / pitch * 0.16;
    let backLen = length(back);
    if (backLen > r * 2.5) {
        back = back * (r * 2.5 / backLen);
    }
    var f = pa.w * present * (bm_gauss(x - p, r) + 0.55 * bm_gauss(x - (p - back), r * 1.25));

    // Four large lights that drift slowly and ease in and out, each over its own period.
    let reach = min(grid.x, grid.y);
    for (var i = 0; i < 4; i = i + 1) {
        let fi = f32(i);
        let h = bm_hash(vec3<f32>(fi, seed, 3.0));
        let c = grid * (vec2<f32>(0.5) + vec2<f32>(0.44 * sin(t * 0.031 * (1.0 + h) + fi * 2.1), 0.42 * cos(t * 0.026 * (1.0 + 0.7 * h) + fi * 1.3)));
        let period = 11.0 + 6.0 * h;
        let tt = t + fi * 3.7;
        let epoch = floor(tt / period);
        let ph = tt / period - epoch;
        let ease = smoothstep(0.0, 0.35, ph) * (1.0 - smoothstep(0.6, 1.0, ph));
        let amp = pb.y * (0.45 + 0.55 * bm_hash(vec3<f32>(epoch, fi, seed)));
        f = f + amp * ease * bm_gauss(x - c, reach * (0.22 + 0.12 * h));
    }

    // The newest agent event: a light at a place set by its count, fading over a few seconds.
    var act = frame.activity;
    if (frame.time.w > 0.5) {
        act = vec4<f32>(0.5, 0.6, 7.0, 0.0);
    }
    let ev = act.z;
    let spot = vec2<f32>(bm_hash(vec3<f32>(ev, seed, 1.0)), bm_hash(vec3<f32>(ev, seed, 2.0))) * grid;
    f = f + pb.w * step(0.5, ev) * exp(-act.y * 0.9) * (0.5 + 0.3 * act.x) * bm_gauss(x - spot, r * 1.4);
    return clamp(f, 0.0, 1.0);
}

// Soft steps: a value holds at one of BM_STEPS levels and eases to the next over the last
// fifth of each step, so a block brightens smoothly as light reaches it.
fn bm_steps(v: f32) -> f32 {
    let s = clamp(v, 0.0, 1.0) * BM_STEPS;
    return (floor(s) + smoothstep(0.82, 1.0, fract(s))) / BM_STEPS;
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
    let core = pa.w * frame.presence.x * bm_gauss(x - frame.pointer.xy / pitch, max(pa.z, 2.0) * 0.4);
    let lit = clamp(0.62 * q + 0.38 * core + 0.2 * q * fine, 0.0, 1.0);

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
