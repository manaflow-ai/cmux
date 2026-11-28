//! The bench fixture: the same mix the web `transcript_fling` bench flings (prose, code every seventh row, a rich
//! KaTeX block every tenth), generated from a fixed seed so both arms and every run draw the same document.

/// One transcript row, before layout.
#[derive(Clone, Debug, PartialEq)]
pub enum RowSource {
    /// A prose paragraph, wrapped to the width.
    Text(String),
    /// A code block: lines drawn in the mono font, not wrapped (clipped at the width), on a filled ground.
    Code(Vec<String>),
    /// A rich block (KaTeX in the fixture): the app rasterizes it to a texture; its height is stored.
    Rich { height: f32 },
}

const WORDS: &[&str] = &[
    "the",
    "agent",
    "reads",
    "file",
    "and",
    "then",
    "writes",
    "a",
    "patch",
    "for",
    "transcript",
    "rows",
    "scroll",
    "frame",
    "budget",
    "native",
    "layer",
    "glyph",
    "atlas",
    "texture",
    "metal",
    "render",
    "thread",
    "fling",
    "late",
    "settled",
    "history",
    "page",
    "window",
    "offset",
    "velocity",
    "decay",
    "viewport",
    "quad",
    "instance",
    "buffer",
    "draw",
    "one",
    "pass",
    "under",
    "duress",
    "seconds",
    "milliseconds",
    "tool",
    "call",
    "result",
    "diff",
    "commit",
];

const CODE: &[&str] = &[
    "fn frame(&mut self, now: f64) -> u32 {",
    "    let first = self.rows.partition_point(|r| r.bottom() < top);",
    "    for row in &self.rows[first..] {",
    "        if row.y > bottom { break; }",
    "    }",
    "}",
    "let quads = scene.frame(now, &mut buf);",
    "encoder.draw_primitives_instanced(Triangle, 0, 4, quads);",
];

/// A small deterministic generator (an LCG): the fixture must not depend on a crate or the platform.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u32 {
        self.0 =
            self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) as u32
    }

    fn below(&mut self, n: u32) -> u32 {
        self.next() % n
    }
}

/// `rows` rows: row i is rich when i % 10 == 9, code when i % 7 == 6 (and not rich), else prose of 12 to 90 words.
pub fn fixture(rows: u32) -> Vec<RowSource> {
    let mut rng = Lcg(0x0121_7a5c_f11e_0001);
    (0..rows)
        .map(|i| {
            if i % 10 == 9 {
                RowSource::Rich { height: 48.0 + (rng.below(5) as f32) * 24.0 }
            } else if i % 7 == 6 {
                let n = 3 + rng.below(6) as usize;
                RowSource::Code(
                    (0..n).map(|k| CODE[(k + i as usize) % CODE.len()].to_string()).collect(),
                )
            } else {
                let n = 12 + rng.below(79);
                let mut s = String::new();
                for w in 0..n {
                    if w > 0 {
                        s.push(' ');
                    }
                    s.push_str(WORDS[rng.below(WORDS.len() as u32) as usize]);
                }
                s.push('.');
                RowSource::Text(s)
            }
        })
        .collect()
}
