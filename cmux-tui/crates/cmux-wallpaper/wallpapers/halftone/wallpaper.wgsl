// Halftone waves: a rotated dot screen whose dot sizes follow slow travelling waves of tone.
// Where the pointer passes, the dots swell; the swollen part prints in the accent ink, a hair
// out of register, like a second risograph plate.
//
// params[0]: x cell (points), y screen angle (degrees), z tone (mean coverage), w drift speed
// params[1]: x wake (how far dots swell), y wake radius (cells), z misregister (points), w grain

fn ht_hash2(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn ht_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = ht_hash2(i);
    let b = ht_hash2(i + vec2<f32>(1.0, 0.0));
    let c = ht_hash2(i + vec2<f32>(0.0, 1.0));
    let d = ht_hash2(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Tone (0..1 coverage) at a screen point, in units of the backdrop height.
fn ht_tone(p: vec2<f32>, t: f32, seed: f32, mean: f32) -> f32 {
    // Two plane waves at incommensurate speeds and one drifting noise octave: no visible period.
    let w1 = sin(dot(p, vec2<f32>(0.83, 0.56)) * 3.1 + t * 0.131 + seed * 6.28);
    let w2 = sin(dot(p, vec2<f32>(-0.38, 0.92)) * 5.3 - t * 0.0877);
    let n = ht_noise(p * 2.2 + vec2<f32>(t * 0.0213, -t * 0.0161) + seed * 17.0);
    let v = 0.42 * w1 + 0.26 * w2 + 1.1 * (n - 0.5);
    // Lows empty out to bare paper, highs fill toward a solid; the mean sets the overall weight.
    let s = clamp(0.5 + 0.48 * v, 0.0, 1.0);
    return clamp(mean * 2.6 * s * s, 0.0, 0.85);
}

fn ht_disc(d: f32, r: f32, aa: f32) -> f32 {
    return 1.0 - smoothstep(r - aa, r + aa, d);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let size = frame.size.xy;
    let scale = max(frame.size.z, 0.25);
    let t = frame.time.x;
    let seed = frame.size.w;
    let pa = frame.params[0];
    let pb = frame.params[1];

    let cell = max(pa.x * scale, 3.0);
    let ang = radians(pa.y);
    let cs = cos(ang);
    let sn = sin(ang);
    let speed = pa.w;
    let ts = t * speed;

    // Screen space -> rotated cell space.
    let q = vec2<f32>(cs * px.x + sn * px.y, -sn * px.x + cs * px.y) / cell;
    let id = floor(q);
    let local = q - id - 0.5;
    let cq = (id + 0.5) * cell;
    let center = vec2<f32>(cs * cq.x - sn * cq.y, sn * cq.x + cs * cq.y);

    // Base tone, sampled once per cell (so each dot is one size, as on a plate).
    let tone = ht_tone(center / size.y, ts, seed, pa.z);

    // The wake: a capsule from the pointer back along its velocity (where it was ~0.3 s ago),
    // strongest at the head, decaying over about a second after the pointer stops.
    let still = frame.time.w;
    var vel = frame.pointer.zw;
    var since = frame.presence.y;
    if (still > 0.5) {
        // A still has no motion; print the wake of a slow diagonal pass that just happened.
        vel = vec2<f32>(-0.55, 0.32) * size.y;
        since = 0.12;
    }
    let tail = vel * 0.32;
    let tl = length(tail);
    let maxTail = size.y * 0.45;
    let tailv = select(tail, tail * (maxTail / max(tl, 1e-3)), tl > maxTail);
    let head = frame.pointer.xy;
    let back = head - tailv;
    let ba = head - back;
    let h = clamp(dot(center - back, ba) / max(dot(ba, ba), 1e-3), 0.0, 1.0);
    let dseg = length(center - back - ba * h);
    let rad = pb.y * cell * (0.7 + 0.3 * h);
    let fall = exp(-(dseg * dseg) / (rad * rad));
    let decay = exp(-since * 2.6);
    let rest = 0.22;
    let wake = clamp(frame.presence.x * fall * (rest + (1.0 - rest) * decay) * (0.35 + 0.65 * h), 0.0, 1.0);

    // Dot radii in cell units: area-true for the tone, then swollen by the wake.
    let r0 = sqrt(tone / 3.14159);
    // Swollen dots stay separate (r below ~0.46), so the wake reads as dots, not a patch.
    let r1 = r0 + wake * pb.x * max(0.46 - r0, 0.06);
    let aa = 0.8 / cell;
    let ink = ht_disc(length(local), r0, aa);

    // The accent plate: same screen, shifted a little (misregistered), only the swell prints.
    // It prints under the ink dot, so a dot reads as ink with an accent rim pushed off to one side.
    let gate = smoothstep(0.04, 0.3, wake);
    let mis = pb.z * scale / cell;
    let off = vec2<f32>(0.72, -0.55) * mis * gate;
    let acc = ht_disc(length(local - off), r1 * gate, aa);

    // Paper grain: a fine per-pixel tooth plus a soft blotch, both static under the dots.
    let g = ht_hash2(floor(px) + seed * 311.0) - 0.5;
    let blot = ht_noise(px / (cell * 7.0) + seed * 5.0) - 0.5;
    let grain = pb.w;
    let dark = frame.presence.w;

    let paper = frame.paper.rgb * (1.0 + grain * (0.9 * g + 0.6 * blot) * (1.0 + 2.0 * dark));
    // Ink density varies a touch per dot, as with a real drum.
    let dens = 0.86 + 0.14 * ht_hash2(id + 7.0);
    // Ink stays a mid-weight print (the wallpaper sits under code); in the wake the ink plate
    // thins so the swollen dots read in the accent with a darker, offset core.
    let inkA = mix(0.74, 0.58, dark) * (1.0 - 0.5 * gate);
    var col = mix(paper, frame.accent.rgb, acc * 0.95);
    // The ink plate overprints the accent: in light, a multiply; in dark, ink is light, so a mix.
    let over = mix(col * frame.ink.rgb, frame.ink.rgb, dark);
    col = mix(col, over, ink * dens * inkA);
    col = col + grain * 0.5 * g * (frame.ink.rgb - frame.paper.rgb) * 0.05;
    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}
