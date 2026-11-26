//! `cmux vm runner new|ls|park`: a user's own runner VM on Freestyle, made or resumed from their machine.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::freestyle::{self, Freestyle};
use crate::github::GitHub;
use crate::http;
use crate::runner::{
    self, DEFAULT_GROUP, DEFAULT_LABEL, DEFAULT_ORG, Fleet, Jit, Pacing, Request, RunnerVm, Secret,
    Size,
};

pub const HELP: &str = "\
usage: cmux vm runner <verb> [options]

One Freestyle runner VM for one GitHub Actions job, made (or resumed) from your own
machine with your own credentials. There is no floor and no minimum: one call, one runner.

  new     resume a parked runner VM of yours, else make one; register a fresh one-job
          runner on it (a JIT config, passed on stdin); the VM powers itself off after
          the job, which parks it. Nothing is ever deleted.
  ls      your runner VMs (--all: every owner's)
  park    power an idle runner VM off (park it): park ID, or every idle one of yours

Options:
  --org ORG        (manaflow-ai)            --group GROUP  (cmux-freestyle-linux)
  --label L        runner label, repeatable (cmux-freestyle-linux-x64)
  --size N         vCPUs: 8, 16 or 32; memory 2 GiB each, 150 GiB disk (8)
  --owner NAME     VM owner tag, metadata fsr_owner (your GitHub login)
  --wait           wait for the runner to come online, then for its one job to
                   finish, and print the job; then the VM is parked
  --timeout SECS   bound of --wait (3600)
  --json           one JSON object on stdout
  park: --force    park without GitHub's word that the runner is idle

Credentials, read in place and never printed: FREESTYLE_API_KEY, else the file
~/.config/freestyle/api-key; GITHUB_TOKEN (or GH_TOKEN), else `gh auth token`.

`new --json` prints {vm_id, runner, labels, owner, org, group, runner_id, reused,
previous_runner, size:{cpu,memory_mib,storage_mib}} and with --wait also wait:
{state: done|timeout|runner_offline, job: {repository, run_id, run_attempt, job_id,
name, conclusion, started_at, completed_at, url} or null, parked}.

TODO: `cmux vm lane new` (a lane VM, create + size) is not here yet: see leo-workspace
tools/freestyle_lanes.py.
";

#[derive(Debug, Default)]
struct Args {
    verb: String,
    id: Option<String>,
    org: String,
    group: String,
    labels: Vec<String>,
    size: Size,
    owner: Option<String>,
    all: bool,
    wait: bool,
    force: bool,
    json: bool,
    timeout_s: u64,
}

fn parse(words: &[String]) -> Result<Args, String> {
    let mut a = Args {
        org: DEFAULT_ORG.to_owned(),
        group: DEFAULT_GROUP.to_owned(),
        timeout_s: 3600,
        ..Args::default()
    };
    let mut it = words.iter();
    while let Some(word) = it.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f, Some(v.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = |name: &str| {
            inline
                .clone()
                .or_else(|| it.next().cloned())
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match flag {
            "--json" => a.json = true,
            "--wait" => a.wait = true,
            "--all" => a.all = true,
            "--force" => a.force = true,
            "--org" => a.org = value(flag)?,
            "--group" => a.group = value(flag)?,
            "--label" => a.labels.push(value(flag)?),
            "--owner" => a.owner = Some(value(flag)?.to_lowercase()),
            "--timeout" => {
                a.timeout_s =
                    value(flag)?.parse().map_err(|_| "--timeout: not a number".to_owned())?;
            }
            "--size" => {
                let v = value(flag)?;
                let cpu: u32 = v
                    .trim_end_matches("vcpu")
                    .parse()
                    .map_err(|_| format!("--size: not a vCPU count: {v}"))?;
                if !matches!(cpu, 8 | 16 | 32) {
                    return Err(format!("--size: {cpu} is not 8, 16 or 32"));
                }
                a.size = Size { cpu };
            }
            "-h" | "--help" => a.verb = "help".to_owned(),
            other if other.starts_with('-') => return Err(format!("unknown option {other}")),
            other if a.verb.is_empty() => a.verb = other.to_owned(),
            other if a.id.is_none() => a.id = Some(other.to_owned()),
            other => return Err(format!("unexpected argument {other}")),
        }
    }
    if a.verb.is_empty() {
        a.verb = "help".to_owned();
    }
    if a.labels.is_empty() {
        a.labels.push(DEFAULT_LABEL.to_owned());
    }
    Ok(a)
}

fn nonblank(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}

/// The user's Freestyle key: `FREESTYLE_API_KEY`, else the file `~/.config/freestyle/api-key`. Read in place: held
/// in memory for the calls, never copied, logged or printed (an error names the path, not the contents).
pub fn freestyle_key(env: &dyn Fn(&str) -> Option<String>) -> Result<Secret, String> {
    if let Some(key) = nonblank(env("FREESTYLE_API_KEY")) {
        return Ok(Secret::new(key));
    }
    let home = env("HOME")
        .or_else(|| env("USERPROFILE"))
        .ok_or("no FREESTYLE_API_KEY and no home directory")?;
    let path: PathBuf = [home.as_str(), ".config", "freestyle", "api-key"].iter().collect();
    match std::fs::read_to_string(&path) {
        Ok(text) => nonblank(Some(text))
            .map(Secret::new)
            .ok_or_else(|| format!("{} is empty", path.display())),
        Err(e) => {
            Err(format!("no FREESTYLE_API_KEY, and {} is unreadable: {}", path.display(), e.kind()))
        }
    }
}

/// The user's GitHub credential: `GITHUB_TOKEN` (or `GH_TOKEN`), else `gh auth token`.
pub fn github_token(
    env: &dyn Fn(&str) -> Option<String>,
    gh: &dyn Fn() -> Option<String>,
) -> Result<Secret, String> {
    nonblank(env("GITHUB_TOKEN"))
        .or_else(|| nonblank(env("GH_TOKEN")))
        .or_else(|| nonblank(gh()))
        .map(Secret::new)
        .ok_or_else(|| {
            "no GITHUB_TOKEN, and `gh auth token` gave none (run `gh auth login`)".to_owned()
        })
}

fn gh_auth_token() -> Option<String> {
    let out = std::process::Command::new("gh")
        .args(["auth", "token"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

pub async fn run(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> i32 {
    let args = match parse(words) {
        Ok(a) => a,
        Err(m) => {
            eprintln!("cmux vm runner: {m}\n\n{HELP}");
            return 2;
        }
    };
    let result = match args.verb.as_str() {
        "help" => {
            let _ = write!(out, "{HELP}");
            return 0;
        }
        "new" => new(&args, env, out).await,
        "ls" | "list" => ls(&args, env, out).await,
        "park" => park(&args, env, out).await,
        other => Err(format!("unknown verb `{other}`\n\n{HELP}")),
    };
    match result {
        Ok(code) => code,
        Err(m) => {
            if args.json {
                let _ = writeln!(out, "{}", json!({"ok": false, "error": m}));
            }
            eprintln!("cmux vm runner: {m}");
            1
        }
    }
}

fn freestyle_client(env: &dyn Fn(&str) -> Option<String>) -> Result<Freestyle, String> {
    let key = freestyle_key(env)?;
    let base =
        nonblank(env("FREESTYLE_API_URL")).unwrap_or_else(|| freestyle::DEFAULT_BASE.to_owned());
    Ok(Freestyle::new(&base, key.expose().to_owned(), runner::PURPOSE))
}

fn jit_client(args: &Args, env: &dyn Fn(&str) -> Option<String>) -> Result<Jit, String> {
    let token = github_token(env, &gh_auth_token)?;
    let base = nonblank(env("GITHUB_API_URL")).unwrap_or_else(|| crate::github::API.to_owned());
    Ok(Jit::new(&base, token, &args.org))
}

async fn owner_of(
    args: &Args,
    jit: Option<&Jit>,
    client: &reqwest::Client,
) -> Result<String, String> {
    if let Some(o) = &args.owner {
        return Ok(o.clone());
    }
    match jit {
        Some(j) => j.login(client).await,
        None => Err("no owner: pass --owner or sign in to GitHub".to_owned()),
    }
}

fn say(msg: &str) {
    eprintln!("cmux vm runner: {msg}");
}

/// Resolves on SIGINT or SIGTERM (Ctrl-C elsewhere) with the signal's name.
async fn interrupted() -> &'static str {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        if let Ok(mut term) = signal(SignalKind::terminate()) {
            return tokio::select! {
                _ = tokio::signal::ctrl_c() => "SIGINT",
                _ = term.recv() => "SIGTERM",
            };
        }
    }
    let _ = tokio::signal::ctrl_c().await;
    "SIGINT"
}

/// Exit code of a run stopped by a signal (128 + SIGINT).
pub const INTERRUPTED: i32 = 130;

/// `new`, stopped cleanly by SIGINT or SIGTERM: a VM it already holds is parked, and it exits 130.
async fn new(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<i32, String> {
    let fs = freestyle_client(env)?;
    let jit = jit_client(args, env)?;
    let client = http::client().map_err(|e| e.0)?;
    let log = |m: &str| say(m);
    let fleet = Fleet { client: &client, fs: &fs, pacing: Pacing::default(), log: &log };
    let held: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
    let outcome = {
        let run = new_until_done(args, &fleet, &jit, &held, &mut *out);
        tokio::pin!(run);
        tokio::select! {
            r = &mut run => Ok(r),
            sig = interrupted() => Err(sig),
        }
    };
    let sig = match outcome {
        Ok(r) => return r,
        Err(sig) => sig,
    };
    let vm = held.lock().ok().and_then(|g| g.clone());
    let parked = match &vm {
        Some(id) => {
            say(&format!("{sig}: parking {id}"));
            park_vm(&fleet, id).await
        }
        None => {
            say(&format!(
                "{sig}: stopped before a VM was ready; `cmux vm runner ls` shows any it left"
            ));
            false
        }
    };
    if args.json {
        let _ = writeln!(
            out,
            "{}",
            json!({"ok": false, "interrupted": sig, "vm_id": vm, "parked": parked})
        );
    } else {
        let _ = writeln!(
            out,
            "interrupted ({sig}); vm {} parked: {parked}",
            vm.as_deref().unwrap_or("-")
        );
    }
    Ok(INTERRUPTED)
}

async fn new_until_done(
    args: &Args,
    fleet: &Fleet<'_>,
    jit: &Jit,
    held: &std::sync::Mutex<Option<String>>,
    out: &mut dyn std::io::Write,
) -> Result<i32, String> {
    let client = fleet.client;
    let owner = owner_of(args, Some(jit), client).await?;
    let group_id = jit.group_id(client, &args.group).await?;
    say(&format!(
        "owner {owner}, group {} ({group_id}); looking for a parked runner VM",
        args.group
    ));
    let req = Request { owner: owner.clone(), labels: args.labels.clone(), size: args.size };
    // A paused VM is taken only when GitHub holds no record of its last runner (a paused guest may still hold a live
    // listener, or a job); a stopped one is clean after `reset`. The roster is read lazily, once.
    let gh = GitHub { token: jit.token.expose().to_owned(), org: args.org.clone(), group_id };
    let vms = fleet.runner_vms().await?;
    let paused_names: std::collections::HashSet<String> =
        if vms.iter().any(|v| v.state == "paused" && v.owner == owner) {
            match gh.roster(client).await {
                Ok(roster) => roster.into_iter().map(|r| r.name).collect(),
                // The roster is unreadable: no paused VM is taken.
                Err(_) => vms.iter().map(|v| v.name.clone()).collect(),
            }
        } else {
            std::collections::HashSet::new()
        };
    let prepared =
        fleet.make_or_resume(&req, &|v: &RunnerVm| !paused_names.contains(&v.name)).await?;
    if let Ok(mut g) = held.lock() {
        *g = Some(prepared.vm_id.clone());
    }
    say(&format!(
        "{} {} prepared; registering {}",
        if prepared.reused { "resumed" } else { "made" },
        prepared.vm_id,
        prepared.name
    ));
    let minted = match jit.mint(client, &prepared.name, group_id, &args.labels).await {
        Ok(m) => m,
        Err(e) => {
            fleet.power_off(&prepared.vm_id, "no JIT config").await;
            return Err(e);
        }
    };
    if let Err(e) = fleet.start_runner(&prepared.vm_id, &prepared.name, &minted.config).await {
        fleet.power_off(&prepared.vm_id, "runner did not start").await;
        return Err(e);
    }
    say(&format!(
        "runner {} ({}) started on {}, labels {}",
        prepared.name,
        minted.runner_id,
        prepared.vm_id,
        args.labels.join(",")
    ));
    let mut report = json!({
        "ok": true,
        "vm_id": prepared.vm_id,
        "runner": prepared.name,
        "labels": args.labels,
        "owner": owner,
        "org": args.org,
        "group": args.group,
        "runner_id": minted.runner_id,
        "reused": prepared.reused,
        "previous_runner": prepared.previous_runner,
        "size": {"cpu": args.size.cpu, "memory_mib": args.size.memory_mib(), "storage_mib": runner::STORAGE_MIB},
    });
    let mut code = 0;
    if args.wait {
        let (wait, c) = wait_for_job(
            fleet,
            jit,
            &prepared.vm_id,
            &prepared.name,
            minted.runner_id,
            args.timeout_s,
        )
        .await;
        if let Some(map) = report.as_object_mut() {
            map.insert("wait".to_owned(), wait);
        }
        code = c;
    }
    if args.json {
        let _ = writeln!(out, "{report}");
    } else {
        let _ = writeln!(
            out,
            "vm {}{}",
            report.get("vm_id").and_then(Value::as_str).unwrap_or(""),
            if prepared.reused { " (resumed)" } else { " (new)" }
        );
        let _ = writeln!(out, "runner {} labels {}", prepared.name, args.labels.join(","));
        if let Some(w) = report.get("wait") {
            human_wait(w, out);
        } else {
            let _ =
                writeln!(out, "runs one job, then the VM powers off (parked); `cmux vm runner ls`");
        }
    }
    Ok(code)
}

fn human_wait(w: &Value, out: &mut dyn std::io::Write) {
    let _ = writeln!(out, "wait: {}", w["state"].as_str().unwrap_or("?"));
    if let Some(job) = w.get("job").filter(|j| !j.is_null()) {
        let f = |k: &str| job[k].as_str().unwrap_or("-").to_owned();
        let _ = writeln!(
            out,
            "job {} ({}) run {} {}: {}",
            f("name"),
            f("job_id"),
            f("run_id"),
            f("url"),
            f("conclusion")
        );
        let _ = writeln!(out, "started {} completed {}", f("started_at"), f("completed_at"));
    }
    let _ = writeln!(out, "parked: {}", w["parked"]);
}

/// `--wait`: online, then the one job, then parked. Returns the `wait` object and the exit code (3: timed out).
async fn wait_for_job(
    fleet: &Fleet<'_>,
    jit: &Jit,
    vm: &str,
    name: &str,
    runner_id: u64,
    timeout_s: u64,
) -> (Value, i32) {
    let deadline = Instant::now() + Duration::from_secs(timeout_s);
    let poll = Duration::from_secs(5);
    let mut record = None;
    let mut seen_online = false;
    let mut busy = false;
    let started = Instant::now();
    let mut last_said = started;
    say(&format!("waiting for {name} to come online and take one job (up to {timeout_s}s)"));
    let state = loop {
        match jit.runner(fleet.client, runner_id).await {
            Ok(None) => break if seen_online || busy { "done" } else { "runner_offline" },
            Ok(Some(r)) => {
                let online = r.get("status").and_then(Value::as_str) == Some("online");
                let now_busy = r.get("busy").and_then(Value::as_bool).unwrap_or(false);
                if let Some(news) = wait_news(seen_online, busy, online, now_busy) {
                    say(&format!("{name}: {news} after {}s", started.elapsed().as_secs()));
                    last_said = Instant::now();
                }
                seen_online |= online;
                busy = now_busy;
            }
            Err(e) => say(&format!("runner status: {e}")),
        }
        if busy
            && record.is_none()
            && let Ok(r) = fleet.exec(vm, "cat /tmp/fsr-job", None, 20_000).await
        {
            record = runner::parse_job_record(&r.stdout);
            if let Some(rec) = &record {
                say(&format!(
                    "{name}: job {} of run {} in {}",
                    rec.job, rec.run_id, rec.repository
                ));
            }
        }
        if Instant::now() >= deadline {
            break "timeout";
        }
        if last_said.elapsed() >= Duration::from_secs(60) {
            let what = if busy {
                "running its job"
            } else if seen_online {
                "online, idle"
            } else {
                "not online yet"
            };
            say(&format!("{name}: {what}, {}s", started.elapsed().as_secs()));
            last_said = Instant::now();
        }
        tokio::time::sleep(poll).await;
    };
    say(&format!("{name}: {state} after {}s", started.elapsed().as_secs()));
    let mut job = Value::Null;
    if let Some(rec) = &record
        && state == "done"
        && let Ok(Some(j)) =
            jit.job_of(fleet.client, &rec.repository, &rec.run_id, &rec.run_attempt, name).await
    {
        let f = |k: &str| j.get(k).cloned().unwrap_or(Value::Null);
        job = json!({
            "repository": rec.repository, "run_id": rec.run_id, "run_attempt": rec.run_attempt,
            "job_id": f("id"), "name": f("name"), "conclusion": f("conclusion"),
            "started_at": f("started_at"), "completed_at": f("completed_at"), "url": f("html_url"),
        });
    } else if let Some(rec) = &record {
        job = json!({"repository": rec.repository, "run_id": rec.run_id, "run_attempt": rec.run_attempt, "name": rec.job});
    }
    // The guest powers itself off after its job. An idle runner that timed out is parked here; one mid-job is left.
    let parked = if state == "timeout" && busy {
        say(&format!("{vm}: left running, its job is still going"));
        false
    } else {
        say(&format!("parking {vm}"));
        park_vm(fleet, vm).await
    };
    (json!({"state": state, "job": job, "parked": parked}), if state == "timeout" { 3 } else { 0 })
}

/// What changed in a runner between two polls, worth a line on stderr.
fn wait_news(was_online: bool, was_busy: bool, online: bool, busy: bool) -> Option<&'static str> {
    match (was_busy, busy) {
        (false, true) => Some("took a job"),
        (true, false) => Some("job finished"),
        _ if online && !was_online => Some("online, waiting for a job"),
        _ => None,
    }
}

/// Parks a running VM (the guest powers off); true once it reads stopped or paused.
async fn park_vm(fleet: &Fleet<'_>, vm: &str) -> bool {
    for i in 0..24 {
        let state = fleet
            .fs
            .get(fleet.client, vm)
            .await
            .ok()
            .and_then(|v| v.get("state").and_then(Value::as_str).map(str::to_owned));
        match state.as_deref() {
            Some("stopped" | "paused") => return true,
            Some("running") if i == 3 => {
                fleet.power_off(vm, "park").await;
            }
            _ => {}
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
    false
}

async fn ls(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<i32, String> {
    let fs = freestyle_client(env)?;
    let client = http::client().map_err(|e| e.0)?;
    let owner = if args.all {
        None
    } else if let Some(o) = &args.owner {
        Some(o.clone())
    } else {
        let jit = jit_client(args, env)?;
        Some(owner_of(args, Some(&jit), &client).await?)
    };
    let log = |_: &str| {};
    let fleet = Fleet { client: &client, fs: &fs, pacing: Pacing::default(), log: &log };
    let vms: Vec<RunnerVm> = fleet
        .runner_vms()
        .await?
        .into_iter()
        .filter(|v| owner.as_ref().is_none_or(|o| &v.owner == o))
        .collect();
    if args.json {
        let rows: Vec<Value> = vms.iter().map(RunnerVm::to_json).collect();
        let _ = writeln!(out, "{}", json!({"ok": true, "owner": owner, "vms": rows}));
    } else {
        for v in &vms {
            let _ = writeln!(
                out,
                "{}  {:8}  {:14}  {} vCPU  {}  {}",
                v.id,
                v.state,
                v.owner,
                v.cpu.map_or("?".to_owned(), |c| c.to_string()),
                v.name,
                v.want
            );
        }
        let _ = writeln!(out, "{} runner VMs", vms.len());
    }
    Ok(0)
}

async fn park(
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    out: &mut dyn std::io::Write,
) -> Result<i32, String> {
    let fs = freestyle_client(env)?;
    let client = http::client().map_err(|e| e.0)?;
    let log = |m: &str| say(m);
    let fleet = Fleet { client: &client, fs: &fs, pacing: Pacing::default(), log: &log };
    let jit = jit_client(args, env).ok();
    let owner = owner_of(args, jit.as_ref(), &client).await?;
    let mut vms: Vec<RunnerVm> =
        fleet.runner_vms().await?.into_iter().filter(|v| v.state == "running").collect();
    match &args.id {
        Some(id) => vms.retain(|v| &v.id == id),
        None => vms.retain(|v| v.owner == owner),
    }
    if let Some(id) = &args.id
        && vms.is_empty()
    {
        return Err(format!("{id}: not a running runner VM"));
    }
    // Idle by GitHub's word: the runner of the VM's last registration is not busy.
    let busy: std::collections::HashSet<String> = match &jit {
        Some(j) => match j.group_id(&client, &args.group).await {
            Ok(group_id) => {
                GitHub { token: j.token.expose().to_owned(), org: args.org.clone(), group_id }
                    .roster(&client)
                    .await
                    .map_err(|e| e.0)?
                    .into_iter()
                    .filter(|r| r.busy)
                    .map(|r| r.name)
                    .collect()
            }
            Err(e) if args.force => {
                say(&e);
                Default::default()
            }
            Err(e) => return Err(e),
        },
        None if args.force => Default::default(),
        None => {
            return Err("no GitHub credential to check the runner is idle; pass --force".to_owned());
        }
    };
    let mut parked = Vec::new();
    for v in &vms {
        if busy.contains(&v.name) {
            say(&format!("{}: runner {} is busy, left running", v.id, v.name));
        } else if fleet.power_off(&v.id, "park").await {
            parked.push(v.id.clone());
        }
    }
    if args.json {
        let _ = writeln!(out, "{}", json!({"ok": true, "parked": parked}));
    } else {
        for id in &parked {
            let _ = writeln!(out, "parked {id}");
        }
        if parked.is_empty() {
            let _ = writeln!(out, "nothing to park");
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::wait_news;

    #[test]
    fn wait_news_names_each_change_once() {
        assert_eq!(wait_news(false, false, true, false), Some("online, waiting for a job"));
        assert_eq!(wait_news(true, false, true, true), Some("took a job"));
        assert_eq!(wait_news(false, false, true, true), Some("took a job"));
        assert_eq!(wait_news(true, true, true, false), Some("job finished"));
        assert_eq!(wait_news(true, false, true, false), None);
        assert_eq!(wait_news(true, true, true, true), None);
        assert_eq!(wait_news(false, false, false, false), None);
    }
}
