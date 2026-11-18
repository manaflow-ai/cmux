// Block matrix: a fine dot matrix on the paper where rectangular blocks of dots light up, hold
// and fade at their own levels, the way pages of a store fill and drain. Each lattice of blocks
// drifts a whole dot at a time, so the dots never leave the grid. Blocks near the pointer glow
// brighter, and the agents' output lights blocks: the newest event flashes one, and the
// activity level lights more of them.
//
// params[0]: x dot pitch (points), y block density, z speed, w pointer glow
// params[1]: x glow radius (dots), y base level, z activity response, w block size (dots)

fn bm_hash(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q = q + dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

// One lattice of blocks at dot `d`: cells of `bsize` dots, shifted `shift` whole dots. Each cell
// lives through periods of 5 to 9 seconds; in a period it is lit or not, as a rectangle filling
// part of the cell, at its own level, rising fast and fading slowly.
fn bm_layer(d: vec2<f32>, t: f32, layer: f32, bsize: vec2<f32>, shift: vec2<f32>, density: f32, seed: f32) -> f32 {
    let q = (d + shift) / bsize;
    let cell = floor(q);
    let key = vec3<f32>(cell, layer * 7.31 + seed * 13.7);
    let period = 5.0 + 4.0 * bm_hash(key);
    let tt = t + bm_hash(key + 17.0) * period;
    let epoch = floor(tt / period);
    let age = tt - epoch * period;
    let ekey = vec3<f32>(cell, epoch * 1.37 + layer * 101.0 + seed * 7.0);
    let lit = step(bm_hash(ekey), density);
    // The lit rectangle: its corner at the cell's corner, half to all of the cell on each axis,
    // in whole dots.
    let extent = floor(mix(vec2<f32>(0.5), vec2<f32>(1.0), vec2<f32>(bm_hash(ekey + 3.0), bm_hash(ekey + 5.0))) * bsize);
    let inside = step(d.x + shift.x - cell.x * bsize.x, extent.x - 0.5) * step(d.y + shift.y - cell.y * bsize.y, extent.y - 0.5);
    let level = 0.2 + 0.8 * bm_hash(ekey + 9.0);
    let fade = 0.25 + 0.35 * bm_hash(ekey + 11.0);
    let env = smoothstep(0.0, 0.5, age) * exp(-age * fade);
    return lit * inside * level * env;
}

fn bm_disc(r: f32, radius: f32, aa: f32) -> f32 {
    return 1.0 - smoothstep(radius - aa, radius + aa, r);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let size = frame.size.xy;
    let scale = max(frame.size.z, 0.25);
    let seed = frame.size.w;
    let still = frame.time.w > 0.5;
    let pa = frame.params[0];
    let pb = frame.params[1];
    let t = frame.time.x * pa.z;

    let pitch = max(pa.x * scale, 2.5);
    let d = floor(px / pitch);
    let local = px / pitch - d - 0.5;
    let center = (d + 0.5) * pitch;

    // The activity: x level (eased 0..1), y seconds since the newest event, z event count.
    var act = frame.activity;
    if (still) {
        // A still shows a moment just after an agent wrote something.
        act = vec4<f32>(0.5, 0.6, 7.0, 0.0);
    }
    let response = pb.z;
    let density = clamp(pa.y + act.x * response * 0.3, 0.0, 0.95);

    // Three lattices of different block sizes, each drifting its own way a dot at a time.
    let b = max(pb.w, 2.0);
    let s0 = floor(vec2<f32>(0.37, 0.11) * t);
    let s1 = floor(vec2<f32>(-0.21, 0.29) * t) + 41.0;
    let s2 = floor(vec2<f32>(0.13, -0.33) * t) + 97.0;
    var v = bm_layer(d, t, 0.0, vec2<f32>(b * 2.0, b), s0, density, seed);
    v = max(v, bm_layer(d, t * 0.8, 1.0, vec2<f32>(b, b * 1.5), s1, density, seed));
    v = max(v, 0.7 * bm_layer(d, t * 1.2, 2.0, vec2<f32>(b * 3.0, b * 2.0), s2, density * 0.6, seed));

    // The newest agent event flashes one block, placed by its count.
    let ev = act.z;
    let spot = vec2<f32>(bm_hash(vec3<f32>(ev, seed, 1.0)), bm_hash(vec3<f32>(ev, seed, 2.0))) * size / pitch;
    let span = floor(vec2<f32>(b * (1.0 + 1.5 * bm_hash(vec3<f32>(ev, 3.0, seed))), b * (0.6 + 0.8 * bm_hash(vec3<f32>(ev, 4.0, seed)))));
    let inFlash = step(0.0, d.x - floor(spot.x)) * step(d.x - floor(spot.x), span.x - 1.0)
        * step(0.0, d.y - floor(spot.y)) * step(d.y - floor(spot.y), span.y - 1.0);
    let flash = inFlash * response * exp(-act.y * 1.4) * step(0.5, ev);
    v = max(v, flash);

    // The pointer: a soft glow in dots, and lit blocks under it brighter still.
    let pr = max(pb.x, 1.0) * pitch;
    let pd = center - frame.pointer.xy;
    let near = frame.presence.x * exp(-dot(pd, pd) / (pr * pr));
    let glow = pa.w;
    v = clamp(v * (1.0 + 1.5 * near * glow) + 0.45 * near * glow, 0.0, 1.0);

    // A faint matrix everywhere, the lit dots on top; a brighter dot is a little larger.
    let base = pb.y;
    let level = max(v, base);
    let radius = mix(0.14, 0.34, sqrt(level));
    let aa = 0.9 / pitch;
    let dotA = bm_disc(length(local), radius, aa);
    let dark = frame.presence.w;
    // Dim dots print in the ink, lit ones lean to the accent; the brightest near the pointer
    // go back toward the ink, like the hot center of a glow.
    var tint = mix(frame.ink.rgb, frame.accent.rgb, smoothstep(0.12, 0.6, v) * 0.85);
    tint = mix(tint, frame.ink.rgb, near * glow * 0.4);
    // Dim dots fall off faster than their level, so the resting matrix stays faint.
    let alpha = dotA * mix(0.15, 1.0, level) * level * mix(0.9, 1.0, dark);
    let col = mix(frame.paper.rgb, tint, clamp(alpha * 1.6, 0.0, 1.0));
    return vec4<f32>(col, 1.0);
}
