//! Bench: remote browser tabs on one host per tab (today's model) against one
//! shared host (`--supervise`), at 1, 3 and 10 tabs. macOS, on the fleet:
//!   (drop the #[ignore] in a side commit, then) cmux-ci run --class isolated \
//!     --script scripts/ci/cmux-remote-browser-host-build.sh --ref SIDE_SHA --cef sha256:HEX \
//!     --artifact .build/artifacts/rb-shared-host-bench.json
//! (ignored in the normal test run). For each model and tab count it reports
//! the processes, their memory (top's MEM, the physical footprint, summed over
//! every process of the model, and the RSS sum), threads, idle wakeups per
//! second over a 5 s idle window, and the time from asking for a tab to its
//! page's first request (the first tab cold; later tabs warm in a shared
//! host). Each tab has a connected viewer, as an open remote tab does.
#![cfg(target_os = "macos")]

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant};

use cmux_rd_proto::control::Control as RdControl;
use cmux_rd_proto::{STREAM_CONTROL, StreamDeframer, encode_stream_frame};
use serde_json::{Value, json};

const SECRET: &str = "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a";
const IDLE_WINDOW_S: u32 = 5;

#[path = "common/bundle.rs"]
mod common_bundle;
use common_bundle::bundle;

type Hits = Arc<(Mutex<Vec<(String, Instant)>>, Condvar)>;

/// A loopback page server that records when each tab's page was asked for.
fn pages(hits: Hits) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut conn) = conn else { continue };
            let hits = hits.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(conn.try_clone().unwrap());
                let mut first = String::new();
                let _ = reader.read_line(&mut first);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                }
                let path = first.split_whitespace().nth(1).unwrap_or("/").to_string();
                let body = "<html><title>bench</title><body><h1>remote tab</h1><p>a still page</p></body></html>";
                let _ = conn.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                );
                if let Some(tab) = path.strip_prefix("/page?tab=") {
                    let (lock, cv) = &*hits;
                    lock.lock().unwrap().push((tab.to_string(), Instant::now()));
                    cv.notify_all();
                }
            });
        }
    });
    port
}

fn wait_hit(hits: &Hits, tab: &str) -> Instant {
    let (lock, cv) = &**hits;
    let until = Instant::now() + Duration::from_secs(90);
    let mut g = lock.lock().unwrap();
    loop {
        if let Some((_, at)) = g.iter().find(|(t, _)| t == tab) {
            return *at;
        }
        let left = until.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "tab {tab} never loaded");
        g = cv.wait_timeout(g, left).unwrap().0;
    }
}

/// A viewer that joins the tab with `token` and stays (reading and dropping
/// what the host sends).
fn viewer(port: u16, token: &str) -> TcpStream {
    let hello: RdControl = serde_json::from_value(json!({
        "t": "hello", "user": "u", "install": "i", "class": "c", "interactive": true,
        "udp_port": null, "max_datagram": 1200, "token": token, "service": "rb/1",
        "caps": ["input.service"],
    }))
    .unwrap();
    let mut out = Vec::new();
    encode_stream_frame(STREAM_CONTROL, &serde_json::to_vec(&hello).unwrap(), &mut out).unwrap();
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.write_all(&out).unwrap();
    let mut reader = s.try_clone().unwrap();
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        let mut deframer = StreamDeframer::default();
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 {
                break;
            }
            deframer.extend(&buf[..n]);
            while let Ok(Some(_)) = deframer.next_frame() {}
        }
    });
    s
}

fn read_json_line(out: &mut impl BufRead, pred: impl Fn(&Value) -> bool) -> Value {
    loop {
        let mut line = String::new();
        assert!(out.read_line(&mut line).unwrap() > 0, "the host's stdout ended");
        if let Ok(v) = serde_json::from_str::<Value>(&line)
            && pred(&v)
        {
            return v;
        }
    }
}

fn port_of(v: &Value) -> u16 {
    v["listening"].as_str().unwrap().rsplit(':').next().unwrap().parse().unwrap()
}

