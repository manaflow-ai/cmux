//! The springing-close rules (`closing_panes`) give the answers the app's Swift rules (`ClosingPanes+Rules.swift`) gave
//! for seeded scripts of closes: `data/closing_panes_corpus.txt` was recorded by the Swift test
//! `ClosingPanesCorpusTests.recordCorpus`, and both the Swift and this test replay every line against it. Each line is
//! one call with its answer and a hash of the whole state after it, so a difference anywhere in the state fails the
//! line. Answers and state are IEEE-754 bit patterns, so every value must be equal bit for bit.

use cmux_layout_reducer::closing_panes::{
    ClosingPanes, Edges, FrameFact, HandleFact, HandleKind, PaneFact, Placed, RowTravel,
};
use std::collections::BTreeMap;

const CORPUS: &str = include_str!("data/closing_panes_corpus.txt");

struct Fields<'a> {
    words: std::str::SplitWhitespace<'a>,
}

impl<'a> Fields<'a> {
    fn word(&mut self) -> &'a str {
        self.words.next().expect("short line")
    }

    fn float(&mut self) -> f64 {
        self.word().parse().expect("number")
    }

    fn optional(&mut self) -> Option<f64> {
        match self.word() {
            "-" => None,
            text => Some(text.parse().expect("number")),
        }
    }

    fn id(&mut self) -> u64 {
        self.word().parse().expect("id")
    }

    fn flag(&mut self) -> bool {
        self.word() == "1"
    }

    fn edges(&mut self) -> Edges {
        Edges { min_x: self.float(), max_x: self.float(), min_y: self.float(), max_y: self.float() }
    }

    fn frames(&mut self) -> Vec<FrameFact> {
        (0..self.id())
            .map(|_| FrameFact {
                id: self.id(),
                now: self.edges(),
                target: self.edges(),
                moving: self.flag(),
                vx: self.float(),
                vy: self.float(),
                vw: self.float(),
                vh: self.float(),
            })
            .collect()
    }

    fn rows(&mut self) -> Vec<RowTravel> {
        (0..self.id())
            .map(|_| RowTravel { column: self.id(), now: self.float(), target: self.float() })
            .collect()
    }
}

fn hex(value: f64) -> String {
    format!("{:x}", value.to_bits())
}

fn rect(r: Placed) -> String {
    [r.x, r.y, r.width, r.height].map(hex).join(",")
}

/// Replays one call on `closing`; returns its answer and the state hash.
fn call(line: &str, closing: &mut ClosingPanes) -> String {
    let mut f = Fields { words: line.split_whitespace() };
    let answer = match f.word() {
        "B" => {
            let pane = f.id();
            let shown = f.edges();
            let max_gap = f.float();
            let view_shift = f.optional();
            let panes: Vec<PaneFact> = (0..f.id())
                .map(|_| PaneFact {
                    id: f.id(),
                    edges: f.edges(),
                    scrolls: f.flag(),
                    area: f.id(),
                    row_column: f.id(),
                })
                .collect();
            let handles: Vec<HandleFact> = (0..f.id())
                .map(|_| HandleFact {
                    kind: match f.id() {
                        0 => HandleKind::Split,
                        1 => HandleKind::ColumnEdge,
                        2 => HandleKind::RowEdge,
                        other => panic!("handle kind {other}"),
                    },
                    horizontal: f.flag(),
                    hit: f.edges(),
                    mid_x: f.float(),
                    mid_y: f.float(),
                    kept: f.flag(),
                    fixed_split: f.flag(),
                    area: f.id(),
                    docked: f.flag(),
                    column: f.id(),
                })
                .collect();
            if closing.begin(pane, shown, &panes, &handles, max_gap, view_shift) {
                "1"
            } else {
                "0"
            }
            .to_owned()
        }
        "T" => {
            let frames = f.frames();
            let rows = f.rows();
            let still: Vec<String> =
                closing.settle(&frames, &rows).iter().map(u64::to_string).collect();
            if still.is_empty() { "-".to_owned() } else { still.join(",") }
        }
        "R" => {
            let frames = f.frames();
            let rows = f.rows();
            let placed: Vec<String> = closing
                .rects(&frames, &rows)
                .iter()
                .map(|(pane, r)| format!("{pane}:{}", rect(*r)))
                .collect();
            if placed.is_empty() { "-".to_owned() } else { placed.join(";") }
        }
        "C" => {
            let drift = f.float();
            closing.carry(drift, f.optional());
            "-".to_owned()
        }
        "K" => {
            closing.settle_carried(f.float());
            "-".to_owned()
        }
        "Y" => {
            let column = f.id();
            closing.shift_y(column, f.float());
            "-".to_owned()
        }
        "X" => {
            let pane = f.id();
            let frames = f.frames();
            closing.remove(pane, &frames).map_or_else(
                || "-".to_owned(),
                |t| format!("{},{}", rect(t.rect), [t.vx, t.vw, t.vy, t.vh].map(hex).join(",")),
            )
        }
        "D" => {
            closing.drop_pane(f.id());
            "-".to_owned()
        }
        other => panic!("unknown call {other}"),
    };
    assert!(f.words.next().is_none(), "unread words: {line}");
    format!("{answer} {:x}", closing.state_hash())
}

#[test]
fn every_call_of_the_corpus_gives_the_swift_answer_and_state() {
    let mut closing = ClosingPanes::new();
    let mut calls: BTreeMap<String, usize> = BTreeMap::new();
    let mut answered: BTreeMap<String, usize> = BTreeMap::new();
    for raw in CORPUS.lines().filter(|l| !l.is_empty() && !l.starts_with('#')) {
        if raw == "S" {
            closing = ClosingPanes::new();
            continue;
        }
        let (inputs, expected) = raw.split_once(" => ").expect("bad line");
        let got = call(inputs, &mut closing);
        assert_eq!(got, expected, "{}", &inputs[..inputs.len().min(120)]);
        let kind = inputs[..1].to_owned();
        *calls.entry(kind.clone()).or_default() += 1;
        if !expected.starts_with("- ") && !expected.starts_with("0 ") {
            *answered.entry(kind).or_default() += 1;
        }
    }
    for (kind, least) in
        [("B", 200), ("T", 160), ("R", 600), ("C", 40), ("K", 20), ("Y", 20), ("X", 20), ("D", 10)]
    {
        let count = calls.get(kind).copied().unwrap_or(0);
        assert!(count >= least, "{kind}: {count} calls");
    }
    assert!(answered.get("R").copied().unwrap_or(0) >= 500);
    assert!(answered.get("T").copied().unwrap_or(0) >= 20);
    assert!(answered.get("X").copied().unwrap_or(0) >= 15);
}
