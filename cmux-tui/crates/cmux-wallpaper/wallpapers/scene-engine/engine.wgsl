// The scene engine (plans/cmux-next/motion-scenes.md): the one first-party program that draws every
// motion scene. It has no look of its own: everything it draws comes from the `Scene` block
// (scene_prelude.wgsl), which Rust packs each frame (src/scene/mod.rs, Player::evaluate). Positions,
// sizes and widths in the block are rendered pixels; colors are linear and already themed.
//
// Draw order, one pass: the mesh-gradient field (or paper), the shapes in order, the guides, the
// rope strips, the image slot, the light, then the grain. Every loop runs to a count in row 0 and
// is capped by the block's limits (16 shapes, 8 guides, 16 rope points), so the worst case sets
// the cost and nothing grows with the window or with time. No derivatives: every edge is
// anti-aliased analytically over about one rendered pixel, so the image's textureSampleLevel is
// the only texture read and no control-flow rule applies.
//
// Colors accumulate premultiplied in linear light; the result is opaque.

const SE_MAX_SHAPES: u32 = 16u;
const SE_MAX_GUIDES: u32 = 8u;
const SE_MAX_ROPE_POINTS: u32 = 16u;
const SE_ROW_FIELD: u32 = 2u;
const SE_ROW_LIGHT: u32 = 10u;
const SE_ROW_SHAPES: u32 = 12u;
const SE_ROW_GUIDES: u32 = 92u;
const SE_ROW_ROPE_POINTS: u32 = 116u;
const SE_ROW_ROPES: u32 = 124u;
const SE_ROW_IMAGE: u32 = 126u;
const SE_TAU: f32 = 6.2831853;

// ---- small helpers -------------------------------------------------------------------------

// p turned by the angle whose cosine and sine are cs.
fn se_turn(p: vec2<f32>, cs: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(cs.x * p.x - cs.y * p.y, cs.y * p.x + cs.x * p.y);
}

// Coverage of a signed distance `d` (px, negative inside): a one-pixel linear ramp, widened and
// eased into a smoothstep by `soft` px of edge blur.
fn se_cover(d: f32, soft: f32) -> f32 {
    let w = 1.0 + soft;
    let x = clamp(0.5 - d / w, 0.0, 1.0);
    return mix(x, x * x * (3.0 - 2.0 * x), clamp(soft, 0.0, 1.0));
}

// Distance from p to the segment a..b (x) and how far along it, in px from a (y).
fn se_segment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> vec2<f32> {
    let ab = b - a;
    let len2 = max(dot(ab, ab), 1e-6);
    let t = clamp(dot(p - a, ab) / len2, 0.0, 1.0);
    return vec2<f32>(length(p - a - ab * t), t * sqrt(len2));
}

// Premultiplied `src` (rgb already times alpha) over `dst`.
fn se_over(dst: vec3<f32>, rgb: vec3<f32>, a: f32) -> vec3<f32> {
    return rgb * a + dst * (1.0 - a);
}

fn se_hash(x: u32, y: u32, z: u32) -> f32 {
    var h = x * 1597334677u ^ y * 3812015801u ^ z * 2798796415u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h = h ^ (h >> 16u);
    return f32(h) * (1.0 / 4294967296.0);
}

// ---- signed distances, in the shape's local space (px, centered, y down) --------------------

// An ellipse with half axes h (a close approximation; exact for circles).
fn se_ellipse(q: vec2<f32>, h: vec2<f32>) -> f32 {
    let hh = max(h, vec2<f32>(0.5));
    let k0 = length(q / hh);
    let k1 = max(length(q / (hh * hh)), 1e-4);
    return select(k0 * (k0 - 1.0) / k1, -min(hh.x, hh.y), k0 < 1e-3);
}

fn se_round_rect(q: vec2<f32>, h: vec2<f32>, r: f32) -> f32 {
    let rr = min(r, min(h.x, h.y));
    let d = abs(q) - h + vec2<f32>(rr);
    return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0) - rr;
}

// A vesica: two circle arcs meeting at (±a, 0), b high at the middle.
fn se_lens(q: vec2<f32>, a: f32, b: f32) -> f32 {
    let bb = max(b, 0.5);
    let r = (a * a + bb * bb) / (2.0 * bb);
    let c = r - bb;
    let p = vec2<f32>(abs(q.x), abs(q.y));
    // Both arcs are the same circle mirrored: the arc through (0, -b) has its center at (0, c).
    return length(p + vec2<f32>(0.0, c)) - r;
}

