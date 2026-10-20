//! The ripgrep bench (design section 8): the same synthetic corpus as
//! files for `rg` and as an index for the engine, the same queries, warm
//! page cache for rg (its best case). Writes a Markdown table to
//! `.build/search-bench/report.md` at the repository root and to stderr.
//!
//! Size: `CMUX_SEARCH_BENCH_BYTES` (default 64 MiB so the workspace run
//! stays cheap; the 10 GB run sets it). rg must be on PATH or in Homebrew;
//! without it the rg columns read "n/a".

use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_search::{EngineConfig, Kind, Query, SearchEngine, SyntheticCorpus};

const FILE_BYTES: usize = 64 << 20;

#[test]
fn cmux_search_search_bench_vs_ripgrep_report() {
    let bytes: usize = std::env::var("CMUX_SEARCH_BENCH_BYTES")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(64 << 20);
    let temp = tempfile::tempdir().unwrap();
    let corpus_dir = temp.path().join("corpus");
    std::fs::create_dir_all(&corpus_dir).unwrap();
    let dir = &corpus_dir;

    // One pass: index every doc and write it to the rg corpus files.
    // Sealed segments go to disk, as the daemon runs it.
    let mut engine =
        SearchEngine::open(&temp.path().join("index"), EngineConfig::default()).unwrap();
    let mut samples = Samples::default();
    let mut writer: Option<BufWriter<File>> = None;
    let mut file_bytes = 0usize;
    let mut file_index = 0;
    let mut index_time = Duration::ZERO;
    let started = Instant::now();
    for (count, doc) in SyntheticCorpus::with_bytes(2026, bytes).enumerate() {
        if writer.is_none() || file_bytes >= FILE_BYTES {
            if let Some(mut old) = writer.take() {
                old.flush().unwrap();
            }
            let path = dir.as_path().join(format!("corpus-{file_index:04}.log"));
            writer = Some(BufWriter::new(File::create(path).unwrap()));
            file_index += 1;
            file_bytes = 0;
        }
        let out = writer.as_mut().unwrap();
        out.write_all(doc.text.as_bytes()).unwrap();
        out.write_all(b"\n").unwrap();
        file_bytes += doc.text.len() + 1;
        if count % 97 == 0 {
            samples.take(&doc.text, doc.kind);
        }
        let append = Instant::now();
        engine.append(doc);
        index_time += append.elapsed();
    }
    if let Some(mut last) = writer.take() {
        last.flush().unwrap();
    }
    let seal = Instant::now();
    engine.seal();
    index_time += seal.elapsed();
    let total_time = started.elapsed();
    let peak_rss = peak_rss_bytes();
    let stats = engine.stats();

    let queries = samples.queries();
    let rg = ripgrep();
    let lowered = lowered_corpus(dir.as_path(), bytes);
    let now = 1_900_000_000_000;
    let mut rows: Vec<Row> = Vec::new();
    for (class, text) in &queries {
        let engine_query = if text.contains(' ') { format!("\"{text}\"") } else { text.clone() };
        let mut engine_times = Vec::new();
        let mut hits = 0;
        for _ in 0..5 {
            let begin = Instant::now();
            let result = engine.search(&Query::new(engine_query.as_str(), now));
            engine_times.push(begin.elapsed());
            hits = result.hits.iter().filter(|hit| !hit.is_name).count();
        }
        engine_times.sort();
        let mut first = Query::new(engine_query.as_str(), now);
        first.budget = Some(Duration::from_millis(10));
        let begin = Instant::now();
        let first_result = engine.search(&first);
        let first_ms = begin.elapsed();
        let first_hits = first_result.hits.iter().filter(|hit| !hit.is_name).count();
        let scan = lowered.as_deref().map(|corpus| naive_scan(corpus, text));
        let (rg_full, rg_first) = match &rg {
            Some(rg) => (
                Some(run_rg(rg, dir.as_path(), text, false)),
                Some(run_rg(rg, dir.as_path(), text, true)),
            ),
            None => (None, None),
        };
        rows.push(Row {
            class,
            text: text.clone(),
            engine: engine_times[2],
            hits,
            scan,
            rg_full,
            rg_first,
            first: first_ms,
            first_hits,
        });
    }

    let report = render(bytes, &stats, index_time, total_time, peak_rss, &rows, rg.as_deref());
    eprintln!("{report}");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/search-bench");
    std::fs::create_dir_all(&out).unwrap();
    std::fs::write(out.join("report.md"), &report).unwrap();
}

struct Row {
    class: &'static str,
    text: String,
    engine: Duration,
    hits: usize,
    scan: Option<Duration>,
    rg_full: Option<Duration>,
    rg_first: Option<Duration>,
    /// The window's first results: 10 ms budget.
    first: Duration,
    first_hits: usize,
}

#[derive(Default)]
struct Samples {
    rare: Vec<String>,
    phrases: Vec<String>,
}

