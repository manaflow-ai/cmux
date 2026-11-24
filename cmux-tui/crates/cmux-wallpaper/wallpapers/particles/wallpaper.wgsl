// Particles: a dithered dust field that drifts and parts around the pointer.
//
// params[0]: x cell (points per particle cell), y clearing radius (points), z drift speed, w cloud contrast
// params[1]: x dither (0 ordered 4x4, 1 blue-noise-like), y accent share at the rim, z stretch, w particle size

fn pt_hash_u(x: u32) -> u32 {
    var h = x * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    return (h >> 22u) ^ h;
}

fn pt_hash_cell(c: vec2<i32>, salt: u32) -> u32 {
    let a = bitcast<u32>(c.x) * 1597334677u;
    let b = bitcast<u32>(c.y) * 3812015801u;
    return pt_hash_u(a ^ b ^ salt);
}

fn pt_unit(h: u32) -> f32 {
    return f32(h & 0xFFFFu) / 65535.0;
}

// Value noise, one octave, hashed lattice.
fn pt_vnoise(p: vec2<f32>) -> f32 {
    let i = vec2<i32>(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = pt_unit(pt_hash_cell(i, 17u));
    let b = pt_unit(pt_hash_cell(i + vec2<i32>(1, 0), 17u));
    let c = pt_unit(pt_hash_cell(i + vec2<i32>(0, 1), 17u));
    let d = pt_unit(pt_hash_cell(i + vec2<i32>(1, 1), 17u));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Ordered 4x4 Bayer threshold, or interleaved gradient noise (a cheap blue-noise stand-in).
fn pt_threshold(px: vec2<f32>, mode: f32) -> f32 {
    let x = u32(px.x) & 3u;
    let y = u32(px.y) & 3u;
    let xy = x ^ y;
    // Bit-interleave (y ^ x, y) into a 4-bit Bayer index.
    let idx = ((xy & 1u) << 3u) | ((y & 1u) << 2u) | ((xy & 2u) << 0u) | ((y & 2u) >> 1u);
    let bayer = (f32(idx) + 0.5) / 16.0;
    let ign = fract(52.9829189 * fract(dot(floor(px), vec2<f32>(0.06711056, 0.00583715))));
    return mix(bayer, ign, step(0.5, mode));
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let t = frame.time.x;
    let ppt = max(frame.size.z, 0.25);           // backing pixels per point
    let cell = max(frame.params[0].x, 4.0) * ppt;
    let radius0 = frame.params[0].y * ppt;
    let speed = frame.params[0].z;
    let contrast = frame.params[0].w;
    let mode = frame.params[1].x;
    let accent_share = frame.params[1].y;
    let stretch_k = frame.params[1].z;
    let psize = frame.params[1].w;
    let seed = u32(frame.size.w * 65535.0);

    // The clearing: an ellipse around the pointer, stretched along its velocity and set back
    // so the wake trails behind. Inverse map in that ellipse's metric: a pixel at radius r >= R
    // reads the field at r0 = r - (R - c) exp(-(r - R) / W), so the source disc inside c is
    // pushed out of sight, the band just outside it is squeezed into a denser rim (dr0/dr = m),
    // and far out the map is the identity. Inside R nothing shows: the calm clearing.
    let present = frame.presence.x;
    let R = radius0 * present;
    let vel = frame.pointer.zw;
    let speed_px = length(vel);
    let vdir = select(vec2<f32>(1.0, 0.0), vel / max(speed_px, 1e-3), speed_px > 1e-3);
    let s = min(speed_px / (600.0 * ppt), 1.6) * stretch_k * present;
    let centre = frame.pointer.xy - vdir * R * s * 0.8;
    let d = px - centre;
    let inv_s = 1.0 / (1.0 + s);
    let along = dot(d, vdir);
    let e = d + vdir * (along * (inv_s - 1.0));
    let r = length(e);
    let c_in = R * 0.55;
    let W = max(R * 0.45, 1.0);
    let ex = exp(-max(r - R, 0.0) / W);
    let r0 = max(r - (R - c_in) * ex, 1e-3);
    let m = 1.0 + (R - c_in) / W * ex;                      // radial squeeze at this radius
    let open = smoothstep(R - 1.5 * ppt, R + 0.5 * ppt, r);
    let q = centre + d * (r0 / max(r, 1e-3));            // where this pixel reads the field
    let u = d / max(length(d), 1e-3);                    // radial direction, for particle shape
    let tan_k = r / r0;                                  // tangential stretch at this radius

    // Slow, non-periodic drift of the whole field, plus a dust cloud that morphs as it drifts.
    let drift = vec2<f32>(7.0, 2.6) * speed * ppt * t;
    let qd = q + drift;
    let cloud_p = (q + drift * 0.55) / (cell * 18.0) + frame.size.w * 37.0;
    let n = pt_vnoise(cloud_p) * 0.68 + pt_vnoise(cloud_p * 2.13 + 5.2) * 0.32;
    let cloud = clamp(0.5 + (n - 0.5) * contrast * 2.4, 0.0, 1.0);

    // Particles: one per cell, jittered and wandering; check the 3x3 neighbourhood.
    let g = qd / cell;
    let gi = vec2<i32>(floor(g));
    var ink_i = 0.0;
    var acc_i = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let cc = gi + vec2<i32>(i, j);
            let h0 = pt_hash_cell(cc, seed);
            let h1 = pt_hash_u(h0);
            let h2 = pt_hash_u(h1);
            let jit = vec2<f32>(pt_unit(h0), pt_unit(h0 >> 16u)) - 0.5;
            let w = vec2<f32>(pt_unit(h1), pt_unit(h1 >> 16u));
            let ph = w * 6.2831;
            let fr = 0.06 + w.yx * 0.11;
            let wander = vec2<f32>(sin(t * fr.x + ph.x), cos(t * fr.y + ph.y)) * 0.22;
            let p = (vec2<f32>(cc) + 0.5 + jit * 0.56 + wander) * cell;
            let size_h = pt_unit(h2);
            // Mostly fine dust, a few larger grains.
            let rad = cell * psize * (0.18 + 0.42 * size_h * size_h * size_h);
            // Distance as it shows on screen: undo the map's local squeeze and stretch so a
            // pushed particle stays round instead of smearing along the rim.
            let o = qd - p;
            let orad = dot(o, u);
            let otan = o - orad * u;
            let od = orad * u / m + otan * tan_k;
            let dist = length(od);
            // Particles whose source sat inside c_in were pushed out of sight; a few of the
            // ones that now line the rim take the accent.
            let sp = p - drift - centre;
            let sa = dot(sp, vdir);
            let r0p = length(sp + vdir * (sa * (inv_s - 1.0)));
            let gone = step(r0p, c_in) * step(1.0, R);
            let lit = pt_unit(h2 >> 16u);
            let exists = step(lit, 0.25 + 0.75 * cloud) * (1.0 - gone);
            let b = (0.35 + 0.65 * lit * lit) * exists;
            let fall = clamp(1.0 - dist / rad, 0.0, 1.0);
            let v = b * min(fall * 1.8, 1.0);  // a solid core, a dithered halo
            let rx = (r0p - c_in) / (W * 0.8);
            let rimness = exp(-rx * rx) * step(0.5, present) * step(1.0, R);
            let is_acc = step(pt_unit(h1 >> 8u), accent_share * rimness);
            // An accent grain reads a touch larger, so the few there are hold their color.
            let fall_a = clamp(1.0 - dist / (rad * 1.7), 0.0, 1.0);
            let va = exists * min(fall_a * 2.0, 1.0);
            ink_i += v * (1.0 - is_acc);
            acc_i += va * is_acc;
        }
    }

    // Faint haze in the cloud: sparse dithered specks between particles.
    let th = pt_threshold(px, mode);
    let total = (ink_i + acc_i) * open;
    let on = step(th, total);
    let haze = cloud * cloud * 0.05 * open;
    let speck = step(pt_unit(pt_hash_cell(vec2<i32>(px), 53u)), haze) * (1.0 - on);

    let paper = frame.paper.rgb;
    let ink = frame.ink.rgb;
    let grain = (pt_unit(pt_hash_cell(vec2<i32>(px), 91u)) - 0.5) * 0.02;
    var col = paper * (1.0 + grain);
    let dot_col = select(ink, frame.accent.rgb, acc_i > ink_i);
    col = mix(col, dot_col, on * 0.88);
    col = mix(col, ink, speck * 0.32);
    return vec4<f32>(col, 1.0);
}
