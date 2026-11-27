//! `critpath`: critical path, drag and speed-of-light gaps from our own traces.
//!
//! ```text
//! critpath acpmux [--hours H] [--root DIR] [--json] [--write-latest] [--perfetto F] [--folded F]
//! critpath spans FILE [--json] [--perfetto F] [--folded F]
//! ```

use cmux_critpath::{Graph, Rollup, acpmux, field, folded, perfetto, spans};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::SystemTime;

struct Args {
    cmd: String,
    file: Option<PathBuf>,
    hours: f64,
    root: Option<PathBuf>,
    json: bool,
    write_latest: bool,
    perfetto: Option<PathBuf>,
    folded: Option<PathBuf>,
}

const USAGE: &str = "usage: critpath acpmux [--hours H] [--root DIR] [--json] [--write-latest] [--perfetto F] [--folded F]\n       critpath spans FILE [--json] [--perfetto F] [--folded F]";

fn parse() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let cmd = it.next().ok_or(USAGE)?;
    let mut a = Args {
        cmd,
        file: None,
        hours: 24.0,
        root: None,
        json: false,
        write_latest: false,
        perfetto: None,
        folded: None,
    };
    while let Some(arg) = it.next() {
        let mut val = || it.next().ok_or(format!("{arg} needs a value"));
        match arg.as_str() {
            "--hours" => a.hours = val()?.parse().map_err(|_| "--hours takes a number")?,
            "--root" => a.root = Some(val()?.into()),
            "--json" => a.json = true,
            "--write-latest" => a.write_latest = true,
            "--perfetto" => a.perfetto = Some(val()?.into()),
            "--folded" => a.folded = Some(val()?.into()),
            "-h" | "--help" => return Err(USAGE.into()),
            other if a.file.is_none() && !other.starts_with('-') => a.file = Some(other.into()),
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
    }
    Ok(a)
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

fn host() -> String {
    std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".into())
}

fn exports(a: &Args, graphs: &[Graph]) -> Result<(), String> {
    if let Some(p) = &a.perfetto {
        std::fs::write(p, perfetto(graphs).to_string())
            .map_err(|e| format!("{}: {e}", p.display()))?;
    }
    if let Some(p) = &a.folded {
        std::fs::write(p, folded(graphs, false)).map_err(|e| format!("{}: {e}", p.display()))?;
    }
    Ok(())
}

fn print_rollup(graphs: &[Graph]) {
    let mut r = Rollup::default();
    for g in graphs {
        r.add(g);
    }
    println!("{} runs, {} s elapsed in all", r.runs, r.elapsed_ms / 1000);
    let path: i64 = r.states.values().sum();
    for (s, ms) in &r.states {
        println!(
            "  path {:>5}: {:>8} s ({:.0}%)",
            s.as_str(),
            ms / 1000,
            100.0 * *ms as f64 / path.max(1) as f64
        );
    }
    println!("what would shorten them (drag, summed over runs):");
    for (cat, d, p, n) in r.top().into_iter().take(15) {
        println!(
            "  {:>8.1} s drag  {:>8.1} s on path  {:>5} runs  {cat}",
            d as f64 / 1000.0,
            p as f64 / 1000.0,
            n
        );
    }
}

fn run(a: Args) -> Result<(), String> {
    match a.cmd.as_str() {
        "acpmux" => {
            let root = a.root.clone().unwrap_or_else(|| home().join(".acpmux/sessions"));
            let now = SystemTime::now();
            let report = acpmux::read(&root, a.hours, now);
            let at_ms = now
                .duration_since(SystemTime::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            let doc = acpmux::summary(&report, &root, &host(), a.hours, at_ms);
            exports(&a, &report.graphs)?;
            if a.write_latest {
                let dir = std::env::var_os("CRITPATH_STATE")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home().join(".local/state/critpath"));
                std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
                let tmp = dir.join("latest.json.tmp");
                std::fs::write(&tmp, serde_json::to_vec_pretty(&doc).unwrap_or_default())
                    .map_err(|e| e.to_string())?;
                std::fs::rename(&tmp, dir.join("latest.json")).map_err(|e| e.to_string())?;
            }
            if a.json {
                println!("{}", serde_json::to_string_pretty(&doc).unwrap_or_default());
                return Ok(());
            }
            println!(
                "{} sessions, {} files, {} turns in the last {} h",
                report.sessions_read,
                report.files_read,
                report.graphs.len(),
                a.hours
            );
            println!("stages (ms): n p50 p90 p99 max | speed of light | excess s");
            for (name, s) in field(&doc, "stages").as_object().into_iter().flatten() {
                println!(
                    "  {name:24} {:>5} {:>7} {:>7} {:>8} {:>8} | {:>6} | {}",
                    field(s, "n"),
                    field(s, "p50_ms"),
                    field(s, "p90_ms"),
                    field(s, "p99_ms"),
                    field(s, "max_ms"),
                    field(s, "sol_ms"),
                    field(s, "excess_over_sol_s")
                );
            }
            print_rollup(&report.graphs);
            println!("stalls: {}", field(&doc, "stalls"));
            println!("finding: {}", field(&doc, "finding").as_str().unwrap_or(""));
            Ok(())
        }
        "spans" => {
            let file = a.file.clone().ok_or(USAGE)?;
            let text =
                std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
            let (graphs, bad) = spans::parse(&text);
            exports(&a, &graphs)?;
            if a.json {
                let runs: Vec<_> = graphs
                    .iter()
                    .map(|g| {
                        let path: Vec<_> = g.critical_path().iter().filter_map(|s| g.nodes.get(s.node).map(|n| serde_json::json!({"name": n.name, "cat": n.cat, "gap_ms": s.gap, "ms": s.dur}))).collect();
                        let drag: Vec<_> = g.drag_by_cat().into_iter().map(|(c, d, p)| serde_json::json!({"cat": c, "drag_ms": d, "path_ms": p})).collect();
                        serde_json::json!({"run": g.label, "elapsed_ms": g.elapsed(), "path": path, "drag": drag})
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::json!({"schema": "critpath-spans/v1", "runs": runs, "bad_lines": bad})
                );
                return Ok(());
            }
            for g in &graphs {
                println!("{}: {} ms elapsed", g.label, g.elapsed());
                for seg in g.critical_path() {
                    let Some(n) = g.nodes.get(seg.node) else { continue };
                    println!(
                        "  {:>8} ms (+{:>6} wait) {:5} {} [{}]",
                        seg.dur,
                        seg.gap,
                        n.state.as_str(),
                        n.name,
                        n.cat
                    );
                }
            }
            print_rollup(&graphs);
            if bad > 0 {
                eprintln!("{bad} lines were not spans");
            }
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}

fn main() -> ExitCode {
    match parse().and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::from(2)
        }
    }
}
