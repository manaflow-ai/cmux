//! `cmux vm pool VERB` (and the `cmux-vm-pool` binary): ls, up, pause, watch, schedule.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use futures_util::future::join_all;
use serde_json::{Value, json};

use crate::freestyle::Freestyle;
use crate::gce::Gce;
use crate::github::{self, GitHub};
use crate::http;
use crate::load::{self, Load};
use crate::model::{Machine, Provider, Runner, now_ms};
use crate::plan;
use crate::schedule::{Demand, Policy, Scheduler, feed_queued, parse_demand};
use crate::watch::Tracker;

pub const HELP: &str = "\
usage: cmux vm pool <verb> [options]

The CI runner pool on Freestyle and GCP: persistent machines that keep their
disks, caches and registered runners. These verbs only resume and pause them;
nothing here deletes a machine.

  ls                     list pool machines (and their runners, with GH_TOKEN)
  up N                   resume paused machines until they carry N runners,
                         Freestyle first, all calls at once; with GH_TOKEN,
                         wait until N of their runners are online in GitHub
  pause                  pause (Freestyle) or suspend (GCE) machines whose
                         runners are all idle: --names FILE, or --idle with GH_TOKEN
  watch                  time runners coming online in GitHub
  load                   measured CPU and RAM per machine, and the pool's CPU p50/p90
                         (GCE Cloud Monitoring; the controller's pool telemetry with --load-url)
  schedule               the loop: queued jobs resume machines, idle ones pause

Options:
  --provider freestyle|gcp|all   (default: every provider with a credential)
  --json                         one JSON object on stdout
  up:       --at UNIX_MS (start at that wall-clock time)  --timeout SECS (120)
            --no-watch  --names FILE (resume exactly these machines, by machine
            or runner name, instead of the pick for N)
  pause:    --names FILE (runner names allowed to pause)  --idle  --max K
  watch:    --since UNIX_MS  --count N  --names FILE  --timeout SECS
            --idle-only --names-out FILE [--prefix P]... [--max N]
  schedule: --feed URL --repo OWNER/NAME... --idle-minutes M (10)
            --load-url URL (the controller's GET /v1/pool/telemetry: scale up when
            work waits and every VM is at 90% CPU or RAM; pause under 20% CPU)
            --demand-file PATH (one line `vcpu=N mem_gib=M`, reread each tick;
            resumes by vCPU instead of by queued job count)
            --keep-idle K (4) --tick SECS (5) [--once]
            The idle pause takes only machines that opted in (Freestyle metadata
            cmux_schedule=pause, GCE label cmux-schedule=pause) or match
            --pause-prefix P; the persistent pools stay running by default.
  GitHub:   --org ORG (manaflow-ai) --group GROUP (cmux-fleet-linux)
  GCP:      --project P (manaflow-437420)
  Pool:     --label L (the jobs runs-on label, cmux-linux)
            --freestyle-purpose P (metadata purpose, freestyle-pool)
            --gce-label V (label purpose=V, cmux-runner-pool)
            --prefix P (runner-name prefix, repeatable)

Credentials: FREESTYLE_API_KEY; CLOUDSDK_AUTH_ACCESS_TOKEN, the GCE metadata
server or gcloud; GH_TOKEN.
";

#[derive(Debug, Default)]
struct Args {
    verb: String,
    count: Option<u32>,
    providers: Option<Vec<Provider>>,
    json: bool,
    at_ms: Option<u64>,
    since_ms: Option<u64>,
    timeout_s: u64,
    no_watch: bool,
    names: Option<String>,
    names_out: Option<String>,
    idle: bool,
    idle_only: bool,
    max: Option<usize>,
    prefixes: Vec<String>,
    org: String,
    group: String,
    project: Option<String>,
    feed: Option<String>,
    repos: Vec<String>,
    idle_minutes: u64,
    keep_idle: u32,
    pause_prefixes: Vec<String>,
    tick_s: u64,
    demand_file: Option<String>,
    load_url: Option<String>,
    once: bool,
    interval_ms: u64,
    label: String,
    freestyle_purpose: Option<String>,
    gce_label: Option<String>,
}

fn parse(words: &[String]) -> Result<Args, String> {
    let mut args = Args {
        timeout_s: 120,
        org: github::DEFAULT_ORG.to_owned(),
        group: github::DEFAULT_GROUP.to_owned(),
        idle_minutes: 10,
        keep_idle: 4,
        tick_s: 5,
        interval_ms: 500,
        label: Policy::default().label,
        ..Args::default()
    };
    let mut it = words.iter().peekable();
    let mut positional = Vec::new();
    while let Some(word) = it.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = |name: &str| -> Result<String, String> {
            inline
                .clone()
                .or_else(|| it.next().cloned())
                .ok_or_else(|| format!("{name} needs a value"))
        };
        let number = |name: &str, v: String| {
            v.parse::<u64>().map_err(|_| format!("{name}: not a number: {v}"))
        };
        match flag {
            "--json" => args.json = true,
            "--no-watch" => args.no_watch = true,
            "--idle" => args.idle = true,
            "--idle-only" => args.idle_only = true,
            "--once" => args.once = true,
            "--provider" => {
                let v = value(flag)?;
                args.providers = Some(if v == "all" {
                    vec![Provider::Freestyle, Provider::Gcp]
                } else {
                    v.split(',')
                        .map(|p| {
                            Provider::parse(p).ok_or_else(|| format!("--provider: unknown {p}"))
                        })
                        .collect::<Result<_, _>>()?
                });
            }
            "--count" => {
                args.count = Some(
                    u32::try_from(number(flag, value(flag)?)?).map_err(|_| "--count too big")?,
                );
            }
            "--at" => args.at_ms = Some(number(flag, value(flag)?)?),
            "--since" => args.since_ms = Some(number(flag, value(flag)?)?),
            "--timeout" => args.timeout_s = number(flag, value(flag)?)?,
            "--names" => args.names = Some(value(flag)?),
            "--names-out" | "--idle-out" => {
                args.names_out = Some(value(flag)?);
                args.idle_only |= flag == "--idle-out";
            }
            "--max" => {
                args.max = Some(
                    usize::try_from(number(flag, value(flag)?)?).map_err(|_| "--max too big")?,
                );
            }
            "--prefix" => args.prefixes.push(value(flag)?),
            "--pause-prefix" => args.pause_prefixes.push(value(flag)?),
            "--org" => args.org = value(flag)?,
            "--group" => args.group = value(flag)?,
            "--project" => args.project = Some(value(flag)?),
            "--feed" => args.feed = Some(value(flag)?),
            "--repo" => args.repos.push(value(flag)?),
            "--idle-minutes" => args.idle_minutes = number(flag, value(flag)?)?,
            "--keep-idle" => {
                args.keep_idle = u32::try_from(number(flag, value(flag)?)?)
                    .map_err(|_| "--keep-idle too big")?;
            }
            "--tick" => args.tick_s = number(flag, value(flag)?)?.max(1),
            "--demand-file" => args.demand_file = Some(value(flag)?),
            "--load-url" => args.load_url = Some(value(flag)?),
            "--interval-ms" => args.interval_ms = number(flag, value(flag)?)?.max(100),
            "--label" => args.label = value(flag)?,
            "--freestyle-purpose" => args.freestyle_purpose = Some(value(flag)?),
            "--gce-label" => args.gce_label = Some(value(flag)?),
            "-h" | "--help" => args.verb = "help".to_owned(),
            other if other.starts_with('-') => return Err(format!("unknown option {other}")),
            other => positional.push(other.to_owned()),
        }
    }
    let mut positional = positional.into_iter();
    if args.verb.is_empty() {
        args.verb = positional.next().unwrap_or_else(|| "help".to_owned());
    }
    if let Some(n) = positional.next() {
        args.count = Some(n.parse().map_err(|_| format!("not a count: {n}"))?);
    }
    if args.prefixes.is_empty() {
        args.prefixes = Policy::default().prefixes;
    }
    Ok(args)
}