// Stacked concentric half rings above the center line: n bands, each half a step wide.
fn se_arcs(q: vec2<f32>, h: vec2<f32>, n: f32) -> f32 {
    let hx = max(h.x, 0.5);
    let e = vec2<f32>(q.x, q.y * hx / max(h.y, 0.5));
    let rho = length(e);
    let step = hx / n;
    let f = fract(rho / step);
    let band = (abs(f - 0.75) - 0.25) * step;
    return max(max(band, rho - hx), q.y);
}

// The isometric cube's silhouette, a hexagon h.x wide (half) and h.y high (half), whose top face
// is k high (half). Returns the distance and, in y, the face: 0 top, 1 left, 2 right; in z the
// distance to the nearest inner edge (the three edges meeting at the near corner).
fn se_cube(q: vec2<f32>, h: vec2<f32>, k: f32) -> vec3<f32> {
    let ax = abs(q.x);
    let hx = max(h.x, 0.5);
    let up = normalize(vec2<f32>(k, -hx));
    let down = normalize(vec2<f32>(k, hx));
    let p = vec2<f32>(ax, q.y);
    let d_up = dot(p - vec2<f32>(0.0, -h.y), up);
    let d_down = dot(p - vec2<f32>(0.0, h.y), down);
    let d = max(max(ax - hx, d_up), d_down);
    // The near corner C, where the three faces meet.
    let cy = -h.y + 2.0 * k;
    // The top face's lower edges run from C to the upper side corners, parallel to the lower
    // outer edges: above them is the top face.
    let to_side = -dot(p - vec2<f32>(0.0, cy), down);
    let top = to_side > 0.0;
    let face = select(select(2.0, 1.0, q.x < 0.0), 0.0, top);
    // Inner edges: C to each upper side corner, and C straight down.
    let e_side = se_segment(p, vec2<f32>(0.0, cy), vec2<f32>(hx, -h.y + k)).x;
    let e_down = se_segment(q, vec2<f32>(0.0, cy), vec2<f32>(0.0, h.y)).x;
    return vec3<f32>(d, face, min(e_side, e_down));
}

// The glass cube's hidden edges, seen through its faces: from the far corner H to the top and to
// the two lower side corners.
fn se_cube_back(q: vec2<f32>, h: vec2<f32>, k: f32) -> f32 {
    let hy = vec2<f32>(0.0, h.y - 2.0 * k);
    let p = vec2<f32>(abs(q.x), q.y);
    let a = se_segment(q, hy, vec2<f32>(0.0, -h.y)).x;
    let b = se_segment(p, hy, vec2<f32>(h.x, h.y - k)).x;
    return min(a, b);
}

// ---- the layers ----------------------------------------------------------------------------

// The mesh gradient: four colored points, wide Gaussian weights by radius (wide, so neighbors
// overlap into long soft blends rather than meeting at a seam), mixed in a sqrt (roughly
// perceptual) space so blends stay luminous. The warp bends the sample point with sinusoids whose
// time terms are whole multiples of the loop phase, so the field loops seamlessly.
fn se_field(px: vec2<f32>) -> vec3<f32> {
    let p0 = scene.rows[SE_ROW_FIELD];
    if (scene.rows[SE_ROW_FIELD + 1u].w <= 0.0) {
        return frame.paper.rgb;
    }
    let s = min(frame.size.x, frame.size.y);
    let warp = clamp(p0.w, 0.0, 1.0);
    let ph = scene.rows[SE_ROW_FIELD + 2u].w * SE_TAU;
    let u = px / s;
    let w1 = sin(u.y * 3.1 + ph + 1.7 * sin(u.x * 2.3 - ph));
    let w2 = sin(u.x * 2.7 - ph + 1.3 * sin(u.y * 3.7 + 2.0 * ph));
    let p = px + vec2<f32>(w1, w2) * warp * s * 0.18;
    var acc = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var i = 0u; i < 4u; i++) {
        let pt = scene.rows[SE_ROW_FIELD + 2u * i];
        let c = scene.rows[SE_ROW_FIELD + 2u * i + 1u].rgb;
        let d = (p - pt.xy) / max(pt.z, 1.0);
        let w = exp(-0.9 * dot(d, d)) + 1e-4;
        acc += sqrt(max(c, vec3<f32>(0.0))) * w;
        wsum += w;
    }
    let m = acc / wsum;
    return m * m;
}

// The light: where it is (xy), its radius (z), intensity (w); color in the next row.
fn se_light_at(px: vec2<f32>) -> f32 {
    let l = scene.rows[SE_ROW_LIGHT];
    if (l.w <= 0.0) {
        return 0.0;
    }
    let d = (px - l.xy) / max(l.z, 1.0);
    return l.w * exp(-dot(d, d));
}

