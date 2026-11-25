// Liquid Gradient: five soft blobs of color that wander on slow, incommensurate paths with a
// low-frequency wiggle and flow into each other, like the blurred, wiggled shapes of a motion
// graphics gradient. Each blob is a wide Gaussian; their sum is the field (a metaball), its
// squares weight the colors, so where two meet the colors melt into one another and nothing has
// an edge. The ground is the theme's paper; the blobs are the accent, two hue turns of it, an
// accent-ink mix and a deep accent. The blobs lean gently toward the pointer. Agent output pushes
// the flow forward (each event advances it a little, eased), lifts the accent blob's saturation
// and brightness with the activity level, and a new event sends a soft swell through every blob.
// A triangular dither (and optional grain) keeps the big gradients from banding in 8 bits.
//
// params[0]: x speed, y blob size, z intensity, w warp (wiggle of the blob shapes)
// params[1]: x hue spread (turns of the color wheel), y pointer lean, z agent response, w grain

const LG_BLOBS: i32 = 5;
const LG_TAU: f32 = 6.2831853;

fn lg_hash(x: u32, y: u32, z: u32) -> f32 {
    var h = x * 1597334677u ^ y * 3812015801u ^ z * 2798796415u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h = h ^ (h >> 16u);
    return f32(h) * (1.0 / 4294967296.0);
}

fn lg_hash1(x: f32) -> f32 {
    return fract(sin(x * 127.1 + 311.7) * 43758.5453);
}

// Turns a color about the gray axis by `a` radians (a hue shift that keeps its lightness close).
fn lg_hue(c: vec3<f32>, a: f32) -> vec3<f32> {
    let k = vec3<f32>(0.57735027);
    let ca = cos(a);
    let r = c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
    return max(r, vec3<f32>(0.0));
}

fn lg_luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let speed = pa.x;
    let size = select(pa.y, 1.0, pa.y <= 0.0);
    let intensity = pa.z;
    let warp = pa.w;
    let spread = pb.x * LG_TAU;
    let lean = pb.y;
    let response = pb.z;
    let grain = pb.w;
    let seed = frame.size.w;
    let h = max(frame.size.y, 1.0);
    let aspect = frame.size.x / h;
    let p = px / h;

    // Agent activity. A still shows a calm, lightly active window.
    var act = frame.activity;
    if (frame.time.w > 0.5) {
        act = vec4<f32>(0.4, 4.0, 3.0, 0.0);
    }
    let level = clamp(act.x, 0.0, 1.0);
    // Each event advances the flow by `push` seconds' worth, eased over two seconds. The sum is
    // continuous: just before an event (count n - 1, eased to 1) and just after (count n, eased
    // from 0) it reads n. It steps once every 1024 events, when the count wraps.
    let push = 3.0 * response * (act.z + smoothstep(0.0, 2.0, act.y));
    let t = frame.time.x * speed + push + seed * 300.0;
    let swell = response * step(0.5, act.z) * smoothstep(0.0, 0.3, act.y) * exp(-act.y * 1.1);

    // A slow wiggle of the whole field, so the blobs bend and morph rather than stay round. It
    // grows a little with activity.
    let wa = 0.05 * warp * (1.0 + 0.6 * level * response);
    let q = p + wa * vec2<f32>(sin(p.y * 2.3 + t * 0.31 + 1.7), sin(p.x * 1.9 - t * 0.27 + 0.4));

    // Colors in a perceptual (sqrt) space: the paper ground and five blob colors from the accent.
    let dark = frame.presence.w > 0.5;
    let pp = sqrt(frame.paper.rgb);
    let ip = sqrt(frame.ink.rgb);
    let ap = sqrt(frame.accent.rgb);
    // The accent blob: saturation and brightness rise with the agents' activity.
    let lift = level * response;
    let al = lg_luma(ap);
    let a0 = mix(vec3<f32>(al), ap, 1.0 + 0.45 * lift) * (1.0 + 0.18 * lift);
    var cols: array<vec3<f32>, 5>;
    cols[0] = max(a0, vec3<f32>(0.0));
    cols[1] = lg_hue(ap, spread);
    cols[2] = lg_hue(ap, -0.8 * spread);
    cols[3] = mix(ap, ip, 0.35);
    cols[4] = lg_hue(ap, 1.7 * spread) * select(0.78, 0.62, dark);

    // The pointer, in the same units; the blobs lean toward it while it is over the window.
    let ptr = frame.pointer.xy / h;
    let pull = 0.22 * lean * frame.presence.x;

    var field = 0.0;
    var acc = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var i = 0; i < LG_BLOBS; i = i + 1) {
        let fi = f32(i);
        let hs = lg_hash1(fi + seed * 17.0);
        let hr = lg_hash1(fi * 3.7 + 11.0 + seed * 5.0);
        // Rates are irrational multiples of each other, so the paths never line up again.
        let w1 = 0.083 * (1.0 + 0.4142 * fi) * (0.85 + 0.3 * hs);
        let w2 = 0.067 * (1.0 + 0.2361 * fi) * (0.85 + 0.3 * hr);
        let ph = LG_TAU * vec2<f32>(hs, hr);
        var c = vec2<f32>(
            aspect * (0.5 + 0.40 * sin(t * w1 + ph.x)),
            0.5 + 0.36 * sin(t * w2 + ph.y),
        );
        // The wiggle: two faster, smaller sines per axis, like a low-frequency noise.
        c = c + 0.045 * vec2<f32>(
            sin(t * 0.41 * (1.0 + 0.13 * fi) + ph.y) + 0.6 * sin(t * 0.73 + fi * 2.1),
            sin(t * 0.37 * (1.0 + 0.17 * fi) + ph.x) + 0.6 * sin(t * 0.67 + fi * 1.3),
        );
        let toward = ptr - c;
        c = c + toward * pull * exp(-dot(toward, toward) * 2.0);
        let r = size * (0.26 + 0.14 * hr) * (1.0 + 0.28 * swell);
        let d = q - c;
        let g = exp(-dot(d, d) / (r * r));
        field = field + g;
        let w = g * g + 1e-6;
        acc = acc + cols[i] * w;
        wsum = wsum + w;
    }
    let blend = acc / wsum;

    // Coverage: a wide, soft rise of the summed field, so the ground shows between blobs with no
    // edge. Intensity keeps the whole thing low-contrast under code; light themes take the blobs
    // a little toward the paper so they read as tints.
    let cover = 1.0 - exp(-field * 1.7);
    let tint = select(mix(blend, pp, 0.18), blend, dark);
    // Dark paper shows color more strongly than light paper does, so dark takes a little less.
    let amount = clamp(intensity * select(1.0, 0.85, dark) * (1.0 + 0.25 * swell) * cover, 0.0, 1.0);
    var col = mix(pp, tint, amount);

    // Dither: triangular, one 8-bit step wide in this (near sRGB) space, new each frame, so the
    // gradient never bands; grain adds a faint film grain on top.
    let ix = u32(px.x);
    let iy = u32(px.y);
    let fz = u32(frame.time.z);
    let tri = lg_hash(ix, iy, fz) + lg_hash(ix + 7919u, iy + 104729u, fz) - 1.0;
    col = col + tri * (1.0 / 255.0 + grain * 0.03);
    col = max(col, vec3<f32>(0.0));
    return vec4<f32>(col * col, 1.0);
}