/// The providers this run talks to.
struct Pool {
    client: reqwest::Client,
    freestyle: Option<Freestyle>,
    gce: Option<Gce>,
    github: Option<GitHub>,
}

impl Pool {
    async fn open(
        args: &Args,
        env: &dyn Fn(&str) -> Option<String>,
        need_github: bool,
    ) -> Result<Self, String> {
        let client = http::client().map_err(|e| e.0)?;
        let wants = |p: Provider| args.providers.as_ref().is_none_or(|ps| ps.contains(&p));
        let mut freestyle =
            if wants(Provider::Freestyle) { Freestyle::from_env(env) } else { None };
        let mut gce = if wants(Provider::Gcp) {
            Gce::from_env(&client, env, args.project.clone()).await
        } else {
            None
        };
        // Another org's pool: its own Freestyle metadata purpose and GCE label.
        if let (Some(f), Some(purpose)) = (freestyle.as_mut(), &args.freestyle_purpose) {
            f.purpose.clone_from(purpose);
        }
        if let (Some(g), Some(label)) = (gce.as_mut(), &args.gce_label) {
            g.label.clone_from(label);
        }
        if let Some(asked) = &args.providers {
            for p in asked {
                let missing = match p {
                    Provider::Freestyle => freestyle.is_none(),
                    Provider::Gcp => gce.is_none(),
                };
                if missing {
                    return Err(format!(
                        "--provider {}: no credential (see `cmux vm pool --help`)",
                        p.as_str()
                    ));
                }
            }
        }
        let github = if need_github {
            GitHub::from_env(&client, env, &args.org, &args.group).await.map_err(|e| e.0)?
        } else {
            None
        };
        Ok(Self { client, freestyle, gce, github })
    }

