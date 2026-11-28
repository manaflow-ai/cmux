//! The bytes-path harness and its hill-climb.
//!
//!   cmux-bytes bench --folder NAME=PATH ... [--profile all|NAME,...] [--strategy today,new]
//!                    [--scenario cold,edit] [--runs N] [--cap-bytes N] [--param K=V ...]
//!                    [--cores N] [--json OUT] [--table OUT.md]
//!   cmux-bytes climb --folder NAME=PATH ... --state STATE --log FINDINGS.md [--steps N] [bench flags]
//!       One hill-climb step per `--steps`: change one param of the best set in STATE, measure both
//!       on the same harness (same corpus, profiles, jitter), keep the change only when it beats the
//!       best at p50 and p95 and grows no payload; every step is a line in FINDINGS.md.
//!   cmux-bytes prefetch --folder NAME=PATH ... [--profile ...] [--runs N] [--param K=V ...]
//!                       [--json OUT] [--table OUT.md]
//!       What a machine holds before a chat reads: today (the whole folder in fill order) against
//!       the ranker (likelihood per byte over idle bandwidth, `prefetch_budget` held), as the
//!       first-turn hit rate and the bytes held but never read, over `--runs` simulated chats.
//!   cmux-bytes bench-levels PATH    zstd throughput per level on PATH's files
//!   cmux-bytes install-timer --folders-file FILE [--every 2h]
//!       Copies this binary to ~/.local/bin/cmux-bytes and writes the systemd user units
//!       cmux-bytes-climb.{service,timer}: two climb steps a run, at idle priority, publishing
//!       ~/.cache/cmux-bytes/latest.json (NOW's bytes section), prefetch.json (first-turn hit
//!       rate, held never read) and the findings log beside it.
//!
//! `--folders-file FILE` gives the folders as `NAME=PATH` lines (`#` comments), like `--folder`.

use std::fmt::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use cmux_bytes::harness::{self, Profile, Scenario, Strategy};
use cmux_bytes::params::Params;
use cmux_bytes::policy::Link;

/// A command's failure: what it could not do, printed before exit status 2.
type Res<T> = Result<T, String>;

/// Name what failed, for `?`.
trait Ctx<T> {
    fn ctx(self, what: &str) -> Res<T>;
}

impl<T, E: std::fmt::Display> Ctx<T> for Result<T, E> {
    fn ctx(self, what: &str) -> Res<T> {
        self.map_err(|e| format!("{what}: {e}"))
    }
}

impl<T> Ctx<T> for Option<T> {
    fn ctx(self, what: &str) -> Res<T> {
        self.ok_or_else(|| what.to_string())
    }
}

/// Exit 0 when the command passed, 1 when a payload grew or failed to decode, 2 on a usage or I/O error.
fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = args.get(1..).unwrap_or_default();
    let got = match args.first().map(String::as_str) {
        Some("bench") => bench(rest),
        Some("climb") => climb(rest),
        Some("prefetch") => prefetch(rest),
        Some("bench-levels") => levels(rest),
        Some("install-timer") => install_timer(rest),
        _ => Err(
            "usage: cmux-bytes bench|climb|prefetch|bench-levels|install-timer ... (see the file header)"
                .into(),
        ),
    };
    match got {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(1),
        Err(why) => {
            eprintln!("cmux-bytes: {why}");
            ExitCode::from(2)
        }
    }
}

struct Opts {
    folders: Vec<(String, PathBuf)>,
    profiles: Vec<Profile>,
    strategies: Vec<Strategy>,
    scenarios: Vec<Scenario>,
    runs: u64,
    cap: u64,
    params: Params,
    cores: usize,
    json: Option<PathBuf>,
    table: Option<PathBuf>,
    state: Option<PathBuf>,
    log: Option<PathBuf>,
    steps: u64,
}

