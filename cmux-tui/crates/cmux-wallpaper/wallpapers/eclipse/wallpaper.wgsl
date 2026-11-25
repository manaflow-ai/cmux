// Eclipse: a dark disc (the moon) over a glowing disc of the same size, set slightly off its
// center, so only a thin bright rim shows: brightest on one arc, which turns slowly around the
// disc while the corona breathes. A soft bloom falls off around the rim, and faint rays stream
// out of it (warped sines of the polar angle with whole-number frequencies, so the pattern has no
// seam). It sits upper right by default and stays low-contrast so it can lie behind code. In a
// dark theme the rim glows in the accent on the dark paper and the disc is darker still; in a
// light theme the ground stays light, the disc is a shade darker than the paper and the rim and
// corona are a deeper accent. Agent activity brightens and widens the rim; a new agent event sends
// a flare running along the rim. The disc shifts a little against the pointer (parallax).
//
// params[0]: x disc radius (fraction of the height), y center x (fraction of the width),
//            z center y (fraction of the height), w speed
// params[1]: x rim brightness, y corona and rays, z agent response, w pointer parallax

const EC_TAU: f32 = 6.2831853;

fn ec_hash(x: u32, y: u32, z: u32) -> f32 {
    var h = x * 1597334677u ^ y * 3812015801u ^ z * 2798796415u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h = h ^ (h >> 16u);
    return f32(h) * (1.0 / 4294967296.0);
}

// An angle folded into -pi..pi.
fn ec_wrap(a: f32) -> f32 {
    return a - EC_TAU * round(a / EC_TAU);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let radius = select(pa.x, 0.16, pa.x <= 0.0);
    let speed = pa.w;
    let rimGain = pb.x;
    let corona = pb.y;
    let response = pb.z;
    let parallax = pb.w;
    let seed = frame.size.w;
    let h = max(frame.size.y, 1.0);
    let p = px / h;
    let t = frame.time.x * speed + seed * 100.0;

    var act = frame.activity;
    if (frame.time.w > 0.5) {
        act = vec4<f32>(0.35, 4.0, 2.0, 0.0);
    }
    let level = clamp(act.x, 0.0, 1.0) * response;

    // The disc's center; it moves a little against the pointer, as if nearer than the ground.
    let half = frame.size.xy / h * 0.5;
    var c = vec2<f32>(pa.y * frame.size.x, pa.z * frame.size.y) / h;
    c = c - (frame.pointer.xy / h - half) * 0.025 * parallax * frame.presence.x;

    let d = p - c;
    let r = length(d);
    let ang = atan2(d.y, d.x);
    let edge = r - radius;
    let aa = 1.2 / h;
    let outside = smoothstep(-aa, aa, edge);

    // The glowing disc sits off the moon's center toward the bright arc, which turns slowly.
    let theta = t * 0.12 + 0.6 * sin(t * 0.043);
    let o = radius * 0.05 * vec2<f32>(cos(theta), sin(theta));
    let dg = length(p - c - o) - radius;
    let breathe = 1.0 + 0.12 * sin(t * 0.37) + 0.06 * sin(t * 0.61 + 1.0);
    let rimW = radius * 0.012 * (1.0 + 0.6 * level) * breathe;
    let arc = 0.5 + 0.5 * cos(ang - theta);
    // The thin rim: the crescent of the glowing disc past the moon, its edge falling off fast,
    // plus a faint ring all the way around.
    var rim = outside * (exp(-max(dg, 0.0) / rimW) + 0.22 * exp(-max(edge, 0.0) / (radius * 0.02)));
    rim = rim * rimGain * (1.0 + 0.7 * level);

    // The corona: a soft bloom near the rim, strongest on the bright arc, and a wide halo.
    let e = max(edge, 0.0);
    var glow = exp(-e / (radius * 0.32 * breathe)) * (0.3 + 0.7 * arc * arc) + 0.35 * exp(-e / (radius * 1.6));

    // Rays: two streak patterns over the angle, each phase-warped by a slower one, drifting.
    let r1 = 0.5 + 0.5 * sin(ang * 9.0 + 1.7 * sin(ang * 4.0 + t * 0.07) + t * 0.021);
    let r2 = 0.5 + 0.5 * sin(ang * 23.0 - t * 0.05 + 3.0 * sin(ang * 2.0 + t * 0.04));
    let stream = 0.75 + 0.25 * sin(r / radius * 6.0 - t * 0.45 + ang * 3.0);
    // Uneven lengths and strengths, so the rays read as a corona and not a star.
    let uneven = 0.55 + 0.45 * sin(ang * 3.0 + t * 0.031) * sin(ang * 5.0 - t * 0.023 + 1.0);
    let reach = radius * (0.6 + 0.6 * uneven);
    let rays = (pow(r1, 6.0) + 0.6 * pow(r2, 10.0)) * uneven * stream * exp(-e / reach) * (0.5 + 0.5 * arc);
    glow = outside * corona * (glow + 0.8 * rays) * (1.0 + 0.3 * level);

    // A new agent event: a flare that starts at a spot set by the event's number and runs along
    // the rim, with a short tail, fading over a few seconds.
    let since = act.y;
    let amp = 1.6 * response * step(0.5, act.z) * smoothstep(0.0, 0.15, since) * exp(-since * 0.7);
    let start = EC_TAU * fract(sin(act.z * 12.9898 + seed * 78.233) * 43758.5453);
    let behind = -ec_wrap(ang - (start + since * 0.9));
    let along = exp(-behind * behind / 0.03) + 0.6 * smoothstep(-0.15, 0.1, behind) * exp(-max(behind, 0.0) * 2.0);
    let flare = amp * along * outside;
    rim = rim + flare * exp(-e / (radius * 0.1));
    glow = glow + 0.9 * flare * exp(-e / (radius * 0.4));

    // Colors in a perceptual (sqrt) space.
    let dark = frame.presence.w > 0.5;
    let pp = sqrt(frame.paper.rgb);
    let ip = sqrt(frame.ink.rgb);
    let ap = sqrt(frame.accent.rgb);
    let moon = select(mix(pp, ip, 0.14), pp * 0.55, dark);
    let glowC = select(mix(ap, pp, 0.2), ap, dark);
    let rimC = select(ap * 0.82, mix(ap, vec3<f32>(1.0), 0.5), dark);

    var col = mix(moon, pp, outside);
    col = mix(col, glowC, clamp(glow * 0.45, 0.0, 1.0));
    col = mix(col, rimC, clamp(rim * 0.8, 0.0, 1.0));

    // Dither: triangular, one 8-bit step, new each frame, so the bloom does not band.
    let ix = u32(px.x);
    let iy = u32(px.y);
    let fz = u32(frame.time.z);
    let tri = ec_hash(ix, iy, fz) + ec_hash(ix + 7919u, iy + 104729u, fz) - 1.0;
    col = max(col + tri * (1.0 / 255.0), vec3<f32>(0.0));
    return vec4<f32>(col * col, 1.0);
}