    async fn machines(&self) -> Result<Vec<Machine>, String> {
        let fs = async {
            match &self.freestyle {
                Some(f) => f.list(&self.client).await,
                None => Ok(Vec::new()),
            }
        };
        let gc = async {
            match &self.gce {
                Some(g) => g.list(&self.client).await,
                None => Ok(Vec::new()),
            }
        };
        let (fs, gc) = futures_util::join!(fs, gc);
        let mut all = fs.map_err(|e| e.0)?;
        all.extend(gc.map_err(|e| e.0)?);
        Ok(all)
    }

    /// Machines from the providers that answered: one provider's failed list (an expired token, an outage)
    /// says so and leaves the other's machines scheduled. Their runners then have no machine and count as no
    /// capacity, so the failure can resume more, never pause more. `Err` only when every provider failed.
    async fn machines_partial(&self) -> Result<Vec<Machine>, String> {
        let fs = async {
            match &self.freestyle {
                Some(f) => {
                    Some(f.list(&self.client).await.map_err(|e| format!("Freestyle: {}", e.0)))
                }
                None => None,
            }
        };
        let gc = async {
            match &self.gce {
                Some(g) => Some(g.list(&self.client).await.map_err(|e| format!("GCE: {}", e.0))),
                None => None,
            }
        };
        let (fs, gc) = futures_util::join!(fs, gc);
        let mut all = Vec::new();
        let mut errors = Vec::new();
        let mut answered = false;
        for listed in [fs, gc].into_iter().flatten() {
            match listed {
                Ok(machines) => {
                    answered = true;
                    all.extend(machines);
                }
                Err(e) => errors.push(e),
            }
        }
        if !errors.is_empty() {
            if !answered {
                return Err(errors.join("; "));
            }
            eprintln!("cmux vm pool: schedule: {}; scheduling the rest", errors.join("; "));
        }
        Ok(all)
    }

    async fn roster(&self) -> Result<Vec<Runner>, String> {
        match &self.github {
            Some(g) => g.roster(&self.client).await.map_err(|e| e.0),
            None => Ok(Vec::new()),
        }
    }