impl Samples {
    fn take(&mut self, text: &str, kind: Kind) {
        if let Some(start) = text.find("{\"id\":\"") {
            let id = &text[start + 7..];
            if id.len() >= 10 && self.rare.len() < 15 {
                self.rare.push(id[2..10].to_owned());
            }
        }
        if kind == Kind::Chat && self.phrases.len() < 10 {
            let words: Vec<&str> = text.split_whitespace().take(3).collect();
            if words.len() == 3
                && words.iter().all(|word| word.chars().all(|ch| ch.is_ascii_alphabetic()))
            {
                self.phrases.push(words.join(" "));
            }
        }
    }

    fn queries(&self) -> Vec<(&'static str, String)> {
        let mut queries: Vec<(&'static str, String)> = Vec::new();
        queries.extend(self.rare.iter().map(|text| ("rare id", text.clone())));
        queries.extend(self.phrases.iter().map(|text| ("phrase", text.clone())));
        for text in
            ["error", "request", "test", "migration", "FAILED", "mismatched types", "Compiling"]
        {
            queries.push(("common", text.to_owned()));
        }
        for text in ["mig", "dep", "lat", "scr"] {
            queries.push(("3-char prefix", text.to_owned()));
        }
        for text in ["qqzv unseen", "zzqxw", "kiwi banana"] {
            queries.push(("miss", text.to_owned()));
        }
        queries
    }
}

/// ripgrep from PATH or Homebrew; else (macOS arm64 only) the pinned
/// 14.1.1 release, downloaded once into `.build/tools` and checked against
/// its published sha256, as the fleet step does for cargo-nextest.
fn ripgrep() -> Option<String> {
    for candidate in ["rg", "/opt/homebrew/bin/rg", "/usr/local/bin/rg"] {
        if Command::new(candidate).arg("--version").output().is_ok_and(|out| out.status.success()) {
            return Some(candidate.to_owned());
        }
    }
    pinned_ripgrep()
}

const RG_RELEASE: &str = "ripgrep-14.1.1-aarch64-apple-darwin";
const RG_SHA256: &str = "24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be";

fn pinned_ripgrep() -> Option<String> {
    if !(cfg!(target_os = "macos") && cfg!(target_arch = "aarch64")) {
        return None;
    }
    let tools = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/tools");
    let binary = tools.join(RG_RELEASE).join("rg");
    if !binary.exists() {
        std::fs::create_dir_all(&tools).ok()?;
        let archive = tools.join(format!("{RG_RELEASE}.tar.gz"));
        let url = format!(
            "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/{RG_RELEASE}.tar.gz"
        );
        let fetched = Command::new("curl").args(["-fsSL", "-o"]).arg(&archive).arg(&url).status();
        if !fetched.is_ok_and(|status| status.success()) {
            return None;
        }
        let sum = Command::new("shasum").args(["-a", "256"]).arg(&archive).output().ok()?;
        if !String::from_utf8_lossy(&sum.stdout).starts_with(RG_SHA256) {
            eprintln!("ripgrep archive sha256 does not match the pin; rg columns stay n/a");
            let _ = std::fs::remove_file(&archive);
            return None;
        }
        let unpacked = Command::new("tar").arg("xzf").arg(&archive).arg("-C").arg(&tools).status();
        if !unpacked.is_ok_and(|status| status.success()) {
            return None;
        }
    }
    let path = binary.to_string_lossy().into_owned();
    Command::new(&path)
        .arg("--version")
        .output()
        .is_ok_and(|out| out.status.success())
        .then_some(path)
}

/// Median of 3 warm runs (one warmup first).
fn run_rg(rg: &str, dir: &Path, text: &str, first: bool) -> Duration {
    let run = || {
        let mut command = Command::new(rg);
        command.args(["-F", "-i", "--no-messages"]);
        if first {
            command.args(["-m", "50"]);
        } else {
            command.arg("-c");
        }
        command.arg("--").arg(text).arg(dir);
        let begin = Instant::now();
        let _ = command.output();
        begin.elapsed()
    };
    run();
    let mut times = [run(), run(), run()];
    times.sort();
    times[1]
}

/// The corpus files, ASCII-lowercased once (the scan's best case); `None`
/// over 4 GiB, where holding a second copy is not worth it.
fn lowered_corpus(dir: &Path, bytes: usize) -> Option<Vec<Vec<u8>>> {
    if bytes > 4 << 30 {
        return None;
    }
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(dir).unwrap().map(|entry| entry.unwrap().path()).collect();
    files.sort();
    Some(files.iter().map(|path| std::fs::read(path).unwrap().to_ascii_lowercase()).collect())
}

/// A single-thread in-process SIMD substring scan of the lowered corpus.
fn naive_scan(corpus: &[Vec<u8>], text: &str) -> Duration {
    let needle = text.to_lowercase();
    let finder = memchr::memmem::Finder::new(needle.as_bytes());
    let begin = Instant::now();
    let found: usize = corpus.iter().map(|content| finder.find_iter(content).count()).sum();
    std::hint::black_box(found);
    begin.elapsed()
}

fn peak_rss_bytes() -> u64 {
    // SAFETY: getrusage writes into the zeroed struct we pass and nothing else.
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        usage
    };
    let max = usage.ru_maxrss.max(0) as u64;
    // macOS reports bytes, Linux kilobytes.
    if cfg!(target_os = "macos") { max } else { max * 1024 }
}

