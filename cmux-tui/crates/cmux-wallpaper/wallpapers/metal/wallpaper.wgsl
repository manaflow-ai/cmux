// Metal: an embossed brushed-steel plate lit by a point light that follows the pointer.
// The relief (a raised chevron, a recessed cursor slot, a turned spot face, machined grooves and a
// border groove) is a height field built from signed distances whose gradients are analytic, so the
// normal costs no extra samples. Shading is Blinn-Phong plus an anisotropic (brushed) lobe.
//
// params[0]: x relief scale, y groove count, z brush density, w gloss
// params[1]: x relief depth, y light height

fn mt_hash(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn mt_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mt_hash(i);
    let b = mt_hash(i + vec2<f32>(1.0, 0.0));
    let c = mt_hash(i + vec2<f32>(0.0, 1.0));
    let d = mt_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Signed distance and its gradient (xy = gradient, z = distance).
fn mt_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, r: f32) -> vec3<f32> {
    let pa = p - a;
    let ba = b - a;
    let t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    let v = pa - ba * t;
    let l = max(length(v), 1e-5);
    return vec3<f32>(v / l, l - r);
}

fn mt_box(p: vec2<f32>, b: vec2<f32>, r: f32) -> vec3<f32> {
    let w = abs(p) - (b - vec2<f32>(r));
    let s = select(vec2<f32>(-1.0), vec2<f32>(1.0), p >= vec2<f32>(0.0));
    let g = max(w.x, w.y);
    let q = max(w, vec2<f32>(0.0));
    let l = max(length(q), 1e-5);
    if (g > 0.0) {
        return vec3<f32>(s * q / l, l - r);
    }
    let axis = select(vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), w.x > w.y);
    return vec3<f32>(s * axis, g - r);
}

// Smoothstep profile and its derivative: x in 0..1 -> (f, f').
fn mt_prof(x: f32) -> vec2<f32> {
    let c = clamp(x, 0.0, 1.0);
    let inside = select(0.0, 1.0, x > 0.0 && x < 1.0);
    return vec2<f32>(c * c * (3.0 - 2.0 * c), 6.0 * c * (1.0 - c) * inside);
}

// A plateau (raised if amount > 0, recessed if < 0) with a bevel of width bw: returns (dh/dxy, h).
fn mt_plateau(sd: vec3<f32>, bw: f32, amount: f32) -> vec3<f32> {
    let f = mt_prof(-sd.z / bw);
    return vec3<f32>(sd.xy * (-amount * f.y / bw), amount * f.x);
}