    /// Measured load by machine name: GCE Cloud Monitoring CPU, then the controller's pool telemetry (CPU and
    /// RAM) over it. A source that fails is said on stderr and left out: no reading never means "full".
    async fn loads(&self, load_url: Option<&str>) -> HashMap<String, Load> {
        let gce = async {
            match &self.gce {
                Some(g) => load::gce_cpu(&self.client, &g.token, &g.project, &g.label, 300)
                    .await
                    .map_err(|e| e.0),
                None => Ok(HashMap::new()),
            }
        };
        let controller = async {
            match load_url {
                Some(url) => load::controller(&self.client, url).await,
                None => Ok(HashMap::new()),
            }
        };
        let (gce, controller) = futures_util::join!(gce, controller);
        let mut loads = gce.unwrap_or_else(|e| {
            eprintln!("cmux vm pool: GCE CPU: {e}");
            HashMap::new()
        });
        match controller {
            Ok(more) => loads.extend(more),
            Err(e) => eprintln!("cmux vm pool: pool telemetry: {e}"),
        }
        loads
    }

    async fn power_on(&self, machine: &Machine) -> Result<(), String> {
        match machine.provider {
            Provider::Freestyle => match &self.freestyle {
                Some(f) => f.start(&self.client, &machine.id).await.map_err(|e| e.0),
                None => Err("no Freestyle credential".to_owned()),
            },
            Provider::Gcp => match &self.gce {
                Some(g) => g.power_on(&self.client, machine).await.map_err(|e| e.0),
                None => Err("no GCP credential".to_owned()),
            },
        }
    }

    async fn pause(&self, machine: &Machine) -> Result<(), String> {
        match machine.provider {
            Provider::Freestyle => match &self.freestyle {
                Some(f) => f.pause(&self.client, &machine.id).await.map_err(|e| e.0),
                None => Err("no Freestyle credential".to_owned()),
            },
            Provider::Gcp => match &self.gce {
                Some(g) => g.suspend(&self.client, machine).await.map_err(|e| e.0),
                None => Err("no GCP credential".to_owned()),
            },
        }
    }

    /// Calls `op` on every machine at once; one JSON row per call with its latency.
    async fn all_at_once<'m, F, Fut>(
        &self,
        machines: &[&'m Machine],
        before_ms: u64,
        op: F,
    ) -> Vec<Value>
    where
        F: Fn(&'m Machine) -> Fut,
        Fut: Future<Output = Result<(), String>>,
    {
        let calls = machines.iter().map(|&m| {
            let fut = op(m);
            async move {
                let started = Instant::now();
                let result = fut.await;
                json!({
                    "provider": m.provider.as_str(),
                    "id": m.id,
                    "name": m.name,
                    "slots": m.slots,
                    "before": m.state,
                    "sent_after_ms": now_ms().saturating_sub(before_ms).saturating_sub(elapsed_ms(started)),
                    "call_ms": elapsed_ms(started),
                    "ok": result.is_ok(),
                    "error": result.err(),
                })
            }
        });
        join_all(calls).await
    }
}

fn elapsed_ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The vCPU in `--demand-file`, when it was written within `fresh_for` (a writer that stopped leaves a number
/// that would hold machines up, or keep them paused, for good).
fn read_demand(path: &str, fresh_for: Duration) -> Result<u64, String> {
    let age = std::fs::metadata(path)
        .and_then(|m| m.modified())
        .map_err(|e| e.to_string())?
        .elapsed()
        .unwrap_or_default();
    if age > fresh_for {
        return Err(format!("written {}s ago", age.as_secs()));
    }
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    parse_demand(&text).ok_or_else(|| "no `vcpu=N`".to_owned())
}

fn read_names(path: &str) -> Result<HashSet<String>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_owned)
        .collect())
}

async fn sleep_until(at_ms: u64) {
    let now = now_ms();
    if at_ms > now {
        tokio::time::sleep(Duration::from_millis(at_ms - now)).await;
    }
}

fn emit(out: &mut dyn std::io::Write, json: bool, value: &Value, text: &str) {
    let _ = if json { writeln!(out, "{value}") } else { write!(out, "{text}") };
}

