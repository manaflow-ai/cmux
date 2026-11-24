// Orbits: a celestial chart of fine conic orbits around an off-centre body. Each orbit is a
// confocal conic (|q| + e * q.d = l) with its own small tilt and eccentricity; a pixel finds its
// nearest orbit from a shared base field and checks 5 candidates. The pointer is a mass: the
// field is sampled through a soft lens, so the orbits near it bend toward it and relax as it
// leaves. One orbit and its body are drawn in the accent.

const TAU: f32 = 6.28318530718;

fn orb_hash(x: u32) -> u32 {
    var v = x * 747796405u + 2891336453u;
    v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return (v >> 22u) ^ v;
}

fn orb_rand(i: i32, salt: u32) -> f32 {
    return f32(orb_hash(u32(i) * 1664525u + salt * 1013904223u) >> 8u) / 16777216.0;
}

// 4x4 ordered dither threshold in [0, 1).
fn orb_bayer(px: vec2<f32>) -> f32 {
    let x = u32(px.x) & 3u;
    let y = u32(px.y) & 3u;
    let xy = x ^ y;
    let v = ((xy & 1u) << 3u) | ((y & 1u) << 2u) | ((xy & 2u)) | ((y & 2u) >> 1u);
    return (f32(v) + 0.5) / 16.0;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let p0 = frame.params[0];
    let p1 = frame.params[1];
    let ratio = max(p0.x, 1.01);   // radius ratio between neighbouring orbits
    let ecc = p0.y;                // mean eccentricity
    let spread = p0.z;             // how much tilt and eccentricity vary per orbit
    let lens = p0.w;               // pointer mass
    let speed = p1.x;
    let accent_ring = i32(p1.y);
    let planet_r = p1.z;
    let grain = p1.w;

    let h = frame.size.y;
    let centre = vec2<f32>(0.64, 0.5) * frame.size.xy;
    let p = (px - centre) / h;
    let t = frame.time.x * speed + frame.size.w * 600.0;
    let dark = frame.presence.w;

    // The pointer as a mass: sample farther from it, so lines near it are drawn toward it.
    let pm = (frame.pointer.xy - centre) / h;
    let v = p - pm;
    let lr = 0.2;
    let x = dot(v, v) / (lr * lr);
    let settle = mix(0.7, 1.0, smoothstep(0.0, 1.5, frame.presence.y));
    let k = lens * frame.presence.x * settle;
    let g = exp(-x);
    let s = p + v * (k * g);
    // Source units per screen unit, radially; turns source distances into pixels.
    let mag = max(1.0 + k * g * (1.0 - 2.0 * x), 0.25);
    let to_px = h / mag;

    let r = max(length(s), 1e-4);
    let phi0 = 0.42 + t * 0.0011;
    let dir0 = vec2<f32>(cos(phi0), sin(phi0));
    let f0 = r + ecc * dot(s, dir0);
    let l0 = planet_r * 1.7;
    let lratio = log(ratio);
    let idx = i32(floor(log(max(f0, 1e-4) / l0) / lratio + 0.5));

    // Denser charts draw each line lighter and carry fewer bodies; dark paper needs less ink.
    let dens = clamp((ratio - 1.0) / 0.075, 0.5, 1.0);
    let ink_k = dens * mix(1.0, 0.78, dark);
    let body_p = 0.38 * dens * dens;

    var ink_a = 0.0;
    var acc_a = 0.0;
    var knock = 0.0;

    for (var c: i32 = -2; c <= 2; c = c + 1) {
        let j = idx + c;
        if (j < 0 || j > 90) {
            continue;
        }
        let l = l0 * pow(ratio, f32(j));
        let h0 = orb_rand(j, 1u);
        let h1 = orb_rand(j, 2u);
        let h2 = orb_rand(j, 3u);
        let h3 = orb_rand(j, 4u);
        let h4 = orb_rand(j, 5u);
        let is_acc = j == accent_ring;
        let major = (j % 5) == 0;

        let ej = clamp(ecc * (1.0 + spread * (h0 - 0.5) * 1.2), 0.0, 0.9);
        let phij = phi0 + spread * (h1 - 0.5) * 0.7;
        let dir = vec2<f32>(cos(phij), sin(phij));
        let fj = r + ej * dot(s, dir) - l;
        let grad = s / r + ej * dir;
        let dpx = abs(fj) / length(grad) * to_px;

        // Kepler-ish angular speed: slower farther out. Irrational per-orbit rates, no period.
        let w = 0.05 * pow(l / 0.2, -1.5) * (0.8 + 0.4 * h3);
        let ang = atan2(s.y * dir.x - s.x * dir.y, dot(s, dir));

        // Line style: gap, solid, dashed or dotted. Majors are solid and a little heavier.
        var cov = 0.0;
        var strength = 0.34;
        if (major || is_acc) {
            let wl = select(0.55, 0.45, is_acc);
            cov = smoothstep(wl + 0.9, wl - 0.1, dpx);
            strength = select(0.62, 1.0, is_acc);
            if (is_acc) {
                // The accent orbit is a fine long dash.
                let n = max(round(l * TAU / 0.03), 3.0);
                let ph = fract(ang / TAU * n - t * w * n / TAU * 0.5);
                let dash_px = r * TAU / n * to_px;
                cov = cov * clamp(min(ph, 0.7 - ph) * dash_px + 0.5, 0.0, 1.0);
            }
        } else if (h2 > 0.14) {
            cov = smoothstep(1.2, 0.2, dpx);
            if (h2 > 0.72) {
                // Dotted: round dots riding the orbit.
                let n = max(round(l * TAU / (0.006 + 0.004 * h4)), 6.0);
                let ph = fract(ang / TAU * n - t * w * n / TAU * 0.5) - 0.5;
                let tang = ph * r * TAU / n * to_px;
                let dd = length(vec2<f32>(dpx, tang));
                cov = smoothstep(1.55, 0.55, dd);
                strength = 0.5;
            } else if (h2 > 0.42) {
                // Dashed.
                let n = max(round(l * TAU / (0.016 + 0.02 * h4)), 4.0);
                let ph = fract(ang / TAU * n - t * w * n / TAU * 0.5);
                let dash_px = r * TAU / n * to_px;
                cov = cov * clamp(min(ph, 0.55 - ph) * dash_px + 0.5, 0.0, 1.0);
                strength = 0.4;
            } else {
                strength = 0.26;
            }
        }

        // A body travelling along some orbits; the accent orbit always has one.
        if (h4 < body_p || is_acc) {
            let a = h0 * TAU + t * w;
            let rr = l / (1.0 + ej * cos(a));
            let bp = rr * vec2<f32>(cos(phij + a), sin(phij + a));
            let bd = length(s - bp) * to_px;
            let br = select(1.6 + 1.6 * h1, 3.2, is_acc || major);
            knock = max(knock, smoothstep(br + 3.2, br + 2.2, bd));
            let disc = smoothstep(br + 0.6, br - 0.4, bd);
            // Larger bodies get a fine halo ring, like a chart symbol.
            let halo = select(0.0, smoothstep(0.9, 0.1, abs(bd - br - 3.6)) * 0.7, br > 2.6);
            if (is_acc) {
                acc_a = max(acc_a, max(disc, halo));
            } else {
                ink_a = max(ink_a, max(disc * 0.85, halo * 0.6));
            }
        }

        if (is_acc) {
            acc_a = max(acc_a, cov * strength * 0.9);
        } else {
            ink_a = max(ink_a, cov * strength * ink_k * (1.0 - knock));
        }
    }

    // The central body: a dithered sphere lit from the upper left, with a hairline rim. It is
    // drawn unlensed so it stays round.
    let sp = p / planet_r;
    let dp = length(sp);
    let rim_px = abs(dp - 1.0) * planet_r * h;
    let inside = smoothstep(0.5, -0.5, (dp - 1.0) * planet_r * h);
    let nz = sqrt(max(1.0 - dp * dp, 0.0));
    let lit = clamp(dot(vec3<f32>(sp, nz), normalize(vec3<f32>(-0.55, -0.6, 0.6))), 0.0, 1.0);
    let density = mix((1.0 - lit) * 0.78 + 0.04, lit * 0.8 + 0.04, dark);
    let dots = step(orb_bayer(px), density);
    ink_a = mix(ink_a, dots * 0.8, inside);
    ink_a = max(ink_a, smoothstep(1.1, 0.2, rim_px) * 0.7);

    // A dotted chart axis through the body along the orbits' apsides, outside the body.
    let axis_d = abs(s.y * dir0.x - s.x * dir0.y) * to_px;
    let along = dot(s, dir0) * to_px;
    let axis_dot = smoothstep(1.1, 0.3, length(vec2<f32>(axis_d, (fract(along / 7.0) - 0.5) * 7.0)));
    ink_a = max(ink_a, axis_dot * 0.3 * (1.0 - inside) * (1.0 - knock));

    // Paper with print grain and a faint ink bloom around the body.
    let n = f32(orb_hash(u32(px.x) + u32(px.y) * 8191u) >> 8u) / 16777216.0 - 0.5;
    let bloom = exp(-length(p) * 2.2) * 0.035;
    let base = mix(frame.paper.rgb, frame.ink.rgb, clamp(bloom + n * grain * mix(0.07, 0.045, dark), 0.0, 1.0));
    var col = mix(base, frame.ink.rgb, clamp(ink_a, 0.0, 1.0));
    col = mix(col, frame.accent.rgb, clamp(acc_a, 0.0, 1.0));
    return vec4<f32>(col, 1.0);
}