fn ms(duration: Duration) -> String {
    format!("{:.3}", duration.as_secs_f64() * 1000.0)
}

fn median(mut values: Vec<Duration>) -> Duration {
    values.sort();
    values.get(values.len() / 2).copied().unwrap_or_default()
}

fn p99(mut values: Vec<Duration>) -> Duration {
    values.sort();
    values.get(values.len() * 99 / 100).copied().unwrap_or_default()
}

fn render(
    bytes: usize,
    stats: &cmux_search::Stats,
    index_time: Duration,
    total_time: Duration,
    peak_rss: u64,
    rows: &[Row],
    rg: Option<&str>,
) -> String {
    let mut out = String::new();
    let mib = |value: usize| value as f64 / (1 << 20) as f64;
    let _ = writeln!(out, "# cmux-search vs ripgrep\n");
    let _ = writeln!(
        out,
        "- corpus: {:.0} MiB synthetic (seed 2026), {} docs, {} blocks, {} segments",
        mib(bytes),
        stats.docs,
        stats.blocks,
        stats.segments
    );
    let _ = writeln!(
        out,
        "- index (postings + tables, not text): {:.1} MiB = {:.3}x the text",
        mib(stats.index_bytes),
        stats.index_bytes as f64 / stats.text_bytes.max(1) as f64
    );
    let _ = writeln!(
        out,
        "- build: {} ms in the engine ({:.0} MiB/s), {} ms with corpus generation and file writes",
        ms(index_time),
        mib(stats.text_bytes) / index_time.as_secs_f64().max(1e-9),
        ms(total_time)
    );
    let _ = writeln!(
        out,
        "- engine resident memory: {:.1} MiB = {:.1} MiB per GiB of text (sealed segments on disk, read with pread); peak RSS of the bench process {:.0} MiB (includes the in-memory copy of the corpus for the 1-thread scan)",
        stats.resident_bytes as f64 / (1 << 20) as f64,
        (stats.resident_bytes as f64 / (1 << 20) as f64)
            / (stats.text_bytes as f64 / (1 << 30) as f64).max(1e-9),
        peak_rss as f64 / (1 << 20) as f64
    );
    let _ = writeln!(out, "- ripgrep: {}", rg.unwrap_or("not found"));
    let _ = writeln!(
        out,
        "- engine time: in-process `search` (limit 50), median of 5; rg: median of 3 warm runs incl. process spawn\n"
    );
    let _ = writeln!(
        out,
        "| class | query | engine ms | content hits | first results ms (10 ms budget) | hits then | rg -c ms | rg -m 50 ms | 1-thread scan ms | rg -c / engine |"
    );
    let _ = writeln!(out, "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    for row in rows {
        let ratio = row.rg_full.map_or("n/a".to_owned(), |rg| {
            format!("{:.0}x", rg.as_secs_f64() / row.engine.as_secs_f64().max(1e-9))
        });
        let _ = writeln!(
            out,
            "| {} | `{}` | {} | {} | {} | {} | {} | {} | {} | {} |",
            row.class,
            row.text,
            ms(row.engine),
            row.hits,
            ms(row.first),
            row.first_hits,
            row.rg_full.map_or("n/a".to_owned(), ms),
            row.rg_first.map_or("n/a".to_owned(), ms),
            row.scan.map_or("n/a".to_owned(), ms),
            ratio
        );
    }
    let engine_times: Vec<Duration> = rows.iter().map(|row| row.engine).collect();
    let _ = writeln!(
        out,
        "\n- engine p50 {} ms, p99 {} ms",
        ms(median(engine_times.clone())),
        ms(p99(engine_times))
    );
    if rows.iter().all(|row| row.rg_full.is_some()) {
        let rg_full: Vec<Duration> = rows.iter().filter_map(|row| row.rg_full).collect();
        let rg_first: Vec<Duration> = rows.iter().filter_map(|row| row.rg_first).collect();
        let speedups: Vec<f64> = rows
            .iter()
            .filter_map(|row| {
                row.rg_full.map(|rg| rg.as_secs_f64() / row.engine.as_secs_f64().max(1e-9))
            })
            .collect();
        let mut sorted = speedups;
        sorted.sort_by(f64::total_cmp);
        let _ = writeln!(
            out,
            "- rg -c p50 {} ms, p99 {} ms; rg -m 50 p50 {} ms",
            ms(median(rg_full.clone())),
            ms(p99(rg_full)),
            ms(median(rg_first))
        );
        let _ = writeln!(
            out,
            "- speedup vs rg -c: p50 {:.0}x, worst {:.0}x",
            sorted[sorted.len() / 2],
            sorted[0]
        );
    }
    out
}
