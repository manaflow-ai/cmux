// Pencil Grid, after Agnes Martin: fine ruled pencil lines on warm paper (or pale lines on a deep
// ground), horizontal ones close together, fainter verticals wider apart, inside a margin. Each
// line is drawn by hand against a ruler: it wobbles a fraction of a point over long runs, its
// pressure swells and fades along its length, its ends start and stop a little unevenly, and the
// graphite catches only on the paper's tooth, so a light stroke breaks into grain. A very wide,
// soft band of light passes slowly across on a slant (about 2 minutes edge to edge), lifting the
// paper and making the graphite glint a little lighter. Where the pointer has just moved, the
// lines darken faintly, as if just drawn, and settle back within a second. The Rose palette lays
// pale pink washed bands under the lines. Colors in OKLCH, mixed in OKLab, dithered.
//
// params[0]: x pitch (points), y vertical pitch (points, 0 none), z weight, w wobble
// params[1]: x grain, y light band, z palette (0 Graphite, 1 Night, 2 Rose), w bands

const AG_TAU: f32 = 6.2831853;

fn ag_hash(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

fn ag_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = ag_hash(i);
    let b = ag_hash(i + vec2<f32>(1.0, 0.0));
    let c = ag_hash(i + vec2<f32>(0.0, 1.0));
    let d = ag_hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 1D value noise along a line, one stream per line (`lane`).
fn ag_n1(x: f32, lane: f32) -> f32 {
    let i = floor(x);
    let f = fract(x);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(ag_hash(vec2<f32>(i, lane)), ag_hash(vec2<f32>(i + 1.0, lane)), u);
}

fn ag_lch(l: f32, c: f32, h: f32) -> vec3<f32> {
    let r = radians(h);
    return vec3<f32>(l, c * cos(r), c * sin(r));
}

fn ag_lab_to_lin(c: vec3<f32>) -> vec3<f32> {
    let l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    let m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    let s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;
    return vec3<f32>(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    );
}

fn ag_dither(lin: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    let n = ag_hash(px) + ag_hash(px.yx + vec2<f32>(19.19, 7.73)) - 1.0;
    let s = pow(max(lin, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2)) + vec3<f32>(n / 255.0);
    return pow(max(s, vec3<f32>(0.0)), vec3<f32>(2.2));
}

// Palette in OKLab: which 0 paper, 1 graphite, 2 band wash. Dark grounds take pale lines.
fn ag_color(pal: f32, which: i32, dark: f32) -> vec3<f32> {
    var lt = vec3<f32>(0.0);
    var dk = vec3<f32>(0.0);
    if (pal < 0.5) {
        // Graphite: warm paper, cool graphite.
        if (which == 0) { lt = vec3<f32>(0.935, 0.017, 82.0); dk = vec3<f32>(0.215, 0.013, 75.0); }
        else if (which == 1) { lt = vec3<f32>(0.44, 0.008, 255.0); dk = vec3<f32>(0.66, 0.007, 250.0); }
        else { lt = vec3<f32>(0.92, 0.02, 80.0); dk = vec3<f32>(0.235, 0.015, 75.0); }
    } else if (pal < 1.5) {
        // Night: a blue-black ground and pale lines; light keeps the cool, on a gray-blue paper.
        if (which == 0) { lt = vec3<f32>(0.925, 0.012, 240.0); dk = vec3<f32>(0.19, 0.022, 256.0); }
        else if (which == 1) { lt = vec3<f32>(0.47, 0.014, 248.0); dk = vec3<f32>(0.72, 0.016, 232.0); }
        else { lt = vec3<f32>(0.91, 0.016, 238.0); dk = vec3<f32>(0.21, 0.026, 254.0); }
    } else {
        // Rose: near-white and pale pink washed bands, warm gray lines.
        if (which == 0) { lt = vec3<f32>(0.948, 0.012, 62.0); dk = vec3<f32>(0.215, 0.018, 24.0); }
        else if (which == 1) { lt = vec3<f32>(0.54, 0.012, 22.0); dk = vec3<f32>(0.64, 0.014, 22.0); }
        else { lt = vec3<f32>(0.915, 0.032, 8.0); dk = vec3<f32>(0.25, 0.036, 8.0); }
    }
    let c = mix(lt, dk, dark);
    // Hue is the same family in both themes; mix hue linearly only between close hues.
    return ag_lch(c.x, c.y, c.z);
}

// One ruled line's graphite at this pixel, `d` px across from its path, `s` px along it, line
// `j` of a family (`fam` keeps the horizontal and vertical streams apart). Returns coverage 0..1.
fn ag_line(d: f32, s: f32, j: f32, fam: f32, pt: f32, sigma: f32, tooth: f32, grain: f32,
           start: f32, end: f32) -> f32 {
    // Pressure: per line, then swelling and fading along it over a couple hundred points.
    let base = 0.78 + 0.22 * ag_hash(vec2<f32>(j, fam + 3.0));
    let press = base * (0.5 + 0.5 * ag_n1(s / (170.0 * pt), j * 7.31 + fam));
    let prof = exp(-(d * d) / (2.0 * sigma * sigma));
    // Graphite catches on the tooth: a light stroke leaves only the peaks.
    let bite = smoothstep(0.72 - press * 0.75, 1.02 - press * 0.75, tooth);
    let dep = mix(press, bite * (0.55 + 0.45 * press), grain);
    // Uneven ends, each with a short taper where the pencil lands and lifts.
    let ends = smoothstep(start, start + 5.0 * pt, s) * (1.0 - smoothstep(end - 7.0 * pt, end, s));
    return prof * dep * ends;
}

// Hand wobble of line j (px), over long and short runs along it.
fn ag_wob(s: f32, j: f32, fam: f32, pt: f32, amt: f32) -> f32 {
    let slow = ag_n1(s / (110.0 * pt), j * 13.7 + fam + 50.0) - 0.5;
    let fine = ag_n1(s / (11.0 * pt), j * 3.1 + fam + 90.0) - 0.5;
    return amt * pt * (0.9 * slow + 0.18 * fine);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let pa = frame.params[0];
    let pb = frame.params[1];
    let size = frame.size.xy;
    let h = max(size.y, 1.0);
    let aspect = size.x / h;
    let pt = max(frame.size.z, 0.25);
    let dark = frame.presence.w;
    let still = frame.time.w > 0.5;
    let seed = select(frame.size.w, 0.0, still);
    let t = frame.time.x;
    let pal = pb.z;
    let grain = pb.x;

    // Paper, and the Rose bands washed under the lines (soft edges that wander a little).
    var col = ag_color(pal, 0, dark);
    let margin = 0.065 * min(size.x, size.y);
    let inner = vec2<f32>(px.x - margin, px.y - margin);
    let inner_size = max(size - 2.0 * margin, vec2<f32>(1.0));
    let band_h = inner_size.y / 9.0;
    let bu = inner.y / band_h + 0.25 * (ag_n1(px.x / (220.0 * pt), 7.0) - 0.5);
    let bf = abs(fract(bu * 0.5) * 2.0 - 1.0);
    let band = smoothstep(0.38, 0.62, bf) * pb.w;
    let in_y = smoothstep(-2.0 * pt, 2.0 * pt, inner.y) * (1.0 - smoothstep(inner_size.y - 2.0 * pt, inner_size.y + 2.0 * pt, inner.y));
    let in_x = smoothstep(-4.0 * pt, 4.0 * pt, inner.x) * (1.0 - smoothstep(inner_size.x - 4.0 * pt, inner_size.x + 4.0 * pt, inner.x));
    col = mix(col, ag_color(pal, 2, dark), band * in_x * in_y);

    // The paper's tooth (fixed, in points) and a faint cockle in the sheet.
    let tooth = ag_noise(px / (0.75 * pt)) * 0.7 + ag_hash(floor(px)) * 0.3;
    let cockle = ag_noise(px / (260.0 * pt) + 11.0) - 0.5;
    col.x = col.x + grain * 0.006 * (tooth - 0.5) + 0.006 * cockle;

    // The band of light: very wide, soft, on a slant, crossing in about 140 s, off the window
    // between passes so the wrap is never seen.
    let dir = vec2<f32>(0.96, 0.28);
    let sp = dot(px / h, dir);
    let reach = aspect * 0.96 + 0.28;
    let center = -0.7 + (reach + 1.4) * fract(t / 140.0 + seed);
    let lb = (sp - center) / 0.34;
    let light = exp(-lb * lb) * pb.y;
    col = col + light * vec3<f32>(mix(0.024, 0.016, dark), 0.002, 0.006);

    // Pencil: the two nearest horizontal lines, then the two nearest verticals.
    let sigma = max(0.33 * pt, 0.55);
    let pitch = max(pa.x * pt, 3.0);
    let wob = pa.w;
    var ink = 0.0;
    let ny = floor(inner_size.y / pitch);
    let oy = 0.5 * (inner_size.y - ny * pitch);
    let jy0 = floor((inner.y - oy) / pitch - 0.5);
    for (var k = 0; k < 2; k = k + 1) {
        let j = jy0 + f32(k);
        if (j >= 0.0 && j < ny) {
            let y = oy + (j + 0.5) * pitch + ag_wob(inner.x, j, 0.0, pt, wob);
            let st = 3.0 * pt * (ag_hash(vec2<f32>(j, 31.0)) - 0.5);
            let en = inner_size.x + 4.0 * pt * (ag_hash(vec2<f32>(j, 37.0)) - 0.5);
            let a = ag_line(inner.y - y, inner.x, j, 0.0, pt, sigma, tooth, grain, st, en);
            ink = 1.0 - (1.0 - ink) * (1.0 - a);
        }
    }
    let vpitch = pa.y * pt;
    if (pa.y > 0.5) {
        let nx = floor(inner_size.x / vpitch);
        let ox = 0.5 * (inner_size.x - nx * vpitch);
        let jx0 = floor((inner.x - ox) / vpitch - 0.5);
        for (var k = 0; k < 2; k = k + 1) {
            let j = jx0 + f32(k);
            if (j >= 0.0 && j < nx) {
                let x = ox + (j + 0.5) * vpitch + ag_wob(inner.y, j, 500.0, pt, wob);
                let st = 3.0 * pt * (ag_hash(vec2<f32>(j, 41.0)) - 0.5);
                let en = inner_size.y + 4.0 * pt * (ag_hash(vec2<f32>(j, 43.0)) - 0.5);
                let a = 0.72 * ag_line(inner.x - x, inner.y, j, 500.0, pt, sigma, tooth, grain, st, en);
                ink = 1.0 - (1.0 - ink) * (1.0 - a);
            }
        }
    }

    // Just drawn: lines near the pointer's recent path (every other trail row, 7 segments)
    // darken faintly and settle back as the path ages out.
    var fresh = 0.0;
    if (!still) {
        let rad = 30.0 * pt;
        let inv_r2 = 1.0 / (rad * rad);
        var a = frame.trail[0];
        for (var i = 1; i < 8; i = i + 1) {
            let b = frame.trail[i * 2];
            if (a.w * b.w > 0.5) {
                let ab = b.xy - a.xy;
                let hh = clamp(dot(px - a.xy, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
                let q = px - (a.xy + ab * hh);
                let age = mix(a.z, b.z, hh);
                let e = exp(-(dot(q, q) * inv_r2 + age * 2.2)) * (1.0 - smoothstep(0.6, 1.0, age));
                fresh = max(fresh, e);
            }
            a = b;
        }
        fresh = fresh * frame.presence.x * (1.0 - smoothstep(0.6, 1.0, frame.presence.y));
    }

    // Line strength: thin and quiet; a light theme needs more graphite for the same presence.
    // In the light band graphite glints: a little less dark, a little lighter in tone.
    let weight = pa.z * mix(0.34, 0.26, dark) * (1.0 + 0.55 * fresh) * (1.0 - 0.28 * light);
    var lead = ag_color(pal, 1, dark);
    lead.x = lead.x + 0.06 * light;
    col = mix(col, lead, clamp(ink * weight, 0.0, 1.0));

    let lin = ag_lab_to_lin(col);
    return vec4<f32>(ag_dither(lin, px), 1.0);
}