/// Every process under `roots` (the roots included).
fn tree(roots: &[u32]) -> Vec<u32> {
    let out = Command::new("ps").args(["-axo", "pid=,ppid="]).output().unwrap();
    let pairs: Vec<(u32, u32)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace().map(|x| x.parse::<u32>().ok());
            Some((it.next()??, it.next()??))
        })
        .collect();
    let mut set: BTreeSet<u32> = roots.iter().copied().collect();
    loop {
        let before = set.len();
        for (pid, ppid) in &pairs {
            if set.contains(ppid) {
                set.insert(*pid);
            }
        }
        if set.len() == before {
            return set.into_iter().collect();
        }
    }
}

fn mb(s: &str) -> f64 {
    let s = s.trim_end_matches(['+', '-']);
    let (num, unit) = s.split_at(s.find(|c: char| c.is_ascii_alphabetic()).unwrap_or(s.len()));
    let n: f64 = num.parse().unwrap_or(0.0);
    match unit {
        "B" => n / 1048576.0,
        "K" => n / 1024.0,
        "M" => n,
        "G" => n * 1024.0,
        _ => n / 1048576.0,
    }
}

/// (processes, MEM MB, RSS MB, threads, idle wakeups/s) of `pids`, over an
/// idle window.
fn sample(pids: &[u32]) -> (usize, f64, f64, u64, f64) {
    let rss_out = Command::new("ps")
        .args(["-o", "rss=", "-p", &pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",")])
        .output()
        .unwrap();
    let rss: f64 = String::from_utf8_lossy(&rss_out.stdout)
        .lines()
        .filter_map(|l| l.trim().parse::<f64>().ok())
        .sum::<f64>()
        / 1024.0;
    let mut args = vec![
        "-l".to_string(),
        "2".into(),
        "-s".into(),
        IDLE_WINDOW_S.to_string(),
        "-c".into(),
        "d".into(),
        "-stats".into(),
        "pid,mem,th,idlew".into(),
    ];
    for p in pids {
        args.push("-pid".into());
        args.push(p.to_string());
    }
    let out = Command::new("top").args(&args).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    // The second sample: the lines after the last header.
    let last = text.rfind("PID").unwrap_or(0);
    let (mut mem, mut threads, mut wakeups) = (0.0, 0u64, 0.0);
    for line in text[last..].lines().skip(1) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 4 || cols[0].parse::<u32>().is_err() {
            continue;
        }
        mem += mb(cols[1]);
        threads += cols[2].split('/').next().and_then(|t| t.parse::<u64>().ok()).unwrap_or(0);
        wakeups += cols[3].trim_end_matches('+').parse::<f64>().unwrap_or(0.0);
    }
    (pids.len(), mem, rss, threads, wakeups / f64::from(IDLE_WINDOW_S))
}

struct Run {
    children: Vec<Child>,
    _viewers: Vec<TcpStream>,
    roots: Vec<u32>,
    open_ms: Vec<f64>,
}

impl Drop for Run {
    fn drop(&mut self) {
        for c in &mut self.children {
            drop(c.stdin.take());
        }
        for c in &mut self.children {
            let _ = c.wait();
        }
    }
}

fn per_tab_hosts(host: &Path, dir: &Path, page: u16, hits: &Hits, n: usize, tag: &str) -> Run {
    let mut run = Run { children: vec![], _viewers: vec![], roots: vec![], open_ms: vec![] };
    for i in 0..n {
        let tab = format!("{tag}-{i}");
        let cache = dir.join(format!("{tab}-cache"));
        std::fs::create_dir_all(&cache).unwrap();
        let asked = Instant::now();
        let mut child = Command::new(host)
            .args([
                "--serve",
                "--listen",
                "127.0.0.1:0",
                "--lifeline",
                "--use-mock-keychain",
                "--url",
            ])
            .arg(format!("http://127.0.0.1:{page}/page?tab={tab}"))
            .env("CMUX_RB_CACHE_DIR", &cache)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        writeln!(child.stdin.as_mut().unwrap(), "{SECRET}").unwrap();
        let mut out = BufReader::new(child.stdout.take().unwrap());
        let port = port_of(&read_json_line(&mut out, |v| v.get("listening").is_some()));
        // Drain the rest of its stdout.
        std::thread::spawn(move || for _ in out.lines() {});
        // The tab opens when its viewer joins.
        run._viewers.push(viewer(port, SECRET));
        let at = wait_hit(hits, &tab);
        run.open_ms.push(at.duration_since(asked).as_secs_f64() * 1000.0);
        run.roots.push(child.id());
        run.children.push(child);
    }
    run
}

