// Dot field: a hex-packed lattice of faint dots in the theme's ink on its paper, each dot a fixed
// size from a slow, seed-based variation (no time term, so a frame at rest is the same frame
// whenever it is drawn). Where the pointer passes, the dots along its path (Frame.trail) light
// up: they grow, turn toward the accent with a small soft halo, and part a little from the path
// like filings, then fade as the path ages.
//
// params[0]: x pitch (points), y dot size (cell fraction), z trail radius (cells), w decay (1/s)
// params[1]: x glow, y push (parting, 0..1 of 0.2 cell), z contrast, w size variation

const DF_SQRT3: f32 = 1.7320508;
// Rows in Frame.trail, and the segments between them.
const DF_SEGMENTS: i32 = 15;
// The largest lit dot, as a fraction of the cell (the hex cell's inscribed radius is 0.5).
const DF_MAX_R: f32 = 0.42;

fn df_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn df_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = df_hash(i);
    let b = df_hash(i + vec2<f32>(1.0, 0.0));
    let c = df_hash(i + vec2<f32>(0.0, 1.0));
    let d = df_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Row `i` of the trail: (x px, y px, age s, valid). A still has no pointer history, so it draws
// a gentle arc of 16 points that ends at the still's pointer, newest first, ages 0..0.8 s.
fn df_row(i: i32, still: bool) -> vec4<f32> {
    if (still) {
        let s = f32(i) / f32(DF_SEGMENTS);
        let a = frame.size.y * 0.36;
        let t0 = 1.5708;
        let center = frame.pointer.xy - a * vec2<f32>(cos(t0), sin(t0));
        let t = t0 + s * 1.7;
        return vec4<f32>(center + a * vec2<f32>(cos(t), sin(t)), s * 0.8, 1.0);
    }
    return frame.trail[i];
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let seed = frame.size.w;
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;

    // The hex lattice: two rectangular grids, the second offset by half a cell each way; the
    // nearer center of the two is this pixel's dot.
    let pitch = max(pa.x * max(frame.size.z, 0.25), 3.0);
    let cell = vec2<f32>(pitch, pitch * DF_SQRT3);
    let ca = (floor(px / cell) + 0.5) * cell;
    let cb = (floor(px / cell - 0.5) + 1.0) * cell;
    let da = px - ca;
    let db = px - cb;
    let center = select(cb, ca, dot(da, da) < dot(db, db));

    // The trail's energy at the dot's center (so a dot is lit as one): the strongest segment's
    // Gaussian across the path, times its age's decay, interpolated along the segment. Rows are
    // uniform, so the skip of an empty segment is a uniform branch: at rest the loop is free.
    let rad = max(pa.z, 0.5) * pitch;
    let inv_r2 = 1.0 / (rad * rad);
    let decay = pa.w;
    var energy = 0.0;
    var nearest = center;
    var a = df_row(0, still);
    // The head alone (a pointer that has moved once).
    if (a.w > 0.5) {
        let d = center - a.xy;
        energy = exp(-(dot(d, d) * inv_r2 + a.z * decay)) * (1.0 - smoothstep(0.7, 1.0, a.z));
        nearest = a.xy;
    }
    for (var i = 0; i < DF_SEGMENTS; i = i + 1) {
        let b = df_row(i + 1, still);
        if (a.w * b.w > 0.5) {
            let ab = b.xy - a.xy;
            let h = clamp(dot(center - a.xy, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
            let q = a.xy + ab * h;
            let d = center - q;
            let age = mix(a.z, b.z, h);
            let e = exp(-(dot(d, d) * inv_r2 + age * decay)) * (1.0 - smoothstep(0.7, 1.0, age));
            if (e > energy) {
                energy = e;
                nearest = q;
            }
        }
        a = b;
    }
    // The head fades with the time since the pointer moved, and the whole trail with presence.
    let since = select(frame.presence.y, 0.0, still);
    energy = energy * frame.presence.x * (1.0 - smoothstep(0.6, 1.0, since));
    // The square root keeps the older part of the path visible: the tail reads as a trail, not
    // only the head.
    let lit = clamp(sqrt(energy) * pb.x, 0.0, 1.0);

    // A fixed size per dot: a slow value-noise field over the lattice, set by the seed.
    let v = df_noise(center / (pitch * 7.0) + seed * 37.0) - 0.5;
    let r0 = clamp(pa.y * (1.0 + pb.w * 1.1 * v), 0.03, 0.3);
    let r = mix(r0, DF_MAX_R, smoothstep(0.0, 1.0, lit));

    // Parting: a lit dot beside the path moves away from it (up to 0.2 cell), a dot on it stays.
    // The shift never takes the dot past its own cell, so it is never cut off.
    let away = center - nearest;
    let al = length(away);
    let dir = select(vec2<f32>(0.0), away / max(al, 1e-3), al > 1e-3);
    let push = min(pb.y * 0.2 * lit * smoothstep(0.0, 0.7 * rad, al), max(0.48 - r, 0.0));
    let local = (px - center) / pitch - dir * push;
    let dist = length(local);
    let aa = 0.75 / pitch;
    let disc = 1.0 - smoothstep(r - aa, r + aa, dist);

    // Ink at low contrast at rest; a lit dot is fuller and leans to the accent.
    // Mixed in linear light, ink on a light paper reads fainter than on a dark one: the light
    // theme gets more of it for the same apparent contrast.
    let contrast = pb.z * mix(1.8, 1.0, dark);
    let tone = mix(frame.ink.rgb, frame.accent.rgb, smoothstep(0.08, 0.7, lit));
    // A lit dot peaks lower in dark: a bright accent on a dark paper reads louder than on a light one.
    let alpha = contrast + (mix(0.75, 0.6, dark) - contrast) * smoothstep(0.0, 0.85, lit);
    var col = mix(frame.paper.rgb, tone, disc * alpha);

    // A small soft halo around a lit dot, gone before the cell's edge.
    let ring = max(dist - r, 0.0);
    let halo = lit * exp(-ring * ring * 90.0) * (1.0 - smoothstep(0.34, 0.5, dist)) * (1.0 - disc);
    let haloA = halo * mix(0.22, 0.14, dark);
    // In dark the halo adds light; in light it tints the paper.
    col = mix(mix(col, frame.accent.rgb, haloA), col + frame.accent.rgb * haloA, dark);
    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
