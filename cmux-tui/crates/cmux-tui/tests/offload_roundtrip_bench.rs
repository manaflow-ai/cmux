//! Offload round trip bench ("offload-anywhere"): a chat moved mid-turn from a
//! "Mac" daemon to a daemon shaped like a personal Cloud VM and back, with the
//! real CLI, timed per phase.
//!
//! Leo: "the ability to offer offloading anything instantly to our fucking
//! cloud and back and wherever the fuck you want". The goal is a round trip
//! p95 under 5 s; this is the "before" harness, nothing here is tuned.
//!
//! One iteration, on the two headless daemons of `journey_support`:
//!
//! 1. On the Mac: a dirty git folder (pushed commit, uncommitted change,
//!    untracked file) and a chat in it with history, a running turn and a
//!    queued prompt, bound to an agent tab. The running turn writes a file.
//! 2. Out (timed from t0): `cmux link seed push`, then `cmux link agent move
//!    --interrupt --vm-kind owner --sync seed`, the commands
//!    `cloud_move_journey.rs` runs (Move to Cloud).
//! 3. Usable on the VM: the turn the move stopped has started again there
//!    (acpmux's continuation prompt is in the chat's events, after its
//!    history). t1.
//! 4. Not timed: the VM's turns settle, the chat gets a VM edit, a new running
//!    turn and a queued prompt, and an agent tab of the VM's store.
//! 5. Back (timed): `cmux link agent move --interrupt --sync pull` (Bring
//!    Back Local: the seeded folder's diff comes back once frozen, then the
//!    chat), as `bring_back_journey.rs` moves a chat back.
//! 6. Usable on the Mac: the stopped turn started again there. t2.
//!
//! Each move's `phases`, `frozen_ms`, `bytes` and `pages` come from the move
//! command's own JSON result. The wait after each move is the agent restart
//! cost, reported on its own (`*_usable_ms`). `roundtrip_ms` is out + its wait
//! + back + its wait (step 4 excluded: it is the test giving the chat new work).
//!
//! Env: `OFFLOAD_BENCH_ITERS` (default 10), `OFFLOAD_BENCH_HISTORY_KB` (chat
//! log written before the move, in KiB of prompt plus echo; default 0: one
//! short turn), `OFFLOAD_BENCH_PREPULL` (1: step 5 first runs the app's
//! pre-freeze pull, `cmux link seed pull --or-copy` as `bringBackPull`, then
//! the VM writes one more file the frozen pull must still bring; default 0),
//! `OFFLOAD_BENCH_OUT` (also write the JSON there). Prints one
//! line `OFFLOAD_BENCH {json}`.
//!
//! Run: `cargo test -p cmux-tui --test it -- offload_roundtrip_bench:: --ignored --nocapture`.
//!
//! Linux only, like the journeys it reuses: a Cloud host is a Linux machine.
#![cfg(target_os = "linux")]

use crate::journey_support;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Map, Value, json};

