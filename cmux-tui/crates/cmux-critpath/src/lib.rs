//! Critical path, drag and speed-of-light gaps from our own trace streams (RFD "Speed of light").
//!
//! The ideas are borrowed (the critical path method's *drag*, Brendan Gregg's off-CPU and wakeup
//! analysis, Rewind's `rewind time`, Nvidia's speed-of-light habit); the code and the data are ours.
//!
//! A run is a [`Graph`]: nodes in causal order (every dependency has a lower index), each with its
//! own `[start, end]` and the nodes it *follows from* (the ones whose end let it start: the waker).
//! The analysis replays the run as a schedule in which a node starts when its last dependency ends
//! plus the wait it really had (its *gap*), so a change to one node's duration moves everything
//! after it, as it would have in the real run:
//!
//! - **critical path**: from the node that ends last, back through the latest-ending dependency
//!   each time; its length is the run's elapsed time;
//! - **drag** of a category (or of one node): how much sooner the run ends when every node of it
//!   takes no time. Drag is never more than the category's time on the path, and less when a
//!   parallel branch takes over (two tool calls in one assistant message);
//! - **state** of each node (ours, model, tool, wait), so the path's off-CPU share falls out.
//!
//! Inputs today: acpmux's per-session event logs ([`acpmux`]), and any JSONL span file
//! ([`spans`]) so landing, CI and nightly timelines feed the same analysis.

pub mod acpmux;
pub mod spans;

use std::collections::BTreeMap;

/// Who was doing the work in a node: what a flame graph colors it by.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum State {
    /// Our own code computing (acpmux, glaeda-gh, a tool we wrote).
    Ours,
    /// A model vendor generating: off our CPU, on theirs.
    Model,
    /// A tool the agent ran (a shell command, a subagent).
    Tool,
    /// Nobody working: a queue, a stall, a wait for a wake.
    Wait,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ours => "ours",
            Self::Model => "model",
            Self::Tool => "tool",
            Self::Wait => "wait",
        }
    }

    pub fn parse(text: &str) -> Self {
        match text {
            "ours" | "on" | "cpu" => Self::Ours,
            "model" => Self::Model,
            "tool" => Self::Tool,
            _ => Self::Wait,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Node {
    /// What this step was (a tool call's command, a stage's name).
    pub name: String,
    /// What it is grouped by for drag: `tool:Bash:cargo`, `acpmux:prompt-write`.
    pub cat: String,
    pub state: State,
    /// Milliseconds (any epoch, the same for one graph).
    pub start: i64,
    pub end: i64,
    /// Indexes of the nodes it follows from; every one is lower than this node's own.
    pub deps: Vec<usize>,
}

impl Node {
    pub fn dur(&self) -> i64 {
        (self.end - self.start).max(0)
    }
}

/// One run: a turn, a delivery, a landing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Graph {
    /// Which run (a session and turn, a PR).
    pub label: String,
    pub nodes: Vec<Node>,
}

/// One stretch of the critical path.
#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub node: usize,
    /// The wait before the node started after its waker ended (0 when it started at once).
    pub gap: i64,
    pub dur: i64,
}

impl Graph {
    pub fn push(&mut self, node: Node) -> usize {
        debug_assert!(node.deps.iter().all(|&d| d < self.nodes.len()));
        self.nodes.push(node);
        self.nodes.len() - 1
    }

    /// The wait each node had after its last dependency ended (a root: none).
    fn gaps(&self) -> Vec<i64> {
        self.nodes
            .iter()
            .map(|n| match n.deps.iter().filter_map(|&d| self.nodes.get(d)).map(|p| p.end).max() {
                Some(ready) => (n.start - ready).max(0),
                None => 0,
            })
            .collect()
    }

