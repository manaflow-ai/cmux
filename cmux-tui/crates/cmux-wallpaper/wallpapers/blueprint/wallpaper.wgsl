// Blueprint: a drafting sheet. Minor and major grid, rulers along the top and left edges,
// faint dashed construction circles, all breathing very slowly. The pointer draws a
// crosshair, dimension lines to the nearest major intersection and tiny 3x5 pixel labels.
//
// params[0].x minor cell (units)   params[0].y minor cells per major
// params[0].z breathing speed      params[0].w construction circle density (0..1)
// params[1].x grain amount         params[1].y line weight

fn bp_hash2(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(0.1031, 0.1030));
    q += dot(q, q.yx + 33.33);
    return fract((q.x + q.y) * q.x);
}

fn bp_vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = bp_hash2(i);
    let b = bp_hash2(i + vec2<f32>(1.0, 0.0));
    let c = bp_hash2(i + vec2<f32>(0.0, 1.0));
    let d = bp_hash2(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Coverage of a line of width w (pixels) at distance d (pixels), antialiased.
fn bp_line(d: f32, w: f32) -> f32 {
    return clamp(0.5 * (w + 1.0) - d, 0.0, 1.0) * clamp(w, 0.0, 1.0);
}

// 3x5 glyphs, row-major from the top-left, bit 14 first. 10 is a decimal point.
fn bp_glyph(c: u32) -> u32 {
    switch c {
        case 0u: { return 0x7b6fu; }
        case 1u: { return 0x2c97u; }
        case 2u: { return 0x73e7u; }
        case 3u: { return 0x73cfu; }
        case 4u: { return 0x5bc9u; }
        case 5u: { return 0x79cfu; }
        case 6u: { return 0x79efu; }
        case 7u: { return 0x7249u; }
        case 8u: { return 0x7befu; }
        case 9u: { return 0x7bcfu; }
        default: { return 0x2u; }
    }
}

fn bp_digits(n: u32) -> u32 {
    return 1u + select(0u, 1u, n >= 10u) + select(0u, 1u, n >= 100u) + select(0u, 1u, n >= 1000u);
}

fn bp_pow10(e: u32) -> u32 {
    return select(select(select(1000u, 100u, e == 2u), 10u, e == 1u), 1u, e == 0u);
}

// Text width in glyph pixels for an integer n (tenths when dec).
fn bp_text_w(n: u32, dec: bool) -> f32 {
    let len = max(bp_digits(n), select(1u, 2u, dec));
    let chars = len + select(0u, 1u, dec);
    return f32(chars) * 4.0 - 1.0;
}

// 1 where pixel q (relative to the text's top-left, in glyph pixels) is lit. n is drawn as an
// integer, or as tenths with a decimal point when dec ("2.3" for 23).
fn bp_text(q: vec2<f32>, n: u32, dec: bool) -> f32 {
    if (q.x < 0.0 || q.y < 0.0 || q.y >= 5.0) {
        return 0.0;
    }
    let len = max(bp_digits(n), select(1u, 2u, dec));
    let chars = len + select(0u, 1u, dec);
    let i = u32(q.x / 4.0);
    if (i >= chars) {
        return 0.0;
    }
    let cx = u32(q.x - f32(i) * 4.0);
    if (cx > 2u) {
        return 0.0;
    }
    var code = 10u;
    let dot_at = len - 1u;
    if (!(dec && i == dot_at)) {
        let j = select(i, i - 1u, dec && i > dot_at);
        code = (n / bp_pow10(len - 1u - j)) % 10u;
    }
    let bit = 14u - (u32(q.y) * 3u + cx);
    return f32((bp_glyph(code) >> bit) & 1u);
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let t = frame.time.x;
    let k = max(1.0, round(frame.size.z * 2.0)); // pixels per design unit
    let p0 = frame.params[0];
    let p1 = frame.params[1];
    let cell = max(p0.x, 4.0) * k;
    let per = max(round(p0.y), 2.0);
    let major = cell * per;
    let speed = p0.z;
    let ruler = 18.0 * k;
    let weight = max(p1.y, 0.3);
    let seed = frame.size.w * 61.0;
    let dark = frame.presence.w;

    // Sheet coordinates: origin at the inner corner of the rulers.
    let q = px - vec2<f32>(ruler);
    let ptr = frame.pointer.xy - vec2<f32>(ruler);
    let pres = frame.presence.x;
    let dp = length(q - ptr);
    let near = exp(-dp * dp / (2.0 * 90.0 * 90.0 * k * k)) * pres;

    // Breathing: two slow travelling waves across the sheet, incommensurate in time.
    let uv = px / frame.size.y;
    let st = t * speed;
    let w1 = sin(dot(uv, vec2<f32>(1.3, 0.7)) * 2.1 - st * 0.091 + 1.7 * sin(dot(uv, vec2<f32>(-0.6, 1.1)) * 1.4 + st * 0.053));
    let breath = 0.5 + 0.5 * w1;

    // Grid lines.
    let gm = abs(fract(q / cell + 0.5) - 0.5) * cell;
    let gM = abs(fract(q / major + 0.5) - 0.5) * major;
    let wm = (0.55 + 0.35 * breath) * weight;
    let wM = (0.95 + 0.45 * breath) * weight;
    let minor = max(bp_line(gm.x, wm), bp_line(gm.y, wm));
    let majr = max(bp_line(gM.x, wM), bp_line(gM.y, wM));
    let fine = clamp(cell / (10.0 * k), 0.45, 1.0);
    var ink_a = minor * fine * (0.10 + 0.07 * breath + 0.10 * near) + majr * (0.22 + 0.10 * breath + 0.12 * near);

    // Construction circles: one candidate per block of 3x3 majors, 3x3 neighbourhood.
    let block = major * 3.0;
    let bc = floor(q / block);
    var circ = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let id = bc + vec2<f32>(f32(i), f32(j));
            let h = bp_hash2(id + seed);
            if (h > p0.w) {
                continue;
            }
            let h2 = bp_hash2(id * 1.7 + 11.0 + seed);
            let h3 = bp_hash2(id * 2.3 + 5.0 + seed);
            let c = (id + vec2<f32>(floor(h2 * 3.0), floor(h3 * 3.0)) / 3.0) * block;
            let r = major * (1.0 + floor(h3 * 2.0 + h2 * 1.5));
            let v = q - c;
            let dv = length(v);
            let ring = bp_line(abs(dv - r), 0.8 * weight);
            // Centre mark: a small cross at the centre.
            let cm = select(0.0, 1.0, max(abs(v.x), abs(v.y)) < 4.0 * k) * max(bp_line(abs(v.x), 0.8), bp_line(abs(v.y), 0.8));
            var dash = 1.0;
            if (ring > 0.0) {
                let ang = atan2(v.y, v.x);
                let dir = select(-1.0, 1.0, h2 > 0.5);
                let ph = ang * r / (6.0 * k) + dir * st * 0.35 + h * 40.0;
                dash = step(0.42, fract(ph));
            }
            circ = max(circ, max(ring * dash, cm) * (0.5 + 0.5 * breath));
        }
    }
    ink_a += circ * 0.20;

    // Rulers along the top and left edges.
    let in_top = px.y < ruler;
    let in_left = px.x < ruler;
    var rule_a = 0.0;
    var rule_acc = 0.0;
    if (in_top || in_left) {
        // Along: position on the ruler's axis; across: distance in from the sheet's edge.
        let along = select(q.y, q.x, in_top);
        let across = select(px.x, px.y, in_top);
        let pa = select(ptr.y, ptr.x, in_top);
        let ma = abs(fract(along / cell + 0.5) - 0.5) * cell;
        let idx = round(along / cell);
        let is_major = abs(idx - round(idx / per) * per) < 0.5;
        let is_half = abs(idx - round(idx / (per * 0.5)) * per * 0.5) < 0.5 && fract(per * 0.5) < 0.1;
        let len = select(select(4.0, 7.0, is_half), 11.0, is_major) * k;
        let tick = bp_line(ma, 0.9) * step(ruler - len, across) * step(0.0, along);
        rule_a = tick * 0.55;
        // Labels at majors: millimetres, beside the tick near the outer edge.
        let mi = round(along / major);
        let lq = select(vec2<f32>(across - 2.0 * k, along - mi * major - 2.0 * k), vec2<f32>(along - mi * major - 2.0 * k, across - 2.0 * k), in_top) / k;
        if (mi >= 0.0 && !(pres > 0.5 && abs(mi * major - pa) < 16.0 * k)) {
            rule_a = max(rule_a, bp_text(lq, u32(mi * per), false) * 0.6);
        }
        // Pointer marker: an accent tick and its value.
        let pm = bp_line(abs(along - pa), 1.2) * step(ruler - 14.0 * k, across);
        let tri = step(abs(along - pa), (across - (ruler - 6.0 * k)) * 0.9) * step(ruler - 6.0 * k, across);
        let pv = u32(max(pa / cell, 0.0) * 10.0 + 0.5);
        let pq = select(vec2<f32>(across - 2.0 * k, along - pa - 3.0 * k), vec2<f32>(along - pa - 3.0 * k, across - 2.0 * k), in_top) / k;
        rule_acc = max(max(pm, tri), bp_text(pq, pv, true)) * pres * step(0.0, pa);
        // Ruler border along its inner edge.
        rule_a = max(rule_a, bp_line(abs(across - ruler + 0.5), 1.0) * 0.6);
        ink_a = ink_a * 0.15;
    }
    // Corner box where the rulers meet.
    if (in_top && in_left) {
        rule_a = bp_line(abs(px.x - ruler + 0.5), 1.0) * 0.6 + bp_line(abs(px.y - ruler + 0.5), 1.0) * 0.6;
        rule_acc = 0.0;
        let o = abs(px - vec2<f32>(ruler * 0.5));
        rule_a = max(rule_a, bp_line(abs(length(px - vec2<f32>(ruler * 0.5)) - 4.0 * k), 0.9) * 0.6);
        rule_a = max(rule_a, select(0.0, 1.0, max(o.x, o.y) < 6.0 * k) * max(bp_line(o.x, 0.8), bp_line(o.y, 0.8)) * 0.6);
    }

    // The pointer: crosshair, dimension lines to the nearest major intersection, labels.
    var acc = rule_acc;
    if (pres > 0.001 && !(in_top || in_left)) {
        let d = q - ptr;
        // Long hairlines that fade with distance, a solid short cross with a gap at the centre.
        let fade = exp(-abs(d) / (110.0 * k));
        let hair = max(bp_line(abs(d.y), 0.7) * fade.x, bp_line(abs(d.x), 0.7) * fade.y) * 0.3;
        let arm = max(bp_line(abs(d.y), 1.4) * step(abs(d.x), 16.0 * k), bp_line(abs(d.x), 1.4) * step(abs(d.y), 16.0 * k)) * step(4.0 * k, max(abs(d.x), abs(d.y)));
        let ring = bp_line(abs(length(d) - 7.0 * k), 1.15);
        acc = max(acc, max(hair, max(arm, ring)));

        // Nearest major intersection, its marker, and the two dimension lines.
        let ip = round(ptr / major) * major;
        let di = q - ip;
        let mark = max(bp_line(abs(length(di) - 3.5 * k), 1.0), select(0.0, 1.0, length(di) < 1.6 * k));
        acc = max(acc, mark);
        // The two major lines through it light up for a short run, fading from it.
        let run = exp(-abs(di) / (0.45 * major));
        let lit = max(bp_line(abs(di.x), wM) * run.y, bp_line(abs(di.y), wM) * run.x) * 0.45;
        acc = max(acc, lit);

        let dx = ip.x - ptr.x;
        let dy = ip.y - ptr.y;
        let off = 10.0 * k; // dimension lines sit off the pointer, like a drawing's
        let sy = select(-1.0, 1.0, dy > 0.0);
        let sx = select(-1.0, 1.0, dx > 0.0);
        // Horizontal dimension (dx), drawn at y = ptr.y - sy*off, from ptr.x to ip.x.
        let hy = ptr.y - sy * off;
        let x0 = min(ptr.x, ip.x);
        let x1 = max(ptr.x, ip.x);
        let inx = step(x0, q.x) * step(q.x, x1);
        var dim = bp_line(abs(q.y - hy), 0.9) * inx;
        // Extension lines and slashed terminators.
        let ext_h = step(min(hy, ptr.y) - 2.0 * k, q.y) * step(q.y, max(hy, ptr.y) + 2.0 * k);
        dim = max(dim, (bp_line(abs(q.x - ptr.x), 0.7) + bp_line(abs(q.x - ip.x), 0.7)) * ext_h * 0.7);
        let sl1 = bp_line(abs((q.x - ptr.x) - (q.y - hy)), 1.0) * step(abs(q.y - hy), 3.0 * k);
        let sl2 = bp_line(abs((q.x - ip.x) - (q.y - hy)), 1.0) * step(abs(q.y - hy), 3.0 * k);
        dim = max(dim, max(sl1, sl2) * step(1.5 * k, abs(dx)));
        // Vertical dimension (dy), drawn at x = ptr.x - sx*off.
        let vx = ptr.x - sx * off;
        let y0 = min(ptr.y, ip.y);
        let y1 = max(ptr.y, ip.y);
        let iny = step(y0, q.y) * step(q.y, y1);
        dim = max(dim, bp_line(abs(q.x - vx), 0.9) * iny);
        let ext_v = step(min(vx, ptr.x) - 2.0 * k, q.x) * step(q.x, max(vx, ptr.x) + 2.0 * k);
        dim = max(dim, (bp_line(abs(q.y - ptr.y), 0.7) + bp_line(abs(q.y - ip.y), 0.7)) * ext_v * 0.7);
        let sl3 = bp_line(abs((q.x - vx) - (q.y - ptr.y)), 1.0) * step(abs(q.x - vx), 3.0 * k);
        let sl4 = bp_line(abs((q.x - vx) - (q.y - ip.y)), 1.0) * step(abs(q.x - vx), 3.0 * k);
        dim = max(dim, max(sl3, sl4) * step(1.5 * k, abs(dy)));
        acc = max(acc, dim * 0.85);

        // Labels in tenths of a cell ("mm"), centred on each dimension line.
        let nx = u32(abs(dx) / cell * 10.0 + 0.5);
        let ny = u32(abs(dy) / cell * 10.0 + 0.5);
        let lwx = bp_text_w(nx, true) * k;
        let lhx = vec2<f32>((x0 + x1) * 0.5 - lwx * 0.5, hy - sy * 3.0 * k - select(5.0 * k, 0.0, sy < 0.0));
        let tx = bp_text((q - lhx) / k, nx, true) * step(1.5 * k, abs(dx));
        let lvy = vec2<f32>(vx - sx * 3.0 * k - select(bp_text_w(ny, true) * k, 0.0, sx < 0.0), (y0 + y1) * 0.5 - 2.5 * k);
        let ty = bp_text((q - lvy) / k, ny, true) * step(1.5 * k, abs(dy));
        acc = max(acc, max(tx, ty));
        acc *= pres;
    }

    // Paper: faint mottling and print grain; the ink itself takes the grain too.
    let mott = bp_vnoise(px / (140.0 * k) + seed) - 0.5;
    let grain = bp_hash2(floor(px / k) + seed * 7.0) - 0.5;
    let g = p1.x;
    var paper = frame.paper.rgb;
    // Linear ink over dark paper reads far brighter than over light; scale it down in dark.
    let tone = mix(1.0, 0.38, dark);
    let lift = select(0.010, 0.012, dark > 0.5);
    paper = mix(paper, frame.ink.rgb, lift + (mott * 0.012 + grain * 0.022 * g) * tone);
    // Rulers sit on a slightly different stock.
    if (in_top || in_left) {
        paper = mix(paper, frame.ink.rgb, 0.035 * tone);
    }
    let inkv = clamp((ink_a + rule_a) * tone * (0.85 + 0.45 * grain * g), 0.0, 1.0);
    var col = mix(paper, frame.ink.rgb, inkv);
    col = mix(col, frame.accent.rgb, clamp(acc * (0.9 + 0.2 * grain * g), 0.0, 1.0));
    return vec4<f32>(col, 1.0);
}
