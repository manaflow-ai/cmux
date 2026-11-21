//! A random walk of layout changes and interrupted motions, refusing any commit that does not
//! tile its viewport exactly (F2: `cmux_layout_reducer::tiling`).
//!
//! Each step is a split, a close, a divider resize (a release that springs), a move of a pane, a
//! zoom or unzoom, a window resize or a move to a display of another scale (1, 1.5, 2, 3). The
//! walk solves the new layout ([`SplitSolver::layout`], the app's `SplitGeometry.layout`) and
//! checks it as it is (the rest commit). Then it shows the change as the app does: a split, a
//! close, a move and a zoom are one commit shown whole; a resize retargets every frame's four
//! springs and keeps their values and velocities (`AnimatedFrame.setTarget`); a window resize
//! moves each frame with its target (`AnimatedFrame.rebase`). The springs step a random number of
//! display frames, so the next change interrupts the motion, and every frame shown is placed as
//! the screen places it (`pixel_edges`) and checked (the motion commits). Floating frames ride
//! along and must stay inside the viewport.
//!
//! `TILING_WALK_WALKS=N` runs N walks instead of 400. `TILING_WALK_COUNT=1` counts the commits that break the rule instead of refusing the first,
//! and prints the counts (the before and after numbers of the change that added this walk).