// Shape i's coverage and premultiplied color, composited over `dst`.
fn se_shape(px: vec2<f32>, i: u32, dst: vec3<f32>) -> vec3<f32> {
    let row = SE_ROW_SHAPES + 5u * i;
    let r0 = scene.rows[row];
    let r1 = scene.rows[row + 1u];
    let c0 = scene.rows[row + 2u];
    let c1 = scene.rows[row + 3u];
    let r4 = scene.rows[row + 4u];
    let kind = i32(round(r0.x));
    let h = max(r1.xy, vec2<f32>(0.0));
    let param = r1.z;
    let squash = clamp(r1.w, 0.02, 1.0);
    let soft = max(r4.y, 0.0);
    let stroke = max(r4.z, 0.0);
    let opacity = clamp(c0.w, 0.0, 1.0);
    if (opacity <= 0.0 || kind < 1 || kind > 8) {
        return dst;
    }
    // Cheap reject: past the bounding circle plus the blur, the stroke and a pixel.
    let reach = length(h) / squash + soft + stroke + 2.0;
    let rel = px - r0.yz;
    if (dot(rel, rel) > reach * reach) {
        return dst;
    }
    // Local space: unrotated, then un-squashed (a body's twist narrows it horizontally).
    let unturn = vec2<f32>(cos(r0.w), -sin(r0.w));
    var q = se_turn(rel, unturn);
    q.x /= squash;

    // The shape's distance, and for the eye its pupil, for the cube its faces and edges.
    var d = 1e6;
    var pupil = 1e6;
    var cube = vec3<f32>(1e6, 0.0, 1e6);
    var back = 1e6;
    switch kind {
        case 1: {
            d = se_ellipse(q, h);
        }
        case 2: {
            d = max(se_ellipse(q, h), q.y);
        }
        case 3: {
            d = se_lens(q, h.x, h.y * clamp(param, 0.02, 1.0));
        }
        case 4: {
            d = se_lens(q, h.x, h.y);
            pupil = length(q) - clamp(param, 0.0, 1.0) * h.y;
        }
        case 5: {
            d = se_arcs(q, h, clamp(round(param), 1.0, 8.0));
        }
        case 6: {
            d = se_round_rect(q, h, clamp(param, 0.0, 1.0) * min(h.x, h.y));
        }
        case 7: {
            let k = h.y * clamp(param, 0.05, 0.9);
            cube = se_cube(q, h, k);
            d = cube.x;
            back = se_cube_back(q, h, k);
        }
        default: {
            let w = clamp(param, 0.0, 1.0) * min(h.x, h.y);
            d = abs(se_ellipse(q, h) + w * 0.5) - w * 0.5;
        }
    }
    // Distances were taken in un-squashed space; scale back so the edge stays one pixel wide.
    d *= squash;
    pupil *= squash;
    if (stroke > 0.0 && kind != 7) {
        d = abs(d) - stroke * 0.5;
    }

    // The fill: solid; linear from color 0 to color 1 along the angle in the shape's own frame
    // (it turns with the shape: 0 points +x, right; pi/2 points +y, down); or radial, color 0 at
    // the center to color 1 at the box's edge.
    let fill = i32(round(c1.w));
    var t = 0.0;
    if (fill == 1) {
        let dir = vec2<f32>(cos(r4.x), sin(r4.x));
        let span = max(abs(h.x * dir.x) + abs(h.y * dir.y), 1.0);
        t = clamp(dot(q, dir) / span * 0.5 + 0.5, 0.0, 1.0);
    } else if (fill == 2) {
        t = clamp(length(q / max(h, vec2<f32>(1.0))), 0.0, 1.0);
    }
    var col = mix(c0.rgb, c1.rgb, t);
    let alpha = opacity;

    // The light at the shape: a soft highlight on the side facing it.
    let lrow = scene.rows[SE_ROW_LIGHT];
    let lcol = scene.rows[SE_ROW_LIGHT + 1u].rgb;
    let lamt = se_light_at(px);
    let ldir_world = lrow.xy - r0.yz;
    let ldir = se_turn(ldir_world / max(length(ldir_world), 1.0), unturn);
    let facing = clamp(dot(q / max(max(h.x, h.y), 1.0), ldir) * 0.5 + 0.5, 0.0, 1.0);
    let lit = clamp(r4.w, 0.0, 1.0);

    if (kind == 7) {
        // Glass: each face lets the backdrop through tinted by the fill (it absorbs: the top a
        // little, toward color 0; the side facing the light more, toward color 1; the far side
        // most, and darker), then reflects a sheen that fades down the face and the light. The
        // hidden back edges show through; every edge is a thin bright line, brightest where it
        // faces the light, with a faint dark rim outside the silhouette so it reads on a pale
        // field.
        let face = cube.y;
        // The right face (2) faces a light to the right; the left face (1) one to the left.
        let light_right = ldir.x >= 0.0;
        let toward_light = light_right == (face == 2.0);
        let one = vec3<f32>(1.0);
        let t_top = mix(one, c0.rgb, 0.35);
        let t_near = mix(one, c1.rgb, 0.5) * 0.94;
        let t_far = mix(one, c1.rgb, 0.9) * 0.7;
        let trans = select(select(t_far, t_near, toward_light), t_top, face == 0.0);
        let sheen = clamp(0.5 - q.y / max(h.y, 1.0) * 0.5, 0.0, 1.0);
        let refl = one * (select(0.06, 0.16, face == 0.0) + 0.12 * sheen)
            + lit * lamt * lcol * (0.08 + 0.35 * facing);
        let glass = dst * trans + refl;
        let body = se_cover(d, soft) * opacity;
        var res = mix(dst, glass, body);
        let edge_w = max(1.0, frame.size.z * 0.7);
        let inside = se_cover(d, 0.0);
        let outer = se_cover(abs(d) - edge_w * 0.5, 0.0);
        let inner = se_cover(cube.z * squash - edge_w * 0.5, 0.0) * inside;
        let hidden = se_cover(back * squash - edge_w * 0.4, 0.0) * inside * 0.5;
        let rim = se_cover(abs(d - edge_w * 1.5) - edge_w * 0.5, 0.0) * 0.3 * opacity;
        let along = clamp(dot(normalize(q + vec2<f32>(1e-3)), ldir) * 0.5 + 0.5, 0.0, 1.0);
        let glint = 0.75 + 0.35 * along + lit * lamt * 0.6 * along;
        let edge = max(max(outer, inner), hidden);
        res = res * (1.0 - rim) + res * c1.rgb * 0.55 * rim;
        let edge_col = min(mix(c0.rgb, one, 0.85) * glint + lcol * lit * lamt * 0.3, vec3<f32>(1.6));
        res = se_over(res, edge_col, clamp(edge * opacity * (0.75 + 0.25 * along), 0.0, 1.0));
        return res;
    }

    col += lit * lamt * lcol * (0.25 + 0.75 * facing);
    var res = se_over(dst, col, se_cover(d, soft) * alpha);
    if (kind == 4) {
        // The pupil: color 1 for a gradient fill; for a solid one, the fill (a stroked eye) or
        // the fill pulled toward ink.
        var pc = c1.rgb;
        if (fill == 0) {
            pc = select(mix(c0.rgb, frame.ink.rgb, 0.65), c0.rgb, stroke > 0.0);
        }
        res = se_over(res, pc, se_cover(max(pupil, d), soft) * opacity);
    }
    return res;
}

