//! Deterministic simulation of the acpmux daemon (HQ#6740, point 1): the real hub, protocol
//! handler, prompt ledger, queue and restart restore run on a simulated runtime (turmoil) with a
//! seeded RNG, simulated time, a simulated network between the app and the daemon, an in-process
//! agent replaying a recorded turn, and a simulated disk. Each seed picks a schedule of prompts
//! and steers and a schedule of faults (message delays, a one-way partition where the daemon
//! looks online but nothing comes back, daemon crashes at any step), then checks the invariants
//! in `sim/invariants.rs`. An hour of daemon behaviour takes milliseconds: nothing waits.
//!
//! Run (from `cmux-tui/`):
//!
//! ```text
//! cargo test -p acpmux --features sim --test sim                       # SIM_SEEDS seeds (default 64)
//! SIM_SEEDS=5000 SIM_SEED_BASE=1000000 cargo test -p acpmux --features sim --test sim
//! SIM_SEED=42 cargo test -p acpmux --features sim --test sim -- --nocapture   # replay one seed, with its trace
//! ```
//!
//! A failing seed prints the command that replays it.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents only: the simulation's agent runs in process (`acpmux::sim_agent`), and
// `python3` is the one tool its harness profile names. SIM_* pick the seeds (module text).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "SIM_SEED",
    "SIM_SEEDS",
    "SIM_SEED_BASE",
    "SIM_FAULTS",
    "SIM_RESEND",
    "SIM_KNOWN_GAPS",
    "SIM_LEAK_TRACE",
]);

#[path = "sim/agent.rs"]
mod agent;
#[path = "sim/app.rs"]
mod app;
#[path = "sim/invariants.rs"]
mod invariants;
#[path = "sim/plan.rs"]
mod plan;
#[path = "sim/rng.rs"]
mod rng;
#[path = "sim/store.rs"]
mod store;
#[path = "sim/world.rs"]
mod world;

use std::collections::BTreeMap;
use world::{Faults, Options};

/// The most seeds one test process runs (see the assert in `seeds_hold_the_delivery_invariants`).
const SEEDS_PER_PROCESS: u64 = 500;

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok())
}

/// The options SIM_FAULTS and SIM_RESEND pick (both on by default).
fn options() -> Options {
    // Crashes and the network's faults by default; SIM_FAULTS=crash,power,network (or all, none)
    // picks others. A power loss is off by default: see `invariants.rs`, KNOWN_GAPS.
    let faults = std::env::var("SIM_FAULTS").map_or(Faults::standard(), |s| Faults::parse(&s));
    // The app's retry carries `_meta.acpmux.resend`, as the Mac's prompt journal sends it. Off,
    // the retry is a bare resend of the same id, as the web pane sends it.
    let resend = !matches!(std::env::var("SIM_RESEND").as_deref(), Ok("0"));
    Options { faults, resend, power_drops_unflushed: true }
}

fn replay_command(seed: u64, opts: &Options) -> String {
    let mut env = format!("SIM_SEED={seed}");
    if !opts.resend {
        env.push_str(" SIM_RESEND=0");
    }
    if opts.faults != Faults::standard() {
        let k = opts.faults.0;
        let kinds: Vec<&str> =
            [(k.crash, "crash"), (k.power_loss, "power"), (k.network, "network")]
                .into_iter()
                .filter_map(|(on, name)| on.then_some(name))
                .collect();
        env.push_str(&format!(
            " SIM_FAULTS={}",
            if kinds.is_empty() { "none".into() } else { kinds.join(",") }
        ));
    }
    format!("(cd cmux-tui && {env} cargo test -p acpmux --features sim --test sim -- --nocapture)")
}