fn parse(args: &[String]) -> Res<Opts> {
    let mut o = Opts {
        folders: Vec::new(),
        profiles: harness::PROFILES.to_vec(),
        strategies: vec![Strategy::Today, Strategy::New],
        scenarios: vec![Scenario::Cold, Scenario::Edit],
        runs: 9,
        cap: 256 << 20,
        params: Params::default(),
        cores: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8),
        json: None,
        table: None,
        state: None,
        log: None,
        steps: 1,
    };
    let mut i = 0;
    while let Some(arg) = args.get(i) {
        let v = args.get(i + 1).cloned().unwrap_or_default();
        match arg.as_str() {
            "--folder" => {
                let (n, p) = v.split_once('=').ctx("--folder NAME=PATH")?;
                o.folders.push((n.into(), p.into()));
            }
            "--folders-file" => {
                let text = std::fs::read_to_string(&v).ctx(&format!("--folders-file {v}"))?;
                for line in
                    text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#'))
                {
                    let (n, p) = line.split_once('=').ctx("NAME=PATH")?;
                    o.folders.push((n.trim().into(), p.trim().into()));
                }
            }
            "--every" => {}
            "--profile" if v != "all" => {
                o.profiles =
                    v.split(',').map(|n| harness::profile(n).ctx("profile")).collect::<Res<_>>()?;
            }
            "--profile" => {}
            "--strategy" => {
                o.strategies = v
                    .split(',')
                    .map(|s| if s == "today" { Strategy::Today } else { Strategy::New })
                    .collect();
            }
            "--scenario" => {
                o.scenarios = v
                    .split(',')
                    .map(|s| if s == "edit" { Scenario::Edit } else { Scenario::Cold })
                    .collect();
            }
            "--runs" => o.runs = v.parse().ctx("--runs N")?,
            "--cap-bytes" => o.cap = v.parse().ctx("--cap-bytes N")?,
            "--cores" => o.cores = v.parse().ctx("--cores N")?,
            "--json" => o.json = Some(v.into()),
            "--table" => o.table = Some(v.into()),
            "--state" => o.state = Some(v.into()),
            "--log" => o.log = Some(v.into()),
            "--steps" => o.steps = v.parse().ctx("--steps N")?,
            "--param" => {
                let (k, val) = v.split_once('=').ctx("--param K=V")?;
                o.params.set(k, val).ctx("--param")?;
            }
            other => return Err(format!("unknown flag {other}")),
        }
        i += 2;
    }
    // A folder that is not there walks as empty, and an empty corpus measures every candidate
    // as equal to the best: the climb then "drops" every step and NOW reads green on no data
    // (11-26 01:25Z to 11-27 06:22Z, steps 13 to 44, after the corpus was removed). An empty
    // folder is a real case; a missing one is an error.
    if let Some((n, p)) = o.folders.iter().find(|(_, p)| !p.is_dir()) {
        return Err(format!("folder {n}={} is not a directory", p.display()));
    }
    Ok(o)
}