use cmux_layout_reducer::floating_panes::{FloatFrame, UNIT};
use cmux_layout_reducer::optimistic::{Dir, Node};
use cmux_layout_reducer::split_layout::{SplitSolver, SplitStyle};
use cmux_layout_reducer::tiling::{Checker, Fault, Frame, RectPt};
use cmux_motion::{MotionSpring, SpringParameters, advance_spring};
use std::collections::BTreeMap;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn pick<T: Copy>(&mut self, items: &[T]) -> T {
        items[self.below(items.len() as u64) as usize]
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Spring {
    value: f64,
    velocity: f64,
    target: f64,
}

/// `AnimatedFrame`: a rect's four springs.
#[derive(Clone, Copy, Debug, Default)]
struct Animated {
    x: Spring,
    y: Spring,
    w: Spring,
    h: Spring,
}

impl Animated {
    fn at(rect: RectPt) -> Animated {
        let s = |v: f64| Spring { value: v, velocity: 0.0, target: v };
        Animated { x: s(rect.x), y: s(rect.y), w: s(rect.w), h: s(rect.h) }
    }

    fn rect(&self) -> RectPt {
        RectPt::new(self.x.value, self.y.value, self.w.value, self.h.value)
    }

    fn target(&self) -> RectPt {
        RectPt::new(self.x.target, self.y.target, self.w.target, self.h.target)
    }

    fn set_target(&mut self, rect: RectPt) {
        (self.x.target, self.y.target, self.w.target, self.h.target) =
            (rect.x, rect.y, rect.w, rect.h);
    }

    /// `AnimatedFrame.rebase(onto:)`.
    fn rebase(&mut self, rect: RectPt) {
        let target = self.target();
        self.x.value += rect.x - target.x;
        self.y.value += rect.y - target.y;
        self.w.value += rect.w - target.w;
        self.h.value += rect.h - target.h;
        self.set_target(rect);
    }

    /// `AnimatedFrame.seed(fractionVelocity:)`.
    fn seed(&mut self, rate: f64) {
        for s in [&mut self.x, &mut self.y, &mut self.w, &mut self.h] {
            s.velocity = (s.target - s.value) * rate;
        }
    }

    /// `advanceUnsettled`: the frames of one motion land together, not each edge on its own.
    fn advance(&mut self, dt: f64, p: SpringParameters) {
        for s in [&mut self.x, &mut self.y, &mut self.w, &mut self.h] {
            advance_spring(&mut s.value, &mut s.velocity, s.target, dt, p, 0.0);
        }
    }

    fn near_rest(&self) -> bool {
        [self.x, self.y, self.w, self.h]
            .iter()
            .all(|s| (s.value - s.target).abs() <= 0.25 && s.velocity.abs() <= 2.0)
    }

    fn snap(&mut self) {
        for s in [&mut self.x, &mut self.y, &mut self.w, &mut self.h] {
            (s.value, s.velocity) = (s.target, 0.0);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
    Pane(u64),
    Divider(u64),
}

fn leaves(node: &Node, out: &mut Vec<u64>) {
    match node {
        Node::Leaf { pane } => out.push(*pane),
        Node::Split { a, b, .. } => {
            leaves(a, out);
            leaves(b, out);
        }
        _ => {}
    }
}

fn split_handles(node: &Node, out: &mut Vec<u64>) {
    if let Node::Split { split, a, b, .. } = node {
        out.push(split.unwrap_or(0));
        split_handles(a, out);
        split_handles(b, out);
    }
}

/// `node` with `pane` split: `pane` stays first unless `before`, the new pane `new` beside it.
fn split(node: Node, pane: u64, dir: Dir, before: bool, new: u64, handle: u64, ratio: f64) -> Node {
    match node {
        Node::Leaf { pane: p } if p == pane => {
            let (a, b) = if before { (new, pane) } else { (pane, new) };
            Node::Split {
                split: Some(handle),
                split_id: None,
                dir,
                ratio,
                a: Box::new(Node::Leaf { pane: a }),
                b: Box::new(Node::Leaf { pane: b }),
            }
        }
        Node::Split { split: s, split_id, dir: d, ratio: r, a, b } => Node::Split {
            split: s,
            split_id,
            dir: d,
            ratio: r,
            a: Box::new(split(*a, pane, dir, before, new, handle, ratio)),
            b: Box::new(split(*b, pane, dir, before, new, handle, ratio)),
        },
        other => other,
    }
}

/// `node` without `pane`: its split's other side takes the split's place.
fn close(node: Node, pane: u64) -> Node {
    match node {
        Node::Split { split, split_id, dir, ratio, a, b } => {
            if matches!(*a, Node::Leaf { pane: p } if p == pane) {
                return *b;
            }
            if matches!(*b, Node::Leaf { pane: p } if p == pane) {
                return *a;
            }
            Node::Split {
                split,
                split_id,
                dir,
                ratio,
                a: Box::new(close(*a, pane)),
                b: Box::new(close(*b, pane)),
            }
        }
        other => other,
    }
}

fn set_ratio(node: &mut Node, handle: u64, value: f64) {
    if let Node::Split { split, ratio, a, b, .. } = node {
        if *split == Some(handle) {
            *ratio = value;
        }
        set_ratio(a, handle, value);
        set_ratio(b, handle, value);
    }
}

#[derive(Default, Debug)]
struct Counts {
    rest: u64,
    rest_faults: BTreeMap<&'static str, u64>,
    motion: u64,
    motion_faults: BTreeMap<&'static str, u64>,
    first: Vec<(String, String)>,
}

impl Counts {
    fn faults(&self) -> u64 {
        self.rest_faults.values().sum::<u64>() + self.motion_faults.values().sum::<u64>()
    }
}

struct Walk {
    rng: Rng,
    tree: Node,
    zoomed: Option<u64>,
    next_id: u64,
    scale: f64,
    px: (u64, u64),
    style: SplitStyle,
    frames: BTreeMap<Key, Animated>,
    floating: Vec<FloatFrame>,
    solver: SplitSolver,
    checker: Checker,
    counts: Counts,
    refuse: bool,
    log: Vec<String>,
}

const SCALES: [f64; 4] = [1.0, 1.5, 2.0, 3.0];

impl Walk {
    fn new(seed: u64, refuse: bool) -> Walk {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let scale = rng.pick(&SCALES);
        let divider = rng.pick(&[1.0, 1.0, 0.0, 2.0]);
        let mut walk = Walk {
            rng,
            tree: Node::Leaf { pane: 1 },
            zoomed: None,
            next_id: 2,
            scale,
            px: (0, 0),
            style: SplitStyle { divider, ..SplitStyle::default() },
            frames: BTreeMap::new(),
            floating: Vec::new(),
            solver: SplitSolver::new(),
            checker: Checker::new(),
            counts: Counts::default(),
            refuse,
            log: Vec::new(),
        };
        walk.px = walk.window();
        walk
    }

    fn window(&mut self) -> (u64, u64) {
        // Mostly a real window; sometimes one smaller than the tree's minimums (a tree another
        // client built, a window being made small).
        if self.rng.below(8) == 0 {
            (1 + self.rng.below(400), 1 + self.rng.below(300))
        } else {
            (600 + self.rng.below(3400), 400 + self.rng.below(2000))
        }
    }

    fn viewport(&self) -> (f64, f64) {
        (self.px.0 as f64 / self.scale, self.px.1 as f64 / self.scale)
    }

    fn shown_tree(&self) -> Node {
        match self.zoomed {
            Some(pane) => Node::Leaf { pane },
            None => self.tree.clone(),
        }
    }

    /// The new layout's frames by key.
    fn targets(&mut self) -> BTreeMap<Key, RectPt> {
        let tree = self.shown_tree();
        let (w, h) = self.viewport();
        let layout = self.solver.layout(&tree, w, h, &self.style, self.scale).clone();
        let mut handles = Vec::new();
        split_handles(&tree, &mut handles);
        let mut out = BTreeMap::new();
        for (pane, rect) in &layout.panes {
            out.insert(Key::Pane(*pane), *rect);
        }
        for (handle, rect) in handles.iter().zip(&layout.dividers) {
            out.insert(Key::Divider(*handle), *rect);
        }
        // The rest commit: the layout as the solver gives it.
        let tiled: Vec<RectPt> = out.values().copied().collect();
        let result = self.checker.check(&Frame {
            width: w,
            height: h,
            scale: self.scale,
            tiled: &tiled,
            floating: &[],
        });
        self.counts.rest += 1;
        self.note(result, true, &tiled);
        out
    }

    fn note(&mut self, result: Result<(), Fault>, rest: bool, tiled: &[RectPt]) {
        let Err(fault) = result else { return };
        let map = if rest { &mut self.counts.rest_faults } else { &mut self.counts.motion_faults };
        let seen = map.contains_key(fault.kind());
        *map.entry(fault.kind()).or_default() += 1;
        let text = format!(
            "{} commit: {fault}\n  scale {} viewport {}x{} px divider {} zoomed {:?}\n  tree {:?}\n  rects {tiled:?}\n  steps: {}",
            if rest { "rest" } else { "motion" },
            self.scale,
            self.px.0,
            self.px.1,
            self.style.divider,
            self.zoomed,
            self.tree,
            self.log.join(" | "),
        );
        if !seen {
            self.counts.first.push((format!("{} {}", rest, fault.kind()), text.clone()));
        }
        assert!(!self.refuse, "F2 broken: {text}");
    }

    /// One frame as the screen shows it.
    fn show(&mut self) {
        let (w, h) = self.viewport();
        let tiled: Vec<RectPt> =
            self.frames.values().map(|f| f.rect().pixel_edges(self.scale)).collect();
        let floating: Vec<RectPt> = self
            .floating
            .iter()
            .map(|f| {
                let u = f64::from(UNIT);
                RectPt::new(
                    f64::from(f.x) / u * w,
                    f64::from(f.y) / u * h,
                    f64::from(f.w) / u * w,
                    f64::from(f.h) / u * h,
                )
            })
            .collect();
        let result = self.checker.check(&Frame {
            width: w,
            height: h,
            scale: self.scale,
            tiled: &tiled,
            floating: &floating,
        });
        self.counts.motion += 1;
        self.note(result, false, &tiled);
    }

    /// The change shown whole in one commit.
    fn snap_to(&mut self, targets: BTreeMap<Key, RectPt>) {
        self.frames = targets.into_iter().map(|(k, r)| (k, Animated::at(r))).collect();
        self.show();
    }

    fn step(&mut self) {
        let mut panes = Vec::new();
        leaves(&self.tree, &mut panes);
        let mut handles = Vec::new();
        split_handles(&self.tree, &mut handles);
        let op = self.rng.below(100);
        let mut springs = false;
        if op < 22 && panes.len() < 24 {
            let pane = self.rng.pick(&panes);
            let dir = self.rng.pick(&[Dir::Right, Dir::Down]);
            let (new, handle) = (self.next_id, self.next_id + 1);
            self.next_id += 2;
            let before = self.rng.below(2) == 0;
            self.log.push(format!("split {pane} {dir:?} new {new}"));
            self.tree = split(self.tree.clone(), pane, dir, before, new, handle, 0.5);
            self.zoomed = None;
            let t = self.targets();
            self.snap_to(t);
        } else if op < 40 && panes.len() > 1 {
            let pane = self.rng.pick(&panes);
            self.log.push(format!("close {pane}"));
            self.tree = close(self.tree.clone(), pane);
            if self.zoomed == Some(pane) {
                self.zoomed = None;
            }
            let t = self.targets();
            self.snap_to(t);
        } else if op < 65 && !handles.is_empty() {
            // A divider released (or a key resize): every frame springs to the new layout from where it shows.
            let handle = self.rng.pick(&handles);
            let ratio = match self.rng.below(6) {
                0 => self.rng.pick(&[0.0, 1.0, 0.5, 1.0 / 3.0, 2.0 / 3.0]),
                _ => 0.05 + 0.9 * self.rng.unit(),
            };
            self.log.push(format!("resize {handle} {ratio}"));
            set_ratio(&mut self.tree, handle, ratio);
            let targets = self.targets();
            if self.frames.keys().ne(targets.keys()) {
                self.snap_to(targets);
            } else {
                let rate = if self.rng.below(2) == 0 { 0.0 } else { 10.0 * self.rng.unit() };
                for (key, rect) in targets {
                    if let Some(frame) = self.frames.get_mut(&key) {
                        frame.set_target(rect);
                        if rate > 0.0 {
                            frame.seed(rate);
                        }
                    }
                }
                springs = true;
            }
        } else if op < 75 && panes.len() > 1 {
            let pane = self.rng.pick(&panes);
            let to = self.rng.pick(&panes);
            if to != pane {
                let dir = self.rng.pick(&[Dir::Right, Dir::Down]);
                let handle = self.next_id;
                self.next_id += 1;
                self.log.push(format!("move {pane} to {to} {dir:?}"));
                let before = self.rng.below(2) == 0;
                // The moved pane keeps its id: closed out, then split in beside `to`.
                self.tree = close(self.tree.clone(), pane);
                self.tree = split(self.tree.clone(), to, dir, before, pane, handle, 0.5);
                self.zoomed = None;
                let t = self.targets();
                self.snap_to(t);
            }
        } else if op < 82 {
            self.zoomed = match self.zoomed {
                Some(_) => None,
                None => Some(self.rng.pick(&panes)),
            };
            self.log.push(format!("zoom {:?}", self.zoomed));
            let t = self.targets();
            self.snap_to(t);
        } else if op < 94 {
            // A window resize under a running motion: each frame moves with its target.
            self.px = self.window();
            self.log.push(format!("window {}x{}", self.px.0, self.px.1));
            let targets = self.targets();
            // A rebase that would turn a pane inside out (the window shrank by more than the spring had left to
            // travel) lands the motion instead (`ScreenContentView.reconcile`, `AnimatedFrame.rebaseKeepsExtent`).
            let inverts = targets.iter().any(|(key, rect)| {
                self.frames.get(key).is_some_and(|f| {
                    let t = f.target();
                    f.w.value + rect.w - t.w < 0.0 || f.h.value + rect.h - t.h < 0.0
                })
            });
            if self.frames.keys().ne(targets.keys()) || inverts {
                self.snap_to(targets);
            } else {
                for (key, rect) in targets {
                    if let Some(frame) = self.frames.get_mut(&key) {
                        frame.rebase(rect);
                    }
                }
                springs = true;
            }
        } else if op < 97 {
            self.scale = self.rng.pick(&SCALES);
            self.log.push(format!("scale {}", self.scale));
            let t = self.targets();
            self.snap_to(t);
        } else {
            let frame = FloatFrame {
                x: self.rng.below(u64::from(UNIT)) as u32,
                y: self.rng.below(u64::from(UNIT)) as u32,
                w: self.rng.below(u64::from(UNIT)) as u32,
                h: self.rng.below(u64::from(UNIT)) as u32,
            }
            .clamped();
            self.floating.push(frame);
            if self.floating.len() > 3 {
                self.floating.remove(0);
            }
        }
        if self.log.len() > 12 {
            self.log.remove(0);
        }
        if !springs {
            return;
        }
        // Display frames until the next change interrupts the motion, or it lands.
        let p = if self.rng.below(2) == 0 {
            MotionSpring::Settle.base()
        } else {
            MotionSpring::Move.base()
        };
        let dt = self.rng.pick(&[1.0 / 120.0, 1.0 / 60.0, 1.0 / 30.0]);
        let frames = self.rng.pick(&[1, 2, 3, 5, 8, 13, 40]);
        for _ in 0..frames {
            for frame in self.frames.values_mut() {
                frame.advance(dt, p);
            }
            if self.frames.values().all(Animated::near_rest) {
                for frame in self.frames.values_mut() {
                    frame.snap();
                }
            }
            self.show();
        }
    }
}

fn run(walks: u64, steps: u64, refuse: bool) -> Counts {
    let mut total = Counts::default();
    for seed in 0..walks {
        let mut walk = Walk::new(seed, refuse);
        let t = walk.targets();
        walk.snap_to(t);
        for _ in 0..steps {
            walk.step();
        }
        total.rest += walk.counts.rest;
        total.motion += walk.counts.motion;
        for (k, v) in walk.counts.rest_faults {
            *total.rest_faults.entry(k).or_default() += v;
        }
        for (k, v) in walk.counts.motion_faults {
            *total.motion_faults.entry(k).or_default() += v;
        }
        for first in walk.counts.first {
            if !total.first.iter().any(|f| f.0 == first.0) {
                total.first.push(first);
            }
        }
    }
    total
}

#[test]
fn every_commit_of_a_random_walk_of_interrupted_motions_tiles_its_viewport() {
    let count = std::env::var_os("TILING_WALK_COUNT").is_some();
    // `TILING_WALK_WALKS=N` runs more walks (each 150 steps) than the 400 of a test run.
    let walks = std::env::var("TILING_WALK_WALKS").ok().and_then(|n| n.parse().ok()).unwrap_or(400);
    let counts = run(walks, 150, !count);
    eprintln!(
        "tiling walk: {} rest commits, faults {:?}; {} motion commits, faults {:?}; {} of {} commits do not tile",
        counts.rest,
        counts.rest_faults,
        counts.motion,
        counts.motion_faults,
        counts.faults(),
        counts.rest + counts.motion,
    );
    for first in &counts.first {
        eprintln!("{}", first.1);
    }
    assert!(counts.motion > 50_000, "the walk shows enough frames: {}", counts.motion);
}
