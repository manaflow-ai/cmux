//! `cmux usage report`: distributions over the records in a time window.
//!
//! Everything is computed from the records alone, at report time, so the recorders stay a plain
//! append. Time spent in a surface is the span from one focus change to the next, ended early by
//! the app going inactive or a launch, and capped at [`IDLE_CAP_MS`] so a night away with cmux in
//! front does not count as use.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write as _;

use chrono::{Local, TimeZone};
use serde::Serialize;

use crate::event::{Entry, Event, Id, Record, Source, Surface};

/// The longest one focus span counts for (30 minutes).
pub const IDLE_CAP_MS: u64 = 30 * 60 * 1000;
/// Action ids whose runs are workspace, tab or pane switches (their latency is the switch latency).
const SWITCH_WORDS: [&str; 5] = ["select", "focus", "switch", "goto", "next"];
/// How many actions the report lists.
const TOP_ACTIONS: usize = 30;

/// A distribution: how many samples and their p50, p95 and largest.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Dist {
    pub n: usize,
    pub p50: f64,
    pub p95: f64,
    pub max: f64,
}

impl Dist {
    pub fn of(mut samples: Vec<f64>) -> Self {
        samples.retain(|s| s.is_finite());
        if samples.is_empty() {
            return Self::default();
        }
        samples.sort_by(f64::total_cmp);
        let at = |q: f64| {
            let rank = (q * samples.len() as f64).ceil() as usize;
            samples[rank.clamp(1, samples.len()) - 1]
        };
        Self { n: samples.len(), p50: at(0.50), p95: at(0.95), max: samples[samples.len() - 1] }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SurfaceTime {
    pub surface: Surface,
    pub seconds: f64,
    pub share: f64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ActionRow {
    pub id: String,
    pub count: usize,
    pub key: usize,
    pub pointer: usize,
    pub automation: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ModelRow {
    pub harness: String,
    pub model: String,
    pub turns: usize,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Unique {
    /// Agent chat tabs the keyboard was in.
    pub chat_tabs: usize,
    /// Content tabs of any kind the keyboard was in.
    pub tabs: usize,
    /// Agent sessions started, shown or with a turn.
    pub agent_sessions: usize,
    /// Machines agent sessions ran on.
    pub machines: usize,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Agents {
    pub sessions_started: usize,
    pub turns: usize,
    pub turn_seconds: Dist,
    pub tool_calls: u64,
    pub subagents: u64,
    pub by_model: Vec<ModelRow>,
    pub by_harness: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Open {
    pub windows: Dist,
    pub workspaces: Dist,
    pub panes: Dist,
    pub tabs: Dist,
    pub terminals: Dist,
    pub browsers: Dist,
    pub chats: Dist,
    pub max_panes_per_screen: Dist,
    pub sidebar_width: Dist,
}

/// The whole report.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Report {
    pub from_ms: u64,
    pub to_ms: u64,
    pub records: usize,
    pub by_source: BTreeMap<String, usize>,
    pub active_hours: usize,
    pub days: usize,
    pub launches: usize,
    /// Launches whose previous run crashed or hung.
    pub crashes: usize,
    pub surface_time: Vec<SurfaceTime>,
    /// Seconds an agent chat tab sat with the keyboard elsewhere before the person came back to it.
    pub chat_hidden_to_return_s: Dist,
    /// The same for browser tabs.
    pub browser_hidden_to_return_s: Dist,
    /// Seconds an agent chat was hidden in every pane before it was shown again (acpmux's view).
    pub chat_view_hidden_to_return_s: Dist,
    /// Distinct agent chat tabs the keyboard was in, per active hour.
    pub chats_per_active_hour: Dist,
    /// Focus changes per active hour.
    pub switches_per_active_hour: Dist,
    pub unique: Unique,
    pub actions: Vec<ActionRow>,
    pub action_runs: usize,
    pub entrypoints: BTreeMap<String, usize>,
    /// Perform-to-commit time of switch actions (workspace, tab, pane, chat selection).
    pub switch_latency_ms: Dist,
    /// Every run's perform-to-commit time.
    pub action_latency_ms: Dist,
    pub latencies_ms: BTreeMap<String, Dist>,
    pub open: Open,
    pub agents: Agents,
    pub interactions: BTreeMap<String, u64>,
    pub connections: BTreeMap<String, Dist>,
}

fn name<T: Serialize>(value: &T) -> String {
    serde_json::to_value(value).ok().and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default()
}

fn hour_of(ms: u64) -> i64 {
    let secs = i64::try_from(ms / 1000).unwrap_or(i64::MAX);
    Local.timestamp_opt(secs, 0).single().map_or(secs / 3600, |t| t.timestamp() / 3600)
}

fn day_of(ms: u64) -> String {
    let secs = i64::try_from(ms / 1000).unwrap_or(i64::MAX);
    Local.timestamp_opt(secs, 0).single().map(|t| t.format("%Y-%m-%d").to_string()).unwrap_or_default()
}

#[derive(Default)]
struct FocusPass {
    surface_ms: BTreeMap<Surface, u64>,
    left: HashMap<Id, u64>,
    chat_return: Vec<f64>,
    browser_return: Vec<f64>,
    chats_by_hour: BTreeMap<i64, BTreeSet<Id>>,
    switches_by_hour: BTreeMap<i64, usize>,
    tabs: BTreeSet<Id>,
    chat_tabs: BTreeSet<Id>,
}

impl FocusPass {
    /// Walks the app's focus, activity and launch records in time order.
    fn run(records: &[&Record]) -> Self {
        let mut pass = Self::default();
        let mut current: Option<(Surface, Option<Id>)> = None;
        let mut since: Option<u64> = None;
        for record in records {
            let at = record.at;
            match &record.ev {
                Event::Focus { surface, tab } => {
                    pass.close(&current, since, at);
                    *pass.switches_by_hour.entry(hour_of(at)).or_default() += 1;
                    if let Some((_, Some(old))) = &current
                        && tab.as_ref() != Some(old)
                    {
                        pass.left.insert(old.clone(), at);
                    }
                    if let Some(tab) = tab {
                        pass.tabs.insert(tab.clone());
                        if let Some(left) = pass.left.remove(tab) {
                            let seconds = at.saturating_sub(left) as f64 / 1000.0;
                            match surface {
                                Surface::Chat => pass.chat_return.push(seconds),
                                Surface::Browser => pass.browser_return.push(seconds),
                                _ => {}
                            }
                        }
                        if *surface == Surface::Chat {
                            pass.chat_tabs.insert(tab.clone());
                            pass.chats_by_hour.entry(hour_of(at)).or_default().insert(tab.clone());
                        }
                    }
                    current = Some((*surface, tab.clone()));
                    since = Some(at);
                }
                Event::Active { on: false } => {
                    pass.close(&current, since, at);
                    since = None;
                }
                Event::Active { on: true } => since = current.as_ref().map(|_| at),
                Event::Launch { .. } => {
                    pass.close(&current, since, at);
                    current = None;
                    since = None;
                    pass.left.clear();
                }
                _ => {}
            }
        }
        pass
    }

    fn close(&mut self, current: &Option<(Surface, Option<Id>)>, since: Option<u64>, at: u64) {
        if let (Some((surface, _)), Some(since)) = (current, since) {
            *self.surface_ms.entry(*surface).or_default() += at.saturating_sub(since).min(IDLE_CAP_MS);
        }
    }
}

/// The report over `records` (in time order) from `from_ms` to `to_ms`.
pub fn build(records: &[Record], from_ms: u64, to_ms: u64) -> Report {
    let mut report = Report { from_ms, to_ms, records: records.len(), ..Report::default() };
    for r in records {
        *report.by_source.entry(name(&r.src)).or_default() += 1;
    }

    let app: Vec<&Record> = records.iter().filter(|r| r.src == Source::App).collect();
    let focus = FocusPass::run(&app);
    let total_ms: u64 = focus.surface_ms.values().sum();
    report.surface_time = focus
        .surface_ms
        .iter()
        .map(|(surface, ms)| SurfaceTime {
            surface: *surface,
            seconds: *ms as f64 / 1000.0,
            share: if total_ms == 0 { 0.0 } else { *ms as f64 / total_ms as f64 },
        })
        .collect();
    report.surface_time.sort_by(|a, b| b.seconds.total_cmp(&a.seconds));
    report.chat_hidden_to_return_s = Dist::of(focus.chat_return);
    report.browser_hidden_to_return_s = Dist::of(focus.browser_return);
    let mut active_hours: BTreeSet<i64> = focus.switches_by_hour.keys().copied().collect();
    let mut actions: BTreeMap<String, (ActionRow, Vec<f64>)> = BTreeMap::new();
    let mut all_latency = Vec::new();
    let mut switch_latency = Vec::new();
    let mut latencies: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut open: [Vec<f64>; 9] = Default::default();
    let mut view_hidden: HashMap<Id, u64> = HashMap::new();
    let mut view_return = Vec::new();
    let mut sessions: BTreeSet<Id> = BTreeSet::new();
    let mut machines: BTreeSet<Id> = BTreeSet::new();
    let mut turn_seconds = Vec::new();
    let mut models: BTreeMap<(String, String), ModelRow> = BTreeMap::new();
    let mut connections: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut days: BTreeSet<String> = BTreeSet::new();

    for r in records {
        days.insert(day_of(r.at));
        match &r.ev {
            Event::Launch { prev, .. } => {
                report.launches += 1;
                if matches!(prev.as_str(), "crash" | "hang") {
                    report.crashes += 1;
                }
            }
            Event::Action { id, via, ms } => {
                active_hours.insert(hour_of(r.at));
                report.action_runs += 1;
                *report.entrypoints.entry(name(via)).or_default() += 1;
                let (row, samples) = actions
                    .entry(id.as_str().to_owned())
                    .or_insert_with(|| (ActionRow { id: id.as_str().to_owned(), ..ActionRow::default() }, Vec::new()));
                row.count += 1;
                match via {
                    Entry::Key => row.key += 1,
                    Entry::Pointer => row.pointer += 1,
                    Entry::Unattributed => {}
                    _ => row.automation += 1,
                }
                let ms = f64::from(*ms);
                samples.push(ms);
                all_latency.push(ms);
                let lower = id.as_str().to_ascii_lowercase();
                if SWITCH_WORDS.iter().any(|w| lower.contains(w)) {
                    switch_latency.push(ms);
                }
            }
            Event::Latency { what, ms } => latencies.entry(what.as_str().to_owned()).or_default().push(f64::from(*ms)),
            Event::Counts {
                windows,
                workspaces,
                panes,
                tabs,
                terminals,
                browsers,
                chats,
                max_panes_per_screen,
                sidebar_width,
                ..
            } => {
                for (slot, value) in open.iter_mut().zip([
                    windows,
                    workspaces,
                    panes,
                    tabs,
                    terminals,
                    browsers,
                    chats,
                    max_panes_per_screen,
                    sidebar_width,
                ]) {
                    slot.push(f64::from(*value));
                }
            }
            Event::View { session, on } => {
                sessions.insert(session.clone());
                if *on {
                    if let Some(hidden) = view_hidden.remove(session) {
                        view_return.push(r.at.saturating_sub(hidden) as f64 / 1000.0);
                    }
                } else {
                    view_hidden.insert(session.clone(), r.at);
                }
            }
            Event::Session { session, harness, machine } => {
                report.agents.sessions_started += 1;
                sessions.insert(session.clone());
                machines.insert(machine.clone());
                report.agents.by_harness.entry(harness.as_str().to_owned()).or_insert(0);
            }
            Event::Turn {
                session,
                harness,
                model,
                ms,
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_write_tokens,
                tool_calls,
                subagents,
            } => {
                sessions.insert(session.clone());
                report.agents.turns += 1;
                report.agents.tool_calls += u64::from(*tool_calls);
                report.agents.subagents += u64::from(*subagents);
                turn_seconds.push(*ms as f64 / 1000.0);
                *report.agents.by_harness.entry(harness.as_str().to_owned()).or_default() += 1;
                let model = model.as_ref().map_or("unknown", |m| m.as_str()).to_owned();
                let row = models.entry((harness.as_str().to_owned(), model.clone())).or_insert_with(|| ModelRow {
                    harness: harness.as_str().to_owned(),
                    model,
                    ..ModelRow::default()
                });
                row.turns += 1;
                row.input_tokens += input_tokens;
                row.output_tokens += output_tokens;
                row.cache_read_tokens += cache_read_tokens;
                row.cache_write_tokens += cache_write_tokens;
            }
            Event::Interaction { what, n } => {
                *report.interactions.entry(what.as_str().to_owned()).or_default() += u64::from(*n);
            }
            Event::Connections { what, n } => {
                connections.entry(what.as_str().to_owned()).or_default().push(f64::from(*n));
            }
            Event::Focus { .. } | Event::Active { .. } => {}
        }
    }

    report.active_hours = active_hours.len();
    report.days = days.len();
    let chats_per_hour: Vec<f64> =
        active_hours.iter().map(|h| focus.chats_by_hour.get(h).map_or(0.0, |s| s.len() as f64)).collect();
    report.chats_per_active_hour = Dist::of(chats_per_hour);
    report.switches_per_active_hour = Dist::of(
        active_hours.iter().map(|h| focus.switches_by_hour.get(h).copied().unwrap_or(0) as f64).collect(),
    );
    report.chat_view_hidden_to_return_s = Dist::of(view_return);
    report.unique = Unique {
        chat_tabs: focus.chat_tabs.len(),
        tabs: focus.tabs.len(),
        agent_sessions: sessions.len(),
        machines: machines.len(),
    };
    let mut rows: Vec<ActionRow> = actions
        .into_values()
        .map(|(mut row, samples)| {
            let dist = Dist::of(samples);
            row.p50_ms = dist.p50;
            row.p95_ms = dist.p95;
            row
        })
        .collect();
    rows.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.id.cmp(&b.id)));
    rows.truncate(TOP_ACTIONS);
    report.actions = rows;
    report.action_latency_ms = Dist::of(all_latency);
    report.switch_latency_ms = Dist::of(switch_latency);
    report.latencies_ms = latencies.into_iter().map(|(k, v)| (k, Dist::of(v))).collect();
    let [windows, workspaces, panes, tabs, terminals, browsers, chats, max_panes_per_screen, sidebar_width] =
        open.map(Dist::of);
    report.open =
        Open { windows, workspaces, panes, tabs, terminals, browsers, chats, max_panes_per_screen, sidebar_width };
    report.agents.turn_seconds = Dist::of(turn_seconds);
    let mut by_model: Vec<ModelRow> = models.into_values().collect();
    by_model.sort_by(|a, b| b.turns.cmp(&a.turns));
    report.agents.by_model = by_model;
    report.connections = connections.into_iter().map(|(k, v)| (k, Dist::of(v))).collect();
    report
}

/// `ms` (Unix milliseconds) as local `YYYY-MM-DD HH:MM`.
pub fn local_time(ms: u64) -> String {
    let secs = i64::try_from(ms / 1000).unwrap_or(0);
    Local.timestamp_opt(secs, 0).single().map(|t| t.format("%Y-%m-%d %H:%M").to_string()).unwrap_or_default()
}

fn duration(seconds: f64) -> String {
    if seconds < 60.0 {
        format!("{seconds:.0}s")
    } else if seconds < 3600.0 {
        format!("{:.1}m", seconds / 60.0)
    } else if seconds < 86_400.0 {
        format!("{:.1}h", seconds / 3600.0)
    } else {
        format!("{:.1}d", seconds / 86_400.0)
    }
}

fn dist_seconds(d: &Dist) -> String {
    if d.n == 0 {
        return "no samples".to_owned();
    }
    format!("p50 {}  p95 {}  max {}  (n={})", duration(d.p50), duration(d.p95), duration(d.max), d.n)
}

fn dist_ms(d: &Dist) -> String {
    if d.n == 0 {
        return "no samples".to_owned();
    }
    format!("p50 {:.1}ms  p95 {:.1}ms  max {:.1}ms  (n={})", d.p50, d.p95, d.max, d.n)
}

fn dist_count(d: &Dist) -> String {
    if d.n == 0 {
        return "no samples".to_owned();
    }
    format!("p50 {:.0}  p95 {:.0}  max {:.0}", d.p50, d.p95, d.max)
}

fn tokens(n: u64) -> String {
    match n {
        0..1_000 => n.to_string(),
        1_000..1_000_000 => format!("{:.1}k", n as f64 / 1e3),
        _ => format!("{:.1}M", n as f64 / 1e6),
    }
}

impl Report {
    /// The report as text for a terminal.
    pub fn render(&self) -> String {
        let mut out = String::new();
        let span = local_time;
        let _ = writeln!(
            out,
            "Usage {} to {}: {} records over {} days, {} active hours, {} launches ({} after a crash or hang)",
            span(self.from_ms),
            span(self.to_ms),
            self.records,
            self.days,
            self.active_hours,
            self.launches,
            self.crashes
        );
        if self.records == 0 {
            out.push_str("Nothing recorded in this window.\n");
            return out;
        }

        out.push_str("\nWhere the keyboard was\n");
        for row in &self.surface_time {
            let _ = writeln!(out, "  {:<14} {:>8}  {:>5.1}%", name(&row.surface), duration(row.seconds), row.share * 100.0);
        }

        out.push_str("\nComing back\n");
        let _ = writeln!(out, "  chat hidden-to-return      {}", dist_seconds(&self.chat_hidden_to_return_s));
        let _ = writeln!(out, "  chat hidden (all panes)    {}", dist_seconds(&self.chat_view_hidden_to_return_s));
        let _ = writeln!(out, "  browser hidden-to-return   {}", dist_seconds(&self.browser_hidden_to_return_s));
        let _ = writeln!(out, "  chats touched per hour     {}", dist_count(&self.chats_per_active_hour));
        let _ = writeln!(out, "  focus changes per hour     {}", dist_count(&self.switches_per_active_hour));
        let _ = writeln!(
            out,
            "  unique                     {} chat tabs, {} tabs, {} agent sessions, {} machines",
            self.unique.chat_tabs, self.unique.tabs, self.unique.agent_sessions, self.unique.machines
        );

        out.push_str("\nLatency\n");
        let _ = writeln!(out, "  switch actions             {}", dist_ms(&self.switch_latency_ms));
        let _ = writeln!(out, "  all actions                {}", dist_ms(&self.action_latency_ms));
        for (what, dist) in &self.latencies_ms {
            let _ = writeln!(out, "  {what:<26} {}", dist_ms(dist));
        }

        if !self.actions.is_empty() {
            let _ = writeln!(out, "\nMost used actions ({} runs)", self.action_runs);
            let _ = writeln!(out, "  {:<40} {:>6} {:>6} {:>6} {:>6} {:>8} {:>8}", "id", "runs", "key", "click", "auto", "p50", "p95");
            for row in &self.actions {
                let _ = writeln!(
                    out,
                    "  {:<40} {:>6} {:>6} {:>6} {:>6} {:>6.1}ms {:>6.1}ms",
                    row.id, row.count, row.key, row.pointer, row.automation, row.p50_ms, row.p95_ms
                );
            }
        }

        out.push_str("\nOpen at once\n");
        for (label, d) in [
            ("workspaces", &self.open.workspaces),
            ("panes", &self.open.panes),
            ("tabs", &self.open.tabs),
            ("terminals", &self.open.terminals),
            ("browsers", &self.open.browsers),
            ("agent chats", &self.open.chats),
            ("panes in one screen", &self.open.max_panes_per_screen),
            ("windows", &self.open.windows),
            ("sidebar width (pt)", &self.open.sidebar_width),
        ] {
            let _ = writeln!(out, "  {label:<26} {}", dist_count(d));
        }

        let agents = &self.agents;
        if agents.turns > 0 || agents.sessions_started > 0 {
            out.push_str("\nAgents\n");
            let _ = writeln!(
                out,
                "  {} sessions started, {} turns, {} tool calls, {} subagents",
                agents.sessions_started, agents.turns, agents.tool_calls, agents.subagents
            );
            let _ = writeln!(out, "  turn length                {}", dist_seconds(&agents.turn_seconds));
            for row in &agents.by_model {
                let _ = writeln!(
                    out,
                    "  {:<10} {:<28} {:>5} turns  in {:>7}  out {:>7}  cache r {:>7} w {:>7}",
                    row.harness,
                    row.model,
                    row.turns,
                    tokens(row.input_tokens),
                    tokens(row.output_tokens),
                    tokens(row.cache_read_tokens),
                    tokens(row.cache_write_tokens)
                );
            }
        }

        if !self.interactions.is_empty() {
            out.push_str("\nIn pages\n");
            for (what, n) in &self.interactions {
                let _ = writeln!(out, "  {what:<26} {n}");
            }
        }
        if !self.connections.is_empty() {
            out.push_str("\nConnections\n");
            for (what, d) in &self.connections {
                let _ = writeln!(out, "  {what:<26} {}", dist_count(d));
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::Token;

    fn rec(at: u64, ev: Event) -> Record {
        Record { at, src: Source::App, ev }
    }

    fn focus(at: u64, surface: Surface, tab: &str) -> Record {
        rec(at, Event::Focus { surface, tab: Some(Id::new(tab)) })
    }

    #[test]
    fn percentiles_use_nearest_rank() {
        let d = Dist::of((1..=100).map(f64::from).collect());
        assert_eq!((d.n, d.p50, d.p95, d.max), (100, 50.0, 95.0, 100.0));
        assert_eq!(Dist::of(vec![]).n, 0);
        assert_eq!(Dist::of(vec![7.0]).p95, 7.0);
    }

    #[test]
    fn hidden_to_return_and_surface_time() {
        let records = vec![
            focus(0, Surface::Chat, "a"),
            focus(10_000, Surface::Chat, "b"),
            focus(70_000, Surface::Terminal, "t"),
            focus(100_000, Surface::Chat, "a"),
            rec(110_000, Event::Active { on: false }),
        ];
        let report = build(&records, 0, 200_000);
        assert_eq!(report.chat_hidden_to_return_s.n, 1);
        assert_eq!(report.chat_hidden_to_return_s.p50, 90.0);
        let chat = report.surface_time.iter().find(|s| s.surface == Surface::Chat).expect("chat");
        assert_eq!(chat.seconds, 80.0);
        let terminal = report.surface_time.iter().find(|s| s.surface == Surface::Terminal).expect("terminal");
        assert_eq!(terminal.seconds, 30.0);
        assert_eq!(report.unique.chat_tabs, 2);
    }

    #[test]
    fn a_long_idle_span_is_capped() {
        let records = vec![focus(0, Surface::Terminal, "t"), focus(10 * IDLE_CAP_MS, Surface::Chat, "a")];
        let report = build(&records, 0, 10 * IDLE_CAP_MS);
        assert_eq!(report.surface_time[0].seconds, IDLE_CAP_MS as f64 / 1000.0);
    }

    #[test]
    fn a_launch_forgets_what_was_hidden() {
        let records = vec![
            focus(0, Surface::Chat, "a"),
            focus(1_000, Surface::Chat, "b"),
            rec(2_000, Event::Launch { channel: Token::new("dev"), build: Token::new("1"), prev: Token::new("crash") }),
            focus(3_000, Surface::Chat, "a"),
        ];
        let report = build(&records, 0, 3_000);
        assert_eq!(report.chat_hidden_to_return_s.n, 0);
        assert_eq!((report.launches, report.crashes), (1, 1));
    }

    #[test]
    fn actions_are_ranked_with_their_entrypoints_and_switch_latency() {
        let action = |at, id: &str, via, ms| rec(at, Event::Action { id: Token::new(id), via, ms });
        let records = vec![
            action(1, "workspace.select-next", Entry::Key, 2.0),
            action(2, "workspace.select-next", Entry::Pointer, 4.0),
            action(3, "tab.new", Entry::Cli, 9.0),
        ];
        let report = build(&records, 0, 10);
        assert_eq!(report.actions[0].id, "workspace.select-next");
        assert_eq!((report.actions[0].key, report.actions[0].pointer), (1, 1));
        assert_eq!(report.actions[1].automation, 1);
        assert_eq!(report.switch_latency_ms.n, 2);
        assert_eq!(report.action_latency_ms.max, 9.0);
    }

    #[test]
    fn agent_turns_sum_tokens_per_model() {
        let turn = |model: &str, input| Record {
            at: 5,
            src: Source::Acpmux,
            ev: Event::Turn {
                session: Id::new("s"),
                harness: Token::new("claude"),
                model: Some(Token::new(model)),
                ms: 4_000,
                input_tokens: input,
                output_tokens: 10,
                cache_read_tokens: 0,
                cache_write_tokens: 0,
                tool_calls: 3,
                subagents: 1,
            },
        };
        let report = build(&[turn("opus", 100), turn("opus", 50), turn("haiku", 7)], 0, 10);
        assert_eq!(report.agents.turns, 3);
        assert_eq!(report.agents.by_model[0].model, "opus");
        assert_eq!(report.agents.by_model[0].input_tokens, 150);
        assert_eq!(report.agents.tool_calls, 9);
        assert!(report.render().contains("opus"));
    }

    #[test]
    fn view_hidden_to_return() {
        let view = |at, on| Record { at, src: Source::Acpmux, ev: Event::View { session: Id::new("s"), on } };
        let report = build(&[view(0, true), view(1_000, false), view(61_000, true)], 0, 61_000);
        assert_eq!(report.chat_view_hidden_to_return_s.p50, 60.0);
    }
}
