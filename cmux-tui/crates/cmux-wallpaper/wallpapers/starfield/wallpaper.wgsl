// Night Sky: four depth layers of stars from hash grids (one candidate star per cell, varied
// size, brightness and color temperature), a faint milky band of dust with darker lanes, and a
// horizon glow in the accent. The whole sky turns very slowly about a pole far above the window
// (stars at infinity, so the turn has no parallax); the pointer shifts the layers a few points
// against each other by depth, a look-around. A few stars swell now and then over seconds (rare,
// slow, never a strobe).
//
// params[0]: x density, y brightness, z band strength, w twinkle (0..1)
// params[1]: x drift (degrees per minute), y parallax (points), z horizon glow, w zenith hue (degrees)

const SF_PI: f32 = 3.14159265;

fn sf_hash12(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn sf_hash42(p: vec2<f32>) -> vec4<f32> {
    var q = fract(vec4<f32>(p.x, p.y, p.x, p.y) * vec4<f32>(0.1031, 0.1030, 0.0973, 0.1099));
    q = q + dot(q, q.wzxy + 33.33);
    return fract((q.xxyz + q.yzzw) * q.zywx);
}

fn sf_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = sf_hash12(i);
    let b = sf_hash12(i + vec2<f32>(1.0, 0.0));
    let c = sf_hash12(i + vec2<f32>(0.0, 1.0));
    let d = sf_hash12(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Four octaves, rotated between octaves so no grid shows.
fn sf_fbm(p0: vec2<f32>) -> f32 {
    var p = p0;
    var v = 0.0;
    var amp = 0.5;
    for (var i = 0; i < 4; i = i + 1) {
        v = v + amp * sf_noise(p);
        p = vec2<f32>(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y) + 7.31;
        amp = amp * 0.5;
    }
    return v / 0.9375;
}

fn sf_oklab(c: vec3<f32>) -> vec3<f32> {
    let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    let q = pow(max(vec3<f32>(l, m, s), vec3<f32>(0.0)), vec3<f32>(1.0 / 3.0));
    return vec3<f32>(
        0.2104542553 * q.x + 0.7936177850 * q.y - 0.0040720468 * q.z,
        1.9779984951 * q.x - 2.4285922050 * q.y + 0.4505937099 * q.z,
        0.0259040371 * q.x + 0.7827717662 * q.y - 0.8086757660 * q.z,
    );
}

fn sf_linear(c: vec3<f32>) -> vec3<f32> {
    let l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    let q = vec3<f32>(l * l * l, m * m * m, s * s * s);
    return vec3<f32>(
        4.0767416621 * q.x - 3.3077115913 * q.y + 0.2309699292 * q.z,
        -1.2684380046 * q.x + 2.6097574011 * q.y - 0.3413193965 * q.z,
        -0.0041960863 * q.x - 0.7034186147 * q.y + 1.7076147010 * q.z,
    );
}

fn sf_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    return vec3<f32>(l, c * cos(h), c * sin(h));
}

fn sf_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let v = clamp(lin, vec3<f32>(0.0), vec3<f32>(1.0));
    let enc = select(1.055 * pow(v, vec3<f32>(1.0 / 2.4)) - 0.055, v * 12.92, v <= vec3<f32>(0.0031308));
    let n = sf_hash12(px + 0.5) + sf_hash12(px.yx + 71.3) - 1.0;
    let e = clamp(enc + n / 255.0, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(pow((e + 0.055) / 1.055, vec3<f32>(2.4)), e / 12.92, e <= vec3<f32>(0.04045));
}

// A star's color by temperature t (0 cool red-orange .. 0.5 white .. 1 blue), as an OKLab (a, b)
// offset: low chroma, most stars near white, as the eye sees them.
fn sf_temp(t: f32) -> vec2<f32> {
    let c = 0.075 * abs(2.0 * t - 1.0);
    let h = select(1.0, 4.4, t > 0.5);
    return c * vec2<f32>(cos(h), sin(h));
}

// One layer: the candidate star of this pixel's cell, if the cell has one. Returns (light,
// temperature a, temperature b, 0). The star sits within 0.3 cell of the cell's center and its
// glow ends well inside the cell, so one cell is enough. `prob` is the chance a cell has a star,
// `size` the largest core radius in pixels, `halo` the strength of a wide soft halo on bright
// stars.
fn sf_layer(p: vec2<f32>, cell: f32, salt: f32, prob: f32, size: f32, halo: f32, twinkle: f32, t: f32) -> vec4<f32> {
    let c = floor(p / cell);
    let h = sf_hash42(c + salt);
    if (h.x > prob) {
        return vec4<f32>(0.0);
    }
    let center = (c + 0.5 + (h.yz - 0.5) * 0.6) * cell;
    let d = p - center;
    let d2 = dot(d, d);
    // Magnitude: a steep power law, so bright stars are rare.
    let mag = pow(h.w, 7.0);
    let r = size * (0.35 + 0.65 * mag);
    let sigma = max(r, 0.6);
    let energy = min(1.0, (r * r) / (sigma * sigma));
    var light = (0.25 + 0.75 * mag) * energy * exp(-d2 / (sigma * sigma));
    light = light + halo * mag * exp(-d2 / (sigma * sigma * 16.0)) * 0.12;
    // Rare, slow swell: about one star in three, once every 25..75 s, over ~3 s.
    let k = fract(h.w * 13.7 + h.x * 7.1);
    let period = 25.0 + 50.0 * k;
    let s = max(sin(t * 2.0 * SF_PI / period + k * 40.0), 0.0);
    let s2 = s * s;
    let s8 = s2 * s2 * s2 * s2;
    let swell = s8 * s8 * s2 * step(0.66, fract(k * 3.3));
    light = light * (1.0 + twinkle * 0.8 * swell);
    let tc = sf_temp(fract(h.y * 5.3 + h.z * 2.1));
    return vec4<f32>(light, tc, 0.0);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let seed = frame.size.w;
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;
    let t = frame.time.x;
    let ppt = max(frame.size.z, 0.25);
    let size = frame.size.xy;
    let uv = px / max(size, vec2<f32>(1.0));

    let density = pa.x;
    let bright = pa.y;
    let band_k = pa.z;
    let twinkle = pa.w;
    let drift = pb.x * SF_PI / (180.0 * 60.0);
    let parallax = pb.y * ppt;
    let horizon = pb.z;
    let zenith_h = pb.w * SF_PI / 180.0;

    // The sky turns about a pole far above the window's top: at the window's bottom a star moves
    // well under a pixel a second (0.25 degrees a minute is about 0.15 px/s on a 900 px window).
    let pole = vec2<f32>(0.5 * size.x, -1.4 * size.y);
    let ang = t * drift;
    let ca = cos(ang);
    let sa = sin(ang);
    let rel = px - pole;
    let sky = pole + vec2<f32>(ca * rel.x - sa * rel.y, sa * rel.x + ca * rel.y);

    // Look-around: the pointer's offset from the window's center moves the near layers against the
    // far ones, eased in and out with the pointer's presence.
    let inside = select(frame.presence.x, 1.0, still);
    let look = -(frame.pointer.xy - 0.5 * size) / max(size.x, 1.0) * parallax * inside;

    // The milky band: a soft diagonal strip, its density shaped by fbm with a darker rift. Sampled
    // in the turning sky's coordinates (scaled to the window), so it turns with the stars.
    let suv = (sky + look * 0.1) / max(size.y, 1.0);
    let bdir = normalize(vec2<f32>(1.0, -0.55));
    let across = dot(suv - vec2<f32>(0.5 * size.x / max(size.y, 1.0), 0.55), vec2<f32>(-bdir.y, bdir.x));
    let along = dot(suv, bdir);
    let profile = exp(-across * across / 0.045);
    let cloud = sf_fbm(vec2<f32>(along * 3.2, across * 6.0) + seed * 17.0);
    let rift = 1.0 - smoothstep(0.0, 0.035, abs(across + 0.06 * (cloud - 0.5)) - 0.01);
    let band = band_k * profile * smoothstep(0.3, 0.85, cloud) * (1.0 - 0.6 * rift);

    // Stars: dust (finest, farthest), far, mid and near layers; the band makes far cells fuller.
    let s0 = sf_layer(sky + look * 0.05, 6.0 * ppt, 3.1 + seed * 41.0, clamp(0.10 * density + 0.5 * band, 0.0, 0.9), 0.45 * ppt, 0.0, twinkle, t);
    let s1 = sf_layer(sky + look * 0.2, 15.0 * ppt, 17.7 + seed * 43.0, clamp(0.35 * density + 0.3 * band, 0.0, 0.95), 0.6 * ppt, 0.0, twinkle, t);
    let s2 = sf_layer(sky + look * 0.5, 38.0 * ppt, 29.3 + seed * 47.0, clamp(0.38 * density, 0.0, 0.95), 0.9 * ppt, 0.5, twinkle, t);
    let s3 = sf_layer(sky + look, 90.0 * ppt, 53.9 + seed * 53.0, clamp(0.35 * density, 0.0, 0.95), 1.4 * ppt, 1.0, twinkle, t);
    let dust_l = s0.x * 0.35;
    let star_l = (dust_l + s1.x * 0.6 + s2.x * 0.85 + s3.x) * bright;
    let star_ab = (s0.yz * dust_l + s1.yz * s1.x + s2.yz * s2.x + s3.yz * s3.x) / max(dust_l + s1.x + s2.x + s3.x, 1e-4);

    // The sky: the theme's paper, leaning a little toward the zenith hue at the top and the accent
    // at the horizon (the bottom), mixed in OKLab. On a light paper the same lean reads as dawn.
    let paper = sf_oklab(frame.paper.rgb);
    let acc = sf_oklab(frame.accent.rgb);
    let up = 1.0 - uv.y;
    let zen = sf_lch(paper.x - mix(0.0, 0.025, dark) * up, mix(0.02, 0.03, dark) * up, zenith_h);
    var base = vec3<f32>(zen.x, paper.yz + zen.yz);
    let hz = horizon * exp(-up * 3.2);
    let acc_c = length(acc.yz);
    let hz_col = vec3<f32>(paper.x + mix(-0.02, 0.06, dark), acc.yz * min(1.0, 0.07 / max(acc_c, 1e-4)));
    base = mix(base, hz_col, clamp(hz * mix(0.55, 0.6, dark), 0.0, 1.0));
    // The band lifts the sky a little in dark (a cool, pale haze) and shades it a little in light.
    let band_col = vec3<f32>(base.x + mix(-0.035, 0.05, dark), base.yz * 0.6 + vec2<f32>(-0.004, -0.008));
    base = mix(base, band_col, clamp(band, 0.0, 1.0) * 0.8);

    var lin = max(sf_linear(base), vec3<f32>(0.0));
    if (dark > 0.5) {
        // Starlight adds light: a near white of the star's temperature.
        let col = max(sf_linear(vec3<f32>(0.92, star_ab)), vec3<f32>(0.0));
        lin = lin + col * star_l * 0.85;
    } else {
        // On a light sky the stars are fine dark specks, faintly colored.
        let col = vec3<f32>(paper.x * 0.55, star_ab * 1.4);
        let mixed = mix(base, col, clamp(star_l * 0.55, 0.0, 0.85));
        lin = max(sf_linear(mixed), vec3<f32>(0.0));
    }
    return vec4<f32>(sf_dither(lin, px), 1.0);
}