fn shared_host(host: &Path, dir: &Path, page: u16, hits: &Hits, n: usize, tag: &str) -> Run {
    let mut child = Command::new(host)
        .arg("--supervise")
        .env("CMUX_RB_CACHE_DIR", dir.join(format!("{tag}-root")))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let (tx, rx) = mpsc::channel::<Value>();
    let out = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str(&line) {
                let _ = tx.send(v);
            }
        }
    });
    let next = |pred: &dyn Fn(&Value) -> bool| loop {
        let v = rx.recv_timeout(Duration::from_secs(90)).expect("the supervisor went quiet");
        if pred(&v) {
            return v;
        }
    };
    let port = port_of(&next(&|v| v.get("listening").is_some()));
    let mut run =
        Run { children: vec![], _viewers: vec![], roots: vec![child.id()], open_ms: vec![] };
    for i in 0..n {
        let tab = format!("{tag}-{i}");
        let asked = Instant::now();
        let line =
            json!({"open": {"tab": tab, "url": format!("http://127.0.0.1:{page}/page?tab={tab}")}});
        let stdin = child.stdin.as_mut().unwrap();
        writeln!(stdin, "{line}").unwrap();
        stdin.flush().unwrap();
        let reply = next(&|v| v["tab"] == tab.as_str() && v.get("token").is_some());
        run._viewers.push(viewer(port, reply["token"].as_str().unwrap()));
        let at = wait_hit(hits, &tab);
        run.open_ms.push(at.duration_since(asked).as_secs_f64() * 1000.0);
    }
    run.children.push(child);
    run
}

#[test]
#[ignore = "bench: a fleet Mac run of a side commit without this line (module doc)"]
fn remote_tabs_per_tab_hosts_against_one_shared_host() {
    let dir = std::env::temp_dir().join(format!("rb-bench-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let host = bundle(&dir);
    let hits: Hits = Arc::new((Mutex::new(Vec::new()), Condvar::new()));
    let page = pages(hits.clone());
    let mut rows = Vec::new();
    for n in [1usize, 3, 10] {
        for model in ["per-tab", "shared"] {
            let tag = format!("{model}-{n}");
            let run = if model == "per-tab" {
                per_tab_hosts(&host, &dir, page, &hits, n, &tag)
            } else {
                shared_host(&host, &dir, page, &hits, n, &tag)
            };
            // Let the pages settle, then the idle window.
            std::thread::sleep(Duration::from_secs(3));
            let pids = tree(&run.roots);
            let (procs, mem, rss, threads, wakeups) = sample(&pids);
            let first = run.open_ms.first().copied().unwrap_or(0.0);
            let mut warm: Vec<f64> = run.open_ms.iter().skip(1).copied().collect();
            warm.sort_by(f64::total_cmp);
            let warm_p50 = warm.get(warm.len() / 2).copied();
            let row = json!({
                "model": model, "tabs": n, "processes": procs, "threads": threads,
                "mem_mb": mem, "mem_mb_per_tab": mem / n as f64,
                "rss_mb": rss, "rss_mb_per_tab": rss / n as f64,
                "idle_wakeups_per_s": wakeups,
                "open_ms_first": first, "open_ms_later_p50": warm_p50,
            });
            eprintln!("RB-BENCH {row}");
            rows.push(row);
            drop(run);
        }
    }
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/artifacts");
    std::fs::create_dir_all(&out).unwrap();
    std::fs::write(
        out.join("rb-shared-host-bench.json"),
        serde_json::to_vec_pretty(&rows).unwrap(),
    )
    .unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