    /// The run's end when the nodes `zero` says are taken to cost nothing. Roots keep their real
    /// start (an arrival from outside the run); every other node starts when its last dependency
    /// ends plus its own gap.
    pub fn makespan_with(&self, zero: impl Fn(usize, &Node) -> bool) -> i64 {
        let gaps = self.gaps();
        let mut ends: Vec<i64> = Vec::with_capacity(self.nodes.len());
        let origin = self.origin();
        let mut last = origin;
        for ((i, n), gap) in self.nodes.iter().enumerate().zip(gaps) {
            // Every dependency is lower than `i` (`push` checks it), so its end is already in.
            let begin = match n.deps.iter().filter_map(|&d| ends.get(d)).max() {
                Some(&ready) => ready + gap,
                None => n.start,
            };
            let end = begin + if zero(i, n) { 0 } else { n.dur() };
            ends.push(end);
            last = last.max(end);
        }
        last
    }

    pub fn origin(&self) -> i64 {
        self.nodes.iter().map(|n| n.start).min().unwrap_or(0)
    }

    /// Elapsed time of the run as recorded: first start to last end.
    pub fn elapsed(&self) -> i64 {
        self.makespan_with(|_, _| false) - self.origin()
    }

    /// The critical path, first segment first.
    pub fn critical_path(&self) -> Vec<Segment> {
        let end_of = |i: usize| self.nodes.get(i).map_or(i64::MIN, |n| n.end);
        let Some(mut at) = (0..self.nodes.len()).max_by_key(|&i| (end_of(i), i)) else {
            return Vec::new();
        };
        let gaps = self.gaps();
        let mut path = Vec::new();
        while let Some(n) = self.nodes.get(at) {
            path.push(Segment { node: at, gap: gaps.get(at).copied().unwrap_or(0), dur: n.dur() });
            match n.deps.iter().copied().max_by_key(|&d| (end_of(d), d)) {
                Some(waker) => at = waker,
                None => break,
            }
        }
        path.reverse();
        path
    }

    /// Drag of every category with time on the critical path: (category, drag ms, path ms).
    pub fn drag_by_cat(&self) -> Vec<(String, i64, i64)> {
        let full = self.makespan_with(|_, _| false);
        let mut on_path: BTreeMap<&str, i64> = BTreeMap::new();
        for seg in self.critical_path() {
            if let Some(n) = self.nodes.get(seg.node) {
                *on_path.entry(n.cat.as_str()).or_default() += seg.dur;
            }
        }
        on_path
            .into_iter()
            .map(|(cat, path_ms)| {
                let drag = full - self.makespan_with(|_, n| n.cat == cat);
                (cat.to_string(), drag, path_ms)
            })
            .collect()
    }

    /// Drag of each node on the critical path, longest first: (node, drag ms).
    pub fn drag_by_node(&self) -> Vec<(usize, i64)> {
        let full = self.makespan_with(|_, _| false);
        let mut out: Vec<(usize, i64)> = self
            .critical_path()
            .into_iter()
            .map(|seg| (seg.node, full - self.makespan_with(|i, _| i == seg.node)))
            .collect();
        out.sort_by_key(|&(i, d)| (-d, i));
        out
    }

    /// Path time per state, and the wait gaps (which are always `Wait`).
    pub fn path_by_state(&self) -> BTreeMap<State, i64> {
        let mut out = BTreeMap::new();
        for seg in self.critical_path() {
            if let Some(n) = self.nodes.get(seg.node) {
                *out.entry(n.state).or_default() += seg.dur;
            }
            *out.entry(State::Wait).or_default() += seg.gap;
        }
        out
    }
}

/// Totals over many runs (every turn of a day): what would shorten them all.
#[derive(Clone, Debug, Default)]
pub struct Rollup {
    pub runs: usize,
    pub elapsed_ms: i64,
    /// category -> (drag ms summed over runs, path ms summed over runs, runs it was on the path)
    pub cats: BTreeMap<String, (i64, i64, usize)>,
    pub states: BTreeMap<State, i64>,
}

impl Rollup {
    pub fn add(&mut self, g: &Graph) {
        if g.nodes.is_empty() {
            return;
        }
        self.runs += 1;
        self.elapsed_ms += g.elapsed();
        for (cat, drag, path) in g.drag_by_cat() {
            let e = self.cats.entry(cat).or_default();
            e.0 += drag;
            e.1 += path;
            e.2 += 1;
        }
        for (s, ms) in g.path_by_state() {
            *self.states.entry(s).or_default() += ms;
        }
    }