/// Runs one `cmux vm pool` command; returns the exit code.
pub async fn run(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> i32 {
    if let [verb, rest @ ..] = words
        && verb == "runner"
    {
        return crate::runner_cli::run(rest, env, out).await;
    }
    let args = match parse(words) {
        Ok(args) => args,
        Err(message) => {
            eprintln!("cmux vm pool: {message}\n\n{HELP}");
            return 2;
        }
    };
    let result = match args.verb.as_str() {
        "help" => {
            let _ = write!(out, "{HELP}");
            Ok(())
        }
        "ls" | "list" => ls(&args, env, out).await,
        "up" => up(&args, env, out).await,
        "pause" => pause(&args, env, out).await,
        "watch" => watch(&args, env, out).await,
        "schedule" => schedule(&args, env, out).await,
        "load" => load(&args, env, out).await,
        other => Err(format!("unknown verb `{other}`\n\n{HELP}")),
    };
    match result {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("cmux vm pool: {message}");
            1
        }
    }
}

async fn ls(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    let pool = Pool::open(args, env, true).await?;
    let (machines, roster) = futures_util::join!(pool.machines(), pool.roster());
    let (machines, roster) = (machines?, roster?);
    let by = plan::runners_by_machine(&machines, &roster);
    let rows: Vec<Value> = machines
        .iter()
        .map(|m| {
            let mut row = m.to_json();
            let runners: Vec<Value> = by
                .get(&m.id)
                .map(|rs| {
                    rs.iter()
                        .map(|r| json!({"name": r.name, "online": r.online, "busy": r.busy}))
                        .collect()
                })
                .unwrap_or_default();
            put(&mut row, "runners", json!(runners));
            row
        })
        .collect();
    let mut text = String::new();
    for m in &machines {
        let online = by.get(&m.id).map_or(0, |rs| rs.iter().filter(|r| r.online).count());
        text.push_str(&format!(
            "{:<9} {:<40} {:<12} slots {} online {online}\n",
            m.provider.as_str(),
            m.name,
            m.state,
            m.slots
        ));
    }
    // Slots busy against jobs queued: the pool's size against its demand (`--feed` and `--repo` add queued).
    let mut totals = plan::totals(&machines, &roster);
    if let Some(feed) = &args.feed {
        put(
            &mut totals,
            "queued",
            json!(read_queued(&pool.client, feed, &args.repos, &args.label).await?),
        );
    }
    text.push_str(&format!("totals: {totals}\n"));
    emit(out, args.json, &json!({"machines": rows, "totals": totals}), &text);
    Ok(())
}

/// Queued jobs for `label` across `repos`, from the build controller's webhook feed.
async fn read_queued(
    client: &reqwest::Client,
    feed: &str,
    repos: &[String],
    label: &str,
) -> Result<u32, String> {
    let mut queued = 0u32;
    for repo in repos {
        let url = format!("{}/v1/github/actions?repo={repo}&recent=0", feed.trim_end_matches('/'));
        let body: Value = client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("{url}: {e}"))?
            .json()
            .await
            .map_err(|e| format!("{url}: {e}"))?;
        queued = queued.saturating_add(feed_queued(&body, label));
    }
    Ok(queued)
}