/// What one git process costs here, in ms (median of 9), run the way the seed runs it
/// (`GIT_CONFIG_NOSYSTEM`). A move runs 40 to 60 of them, so this number scales every
/// figure in the line: a wrapped `git` on PATH that costs 130 ms turns a 1.7 s round trip
/// into 16 s. Read it before comparing two runs.
fn git_start_ms() -> f64 {
    let mut runs: Vec<f64> = (0..9)
        .map(|_| {
            let start = Instant::now();
            let _ = Command::new("git")
                .arg("--version")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .output();
            start.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    runs.sort_by(|a, b| a.total_cmp(b));
    (runs[runs.len() / 2] * 10.0).round() / 10.0
}

const CONTINUED: &str = "This chat moved to another machine";
/// The largest single prompt the bench sends to grow the chat log.
const FILLER_PROMPT_BYTES: usize = 256 * 1024;

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// A working copy `name` with a commit pushed to its GitHub remote
/// (`acme/<name>` under `github`), an uncommitted change and an untracked file.
fn dirty_repo(at: &Path, github: &Path, name: &str) -> PathBuf {
    let repo = at.join(name);
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let bare = github.join(format!("acme/{name}.git"));
    fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare"]);
    git(&bare, &["config", "uploadpack.allowFilter", "true"]);
    git(&repo, &["remote", "add", "origin", &format!("https://github.com/acme/{name}.git")]);
    let local = format!("url.file://{}/.insteadOf", github.display());
    git(&repo, &["config", &local, "https://github.com/"]);
    git(&repo, &["-c", "protocol.file.allow=always", "push", "-q", "-u", "origin", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\nuncommitted change\n").unwrap();
    fs::write(repo.join("notes.txt"), "untracked\n").unwrap();
    repo
}

/// Polls `probe` every 10 ms (finer than `wait_until`'s 100 ms: the wait is measured).
fn wait_fine<T>(secs: u64, what: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(found) = probe() {
            return found;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Events of `session` after `after` (its `seq`).
fn events_after(acpmux: &mut Acpmux, session: &str, after: u64) -> Vec<Value> {
    let page = acpmux
        .call("_acpmux/events", json!({"sessionId": session, "afterSeq": after, "limit": 5000}));
    page["events"].as_array().cloned().unwrap_or_default()
}

fn last_seq(events: &[Value]) -> u64 {
    events.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap_or(0)
}

fn is_continuation(event: &Value) -> bool {
    event["kind"] == "user_message"
        && event["msg"]["text"].as_str().is_some_and(|t| t.starts_with(CONTINUED))
}

/// Waits until `session` is usable on `acpmux`'s machine: it lists the chat and
/// the turn the move stopped has started there (its `nth` continuation prompt).
/// Answers the events seen (all of them, read in pages).
fn wait_usable(acpmux: &mut Acpmux, session: &str, nth: usize, what: &str) -> Vec<Value> {
    let mut seen: Vec<Value> = Vec::new();
    wait_fine(60, what, || {
        let fresh = events_after(acpmux, session, last_seq(&seen));
        seen.extend(fresh);
        (seen.iter().filter(|e| is_continuation(e)).count() >= nth).then_some(())
    });
    seen
}

/// The Mac's chat: `history_kb` KiB of finished turns (at least one), a turn
/// waiting for a cancel and a prompt queued behind it.
fn chat_on_mac(acpmux: &mut Acpmux, cwd: &Path, iter: u64, history_kb: u64) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, "hello from the mac", &format!("p{iter}-h")));
    // The agent echoes each prompt: half the log is prompts, half echoes.
    let mut left = (history_kb as usize * 1024) / 2;
    let mut n = 0;
    while left > 0 {
        let size = left.min(FILLER_PROMPT_BYTES);
        let text = format!("{n:08} {}", "x".repeat(size.saturating_sub(9)));
        acpmux.call("session/prompt", prompt(&session, &text, &format!("p{iter}-fill-{n}")));
        left -= size;
        n += 1;
    }
    running_turn_and_queue(acpmux, &session, &format!("p{iter}-out"));
    session
}

/// A turn that runs until a cancel, and a prompt queued behind it.
fn running_turn_and_queue(acpmux: &mut Acpmux, session: &str, tag: &str) {
    acpmux.send("session/prompt", prompt(session, "until-cancel", &format!("{tag}-running")));
    wait_until(20, "the running turn", || {
        acpmux.summary(session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    acpmux.send("session/prompt", prompt(session, "queued", &format!("{tag}-queued")));
    wait_until(20, "the queued prompt", || {
        acpmux.summary(session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
    });
}

/// Until `session`'s turns on `acpmux` are done: no turn runs, nothing is queued.
fn settled(acpmux: &mut Acpmux, session: &str) {
    wait_until(30, "the chat's turns to finish", || {
        acpmux
            .summary(session)
            .filter(|s| !s["turn"].is_object() && s["queued"].as_u64().unwrap_or(0) == 0)
            .map(|_| ())
    });
}

/// One timed move: the command's JSON and its wall time.
fn timed(command: &mut Command, what: &str) -> (Value, u128) {
    let start = Instant::now();
    let (ok, answer) = run_json(command);
    let ms = start.elapsed().as_millis();
    assert!(ok && answer["ok"] == json!(true), "{what}: {answer}");
    (answer, ms)
}

/// One iteration's numbers.
#[derive(Default)]
struct Sample {
    seed_push_ms: u128,
    out_move_ms: u128,
    out_ms: u128,
    out_usable_ms: u128,
    back_ms: u128,
    prepull_ms: u128,
    back_usable_ms: u128,
    roundtrip_ms: u128,
    push: Value,
    out: Value,
    back: Value,
}

/// p50, p95 (nearest rank) and max of `values`.
fn stats(values: &[u128]) -> Value {
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    let rank = |p: f64| {
        let i = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
        sorted[i - 1]
    };
    json!({"p50": rank(0.50), "p95": rank(0.95), "max": sorted.last().copied().unwrap_or(0)})
}

/// Per-phase stats over every sample's move result `pick`.
fn phase_stats(samples: &[Sample], pick: impl Fn(&Sample) -> &Value) -> Value {
    let mut by_phase: BTreeMap<String, Vec<u128>> = BTreeMap::new();
    for sample in samples {
        if let Some(phases) = pick(sample)["phases"].as_object() {
            for (name, ms) in phases {
                by_phase.entry(name.clone()).or_default().push(ms.as_u64().unwrap_or(0).into());
            }
        }
    }
    Value::Object(by_phase.into_iter().map(|(k, v)| (k, stats(&v))).collect::<Map<_, _>>())
}

/// One sync's sub-phases (`cmux link`'s `link::spans`: `{"spans": {name: {"ms","n"}}, "remote":
/// [{"op", "timings": {"job_ms", "phases", "git"}}]}`) as name -> (ms, runs); a machine job's
/// as `<op> job`, `<op> phase <name>` and `<op> git <name>`.
fn flat_spans(sync: &Value) -> BTreeMap<String, (u128, u128)> {
    let mut flat: BTreeMap<String, (u128, u128)> = BTreeMap::new();
    let mut add = |name: String, ms: &Value, n: u128| {
        let entry = flat.entry(name).or_default();
        entry.0 += u128::from(ms.as_u64().unwrap_or(0));
        entry.1 += n;
    };
    for (name, span) in sync["spans"].as_object().into_iter().flatten() {
        add(name.clone(), &span["ms"], span["n"].as_u64().unwrap_or(0).into());
    }
    for job in sync["remote"].as_array().into_iter().flatten() {
        let op = job["op"].as_str().unwrap_or("?");
        let timings = &job["timings"];
        add(format!("{op} job"), &timings["job_ms"], 1);
        for (name, ms) in timings["phases"].as_object().into_iter().flatten() {
            add(format!("{op} phase {name}"), ms, 1);
        }
        for (name, run) in timings["git"].as_object().into_iter().flatten() {
            add(format!("{op} {name}"), &run["ms"], run["n"].as_u64().unwrap_or(0).into());
        }
    }
    flat
}

/// Per-sub-phase ms stats (and the median run count `n`) over every sample's sync `pick`.
fn span_stats(samples: &[Sample], pick: impl Fn(&Sample) -> &Value) -> Value {
    let mut by_name: BTreeMap<String, (Vec<u128>, Vec<u128>)> = BTreeMap::new();
    for sample in samples {
        for (name, (ms, n)) in flat_spans(pick(sample)) {
            let entry = by_name.entry(name).or_default();
            entry.0.push(ms);
            entry.1.push(n);
        }
    }
    let stats = by_name.into_iter().map(|(name, (ms, n))| {
        let mut row = stats(&ms);
        row["n"] = stats(&n)["p50"].clone();
        (name, row)
    });
    Value::Object(stats.collect::<Map<_, _>>())
}

#[test]
#[ignore = "bench: run with --ignored --nocapture (OFFLOAD_BENCH_ITERS, OFFLOAD_BENCH_HISTORY_KB)"]
fn offload_roundtrip_bench_moves_a_running_chat_to_a_cloud_vm_and_back() {
    let iters = env_u64("OFFLOAD_BENCH_ITERS", 10).max(1);
    let prepull = env_u64("OFFLOAD_BENCH_PREPULL", 0) == 1;
    let history_kb = env_u64("OFFLOAD_BENCH_HISTORY_KB", 0);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("orb-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let github = root.join("github");
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-offload-roundtrip-bench".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let mut mac_acpmux = mac.acpmux();
    let mut vm_acpmux = vm.acpmux();
    let mac_state = mac.dir.join("state");
    let mut samples = Vec::new();

    for iter in 0..iters {
        let name = format!("app{iter}");
        let repo = dirty_repo(&mac.home(), &github, &name);
        let synced = vm.home().join("work").join(&name);
        // Bring Back Local's guard on the Mac: the person trusted the folder before it moved.
        mac_acpmux.call("acp.trust.set", json!({"cwd": repo, "level": "trusted"}));
        let session = chat_on_mac(&mut mac_acpmux, &repo, iter, history_kb);
        let surface = bound_agent_tab(&mac, &session);
        fs::write(repo.join("src/turn.txt"), "written by the running turn\n").unwrap();

        // Out: Move to Cloud.
        let t0 = Instant::now();
        let (push, seed_push_ms) = timed(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", &mac_state)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "seed", "push", "--socket"])
                .arg(&vm.socket)
                .arg(&repo)
                .arg(&synced),
            "seed push",
        );
        let (out, out_move_ms) = timed(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", &mac_state)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "agent", "move", "--from-socket"])
                .arg(&mac.socket)
                .args(["--surface", &surface.to_string(), "--to-socket"])
                .arg(&vm.socket)
                .arg("--cwd")
                .arg(&synced)
                .arg("--interrupt")
                .args(["--vm-kind", "owner"])
                .args(["--sync", "seed", "--sync-socket"])
                .arg(&vm.socket)
                .arg("--sync-local")
                .arg(&repo)
                .arg("--sync-remote")
                .arg(&synced)
                .arg("--state-dir")
                .arg(root.join("pump-out")),
            "move to the VM",
        );
        let out_ms = t0.elapsed().as_millis();
        let landed = wait_usable(&mut vm_acpmux, &session, 1, "the chat usable on the VM");
        let out_usable_ms = t0.elapsed().as_millis() - out_ms;
        assert!(
            landed
                .iter()
                .any(|e| e["kind"] == "user_message"
                    && e["msg"]["text"] == json!("hello from the mac")),
            "the history did not land on the VM"
        );
        assert_eq!(
            fs::read_to_string(synced.join("src/turn.txt")).unwrap(),
            "written by the running turn\n"
        );

        // Not timed: new work for the chat on the VM, as the person gives it there.
        settled(&mut vm_acpmux, &session);
        fs::write(synced.join("src/vm.txt"), "written on the vm\n").unwrap();
        let vm_surface = bound_agent_tab(&vm, &session);
        running_turn_and_queue(&mut vm_acpmux, &session, &format!("p{iter}-back"));

        // The app's pre-freeze pull (`bringBackPull`), then a write it missed.
        let prepull_ms = if prepull {
            let (_, ms) = timed(
                Command::new(bin())
                    .env("CMUX_TUI_STATE_DIR", &mac_state)
                    .env("GIT_CONFIG_GLOBAL", "/dev/null")
                    .args(["link", "seed", "pull", "--socket"])
                    .arg(&vm.socket)
                    .arg(&repo)
                    .arg(&synced)
                    .arg("--or-copy"),
                "the pre-freeze pull",
            );
            assert_eq!(fs::read_to_string(repo.join("src/vm.txt")).unwrap(), "written on the vm\n");
            fs::write(synced.join("src/after-pull.txt"), format!("after the first pull {iter}\n"))
                .unwrap();
            ms
        } else {
            0
        };

        // Back: Bring Back Local.
        let t1 = Instant::now();
        let (back, back_ms) = timed(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", &mac_state)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "agent", "move", "--from-socket"])
                .arg(&vm.socket)
                .args(["--surface", &vm_surface.to_string(), "--to-socket"])
                .arg(&mac.socket)
                .arg("--cwd")
                .arg(&repo)
                .arg("--interrupt")
                .args(["--sync", "pull", "--sync-socket"])
                .arg(&vm.socket)
                .arg("--sync-local")
                .arg(&repo)
                .arg("--sync-remote")
                .arg(&synced)
                .arg("--state-dir")
                .arg(root.join("pump-back")),
            "move back to the Mac",
        );
        // Both continuations: the one from the VM's log and the new one here.
        wait_usable(&mut mac_acpmux, &session, 2, "the chat usable on the Mac");
        let back_usable_ms = t1.elapsed().as_millis() - back_ms;
        assert_eq!(fs::read_to_string(repo.join("src/vm.txt")).unwrap(), "written on the vm\n");
        if prepull {
            // The frozen pull still brings what the VM wrote after the first pull.
            assert_eq!(
                fs::read_to_string(repo.join("src/after-pull.txt")).unwrap(),
                format!("after the first pull {iter}\n")
            );
        }
        settled(&mut mac_acpmux, &session);

        let roundtrip_ms = out_ms + out_usable_ms + back_ms + back_usable_ms;
        eprintln!(
            "offload bench iter {iter}: out {out_ms} (+{out_usable_ms} usable) back {back_ms} \
             (+{back_usable_ms} usable) roundtrip {roundtrip_ms} ms; out {out} back {back}"
        );
        samples.push(Sample {
            seed_push_ms,
            out_move_ms,
            out_ms,
            out_usable_ms,
            back_ms,
            prepull_ms,
            back_usable_ms,
            roundtrip_ms,
            push,
            out,
            back,
        });
    }

    let col = |f: fn(&Sample) -> u128| samples.iter().map(f).collect::<Vec<_>>();
    let field = |pick: fn(&Sample) -> &Value, key: &'static str| {
        samples.iter().map(|s| pick(s)[key].as_u64().unwrap_or(0).into()).collect::<Vec<u128>>()
    };
    let roundtrip = stats(&col(|s| s.roundtrip_ms));
    let report = json!({
        // The binaries `cargo test` built: the dev profile (opt-level 1) unless `--release`.
        "profile": if cfg!(debug_assertions) { "dev" } else { "release" },
        "git_start_ms": git_start_ms(),
        "iters": iters,
        "history_kb": history_kb,
        "offload_roundtrip_p50_ms": roundtrip["p50"],
        "offload_roundtrip_p95_ms": roundtrip["p95"],
        "roundtrip_ms": roundtrip,
        "out_ms": stats(&col(|s| s.out_ms)),
        "out_seed_push_ms": stats(&col(|s| s.seed_push_ms)),
        "out_move_ms": stats(&col(|s| s.out_move_ms)),
        "out_usable_ms": stats(&col(|s| s.out_usable_ms)),
        "out_frozen_ms": stats(&field(|s| &s.out, "frozen_ms")),
        "out_bytes": stats(&field(|s| &s.out, "bytes")),
        "out_pages": stats(&field(|s| &s.out, "pages")),
        "out_phases": phase_stats(&samples, |s| &s.out),
        "out_seed_push_spans": span_stats(&samples, |s| &s.push["sync_phases"]),
        "out_frozen_sync_spans": span_stats(&samples, |s| &s.out["frozen_sync_phases"]),
        "prepull": prepull,
        "back_ms": stats(&col(|s| s.back_ms)),
        "back_prepull_ms": stats(&col(|s| s.prepull_ms)),
        "back_with_prepull_ms": stats(&col(|s| s.prepull_ms + s.back_ms)),
        "back_usable_ms": stats(&col(|s| s.back_usable_ms)),
        "back_frozen_ms": stats(&field(|s| &s.back, "frozen_ms")),
        "back_bytes": stats(&field(|s| &s.back, "bytes")),
        "back_pages": stats(&field(|s| &s.back, "pages")),
        "back_phases": phase_stats(&samples, |s| &s.back),
        "back_frozen_sync_spans": span_stats(&samples, |s| &s.back["frozen_sync_phases"]),
    });
    println!("OFFLOAD_BENCH {report}");
    if let Ok(path) = std::env::var("OFFLOAD_BENCH_OUT")
        && !path.is_empty()
    {
        fs::write(&path, format!("{report}\n")).unwrap();
    }
}
