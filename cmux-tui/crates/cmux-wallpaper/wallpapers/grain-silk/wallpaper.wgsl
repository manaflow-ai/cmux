// Grain and Silk: light on draped satin, photographed on film. Diagonal folds of varying width bend
// slowly; each ridge carries a narrow specular streak along the fold. The fold under the pointer
// lifts and its streak takes the accent; a fast pointer leaves a ripple that settles as the host's
// smoothed velocity decays. Pure function of `frame` and `px`.
//
// params[0]: x scale (fold frequency), y speed, z grain, w sheen (contrast)

const GS_ALONG: vec2<f32> = vec2<f32>(0.80, 0.60);
const GS_ACROSS: vec2<f32> = vec2<f32>(-0.60, 0.80);

fn gs_hash(x: u32, y: u32, z: u32) -> f32 {
    var h = x * 1597334677u ^ y * 3812015801u ^ z * 2798796415u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h = h ^ (h >> 16u);
    return f32(h) * (1.0 / 4294967296.0);
}

// Distance from p to the segment a..b, and how far along it (0 at a).
fn gs_segment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    let ab = b - a;
    let t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return vec2<f32>(length(p - a - ab * t), t);
}

// The satin's height at p (units of backdrop height times scale). Folds run along GS_ALONG; their
// line bends slowly (curvature), their phase is frequency-modulated (folds of varying width), their
// amplitude swells and fades along their length, and a broad billow lies under them. Rates are
// incommensurate, so no period shows. The fold under the pointer is raised; a fast pointer leaves
// a wake.
fn gs_height(p: vec2<f32>, t: f32, ptr: vec2<f32>, lift: f32, r: f32, tail: vec2<f32>, wake: f32, now: f32) -> f32 {
    let u0 = dot(p, GS_ACROSS);
    let v = dot(p, GS_ALONG);
    let u = u0 + 0.34 * sin(v * 1.05 + t * 0.023 + 1.3);
    let phi = u * 9.0 + 1.1 * sin(u * 2.3 + v * 0.45 + t * 0.047) + t * 0.061;
    let amp = 0.72 + 0.28 * sin(v * 0.85 + u * 0.35 - t * 0.017 + 0.6);
    var h = amp * (sin(phi) + 0.24 * sin(phi * 2.0 + 1.2));
    h += 0.30 * sin(u * 2.1 - v * 0.55 + t * 0.029 + 2.0);
    let d = p - ptr;
    let near = exp(-dot(d, d) / (r * r));
    h = h * (1.0 + 0.8 * lift * near) + 0.12 * lift * near;
    let sg = gs_segment(p, ptr, tail);
    let ds = sqrt(sg.x * sg.x + 0.01);
    h += wake * (1.0 - 0.8 * sg.y) * sin(ds * 24.0 - now * 5.0) * exp(-ds * 3.5);
    return h;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let prm = frame.params[0];
    let scale = select(prm.x, 1.6, prm.x <= 0.0);
    let speed = prm.y;
    let grain = prm.z;
    let sheen = select(prm.w, 1.0, prm.w <= 0.0);

    let inv = scale / frame.size.y;
    let p = px * inv;
    let now = frame.time.x;
    let t = now * speed * 6.0 + frame.size.w * 400.0;

    // Pointer: the lift eases with presence; the wake grows with speed and fades over ~0.6 s once
    // motion stops (velocity decays in the host; presence.y counts up).
    let ptr = frame.pointer.xy * inv;
    let vel = frame.pointer.zw * inv;
    let spd = length(frame.pointer.zw) / frame.size.y;
    let present = frame.presence.x;
    let lift = present;
    let r = 0.15 * scale;
    let wake = 0.85 * smoothstep(0.08, 0.8, spd) * exp(-frame.presence.y * 0.6) * present;
    // The trail covers the last 0.15 s of motion, at most 0.3 units long, so the ripple stays local.
    let vl = length(vel);
    let tail = ptr - vel * (min(vl * 0.15, 0.3) / max(vl, 1e-4));

    // Height and its gradient by forward differences (three evaluations).
    let e = 1.5 * inv;
    let h0 = gs_height(p, t, ptr, lift, r, tail, wake, now);
    let hx = gs_height(p + vec2<f32>(e, 0.0), t, ptr, lift, r, tail, wake, now);
    let hy = gs_height(p + vec2<f32>(0.0, e), t, ptr, lift, r, tail, wake, now);
    let g = vec2<f32>(hx - h0, hy - h0) / e * 0.06;

    // Tone: lambert from the upper right, across the folds, plus occlusion by height, as a signed value
    // (-1 deep trough, 0 midtone, 1 bright ridge).
    let n = normalize(vec3<f32>(-g, 1.0));
    let l = normalize(vec3<f32>(0.42, -0.72, 0.55));
    let lam = dot(n, l) - l.z;
    let ao = clamp(h0 * 0.36, -1.0, 1.0);
    let sx = (lam * 4.6 + ao * 0.8) * sheen;
    let s = sx * inverseSqrt(1.0 + sx * sx);

    // Anisotropic streak: only the slope across the fold counts, so the highlight is a narrow line
    // running along each fold, sitting on the lit shoulder of the ridge.
    let ga = dot(g, GS_ACROSS);
    // The light falls across the folds, so a shoulder faces it where the across slope is ~0.4.
    let dp = p - ptr;
    let near = exp(-dot(dp, dp) / (r * r * 1.4)) * present;
    let sd = (ga - 0.42) * 12.0 / (1.0 + 1.2 * near);
    let streak = exp(-sd * sd) * smoothstep(-0.3, 0.6, ao) * (1.0 + 0.6 * near) * sheen;

    // Colors mixed in a perceptual (sqrt) space. Light: troughs reach ink at ~40%, ridges go
    // toward white. Dark: troughs deepen below paper, ridges reach ~42% and streaks ~62% toward ink.
    let dark = frame.presence.w > 0.5;
    let pp = sqrt(frame.paper.rgb);
    let ip = sqrt(frame.ink.rgb);
    let trough = select(mix(pp, ip, 0.40), pp * 0.72, dark);
    let mid = select(mix(pp, ip, 0.12), mix(pp, ip, 0.12), dark);
    let ridge = select(mix(pp, vec3<f32>(1.0), 0.75), mix(pp, ip, 0.42), dark);
    let shine = select(vec3<f32>(1.0), mix(pp, ip, 0.62), dark);
    var c = select(mix(mid, ridge, s), mix(mid, trough, -s), s < 0.0);
    // The accent tints only the streak, only where the fold lifts under the pointer.
    let tint = mix(shine, sqrt(frame.accent.rgb) * select(1.0, 1.15, dark), near * 0.85);
    c = mix(c, tint, clamp(streak, 0.0, 1.0));

    // Film grain: luminance only, new each frame, triangular per pixel plus a 2x2 clump term, and
    // stronger in the shadows.
    let ix = u32(px.x);
    let iy = u32(px.y);
    let fz = u32(frame.time.z);
    let fine = gs_hash(ix, iy, fz) + gs_hash(ix + 7919u, iy, fz) - 1.0;
    let clump = gs_hash(ix >> 1u, iy >> 1u, fz + 104729u) - 0.5;
    let shadowy = 1.0 + 0.8 * clamp(-s, 0.0, 1.0);
    c = c + (fine * 0.75 + clump * 0.6) * grain * 0.075 * shadowy;
    c = max(c, vec3<f32>(0.0));
    return vec4<f32>(c * c, 1.0);
}