async fn up(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    // `--names FILE`: exactly the machines a plan named (machine or runner names), so what is resumed is what
    // is watched; else the pick for N.
    let named = args.names.as_deref().map(read_names).transpose()?;
    if args.count.is_none() && named.is_none() {
        return Err("up needs a count (`cmux vm pool up N`) or --names FILE".to_owned());
    }
    if let Some(at) = args.at_ms {
        sleep_until(at).await;
    }
    let t0 = now_ms();
    let started = Instant::now();
    let pool = Pool::open(args, env, !args.no_watch).await?;
    let (machines, roster) = futures_util::join!(pool.machines(), pool.roster());
    let (machines, roster) = (machines?, roster?);
    let listed_ms = elapsed_ms(started);
    let picked: Vec<&Machine> = match &named {
        Some(names) => machines
            .iter()
            .filter(|m| m.power.resumable())
            .filter(|m| names.contains(&m.name) || names.iter().any(|n| m.owns_runner(n)))
            .collect(),
        None => plan::pick_up(&machines, args.count.unwrap_or_default()),
    };
    let slots: u32 = picked.iter().map(|m| m.slots.max(1)).sum();
    let count = args.count.unwrap_or(slots);
    let calls = pool.all_at_once(&picked, t0, |m| pool.power_on(m)).await;
    let calls_done_ms = elapsed_ms(started);
    let mut result = json!({
        "t0_ms": t0,
        "count": count,
        "listed_ms": listed_ms,
        "picked": picked.len(),
        "picked_slots": slots,
        "calls_done_ms": calls_done_ms,
        "calls": calls,
    });
    let failed = calls.iter().filter(|c| c["ok"] != json!(true)).count();
    let mut text = format!(
        "resumed {} machine(s), {slots} runner slot(s), in {calls_done_ms} ms ({failed} failed)\n",
        picked.len()
    );
    let mut missed: Vec<String> = Vec::new();
    if pool.github.is_some() {
        let wanted = plan::wanted_runners(&picked, &roster);
        // N stays the target: a plan short of N is a failed run, not a smaller success.
        let target = usize::try_from(count).unwrap_or(usize::MAX);
        if wanted.len() < target {
            missed.push(format!(
                "the picked machines carry {} runner(s), fewer than {target}",
                wanted.len()
            ));
        }
        let mut tracker = Tracker::new(t0, Some(wanted));
        // The read before any resume call is the offline baseline.
        tracker.baseline(&roster);
        let deadline = started + Duration::from_secs(args.timeout_s);
        while tracker.online_count() < target && Instant::now() < deadline {
            let at = now_ms();
            if let Ok(roster) = pool.roster().await {
                tracker.observe(at, &roster);
            }
            tokio::time::sleep(Duration::from_millis(args.interval_ms)).await;
        }
        let marks = [1, 10, 25, 50, target];
        put(&mut result, "watch", tracker.to_json(&marks));
        put(&mut result, "online", json!(tracker.online_count()));
        put(&mut result, "target", json!(target));
        let nth = tracker.nth(&[target]);
        text.push_str(&match nth.get(&target) {
            Some(ms) => format!(
                "{target} runner(s) online in GitHub {:.1} s after the command started\n",
                *ms as f64 / 1000.0
            ),
            None => {
                missed
                    .push(format!("{} of {target} online by the timeout", tracker.online_count()));
                format!(
                    "only {} of {target} runner(s) came online within {} s\n",
                    tracker.online_count(),
                    args.timeout_s
                )
            }
        });
    }
    if failed > 0 {
        missed.push(format!("{failed} resume call(s) failed"));
    }
    put(&mut result, "ok", json!(missed.is_empty()));
    emit(out, args.json, &result, &text);
    if missed.is_empty() { Ok(()) } else { Err(missed.join("; ")) }
}

async fn pause(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    if args.names.is_none() && !args.idle {
        return Err("pause needs --names FILE or --idle".to_owned());
    }
    let pool = Pool::open(args, env, args.idle).await?;
    let (machines, roster) = futures_util::join!(pool.machines(), pool.roster());
    let (machines, roster) = (machines?, roster?);
    let mut picked: Vec<&Machine> = if args.idle {
        let allowed: HashSet<String> = match &args.names {
            Some(path) => read_names(path)?,
            None => roster.iter().filter(|r| r.online && !r.busy).map(|r| r.name.clone()).collect(),
        };
        plan::pick_pause(&machines, &roster, &allowed)
    } else {
        // No roster here (the bench's pause job holds no GitHub key): the names file already says idle.
        let names = read_names(args.names.as_deref().unwrap_or_default())?;
        machines
            .iter()
            .filter(|m| {
                m.power == crate::model::Power::Running && {
                    // Every runner of the machine named idle, never one of several.
                    let owned = names.iter().filter(|n| m.owns_runner(n)).count();
                    owned > 0 && owned >= usize::try_from(m.slots.max(1)).unwrap_or(usize::MAX)
                }
            })
            .collect()
    };
    if let Some(max) = args.max {
        picked.truncate(max);
    }
    let t0 = now_ms();
    let calls = pool.all_at_once(&picked, t0, |m| pool.pause(m)).await;
    let failed = calls.iter().filter(|c| c["ok"] != json!(true)).count();
    let text = format!("paused {} machine(s) ({failed} failed)\n", calls.len());
    emit(out, args.json, &json!({"t0_ms": t0, "calls": calls}), &text);
    if failed > 0 { Err(format!("{failed} pause call(s) failed")) } else { Ok(()) }
}

