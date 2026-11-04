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

use world::{Faults, Options};

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
    Options { faults, resend }
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
            panic!("seed {seed}: {failure}\nreplay: {}", replay_command(seed, &opts));
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
    let base = env_u64("SIM_SEED_BASE").unwrap_or(0);
    let started = std::time::Instant::now();
    let mut simulated = std::time::Duration::ZERO;
    let mut failures = Vec::new();
    for seed in base..base + seeds {
        let run = world::run(seed, &opts);
        simulated += run.simulated;
        if let Err(failure) = invariants::check(&run) {
            failures
                .push(format!("seed {seed}: {failure}\n  replay: {}", replay_command(seed, &opts)));
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
    let gaps = if opts.faults != Faults::standard() || !opts.resend {
        format!(
            "\nknown gaps these options can show (sim/invariants.rs): {}",
            invariants::KNOWN_GAPS.join("; ")
        )
    } else {
        String::new()
    };
    assert!(
        failures.is_empty(),
        "{} of {seeds} seeds failed:\n{}{gaps}",
        failures.len(),
        failures.join("\n")
    );
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