/// Every seed of the run, or the one SIM_SEED names, with its trace.
#[test]
fn seeds_hold_the_delivery_invariants() {
    let opts = options();
    if let Some(seed) = env_u64("SIM_SEED") {
        let run = world::run(seed, &opts);
        eprintln!("{}", run.trace.join("\n"));
        // The chat's log as the faulty run left it on disk, one record a line.
        for (chat, records) in &run.faulty.log {
            eprintln!("log of {chat}:");
            for r in records {
                let msg = r.msg.to_string();
                eprintln!(
                    "  {:>4} {} {} {}",
                    r.seq,
                    r.dir,
                    r.kind,
                    msg.chars().take(160).collect::<String>()
                );
            }
        }
        if let Err(failure) = invariants::check(&run) {
            let known = invariants::known_gaps_of(seed, &opts);
            let known = if known.is_empty() {
                String::new()
            } else {
                format!("\nknown gap (it holds without it): {}", known.join(" + "))
            };
            panic!("seed {seed}: {failure}{known}\nreplay: {}", replay_command(seed, &opts));
        }
        eprintln!(
            "seed {seed}: every invariant holds ({} simulated, {} faults, {} daemon restarts)",
            world::human(run.simulated),
            run.plan.faults.len(),
            run.faulty.restarts
        );
        return;
    }
    let seeds = env_u64("SIM_SEEDS").unwrap_or(64);
    // Every hub a seed builds outlives its simulation (about 13 MB and 2 fds a seed, one
    // `acpmux-audit` thread a hub; SIM_LEAK_TRACE=1 shows it): 4000 seeds in one process reached
    // 31 GB and filled a pool host's disk with swap (acpmux-sim-sweep run 45768539377). Until
    // what keeps them is found, a process runs at most this many and the sweep runs chunks.
    assert!(
        seeds <= SEEDS_PER_PROCESS,
        "SIM_SEEDS={seeds} is over {SEEDS_PER_PROCESS} in one process: run chunks of at most \
         that many with SIM_SEED_BASE offsets (acpmux-sim-sweep.yml), each seed's hubs stay alive"
    );
    let base = env_u64("SIM_SEED_BASE").unwrap_or(0);
    let started = std::time::Instant::now();
    let mut simulated = std::time::Duration::ZERO;
    let mut failures = Vec::new();
    // A known-gap leg (SIM_KNOWN_GAPS=1, acpmux-sim-sweep.yml) counts the seeds that fail only
    // by a known gap (they hold once its cause is taken away) instead of failing on them. Every
    // other run fails on them, whatever SIM_FAULTS and SIM_RESEND pick.
    let known_gaps = matches!(std::env::var("SIM_KNOWN_GAPS").as_deref(), Ok("1"));
    // Seeds that fail only by a known gap: they hold once its cause is taken away.
    let mut shown: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    let trace_leaks = std::env::var_os("SIM_LEAK_TRACE").is_some();
    for seed in base..base + seeds {
        let run = world::run(seed, &opts);
        if trace_leaks {
            let (alive, built) = world::left_alive();
            let count = |d: &str| std::fs::read_dir(d).map_or(0, |r| r.count());
            let mut names: BTreeMap<String, usize> = BTreeMap::new();
            if let Ok(tasks) = std::fs::read_dir("/proc/self/task") {
                for t in tasks.flatten() {
                    let n = std::fs::read_to_string(t.path().join("comm")).unwrap_or_default();
                    *names.entry(n.trim().to_owned()).or_default() += 1;
                }
            }
            let rss = std::fs::read_to_string("/proc/self/status")
                .unwrap_or_default()
                .lines()
                .find(|l| l.starts_with("VmRSS"))
                .map(str::to_owned)
                .unwrap_or_default();
            eprintln!(
                "leak seed {seed}: hubs alive {alive}/{built} fds {} {rss} threads {names:?}",
                count("/proc/self/fd")
            );
        }
        simulated += run.simulated;
        if let Err(failure) = invariants::check(&run) {
            let known =
                if known_gaps { invariants::known_gaps_of(seed, &opts) } else { Vec::new() };
            if known.is_empty() {
                failures.push(format!(
                    "seed {seed}: {failure}\n  replay: {}",
                    replay_command(seed, &opts)
                ));
            } else {
                shown.entry(known.join(" + ")).or_default().push(seed);
            }
        }
    }
    let wall = started.elapsed();
    eprintln!(
        "sim: {seeds} seeds in {:.1} s ({:.0} seeds/min), {} simulated ({:.0}x real time)",
        wall.as_secs_f64(),
        seeds as f64 / wall.as_secs_f64().max(1e-9) * 60.0,
        world::human(simulated),
        simulated.as_secs_f64() / wall.as_secs_f64().max(1e-9),
    );
    eprintln!("sim: not checked yet: {}", invariants::NOT_CHECKED.join("; "));
    for (gap, hit) in &shown {
        eprintln!(
            "sim: known gap, not a failure (sim/invariants.rs KNOWN_GAPS): {gap}: {} of {seeds} \
             seeds, each holds without it; first: {}",
            hit.len(),
            replay_command(hit[0], &opts)
        );
    }
    assert!(
        failures.is_empty(),
        "{} of {seeds} seeds failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// Seeds a sweep found failing under the standard faults, kept once fixed: what each broke,
/// and why.
const FOUND: &[u64] = &[
    // Sweeps 266 and 300: a resumed chat ended with a turn still open. A partition cut the app's
    // connection, so it missed the daemon's next crash, read the quiet as settled and left
    // while the restart's continuation still ran (app.rs, `chat_settled`).
    2663130, 3000166,
];

/// Every seed in [`FOUND`] holds.
#[test]
fn seeds_the_sweep_found_hold() {
    let opts = Options { faults: Faults::standard(), resend: true, power_drops_unflushed: true };
    let failed: Vec<String> = FOUND
        .iter()
        .filter_map(|&seed| {
            invariants::check(&world::run(seed, &opts))
                .err()
                .map(|e| format!("seed {seed}: {e}\n  replay: {}", replay_command(seed, &opts)))
        })
        .collect();
    assert!(failed.is_empty(), "{}", failed.join("\n"));
}

/// What a seed decides, which a replay must repeat: the verdict, the faults as they were
/// applied, and each prompt's outcome and how often it was applied and logged. The order in
/// which back-to-back requests are admitted is not in it: the daemon admits each on its own
/// task and part of that path runs on tokio's blocking pool (real threads), so a burst of
/// resends can queue in a different order from run to run, as it can in production
/// (manaflow-ai/cmux#34586).
fn fingerprint(run: &world::Run) -> String {
    let faults: Vec<&String> = run.trace.iter().filter(|l| l.contains(" sim: ")).collect();
    let mut prompts: Vec<String> = run
        .faulty
        .app
        .items
        .iter()
        .map(|(s, i)| format!("{} {:?} accepted={}", s.prompt_id, i.outcome, i.accepted))
        .collect();
    prompts.sort();
    format!(
        "{:?}\n{faults:#?}\n{prompts:#?}\nrestarts {}",
        invariants::check(run),
        run.faulty.restarts
    )
}

/// The same seed twice decides the same: what makes a failing seed a replay.
#[test]
fn a_seed_replays_exactly() {
    let opts = options();
    for seed in [1, 7, 23] {
        let (a, b) = (fingerprint(&world::run(seed, &opts)), fingerprint(&world::run(seed, &opts)));
        assert_eq!(a, b, "seed {seed} ran two ways: the simulation lost its determinism");
    }
}

/// One way to break a run that a named invariant must catch.
struct Mutation {
    invariant: &'static str,
    what: &'static str,
    apply: fn(&mut world::Run),
}

/// For each invariant, a run broken the way it guards against. An invariant no mutation turns
/// red could pass on anything, so a green sweep would say nothing about it: every entry of
/// [`invariants::INVARIANTS`] needs one here.
const MUTATIONS: &[Mutation] = &[
    Mutation {
        invariant: "the run finished",
        what: "the faulty run stopped with an error",
        apply: |run| run.faulty.error = Some("mutation: stopped".into()),
    },
    Mutation {
        invariant: "no prompt or steer is lost",
        what: "the agent never got the first send",
        apply: |run| {
            let text = run.faulty.app.items[0].0.text.clone();
            run.faulty.given.retain(|g| g.text != text);
        },
    },
    Mutation {
        invariant: "no prompt or steer is applied twice",
        what: "the agent got the first prompt it was given twice",
        apply: |run| {
            let g = run.faulty.given[0].clone();
            run.faulty.given.push(g);
        },
    },
    Mutation {
        invariant: "event seq has no gaps",
        what: "a chat's last record skips a seq",
        apply: |run| {
            let records = run.faulty.log.values_mut().next().expect("a chat log");
            records.last_mut().expect("a record").seq += 1;
        },
    },
    Mutation {
        invariant: "a resumed chat ends as an uninterrupted one",
        what: "the run without faults applied a prompt once more",
        apply: |run| {
            let calm = run.uninterrupted.as_mut().expect("an uninterrupted run");
            let g = calm.given[0].clone();
            calm.given.push(g);
        },
    },
];

/// Each invariant fails on a run broken the way it guards against, and holds on the same run
/// unbroken (the checker's own mutation test: a check that never fails proves nothing).
#[test]
fn every_invariant_fails_on_its_mutation() {
    for inv in invariants::INVARIANTS {
        assert!(
            MUTATIONS.iter().any(|m| m.invariant == inv.name),
            "invariant \"{}\" has no mutation in MUTATIONS: add a broken run it must catch",
            inv.name
        );
    }
    let opts = Options { faults: Faults::standard(), resend: true, power_drops_unflushed: true };
    // A seed every mutation can apply to: it holds, had faults (so it has a run without them),
    // and the agent was given something and the log has records.
    let usable = |run: &world::Run| {
        invariants::check(run).is_ok()
            && run.uninterrupted.as_ref().is_some_and(|c| !c.given.is_empty())
            && !run.faulty.app.items.is_empty()
            && !run.faulty.given.is_empty()
            && run.faulty.log.values().next().is_some_and(|r| !r.is_empty())
    };
    let seed = (0..64)
        .find(|&s| usable(&world::run(s, &opts)))
        .expect("no seed in 0..64 holds with faults, sends and a log to mutate");
    for m in MUTATIONS {
        let inv = invariants::INVARIANTS
            .iter()
            .find(|i| i.name == m.invariant)
            .unwrap_or_else(|| panic!("mutation names no invariant: {}", m.invariant));
        let mut run = world::run(seed, &opts);
        assert!((inv.check)(&run).is_ok(), "seed {seed}: \"{}\" fails unmutated", inv.name);
        (m.apply)(&mut run);
        assert!(
            (inv.check)(&run).is_err(),
            "seed {seed}: \"{}\" still holds after the mutation \"{}\": the check has no teeth",
            inv.name,
            m.what
        );
    }
}
