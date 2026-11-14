//! The keyboard resize rules (`shown_resize`) give the answers the app's Swift rules (`ShownResizeRange+Rules.swift`)
//! gave for a seeded corpus: `data/shown_resize_corpus.txt` was recorded by the Swift test
//! `ShownResizeRangeCorpusTests.recordCorpus`, and both the Swift and this test check every line against it. Floats are
//! IEEE-754 bit patterns, so every answer must be equal bit for bit.

use cmux_layout_reducer::shown_resize::{
    self, Bounds, DockSide, RowInput, TradeCandidates, TradeInput,
};

const CORPUS: &str = include_str!("data/shown_resize_corpus.txt");

struct Fields<'a> {
    words: std::str::SplitWhitespace<'a>,
}

impl<'a> Fields<'a> {
    fn word(&mut self) -> &'a str {
        self.words.next().expect("short line")
    }

    fn float(&mut self) -> f64 {
        f64::from_bits(u64::from_str_radix(self.word(), 16).expect("float bits"))
    }

    fn int(&mut self) -> i64 {
        self.word().parse().expect("int")
    }

    fn flag(&mut self) -> bool {
        self.word() == "1"
    }
}

fn hex(value: f64) -> String {
    format!("{:x}", value.to_bits())
}

fn bounds(answer: Option<Bounds>) -> String {
    answer.map_or_else(|| "-".to_owned(), |b| format!("{} {}", hex(b.lower), hex(b.upper)))
}

fn candidates(answer: Option<TradeCandidates>) -> String {
    answer.map_or_else(
        || "-".to_owned(),
        |c| [c.move_points, c.first.0, c.first.1, c.second.0, c.second.1].map(hex).join(" "),
    )
}

fn answer(kind: &str, f: &mut Fields<'_>) -> String {
    match kind {
        "ratio" => bounds(shown_resize::ratio(f.float(), f.float(), f.float(), f.float())),
        "width" => {
            bounds(shown_resize::column_width(f.flag(), f.flag(), f.float(), f.float(), f.float()))
        }
        "dock" => {
            let (viewport, gap, minimum) = (f.float(), f.float(), f.float());
            let count = f.int();
            let sides: Vec<DockSide> = (0..count)
                .map(|_| DockSide {
                    is_target: f.flag(),
                    is_band: f.flag(),
                    is_docked: f.flag(),
                    width: f.float(),
                })
                .collect();
            bounds(shown_resize::dock_width(sides.iter().copied(), viewport, gap, minimum))
        }
        "trade" => {
            let is_columns = f.flag();
            let (strip_width, gap, scale, delta) = (f.float(), f.float(), f.float(), f.float());
            let (left_min_x, left_max_x, left_width) = (f.float(), f.float(), f.float());
            let (right_min_x, right_max_x, right_width) = (f.float(), f.float(), f.float());
            let (left_minimum_width, right_minimum_width) = (f.float(), f.float());
            let (left_fraction, right_fraction) = (f.float(), f.float());
            let offset = f.word();
            let strip_offset = (offset != "-")
                .then(|| f64::from_bits(u64::from_str_radix(offset, 16).expect("offset bits")));
            let (uncovered_min_x, uncovered_max_x, strip_min_x) = (f.float(), f.float(), f.float());
            candidates(shown_resize::trade(&TradeInput {
                is_columns,
                strip_width,
                gap,
                scale,
                delta,
                left_min_x,
                left_max_x,
                left_width,
                right_min_x,
                right_max_x,
                right_width,
                left_minimum_width,
                right_minimum_width,
                left_fraction,
                right_fraction,
                strip_offset,
                uncovered_min_x,
                uncovered_max_x,
                strip_min_x,
            }))
        }
        "rows" => {
            let count = usize::try_from(f.int()).expect("count");
            let heights: Vec<i64> = (0..count).map(|_| f.int()).collect();
            let minimum_heights: Vec<f64> = (0..count).map(|_| f.float()).collect();
            let pane_row = usize::try_from(f.int()).expect("row");
            let rows_enabled = f.flag();
            let (column_height, gap, scale, delta) = (f.float(), f.float(), f.float(), f.float());
            let input = RowInput {
                heights: &heights,
                minimum_heights: &minimum_heights,
                pane_row,
                rows_enabled,
                column_height,
                gap,
                scale,
                delta,
            };
            let mut out = vec![0; count];
            if shown_resize::row_heights(&input, &mut out) {
                out.iter().map(i64::to_string).collect::<Vec<_>>().join(" ")
            } else {
                "-".to_owned()
            }
        }
        other => panic!("unknown kind {other}"),
    }
}

#[test]
fn shown_resize_corpus_matches_the_swift_rules() {
    let mut counts = std::collections::BTreeMap::<&str, usize>::new();
    for line in CORPUS.lines().filter(|line| !line.starts_with('#') && !line.is_empty()) {
        let (inputs, expected) = line.split_once(" => ").expect("=>");
        let mut fields = Fields { words: inputs.split_whitespace() };
        let kind = fields.word();
        assert_eq!(answer(kind, &mut fields), expected, "{line}");
        assert!(fields.words.next().is_none(), "unread fields: {line}");
        *counts.entry(kind).or_default() += 1;
    }
    for kind in ["ratio", "width", "dock", "trade", "rows"] {
        assert!(counts.get(kind).copied().unwrap_or(0) >= 100, "{kind}: {counts:?}");
    }
}