// Guide i: a thin line, dashed when dash > 0, with hollow square handles at both ends.
fn se_guide(px: vec2<f32>, i: u32, dst: vec3<f32>) -> vec3<f32> {
    let row = SE_ROW_GUIDES + 3u * i;
    let g = scene.rows[row];
    let o = scene.rows[row + 1u];
    let c = scene.rows[row + 2u].rgb;
    let opacity = clamp(o.y, 0.0, 1.0);
    if (opacity <= 0.0) {
        return dst;
    }
    let w = max(o.x, 0.0);
    // Ends snapped to pixel centers, so a level or plumb line lands on one row or column and
    // stays crisp instead of splitting into two half-strength ones.
    let a = floor(g.xy) + vec2<f32>(0.5);
    let b = floor(g.zw) + vec2<f32>(0.5);
    let seg = se_segment(px, a, b);
    // A line under a pixel wide is drawn one pixel wide; under two thirds of one, fainter.
    var cov = se_cover(seg.x - max(w, 1.0) * 0.5, 0.0) * min(max(w, 0.33) * 1.5, 1.0);
    let dash = o.w;
    if (dash > 0.0) {
        let m = seg.y - floor(seg.y / (2.0 * dash)) * 2.0 * dash;
        cov *= clamp(0.5 + dash * 0.5 - abs(m - dash * 0.5), 0.0, 1.0);
    }
    if (o.z > 0.5) {
        // Handles: hollow squares about 5 points across, the line stopping at their edge.
        // A whole number of pixels, on the snapped ends, so the square's sides are crisp.
        let hs = max(round(2.5 * frame.size.z), 2.0);
        let lw = max(1.0, round(frame.size.z * 0.75));
        let da = max(abs(px.x - a.x), abs(px.y - a.y)) - hs;
        let db = max(abs(px.x - b.x), abs(px.y - b.y)) - hs;
        let dh = min(da, db);
        cov *= se_cover(-dh, 0.0);
        cov = max(cov, se_cover(abs(dh) - lw * 0.5, 0.0));
    }
    return se_over(dst, c, cov * opacity);
}