/// One case's result over the jittered runs.
#[derive(Clone, Debug)]
struct Row {
    folder: String,
    scenario: Scenario,
    profile: &'static str,
    strategy: Strategy,
    files: u64,
    raw: u64,
    wire: u64,
    ttft: (f64, f64),
    synced: (f64, f64),
    cpu: (f64, f64),
    grown: u64,
    worst_growth: i64,
    fails: u64,
    reasons: Vec<(&'static str, u64)>,
}

impl Row {
    fn key(&self) -> (String, &'static str, &'static str) {
        (self.folder.clone(), self.scenario.name(), self.profile)
    }
}

fn measure(o: &Opts, params: &Params, quiet: bool) -> Vec<Row> {
    let mut rows = Vec::new();
    for (name, root) in &o.folders {
        let (entries, _dirs, bytes) = harness::walk(root, o.cap);
        if !quiet {
            eprintln!("{name}: {} files, {:.1} MB", entries.len(), bytes as f64 / 1e6);
        }
        for &sc in &o.scenarios {
            // Today's codec work does not depend on the link: encode it once per scenario.
            let today = o
                .strategies
                .contains(&Strategy::Today)
                .then(|| harness::encode_today(root, &entries, sc, 40));
            // The new path's work depends on the link only through the zstd level.
            let mut by_level: Vec<(i32, harness::Encoded)> = Vec::new();
            for p in &o.profiles {
                for &st in &o.strategies {
                    let enc = match st {
                        Strategy::Today => match &today {
                            Some(t) => t,
                            None => continue,
                        },
                        Strategy::New => {
                            let link =
                                Link { bytes_per_sec: p.bandwidth, rtt: p.rtt, cores: o.cores };
                            let level = cmux_bytes::policy::level_for(&link, params);
                            if !by_level.iter().any(|(l, _)| *l == level) {
                                by_level.push((
                                    level,
                                    harness::encode_new(root, &entries, sc, params, &link),
                                ));
                            }
                            match by_level.iter().find(|(l, _)| *l == level) {
                                Some((_, e)) => e,
                                None => continue,
                            }
                        }
                    };
                    let rs: Vec<_> = (0..o.runs)
                        .map(|r| {
                            harness::simulate(enc, st, p, params, o.cores, harness::jitter(7, r))
                        })
                        .collect();
                    let ft: Vec<f64> = rs.iter().map(|r| r.first_turn_s).collect();
                    let sy: Vec<f64> = rs.iter().map(|r| r.synced_s).collect();
                    let Some(first_run) = rs.first() else { continue };
                    let mut reasons: Vec<_> = enc.reasons.iter().map(|(k, v)| (*k, *v)).collect();
                    reasons.sort();
                    let row = Row {
                        folder: name.clone(),
                        scenario: sc,
                        profile: p.name,
                        strategy: st,
                        files: enc.files,
                        raw: enc.raw_bytes,
                        wire: first_run.wire_bytes,
                        ttft: (harness::pct(&ft, 50.0), harness::pct(&ft, 95.0)),
                        synced: (harness::pct(&sy, 50.0), harness::pct(&sy, 95.0)),
                        cpu: (first_run.cpu_send_s, first_run.cpu_recv_s),
                        grown: enc.grown_bytes,
                        worst_growth: enc.worst_growth,
                        fails: enc.verify_failures,
                        reasons,
                    };
                    if !quiet {
                        println!(
                            "{:12} {:4} {:15} {:5} raw {:9.2}MB wire {:9.2}MB ({:>6}) ttft p50 {:8.3}s p95 {:8.3}s synced p50 {:8.3}s p95 {:8.3}s cpu {:.2}/{:.2}s",
                            row.folder,
                            sc.name(),
                            p.name,
                            st.name(),
                            row.raw as f64 / 1e6,
                            row.wire as f64 / 1e6,
                            pct_of(row.wire, row.raw),
                            row.ttft.0,
                            row.ttft.1,
                            row.synced.0,
                            row.synced.1,
                            row.cpu.0,
                            row.cpu.1
                        );
                    }
                    rows.push(row);
                }
            }
        }
    }
    rows
}

/// Wire as a percentage of raw, or "-" when there is no raw content (an empty folder).
fn pct_of(a: u64, b: u64) -> String {
    if b == 0 { "-".into() } else { format!("{:.1}%", 100.0 * a as f64 / b as f64) }
}

/// The `now-bytes/v1` document: NOW's bytes-path section reads it (leo-workspace
/// tools/now_bytes_source.py). `climb` is the hill-climb's step, kept count and last findings line.
fn json_of(o: &Opts, params: &Params, rows: &[Row], climb: Option<(u64, u64, &str)>) -> String {
    let mut out = String::new();
    let pairs: Vec<String> =
        params.pairs().iter().map(|(k, v)| format!("\"{k}\":\"{v}\"")).collect();
    let host = std::fs::read_to_string("/etc/hostname").unwrap_or_default();
    let climb = climb.map_or("null".to_string(), |(step, kept, last)| {
        format!(
            "{{\"step\":{step},\"kept\":{kept},\"last\":\"{}\"}}",
            last.trim().replace('\\', "\\\\").replace('"', "\\\"")
        )
    });
    let _ = writeln!(
        out,
        "{{\"schema\":\"now-bytes/v1\",\"at\":\"{}\",\"host\":\"{}\",\"params\":{{{}}},\"cores\":{},\"runs\":{},\"climb\":{climb},\"rows\":[",
        now_utc(),
        host.trim(),
        pairs.join(","),
        o.cores,
        o.runs
    );
    let rows: Vec<String> = rows
        .iter()
        .map(|r| {
            let reasons: Vec<String> = r.reasons.iter().map(|(k, v)| format!("\"{k}\":{v}")).collect();
            format!(
                "{{\"folder\":\"{}\",\"scenario\":\"{}\",\"profile\":\"{}\",\"strategy\":\"{}\",\"files\":{},\"raw_bytes\":{},\"wire_bytes\":{},\"first_turn_p50\":{:.4},\"first_turn_p95\":{:.4},\"synced_p50\":{:.4},\"synced_p95\":{:.4},\"cpu_send_s\":{:.4},\"cpu_recv_s\":{:.4},\"grown_bytes\":{},\"worst_growth\":{},\"verify_failures\":{},\"reasons\":{{{}}}}}",
                r.folder, r.scenario.name(), r.profile, r.strategy.name(), r.files, r.raw, r.wire, r.ttft.0, r.ttft.1,
                r.synced.0, r.synced.1, r.cpu.0, r.cpu.1, r.grown, r.worst_growth, r.fails, reasons.join(",")
            )
        })
        .collect();
    out.push_str(&rows.join(",\n"));
    out.push_str("\n]}\n");
    out
}

/// The before/after status table: one line per folder kind, scenario and network profile.
fn table_of(rows: &[Row]) -> String {
    let mut out = String::from(
        "| folder | scenario | profile | wire today | wire new | first turn today p50/p95 | first turn new p50/p95 | synced today p50/p95 | synced new p50/p95 | CPU send/recv new |\n|---|---|---|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    let secs = |(a, b): (f64, f64)| format!("{} / {}", short(a), short(b));
    for new in rows.iter().filter(|r| r.strategy == Strategy::New) {
        let today = rows.iter().find(|r| r.strategy == Strategy::Today && r.key() == new.key());
        let (tw, tt, ts) = today.map_or(("-".into(), "-".into(), "-".into()), |t| {
            (format!("{} ({})", mb(t.wire), pct_of(t.wire, t.raw)), secs(t.ttft), secs(t.synced))
        });
        let _ = writeln!(
            out,
            "| {} | {} | {} | {tw} | {} ({}) | {tt} | {} | {ts} | {} | {:.2} / {:.2} s |",
            new.folder,
            new.scenario.name(),
            new.profile,
            mb(new.wire),
            pct_of(new.wire, new.raw),
            secs(new.ttft),
            secs(new.synced),
            new.cpu.0,
            new.cpu.1
        );
    }
    out
}

fn mb(b: u64) -> String {
    if b >= 10_000_000 {
        format!("{:.0} MB", b as f64 / 1e6)
    } else {
        format!("{:.2} MB", b as f64 / 1e6)
    }
}

fn short(s: f64) -> String {
    if s >= 10.0 {
        format!("{s:.0}s")
    } else if s >= 1.0 {
        format!("{s:.1}s")
    } else {
        format!("{:.0}ms", s * 1e3)
    }
}

fn bad(rows: &[Row]) -> (u64, u64) {
    let new = rows.iter().filter(|r| r.strategy == Strategy::New);
    (new.clone().map(|r| r.grown).sum(), rows.iter().map(|r| r.fails).sum())
}

fn bench(args: &[String]) -> Res<bool> {
    let o = parse(args)?;
    let rows = measure(&o, &o.params, false);
    if let Some(p) = &o.json {
        std::fs::write(p, json_of(&o, &o.params, &rows, None)).ctx("write --json")?;
    }
    if let Some(p) = &o.table {
        std::fs::write(p, table_of(&rows)).ctx("write --table")?;
    }
    let (grew, fails) = bad(&rows);
    if fails > 0 || grew > 0 {
        eprintln!("FAIL: {fails} verify failures, {grew} grown bytes on the new path");
        return Ok(false);
    }
    Ok(true)
}

fn prefetch(args: &[String]) -> Res<bool> {
    let o = parse(args)?;
    let mut table = String::from(
        "| folder | profile | first-turn hit today | first-turn hit new | held never read today | held never read new |\n|---|---|---|---|---|---|\n",
    );
    let mut rows = Vec::new();
    for (name, root) in &o.folders {
        let (entries, _dirs, _bytes) = harness::walk(root, o.cap);
        for p in &o.profiles {
            let r = harness::prefetch_eval(&entries, &o.params, p, o.runs);
            let _ = writeln!(
                table,
                "| {name} | {} | {:.0}% | {:.0}% | {} | {} |",
                p.name,
                r.today.first_turn_hit_rate * 100.0,
                r.new.first_turn_hit_rate * 100.0,
                mb(r.today.held_never_read_bytes),
                mb(r.new.held_never_read_bytes),
            );
            let side = |h: &cmux_bytes::prefetch::HitStats| {
                format!(
                    "{{\"first_turn_hit_rate\":{:.4},\"first_turn_hit_bytes_rate\":{:.4},\"held_never_read_bytes\":{},\"held_bytes\":{},\"first_turn_reads\":{}}}",
                    h.first_turn_hit_rate,
                    h.first_turn_hit_bytes_rate,
                    h.held_never_read_bytes,
                    h.held_bytes,
                    h.first_turn_reads
                )
            };
            rows.push(format!(
                "{{\"folder\":{name:?},\"profile\":{:?},\"today\":{},\"new\":{}}}",
                p.name,
                side(&r.today),
                side(&r.new)
            ));
        }
    }
    print!("{table}");
    if let Some(p) = &o.json {
        let params: Vec<String> =
            o.params.pairs().iter().map(|(k, v)| format!("{k:?}:{v:?}")).collect();
        let doc = format!(
            "{{\"schema\":\"cmux-bytes-prefetch/v1\",\"at\":{:?},\"runs\":{},\"params\":{{{}}},\"rows\":[{}]}}\n",
            now_utc(),
            o.runs,
            params.join(","),
            rows.join(",")
        );
        std::fs::write(p, doc).ctx("write --json")?;
    }
    if let Some(p) = &o.table {
        std::fs::write(p, table).ctx("write --table")?;
    }
    Ok(true)
}

/// The next candidates around `p`: each changes one param one step.
fn neighbors(p: &Params) -> Vec<(&'static str, String)> {
    let f = |x: f64| format!("{x}");
    vec![
        ("cdc_avg", (p.cdc_avg * 2).min(1 << 20).to_string()),
        ("cdc_avg", (p.cdc_avg / 2).max(4096).to_string()),
        ("entropy_store_bits", f(((p.entropy_store_bits + 0.1) * 10.0).round() / 10.0)),
        ("entropy_store_bits", f(((p.entropy_store_bits - 0.1) * 10.0).round() / 10.0)),
        ("keep_ratio", f(((p.keep_ratio + 0.01) * 100.0).round().min(100.0) / 100.0)),
        ("keep_ratio", f(((p.keep_ratio - 0.01) * 100.0).round() / 100.0)),
        ("cpu_headroom", f((p.cpu_headroom * 1.5 * 100.0).round() / 100.0)),
        ("cpu_headroom", f((p.cpu_headroom / 1.5 * 100.0).round() / 100.0)),
        ("streams", (p.streams + 2).min(64).to_string()),
        ("streams", p.streams.saturating_sub(2).max(1).to_string()),
        ("max_streams", (p.max_streams + 4).min(64).to_string()),
        ("max_streams", p.max_streams.saturating_sub(4).max(p.streams).to_string()),
        ("dictionaries", (!p.dictionaries).to_string()),
        ("dict_max_chunk", (p.dict_max_chunk * 2).min(256 << 10).to_string()),
        ("dict_max_chunk", (p.dict_max_chunk / 2).max(1024).to_string()),
        ("dict_bytes", (p.dict_bytes * 2).min(1 << 20).to_string()),
        ("dict_bytes", (p.dict_bytes / 2).max(8192).to_string()),
        ("dict_max_bandwidth", f(p.dict_max_bandwidth * 2.0)),
        ("dict_max_bandwidth", f(p.dict_max_bandwidth / 2.0)),
        ("max_level", (p.max_level - 3).max(p.min_level).to_string()),
        ("max_level", (p.max_level + 3).min(19).to_string()),
        ("min_level", (p.min_level + 1).min(p.max_level).to_string()),
        ("entropy_sample", (p.entropy_sample * 2).min(64 << 10).to_string()),
        ("entropy_sample", (p.entropy_sample / 2).max(1024).to_string()),
    ]
}

fn geomean(v: impl Iterator<Item = f64>) -> f64 {
    let (s, n) = v.fold((0.0, 0usize), |(s, n), x| (s + x.max(1e-9).ln(), n + 1));
    if n == 0 { 1.0 } else { (s / n as f64).exp() }
}

fn climb(args: &[String]) -> Res<bool> {
    let mut o = parse(args)?;
    o.strategies = vec![Strategy::New];
    let state = o.state.clone().ctx("--state STATE")?;
    let log = o.log.clone().ctx("--log FINDINGS.md")?;
    // STATE: `key=value` lines of the best params, plus `step=N`.
    let text = std::fs::read_to_string(&state).unwrap_or_default();
    let mut best = o.params.clone();
    let mut step = 0u64;
    for line in text.lines() {
        if let Some((k, v)) = line.split_once('=') {
            if k == "step" {
                step = v.trim().parse().unwrap_or(0);
            } else if k != "kept" {
                let _ = best.set(k.trim(), v.trim());
            }
        }
    }
    if !std::path::Path::new(&log).exists() {
        let _ = std::fs::write(
            &log,
            "# cmux-bytes hill-climb findings\n\nOne line per step: the change tried, the geomean ratios (candidate / best) across every folder, scenario and profile of time to fully synced at p50 and p95 and time to the first turn at p50, wire bytes, and whether it was kept. Kept: synced p50 < 0.99, synced p95 < 1.0, first turn p50 <= 1.005, no payload grown, every chunk round-tripped.\n\n| when | step | change | synced p50 | synced p95 | first turn p50 | wire | verdict |\n|---|---:|---|---:|---:|---:|---:|---|\n",
        );
    }
    let mut kept: u64 =
        text.lines().find_map(|l| l.strip_prefix("kept=")?.trim().parse().ok()).unwrap_or(0);
    let mut last = String::new();
    let mut base = measure(&o, &best, true);
    for _ in 0..o.steps {
        let ns = neighbors(&best);
        let Some((key, value)) =
            (step as usize).checked_rem(ns.len()).and_then(|k| ns.get(k)).cloned()
        else {
            break;
        };
        step += 1;
        let mut cand = best.clone();
        if cand.set(key, &value).is_err() || cand == best {
            continue;
        }
        let t = Instant::now();
        let rows = measure(&o, &cand, true);
        let ratio = |f: &dyn Fn(&Row) -> f64| {
            geomean(rows.iter().filter_map(|r| {
                let b = base.iter().find(|b| b.key() == r.key())?;
                Some((f(r) + 1e-3) / (f(b) + 1e-3))
            }))
        };
        let s50 = ratio(&|r| r.synced.0);
        let s95 = ratio(&|r| r.synced.1);
        let f50 = ratio(&|r| r.ttft.0);
        let wire = ratio(&|r| r.wire as f64);
        let (grew, fails) = bad(&rows);
        let keep = s50 < 0.99 && s95 < 1.0 && f50 <= 1.005 && grew == 0 && fails == 0;
        let verdict = if grew > 0 || fails > 0 {
            format!("refused: {grew} grown bytes, {fails} round-trip failures")
        } else if keep {
            "kept".into()
        } else {
            "dropped".into()
        };
        let line = format!(
            "| {} | {step} | {key} {} -> {value} | {s50:.4} | {s95:.4} | {f50:.4} | {wire:.4} | {verdict} ({:.0}s) |\n",
            now_utc(),
            best.pairs()
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| v.clone())
                .unwrap_or_default(),
            t.elapsed().as_secs_f64()
        );
        print!("{line}");
        last.clone_from(&line);
        let mut f = std::fs::OpenOptions::new().append(true).open(&log).ctx("open --log")?;
        std::io::Write::write_all(&mut f, line.as_bytes()).ctx("append --log")?;
        if keep {
            best = cand;
            base = rows;
            kept += 1;
        }
        let mut s = String::new();
        for (k, v) in best.pairs() {
            let _ = writeln!(s, "{k}={v}");
        }
        let _ = writeln!(s, "step={step}");
        let _ = writeln!(s, "kept={kept}");
        std::fs::write(&state, s).ctx("write --state")?;
    }
    if let Some(p) = o.json.clone() {
        // The published table carries today's rows beside the best's, so NOW shows before and after.
        let mut all = base;
        let today = Opts { strategies: vec![Strategy::Today], ..o };
        all.extend(measure(&today, &best, true));
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = p.with_extension("json.tmp");
        std::fs::write(&tmp, json_of(&today, &best, &all, Some((step, kept, &last))))
            .ctx("write --json")?;
        std::fs::rename(&tmp, &p).ctx("rename --json")?;
        if let Some(t) = &today.table {
            std::fs::write(t, table_of(&all)).ctx("write --table")?;
        }
    }
    Ok(true)
}

fn now_utc() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let (d, s) = (secs / 86400, secs % 86400);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = d as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}Z", s / 3600, s % 3600 / 60)
}