// A groove of half width gw along the zero set of sd: returns (dh/dxy, h).
fn mt_groove(sd: vec3<f32>, gw: f32, depth: f32) -> vec3<f32> {
    let f = mt_prof(1.0 - abs(sd.z) / gw);
    let s = select(-1.0, 1.0, sd.z >= 0.0);
    return vec3<f32>(sd.xy * (depth * f.y * s / gw), -depth * f.x);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let t = frame.time.x;
    let res = frame.size.xy;
    let dark = frame.presence.w;
    let scale = frame.params[0].x;
    let grooves = frame.params[0].y;
    let brush = frame.params[0].z;
    let gloss = frame.params[0].w;
    let depth = frame.params[1].x;
    let lightZ = frame.params[1].y;

    // Plate space: height = 1, origin at the centre, y down.
    let q = (px - 0.5 * res) / res.y;
    let hw = 0.5 * res.x / res.y;

    // --- Relief ---------------------------------------------------------------------------------
    var hg = vec3<f32>(0.0); // (dh/dx, dh/dy, h)

    // The chevron, raised.
    let cc = vec2<f32>(-hw * 0.42, -0.02);
    let s = scale;
    let a = cc + vec2<f32>(-0.20, -0.30) * s;
    let b = cc + vec2<f32>(0.18, 0.0) * s;
    let c = cc + vec2<f32>(-0.20, 0.30) * s;
    let r = 0.075 * s;
    let d1 = mt_seg(q, a, b, r);
    let d2 = mt_seg(q, b, c, r);
    let chev = select(d2, d1, d1.z < d2.z);
    hg += mt_plateau(chev, 0.05 * s, 0.035 * depth);

    // The cursor slot, recessed, after the chevron.
    let slot = mt_box(q - (cc + vec2<f32>(0.50, 0.25) * s), vec2<f32>(0.17, 0.05) * s, 0.035 * s);
    hg += mt_plateau(slot, 0.025 * s, -0.02 * depth);
    let inSlot = smoothstep(0.0, -0.02 * s, slot.z);

    // A turned spot face, recessed, top right.
    let sc = vec2<f32>(hw - 0.24, -0.22);
    let rel = q - sc;
    let rl = max(length(rel), 1e-5);
    let spot = vec3<f32>(rel / rl, rl - 0.12);
    hg += mt_plateau(spot, 0.022, -0.018 * depth);
    hg += mt_groove(vec3<f32>(spot.xy, rl - 0.045), 0.006, 0.006 * depth);
    let inSpot = smoothstep(0.0, -0.015, spot.z);

    // Machined grooves, lower right: nearest groove only, so the cost is constant.
    let n = floor(grooves + 0.5);
    let sp = 0.04;
    let y0 = 0.40 - (n - 1.0) * sp;
    let gi = clamp(floor((q.y - y0) / sp + 0.5), 0.0, max(n - 1.0, 0.0));
    let gy = y0 + gi * sp;
    let gx0 = max(-hw * 0.05, cc.x + 0.72 * s);
    let gr = mt_seg(q, vec2<f32>(gx0, gy), vec2<f32>(hw - 0.12, gy), 0.0);
    hg += mt_groove(gr, 0.009, 0.008 * depth) * select(0.0, 1.0, n > 0.5);

    // A border groove around the plate.
    let border = mt_box(q, vec2<f32>(hw - 0.045, 0.455), 0.05);
    hg += mt_groove(border, 0.006, 0.007 * depth);

    // --- Brushing -------------------------------------------------------------------------------
    // Linear brushing along x on the plate; turned (tangential) inside the spot face.
    let lp = px / frame.size.z; // logical pixels
    let seed = frame.size.w * 97.0;
    let lin = 0.65 * mt_noise(vec2<f32>(lp.x * 0.006 + seed, lp.y * 0.55 * brush))
            + 0.35 * mt_noise(vec2<f32>(lp.x * 0.03 - seed, lp.y * 1.9 * brush));
    let ang = atan2(rel.y, rel.x);
    let rpx = rl * res.y / frame.size.z;
    let turned = 0.65 * mt_noise(vec2<f32>(ang * 3.0 + seed, rpx * 0.55 * brush))
               + 0.35 * mt_noise(vec2<f32>(ang * 14.0, rpx * 1.9 * brush));
    let streak = mix(lin, turned, inSpot);
    let tan2 = normalize(mix(vec2<f32>(1.0, 0.0), vec2<f32>(-rel.y, rel.x) / rl, inSpot));

    // --- Light ----------------------------------------------------------------------------------
    // At rest the light drifts on incommensurate slow sines (no visible period); with the pointer
    // inside it follows the pointer, trailing a little behind its motion.
    let drift = vec2<f32>(
        hw * (0.30 * sin(t * 0.041 + 1.3) + 0.12 * sin(t * 0.097 + 4.0)),
        -0.10 + 0.14 * sin(t * 0.033 + 0.7) + 0.06 * cos(t * 0.083));
    let pq = (frame.pointer.xy - 0.5 * res) / res.y - frame.pointer.zw / res.y * 0.06;
    let lq = mix(drift, pq, frame.presence.x);
    let L3 = vec3<f32>(lq, lightZ) - vec3<f32>(q, hg.z);
    let dist = length(L3);
    let L = L3 / dist;
    let N = normalize(vec3<f32>(-hg.xy, 1.0));
    let V = vec3<f32>(0.0, 0.0, 1.0);
    let H = normalize(L + V);
    let atten = 1.0 / (1.0 + dist * dist * 9.0);

    let ndl = max(dot(N, L), 0.0);
    let flat = max(L.z, 0.0);
    let T = normalize(vec3<f32>(tan2, 0.0) - N * dot(N, vec3<f32>(tan2, 0.0)));
    let th = dot(T, H) + (streak - 0.5) * 0.10;
    let aniso = pow(max(1.0 - th * th, 0.0), 40.0 * gloss) * (0.55 + 0.9 * streak);
    let iso = pow(max(dot(N, H), 0.0), 160.0 * gloss);
    let spec = (aniso * 0.55 + iso * 1.1) * atten * 1.5;

    // --- Tone -----------------------------------------------------------------------------------
    // Dark: graphite steel from paper to ink. Light: pale aluminium from a grey of ink to white.
    let lo = mix(mix(frame.paper.rgb, frame.ink.rgb, 0.55), frame.paper.rgb * 0.6, dark);
    let hi = mix(vec3<f32>(1.0), frame.ink.rgb, dark);
    let amb = mix(0.58, 0.07, dark);
    var tone = amb + (streak - 0.5) * mix(0.10, 0.07, dark);
    tone += (ndl - flat) * mix(0.75, 0.30, dark);          // the emboss: bevels turn to or from the light
    tone += ndl * atten * mix(0.42, 0.30, dark);            // the pool of light
    tone += min(hg.z, 0.0) * mix(3.0, 1.5, dark);           // recesses sit in shade
    tone -= inSlot * mix(0.03, 0.015, dark);
    var col = mix(lo, hi, clamp(tone, 0.0, 1.0));
    let specCol = mix(hi, frame.accent.rgb, mix(0.45, 0.30, dark));
    col = mix(col, specCol, clamp(spec * mix(0.8, 1.0, dark), 0.0, 1.0));

    // Print grain, fixed to the plate.
    let g = mt_hash(px + seed * 13.0) - 0.5;
    col += g * mix(0.035, 0.022, dark) * (0.5 + col);
    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