// Rope point j (two to a row: xy, then zw).
fn se_rope_point(j: u32) -> vec2<f32> {
    let r = scene.rows[SE_ROW_ROPE_POINTS + j / 2u];
    return select(r.zw, r.xy, (j & 1u) == 0u);
}

// The ropes: rope 0's points first, then rope 1's; each a polyline strip of its width and color.
fn se_ropes(px: vec2<f32>, dst: vec3<f32>, n0: u32, n1: u32) -> vec3<f32> {
    var res = dst;
    for (var r = 0u; r < 2u; r++) {
        let first = select(n0, 0u, r == 0u);
        let n = select(n1, n0, r == 0u);
        if (n < 2u) {
            continue;
        }
        let style = scene.rows[SE_ROW_ROPES + r];
        var d = 1e6;
        var a = se_rope_point(first);
        for (var j = 1u; j < n; j++) {
            let b = se_rope_point(first + j);
            d = min(d, se_segment(px, a, b).x);
            a = b;
        }
        let w = max(style.w, 1.0);
        // A flat strap of the rope's width and color.
        res = se_over(res, style.rgb, se_cover(d - w * 0.5, 0.0));
    }
    return res;
}

// The image slot: a rounded rect, turned and squashed with its body, sampled from the host's
// texture (premultiplied; an sRGB texture, so samples are linear).
fn se_image(px: vec2<f32>, dst: vec3<f32>) -> vec3<f32> {
    let a = scene.rows[SE_ROW_IMAGE];
    let b = scene.rows[SE_ROW_IMAGE + 1u];
    let h = max(a.zw, vec2<f32>(1.0));
    let squash = clamp(b.y, 0.02, 1.0);
    var q = se_turn(px - a.xy, vec2<f32>(cos(b.x), -sin(b.x)));
    q.x /= squash;
    let d = se_round_rect(q, h, max(b.z, 0.0)) * squash;
    let cov = se_cover(d, 0.0) * clamp(b.w, 0.0, 1.0);
    if (cov <= 0.0) {
        return dst;
    }
    let uv = clamp(q / (2.0 * h) + 0.5, vec2<f32>(0.0), vec2<f32>(1.0));
    let s = textureSampleLevel(scene_image, scene_sampler, uv, 0.0);
    return s.rgb * cov + dst * (1.0 - s.a * cov);
}

// Film grain: a triangular per-cell hash, `size` px cells, applied in sqrt space so it reads the
// same in shadows and highlights. Seed 0 keeps the same grain every frame.
fn se_grain(px: vec2<f32>, c: vec3<f32>) -> vec3<f32> {
    let g = scene.rows[1];
    let amount = clamp(g.x, 0.0, 1.0);
    if (amount <= 0.0) {
        return c;
    }
    let cell = vec2<u32>(max(floor(px / max(g.y, 0.5)), vec2<f32>(0.0)));
    let z = u32(fract(g.z) * 65536.0);
    let n = se_hash(cell.x, cell.y, z) + se_hash(cell.x + 7919u, cell.y + 104729u, z) - 1.0;
    let sq = sqrt(max(c, vec3<f32>(0.0))) + vec3<f32>(n * amount * 0.6);
    let v = max(sq, vec3<f32>(0.0));
    return v * v;
}

fn wallpaper(px: vec2<f32>) -> vec4<f32> {
    let head = scene.rows[0];
    var col = se_field(px);

    let shapes = min(u32(max(head.x, 0.0)), SE_MAX_SHAPES);
    for (var i = 0u; i < shapes; i++) {
        col = se_shape(px, i, col);
    }
    let guides = min(u32(max(head.y, 0.0)), SE_MAX_GUIDES);
    for (var i = 0u; i < guides; i++) {
        col = se_guide(px, i, col);
    }
    let n0 = min(u32(max(head.z, 0.0)), SE_MAX_ROPE_POINTS);
    let n1 = min(u32(max(head.w, 0.0)), SE_MAX_ROPE_POINTS - n0);
    col = se_ropes(px, col, n0, n1);
    if (scene.rows[1].w > 0.5) {
        col = se_image(px, col);
    }
    col += scene.rows[SE_ROW_LIGHT + 1u].rgb * se_light_at(px) * 0.35;
    col = se_grain(px, col);
    return vec4<f32>(col, 1.0);
}