fn levels(args: &[String]) -> Res<bool> {
    let root = PathBuf::from(args.first().ctx("bench-levels FOLDER")?);
    let (entries, _, _) = harness::walk(&root, 64 << 20);
    let mut data = Vec::new();
    for e in &entries {
        if let Ok(b) = std::fs::read(root.join(&e.path)) {
            data.extend(b);
        }
    }
    for level in [1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 15, 17, 19] {
        let t = Instant::now();
        let c = zstd::bulk::compress(&data, level).ctx("zstd")?;
        let s = t.elapsed().as_secs_f64();
        println!(
            "level {level:2}: {:7.1} MB/s ratio {:.3}",
            data.len() as f64 / s / 1e6,
            c.len() as f64 / data.len() as f64
        );
    }
    Ok(true)
}

fn install_timer(args: &[String]) -> Res<bool> {
    let mut folders = None;
    let mut every = "2h".to_string();
    let mut i = 0;
    while let Some(arg) = args.get(i) {
        let v = args.get(i + 1).cloned().unwrap_or_default();
        match arg.as_str() {
            "--folders-file" => folders = Some(v),
            "--every" => every = v,
            other => return Err(format!("unknown flag {other}")),
        }
        i += 2;
    }
    let folders = std::fs::canonicalize(folders.ctx("--folders-file FILE")?).ctx("folders file")?;
    let home = PathBuf::from(std::env::var("HOME").ctx("HOME")?);
    let bin = home.join(".local/bin/cmux-bytes");
    let cache = home.join(".cache/cmux-bytes");
    let units = home.join(".config/systemd/user");
    std::fs::create_dir_all(home.join(".local/bin")).ctx("~/.local/bin")?;
    std::fs::create_dir_all(&cache).ctx("cache dir")?;
    std::fs::create_dir_all(&units).ctx("units dir")?;
    let me = std::env::current_exe().ctx("current exe")?;
    let tmp = bin.with_extension("new");
    std::fs::copy(&me, &tmp).ctx("copy binary")?;
    std::fs::rename(&tmp, &bin).ctx("install binary")?;
    let service = format!(
        "# Written by `cmux-bytes install-timer` (manaflow-ai/cmux cmux-tui/crates/cmux-bytes).\n\
[Unit]\nDescription=cmux-bytes hill-climb: two steps on the bytes-path corpus, published for NOW\n\n\
[Service]\nType=oneshot\nNice=19\nIOSchedulingClass=idle\nTimeoutStartSec=100min\n\
ExecStart={bin} climb --folders-file {folders} --steps 2 --runs 9 --cap-bytes 67108864 --state {cache}/state --log {cache}/findings.md --json {cache}/latest.json --table {cache}/table.md\n\
ExecStart={bin} prefetch --folders-file {folders} --runs 9 --cap-bytes 67108864 --json {cache}/prefetch.json\n",
        bin = bin.display(),
        folders = folders.display(),
        cache = cache.display(),
    );
    let timer = format!(
        "# Written by `cmux-bytes install-timer`.\n[Unit]\nDescription=cmux-bytes hill-climb every {every}\n\n\
[Timer]\nOnBootSec=15min\nOnUnitInactiveSec={every}\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n"
    );
    std::fs::write(units.join("cmux-bytes-climb.service"), service).ctx("write service")?;
    std::fs::write(units.join("cmux-bytes-climb.timer"), timer).ctx("write timer")?;
    let run = |a: &[&str]| {
        std::process::Command::new("systemctl").arg("--user").args(a).status().map(|s| s.success())
    };
    let ok = run(&["daemon-reload"]).unwrap_or(false)
        && run(&["enable", "--now", "cmux-bytes-climb.timer"]).unwrap_or(false);
    println!(
        "{} cmux-bytes-climb.timer (every {every}); binary {}",
        if ok { "enabled" } else { "wrote (systemctl failed)" },
        bin.display()
    );
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_folder_is_an_error_and_an_empty_one_is_not() {
        let empty = std::env::temp_dir().join(format!("cmux-bytes-empty-{}", std::process::id()));
        std::fs::create_dir_all(&empty).unwrap();
        let ok = parse(&["--folder".into(), format!("empty={}", empty.display())]);
        let gone = parse(&["--folder".into(), format!("gone={}/missing", empty.display())]);
        std::fs::remove_dir(&empty).unwrap();
        assert!(ok.is_ok());
        assert!(gone.err().unwrap().contains("gone="));
    }
}