async fn watch(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    let client = http::client().map_err(|e| e.0)?;
    let gh = GitHub::from_env(&client, env, &args.org, &args.group)
        .await
        .map_err(|e| e.0)?
        .ok_or("watch needs GH_TOKEN")?;
    let in_pool = |name: &str| args.prefixes.iter().any(|p| name.starts_with(p.as_str()));
    if args.idle_only {
        let roster = gh.roster(&client).await.map_err(|e| e.0)?;
        let mut idle: Vec<String> = roster
            .iter()
            .filter(|r| r.online && !r.busy && in_pool(&r.name))
            .map(|r| r.name.clone())
            .collect();
        idle.sort();
        if let Some(max) = args.max {
            idle.truncate(max);
        }
        if let Some(path) = &args.names_out {
            std::fs::write(path, idle.join("\n") + "\n").map_err(|e| format!("{path}: {e}"))?;
        }
        emit(out, args.json, &json!({"idle": idle}), &format!("{} idle runner(s)\n", idle.len()));
        return Ok(());
    }
    let wanted = match &args.names {
        Some(path) => Some(read_names(path)?),
        None => None,
    };
    let since = args.since_ms.unwrap_or_else(now_ms);
    sleep_until(since).await;
    let target = usize::try_from(args.count.unwrap_or(50)).unwrap_or(usize::MAX);
    let mut tracker = Tracker::new(since, wanted);
    let deadline = Instant::now() + Duration::from_secs(args.timeout_s);
    let mut reads = 0u64;
    while tracker.online_count() < target && Instant::now() < deadline {
        let at = now_ms();
        match gh.roster(&client).await {
            Ok(roster) => {
                let pool: Vec<Runner> = roster.into_iter().filter(|r| in_pool(&r.name)).collect();
                tracker.observe(at, &pool);
                reads += 1;
            }
            Err(e) => eprintln!("cmux vm pool: roster: {e}"),
        }
        tokio::time::sleep(Duration::from_millis(args.interval_ms)).await;
    }
    let mut value = tracker.to_json(&[1, 10, 25, 50, target]);
    put(&mut value, "reads", json!(reads));
    put(&mut value, "target", json!(target));
    let text = match tracker.nth(&[target]).get(&target) {
        Some(ms) => {
            format!("{target} runner(s) online {:.1} s after {since}\n", *ms as f64 / 1000.0)
        }
        None => {
            emit(out, args.json, &value, "");
            return Err(format!(
                "{} of {target} runner(s) online by the timeout",
                tracker.online_count()
            ));
        }
    };
    emit(out, args.json, &value, &text);
    Ok(())
}