    /// Categories by drag, largest first.
    pub fn top(&self) -> Vec<(&str, i64, i64, usize)> {
        let mut v: Vec<_> = self.cats.iter().map(|(c, &(d, p, n))| (c.as_str(), d, p, n)).collect();
        v.sort_by_key(|&(c, d, _, _)| (-d, c.to_string()));
        v
    }
}

/// Percentiles of a sample, nearest rank: (p50, p90, p99, max).
pub fn quantiles(values: &mut [i64]) -> (i64, i64, i64, i64) {
    if values.is_empty() {
        return (0, 0, 0, 0);
    }
    values.sort_unstable();
    let last = values.len() - 1;
    let at =
        |q: f64| values.get(((q * values.len() as f64) as usize).min(last)).copied().unwrap_or(0);
    (at(0.5), at(0.9), at(0.99), values.last().copied().unwrap_or(0))
}

/// Chrome/Perfetto trace-event JSON (ui.perfetto.dev opens it): one track per graph, a slice per
/// node, and a flow arrow from each waker to the node it woke. The event-time view.
pub fn perfetto(graphs: &[Graph]) -> serde_json::Value {
    use serde_json::json;
    let mut events = Vec::new();
    let mut flow = 0u64;
    for (tid, g) in graphs.iter().enumerate() {
        events.push(json!({"ph": "M", "name": "thread_name", "pid": 1, "tid": tid, "args": {"name": g.label}}));
        let path: std::collections::BTreeSet<usize> =
            g.critical_path().iter().map(|s| s.node).collect();
        for (i, n) in g.nodes.iter().enumerate() {
            events.push(json!({
                "ph": "X", "pid": 1, "tid": tid, "name": n.name, "cat": n.cat,
                "ts": n.start * 1000, "dur": n.dur() * 1000,
                "args": {"state": n.state.as_str(), "critical": path.contains(&i)},
            }));
            for &d in &n.deps {
                let Some(from) = g.nodes.get(d) else { continue };
                flow += 1;
                events.push(json!({"ph": "s", "id": flow, "pid": 1, "tid": tid, "ts": from.end * 1000, "name": "wake", "cat": "wake"}));
                events.push(json!({"ph": "f", "bp": "e", "id": flow, "pid": 1, "tid": tid, "ts": n.start * 1000, "name": "wake", "cat": "wake"}));
            }
        }
    }
    json!({"traceEvents": events, "displayTimeUnit": "ms"})
}

/// Folded stacks of the critical paths (flamegraph.pl, speedscope, inferno): `run;state;cat;name ms`,
/// waits as `wait;<what it waited for>`. The aggregate view: where path time goes, summed.
pub fn folded(graphs: &[Graph], by_run: bool) -> String {
    let mut stacks: BTreeMap<String, i64> = BTreeMap::new();
    for g in graphs {
        let head = if by_run { format!("{};", sanitize(&g.label)) } else { String::new() };
        for seg in g.critical_path() {
            let Some(n) = g.nodes.get(seg.node) else { continue };
            if seg.gap > 0 {
                *stacks.entry(format!("{head}wait;until:{}", sanitize(&n.cat))).or_default() +=
                    seg.gap;
            }
            if seg.dur > 0 {
                let key = format!(
                    "{head}{};{};{}",
                    n.state.as_str(),
                    sanitize(&n.cat),
                    sanitize(&n.name)
                );
                *stacks.entry(key).or_default() += seg.dur;
            }
        }
    }
    let mut out = String::new();
    for (k, v) in stacks {
        out.push_str(&format!("{k} {v}\n"));
    }
    out
}

/// `v[key]` without the panic lint: a missing key (or a `v` that is not an object) reads as null.
pub fn field<'a>(v: &'a serde_json::Value, key: &str) -> &'a serde_json::Value {
    static NULL: serde_json::Value = serde_json::Value::Null;
    v.get(key).unwrap_or(&NULL)
}

fn sanitize(text: &str) -> String {
    text.chars().map(|c| if c == ';' || c == '\n' || c == ' ' { '_' } else { c }).take(80).collect()
}

#[cfg(test)]
mod tests;
