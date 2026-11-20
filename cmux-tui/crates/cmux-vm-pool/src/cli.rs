//! `cmux vm pool VERB` (and the `cmux-vm-pool` binary): ls, up, pause, watch, schedule.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use futures_util::future::join_all;
use serde_json::{Value, json};

use crate::freestyle::Freestyle;
use crate::gce::Gce;
use crate::github::{self, GitHub};
use crate::http;
use crate::model::{Machine, Provider, Runner, now_ms};
use crate::plan;
use crate::schedule::{Policy, Scheduler, feed_queued};
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
  schedule               the loop: queued jobs resume machines, idle ones pause

Options:
  --provider freestyle|gcp|all   (default: every provider with a credential)
  --json                         one JSON object on stdout
  up:       --at UNIX_MS (start at that wall-clock time)  --timeout SECS (120)
            --no-watch
  pause:    --names FILE (runner names allowed to pause)  --idle  --max K
  watch:    --since UNIX_MS  --count N  --names FILE  --timeout SECS
            --idle-only --names-out FILE [--prefix P]... [--max N]
  schedule: --feed URL --repo OWNER/NAME... --idle-minutes M (10)
            --keep-idle K (4) --tick SECS (5) [--once]
  GitHub:   --org ORG (manaflow-ai) --group GROUP (cmux-fleet-linux)
  GCP:      --project P (manaflow-437420)

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
    tick_s: u64,
    once: bool,
    interval_ms: u64,
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
                )
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
                )
            }
            "--prefix" => args.prefixes.push(value(flag)?),
            "--org" => args.org = value(flag)?,
            "--group" => args.group = value(flag)?,
            "--project" => args.project = Some(value(flag)?),
            "--feed" => args.feed = Some(value(flag)?),
            "--repo" => args.repos.push(value(flag)?),
            "--idle-minutes" => args.idle_minutes = number(flag, value(flag)?)?,
            "--keep-idle" => {
                args.keep_idle =
                    u32::try_from(number(flag, value(flag)?)?).map_err(|_| "--keep-idle too big")?
            }
            "--tick" => args.tick_s = number(flag, value(flag)?)?.max(1),
            "--interval-ms" => args.interval_ms = number(flag, value(flag)?)?.max(100),
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
        let freestyle = if wants(Provider::Freestyle) { Freestyle::from_env(env) } else { None };
        let gce = if wants(Provider::Gcp) {
            Gce::from_env(&client, env, args.project.clone()).await
        } else {
            None
        };
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

    async fn roster(&self) -> Result<Vec<Runner>, String> {
        match &self.github {
            Some(g) => g.roster(&self.client).await.map_err(|e| e.0),
            None => Ok(Vec::new()),
        }
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
            row["runners"] = json!(runners);
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
    emit(out, args.json, &json!({"machines": rows}), &text);
    Ok(())
}

async fn up(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<(), String> {
    let count = args.count.ok_or("up needs a count: `cmux vm pool up N`")?;
    if let Some(at) = args.at_ms {
        sleep_until(at).await;
    }
    let t0 = now_ms();
    let started = Instant::now();
    let pool = Pool::open(args, env, !args.no_watch).await?;
    let (machines, roster) = futures_util::join!(pool.machines(), pool.roster());
    let (machines, roster) = (machines?, roster?);
    let listed_ms = elapsed_ms(started);
    let picked = plan::pick_up(&machines, count);
    let slots: u32 = picked.iter().map(|m| m.slots.max(1)).sum();
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
    if pool.github.is_some() {
        let wanted = plan::wanted_runners(&picked, &roster);
        let target = usize::try_from(count).unwrap_or(usize::MAX).min(wanted.len().max(1));
        let mut tracker = Tracker::new(t0, Some(wanted));
        let deadline = started + Duration::from_secs(args.timeout_s);
        while tracker.online_count() < target && Instant::now() < deadline {
            let at = now_ms();
            if let Ok(roster) = pool.roster().await {
                tracker.observe(at, &roster);
            }
            tokio::time::sleep(Duration::from_millis(args.interval_ms)).await;
        }
        let marks = [1, 10, 25, 50, target];
        result["watch"] = tracker.to_json(&marks);
        result["online"] = json!(tracker.online_count());
        result["target"] = json!(target);
        let nth = tracker.nth(&[target]);
        text.push_str(&match nth.get(&target) {
            Some(ms) => format!(
                "{target} runner(s) online in GitHub {:.1} s after the command started\n",
                *ms as f64 / 1000.0
            ),
            None => format!(
                "only {} of {target} runner(s) came online within {} s\n",
                tracker.online_count(),
                args.timeout_s
            ),
        });
    }
    emit(out, args.json, &result, &text);
    if failed > 0 { Err(format!("{failed} resume call(s) failed")) } else { Ok(()) }
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
                m.power == crate::model::Power::Running && names.iter().any(|n| m.owns_runner(n))
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
    value["reads"] = json!(reads);
    value["target"] = json!(target);
    let text = match tracker.nth(&[target]).get(&target) {
        Some(ms) => {
            format!("{target} runner(s) online {:.1} s after {since}\n", *ms as f64 / 1000.0)
        }
        None => format!("{} of {target} runner(s) online by the timeout\n", tracker.online_count()),
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
    let pool = Pool::open(args, env, true).await?;
    if pool.github.is_none() {
        return Err("schedule needs GH_TOKEN".to_owned());
    }
    let mut scheduler = Scheduler::new(Policy {
        idle_ms: args.idle_minutes.saturating_mul(60_000),
        keep_idle: args.keep_idle,
        prefixes: args.prefixes.clone(),
        ..Policy::default()
    });
    loop {
        let tick_started = Instant::now();
        let mut queued = 0u32;
        let mut feed_error = None;
        for repo in &args.repos {
            let url =
                format!("{}/v1/github/actions?repo={repo}&recent=0", feed.trim_end_matches('/'));
            match pool.client.get(&url).send().await {
                Ok(response) => match response.json::<Value>().await {
                    Ok(body) => {
                        queued = queued.saturating_add(feed_queued(&body, &scheduler.policy.label))
                    }
                    Err(e) => feed_error = Some(format!("{url}: {e}")),
                },
                Err(e) => feed_error = Some(format!("{url}: {e}")),
            }
        }
        let (machines, roster) = futures_util::join!(pool.machines(), pool.roster());
        match (machines, roster, feed_error) {
            (Ok(machines), Ok(roster), None) => {
                let decision = scheduler.tick(now_ms(), &machines, &roster, queued);
                let resume: Vec<&Machine> =
                    machines.iter().filter(|m| decision.resume.contains(&m.id)).collect();
                let pause: Vec<&Machine> =
                    machines.iter().filter(|m| decision.pause.contains(&m.id)).collect();
                let t0 = now_ms();
                let resumed = pool.all_at_once(&resume, t0, |m| pool.power_on(m)).await;
                let paused = pool.all_at_once(&pause, t0, |m| pool.pause(m)).await;
                if !resumed.is_empty() || !paused.is_empty() || args.once {
                    let line = json!({
                        "at_ms": t0,
                        "queued": decision.queued,
                        "idle_online": decision.idle_online,
                        "starting": decision.starting,
                        "resumed": resumed,
                        "paused": paused,
                    });
                    emit(out, true, &line, "");
                    let _ = out.flush();
                }
            }
            (m, r, f) => {
                // A read failed: decide nothing this tick (never pause on a partial view).
                let why =
                    [m.err(), r.err(), f].into_iter().flatten().collect::<Vec<_>>().join("; ");
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