async fn schedule(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    let feed = args.feed.clone().ok_or("schedule needs --feed URL (the build controller)")?;
    if args.repos.is_empty() {
        return Err("schedule needs --repo OWNER/NAME (one or more)".to_owned());
    }
    let mut pool = Pool::open(args, env, true).await?;
    if pool.github.is_none() {
        return Err("schedule needs GH_TOKEN".to_owned());
    }
    let mut scheduler = Scheduler::new(Policy {
        idle_ms: args.idle_minutes.saturating_mul(60_000),
        keep_idle: args.keep_idle,
        prefixes: args.prefixes.clone(),
        label: args.label.clone(),
        pause_prefixes: args.pause_prefixes.clone(),
        ..Policy::default()
    });
    loop {
        let tick_started = Instant::now();
        if let Some(gce) = pool.gce.as_mut() {
            // Metadata and gcloud tokens last about an hour; a scheduler runs for days.
            gce.refresh_if_old(&pool.client, Duration::from_secs(40 * 60)).await;
        }
        let (queued, machines, roster) = futures_util::join!(
            read_queued(&pool.client, &feed, &args.repos, &scheduler.policy.label),
            pool.machines_partial(),
            pool.roster()
        );
        match (machines, roster, queued) {
            (Ok(machines), Ok(roster), Ok(queued)) => {
                // The learned-size scheduler's vCPU demand when it writes one (and wrote it lately); else queued
                // jobs. Queued jobs count either way: nothing pauses while the feed shows one.
                let fresh_for = Duration::from_secs(args.tick_s.saturating_mul(3).max(30));
                let demand = match &args.demand_file {
                    Some(path) => match read_demand(path, fresh_for) {
                        Ok(vcpu) => Demand::Vcpu { vcpu, queued },
                        Err(why) => {
                            eprintln!("cmux vm pool: schedule: {path}: {why}; using queued jobs");
                            Demand::Jobs(queued)
                        }
                    },
                    None => Demand::Jobs(queued),
                };
                scheduler.set_loads(pool.loads(args.load_url.as_deref()).await);
                let decision = scheduler.tick(now_ms(), &machines, &roster, demand);
                let resume: Vec<&Machine> =
                    machines.iter().filter(|m| decision.resume.contains(&m.id)).collect();
                let mut pause: Vec<&Machine> =
                    machines.iter().filter(|m| decision.pause.contains(&m.id)).collect();
                if !pause.is_empty() {
                    // A job may have landed since the roster read: read it again and keep busy machines up.
                    match pool.roster().await {
                        Ok(now) => {
                            let by = plan::runners_by_machine(&machines, &now);
                            pause.retain(|m| {
                                by.get(&m.id).is_none_or(|rs| rs.iter().all(|r| !r.busy))
                            });
                        }
                        Err(e) => {
                            eprintln!(
                                "cmux vm pool: schedule: roster re-read: {e}; pausing nothing"
                            );
                            pause.clear();
                        }
                    }
                }
                let t0 = now_ms();
                let resumed = pool.all_at_once(&resume, t0, |m| pool.power_on(m)).await;
                let paused = pool.all_at_once(&pause, t0, |m| pool.pause(m)).await;
                if !resumed.is_empty() || !paused.is_empty() || args.once {
                    let line = json!({
                        "at_ms": t0,
                        "queued": decision.queued,
                        "idle_online": decision.idle_online,
                        "starting": decision.starting,
                        "demand_vcpu": decision.demand_vcpu,
                        "free_vcpu": decision.free_vcpu,
                        "all_full": decision.all_full,
                        "resumed": resumed,
                        "paused": paused,
                    });
                    emit(out, true, &line, "");
                    let _ = out.flush();
                }
            }
            (m, r, f) => {
                // A read failed: decide nothing this tick (never pause on a partial view).
                let why = [m.err(), r.err(), f.err()]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>()
                    .join("; ");
                eprintln!("cmux vm pool: schedule: skipped a tick: {why}");
            }
        }
        if args.once {
            return Ok(());
        }
        let tick = Duration::from_secs(args.tick_s);
        if let Some(rest) = tick.checked_sub(tick_started.elapsed()) {
            tokio::time::sleep(rest).await;
        }
    }
}

/// `load`: each pool machine's measured CPU (and RAM where the controller has it), and the pool's p50/p90:
/// the before and after numbers of a placement change.
async fn load(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    let pool = Pool::open(args, env, false).await?;
    let machines = pool.machines().await?;
    let loads = pool.loads(args.load_url.as_deref()).await;
    let pooled: HashMap<String, Load> =
        loads.into_iter().filter(|(name, _)| machines.iter().any(|m| &m.name == name)).collect();
    let mut rows: Vec<Value> = pooled
        .iter()
        .map(|(name, l)| json!({"name": name, "cpu_pct": l.cpu_pct, "mem_pct": l.mem_pct}))
        .collect();
    rows.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    let summary = load::summary(&pooled);
    let running = machines.iter().filter(|m| m.power == crate::model::Power::Running).count();
    let text = format!("{running} running, {summary}\n");
    emit(out, args.json, &json!({"running": running, "summary": summary, "machines": rows}), &text);
    Ok(())
}

/// Sets `key` on a JSON object; a non-object value is left as it is (indexing a `Value` panics there).
fn put(value: &mut Value, key: &str, field: Value) {
    if let Some(map) = value.as_object_mut() {
        map.insert(key.to_owned(), field);
    }
}
