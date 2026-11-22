//! A code layer rebuilt on this app's commit (cmuxterm-hq RFD 0038,
//! "Customizations across updates", phase 1 step 2).
//!
//! A web layer is a whole bundle, so one built on base B is only right on an
//! app at B. When `library refresh` finds the newest layer of an entry built
//! on another commit than the app's, it asks CI to build the entry's head on
//! the app's commit (`-f base=<app commit>`; CI publishes it at
//! `<head>-<app commit>.json`) and keeps what it asked here, in
//! `<state dir>/layers/rebuilds.json`, by entry name:
//!
//! - While CI builds, the person's current bundle stays on: nothing changes
//!   on screen, and the entry's note says it is rebuilding.
//! - When the pointer is there, refresh takes it as any newer layer
//!   (`Step::Take`): web-dev.json points at the new folder and the app swaps.
//! - When CI says it could not build it (the change conflicts on the app's
//!   commit; any other failure twice, since the first may be CI's own, as
//!   its GitHub rate limit; or no build within [`WAIT_MS`]), the entry
//!   turns off with the reason as its one quiet note: the app's own pages
//!   are back. A later app commit asks again, and a rebuild that then works
//!   turns it back on.
//!
//! Something has to pick the finished build up: refresh starts one waiter
//! (`library refresh --wait`, detached, one at a time under a lock) that
//! looks for the pointer every [`POLL`] and asks gh about the run now and
//! then, runs refresh once something finished, and stops when nothing is
//! left to wait for or after [`WAIT_MS`]. Neither the CLI nor app start ever
//! waits for a build. Our CI never builds fork code, so forks are never
//! asked for here.
//!
//! The decisions are [`verdict`], [`run_state`] and [`look`]: pure, tested
//! with fake runs and pointers (rebuild_tests.rs).

use std::collections::BTreeMap;
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

use cmux_customize::Customize;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Failure;
use super::pr::{Http, REPO, short};
use super::render::Answer;

/// Where refresh keeps the rebuilds it asked for, under the layers folder.
const FILE: &str = "rebuilds.json";
/// The lock one waiter holds while it waits.
const WAIT_LOCK: &str = "rebuilds.wait.lock";
/// How long a rebuild may take before it counts as failed, and how long the
/// waiter waits at most.
pub(super) const WAIT_MS: u64 = 60 * 60_000;
/// How often the waiter looks for the rebuilt layer's pointer (one GET of a
/// static file, no GitHub API).
const POLL: Duration = Duration::from_secs(POLL_MS / 1000);
const POLL_MS: u64 = 60_000;
/// The waiter asks gh about the CI run every this many looks.
const RUN_EVERY: u32 = 3;
/// How long one `gh` call may take.
const GH_TIMEOUT: Duration = Duration::from_secs(30);
/// What cmux-next-web-bundle-publish.yml says (`::error::`, an annotation on
/// the failed job) when the change does not apply on the base. A failure
/// without it (the CI installation's GitHub rate limit, a runner that died)
/// says nothing about the change, so it is asked again once first.
const CONFLICT_SAYS: &str = "does not apply onto";
/// How many times a rebuild that failed for no reason of its own is asked.
const TRIES: u32 = 2;

/// One rebuild refresh asked CI for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Rebuild {
    /// The entry's head, built on `base`.
    pub head: String,
    /// The app's commit it is built on.
    pub base: String,
    pub asked_ms: u64,
    /// The CI run, when `gh workflow run` named it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<u64>,
    /// Where CI publishes the rebuilt layer's pointer.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub pointer: String,
    /// Why it could not be built: set when refresh turned the entry off for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failed: Option<String>,
    /// The entry is off because a rebuild of it failed (not by the person),
    /// so a later rebuild that works turns it back on.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub off_by_rebuild: bool,
    /// How many times CI was asked for this head on this base.
    #[serde(default)]
    pub tries: u32,
}

impl Rebuild {
    fn late(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.asked_ms) > WAIT_MS
    }
}

/// What CI says of a run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Run {
    Building,
    Built,
    /// The change does not apply on the base.
    Conflict,
    /// It failed otherwise: why, in a few words.
    Failed(String),
    /// gh did not answer (or there is no run to ask about).
    Unknown,
}

/// What refresh does with an entry whose newest layer is built on another
/// commit than the app's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verdict {
    /// Nothing asked for this head on this app yet, or it failed for no
    /// reason of its own and has a try left: ask CI.
    Ask,
    /// CI is building it: the current bundle stays on, with this note.
    Wait(String),
    /// It could not be built: turn the entry off with this note.
    Off(String),
    /// It could not be built, and refresh turned it off for that already:
    /// the note again, on or off left as the person has it.
    Failed(String),
}

/// The rebuild of `head` on `app`, from what was asked (`rebuild`) and what
/// CI says of its run (`run`, asked only while it builds).
pub(super) fn verdict(
    rebuild: Option<&Rebuild>,
    head: &str,
    app: &str,
    now_ms: u64,
    run: impl FnOnce(u64) -> Run,
) -> Verdict {
    let Some(rebuild) = rebuild.filter(|r| r.head == head && r.base == app) else {
        return Verdict::Ask;
    };
    if let Some(why) = &rebuild.failed {
        return Verdict::Failed(why.clone());
    }
    match rebuild.run.map_or(Run::Unknown, run) {
        Run::Conflict => Verdict::Off(off_note(app, "it conflicts with what changed since")),
        Run::Failed(_) if rebuild.tries.max(1) < TRIES => Verdict::Ask,
        Run::Failed(why) => Verdict::Off(off_note(app, &why)),
        Run::Unknown if rebuild.late(now_ms) => Verdict::Off(off_note(
            app,
            &format!("CI did not build it within {} min", WAIT_MS / 60_000),
        )),
        Run::Building | Run::Built | Run::Unknown => {
            Verdict::Wait(wait_note(app, rebuild.asked_ms, now_ms))
        }
    }
}

/// Whether refresh rebuilds an entry: one that is on, or one a failed
/// rebuild turned off. One the person turned off is left as it is.
pub(super) fn follows(on: bool, rebuild: Option<&Rebuild>) -> bool {
    on || rebuild.is_some_and(|rebuild| rebuild.off_by_rebuild)
}

/// The note while CI builds.
pub(super) fn wait_note(app: &str, asked_ms: u64, now_ms: u64) -> String {
    let minutes = now_ms.saturating_sub(asked_ms) / 60_000;
    format!(
        "rebuilding on this app's {} (asked {minutes} min ago); your current one stays on until it is ready",
        short(app)
    )
}

fn off_note(app: &str, why: &str) -> String {
    format!(
        "could not be rebuilt on this app's {}: {why}; the app's own pages are back",
        short(app)
    )
}

/// What `gh run view --json status,conclusion,jobs` says of a run, with
/// the messages of its failed job's annotations (`said`).
pub(super) fn run_state(run: &Value, said: &[String]) -> Run {
    let field = |key: &str| run.get(key).and_then(Value::as_str).unwrap_or_default();
    if field("status") != "completed" {
        return if field("status").is_empty() { Run::Unknown } else { Run::Building };
    }
    match field("conclusion") {
        "success" => return Run::Built,
        "cancelled" => return Run::Failed("its CI run was cancelled".to_owned()),
        _ => {}
    }
    if said.iter().any(|message| message.contains(CONFLICT_SAYS)) {
        return Run::Conflict;
    }
    let step = failed_job(run)
        .and_then(|job| job.get("steps").and_then(Value::as_array))
        .into_iter()
        .flatten()
        .find(|step| step.get("conclusion").and_then(Value::as_str) == Some("failure"))
        .and_then(|step| step.get("name").and_then(Value::as_str));
    let message = said
        .iter()
        .find(|message| !message.starts_with("Process completed with exit code"))
        .map(|message| format!(": {}", message.chars().take(120).collect::<String>()))
        .unwrap_or_default();
    Run::Failed(match step {
        Some(step) => format!("CI failed at \"{step}\"{message}"),
        None => format!("CI failed{message}"),
    })
}

/// The first job of `run` that failed.
fn failed_job(run: &Value) -> Option<&Value> {
    run.get("jobs")
        .and_then(Value::as_array)?
        .iter()
        .find(|job| job.get("conclusion").and_then(Value::as_str) == Some("failure"))
}

/// The run `gh workflow run` named in what it printed.
pub(super) fn run_id(printed: &str) -> Option<u64> {
    let after = printed.split("/actions/runs/").nth(1)?;
    let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// What the waiter saw of one open rebuild.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Seen {
    pub asked_ms: u64,
    /// The rebuilt layer's pointer is published.
    pub found: bool,
    /// What CI said of the run, when it was asked this look.
    pub run: Option<Run>,
}

/// What the waiter does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Look {
    /// Something finished: run refresh, which takes it or turns it off.
    Refresh,
    Sleep,
    /// Nothing left to wait for.
    Done,
}

/// The waiter's next move over the open rebuilds. A run CI says it built
/// also gets a refresh even when its exact pointer did not read yet
/// (refresh reads `latest.json` too); one past [`WAIT_MS`] gets one last
/// refresh, which turns it off.
pub(super) fn look(open: &[Seen], now_ms: u64) -> Look {
    let finished = |seen: &Seen| {
        seen.found
            || matches!(seen.run, Some(Run::Built | Run::Conflict | Run::Failed(_)))
            || now_ms.saturating_sub(seen.asked_ms) > WAIT_MS
    };
    if open.iter().any(finished) {
        Look::Refresh
    } else if open.is_empty() {
        Look::Done
    } else {
        Look::Sleep
    }
}

/// The rebuilds refresh asked for, by entry name.
#[derive(Debug, Default)]
pub(super) struct Rebuilds {
    path: PathBuf,
    pub by_name: BTreeMap<String, Rebuild>,
}

impl Rebuilds {
    pub(super) fn load(customize: &Customize) -> Rebuilds {
        let path = customize.roots().state_dir.join("layers").join(FILE);
        let by_name = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Rebuilds { path, by_name }
    }

    pub(super) fn save(&self) -> std::io::Result<()> {
        if self.by_name.is_empty() {
            return match std::fs::remove_file(&self.path) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
                _ => Ok(()),
            };
        }
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let text = serde_json::to_string_pretty(&self.by_name).map_err(std::io::Error::other)?;
        cmux_config::fsio::write_atomic(&self.path, format!("{text}\n").as_bytes())
    }

    /// Those still building (not failed).
    fn open(&self) -> impl Iterator<Item = &Rebuild> {
        self.by_name.values().filter(|rebuild| rebuild.failed.is_none())
    }
}

/// One quiet line per entry a failed rebuild turned off, for `library
/// status` (which lists only what is on): its name and why. `still_off`:
/// the entry is in the library and off now.
pub(super) fn off_lines(rebuilds: &Rebuilds, still_off: impl Fn(&str) -> bool) -> String {
    rebuilds
        .by_name
        .iter()
        .filter(|(name, rebuild)| rebuild.off_by_rebuild && still_off(name))
        .filter_map(|(name, rebuild)| {
            Some(format!("  {name} is off: {}\n", rebuild.failed.as_ref()?))
        })
        .collect()
}

/// Runs `gh` with `args`, bounded: what it printed, or why it failed in
/// gh's own last line.
pub(super) fn gh(args: &[String], timeout: Duration) -> Result<String, String> {
    let mut child = cmux_process::Command::new("gh")
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        .spawn()
        .map_err(|error| format!("gh: {error}"))?;
    let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
    // Read while it runs, on threads this call owns: a pipe that fills would
    // hold gh until the timeout. Killing gh ends both reads.
    let (status, printed, said) = std::thread::scope(|scope| {
        let out = scope.spawn(move || read_all(stdout));
        let err = scope.spawn(move || read_all(stderr));
        let status = match child.wait_timeout(timeout) {
            Ok(Some(status)) => Some(status),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                None
            }
        };
        (status, out.join().unwrap_or_default(), err.join().unwrap_or_default())
    });
    let Some(status) = status else {
        return Err(format!("gh did not answer in {}s", timeout.as_secs()));
    };
    if status.success() {
        return Ok(printed);
    }
    Err(said
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(|line| line.chars().take(200).collect())
        .unwrap_or_else(|| format!("gh exited {status}")))
}

fn read_all(pipe: Option<impl Read>) -> String {
    let mut text = String::new();
    if let Some(mut pipe) = pipe {
        let _ = pipe.read_to_string(&mut text);
    }
    text
}

/// What CI says of run `id` now.
pub(super) fn ask_run(id: u64) -> Run {
    let args: Vec<String> =
        ["run", "view", &id.to_string(), "-R", REPO, "--json", "status,conclusion,jobs"]
            .map(str::to_owned)
            .into();
    let Some(run) =
        gh(&args, GH_TIMEOUT).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok())
    else {
        return Run::Unknown;
    };
    // Only a failed run costs the second call: what its failed job said.
    let said = failed_job(&run)
        .and_then(|job| job.get("databaseId").and_then(Value::as_u64))
        .filter(|_| run.get("conclusion").and_then(Value::as_str) == Some("failure"))
        .map(|job| {
            let args: Vec<String> = [
                "api",
                &format!("repos/{REPO}/check-runs/{job}/annotations"),
                "--jq",
                ".[].message",
            ]
            .map(str::to_owned)
            .into();
            gh(&args, GH_TIMEOUT)
                .map(|text| text.lines().map(str::to_owned).collect::<Vec<_>>())
                .unwrap_or_default()
        })
        .unwrap_or_default();
    run_state(&run, &said)
}

/// Starts the waiter in the background, on its own: it outlives this
/// command, and a second one sees the first one's lock and leaves.
pub(super) fn start_waiter() {
    let Ok(exe) = std::env::current_exe() else { return };
    let child = cmux_process::Command::new(exe)
        .args(["customize", "library", "refresh", "--wait"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .new_session()
        .spawn();
    if let Ok(mut child) = child {
        child.detach("waits for a code layer CI is rebuilding on this app's commit, bounded");
    }
}

/// `cmux customize library refresh --wait`: waits for the rebuilds refresh
/// asked for, runs refresh once one finished, and stops when none is left or
/// after [`WAIT_MS`].
pub(super) fn wait(
    customize: &Customize,
    origin: &str,
    now: impl Fn() -> u64,
) -> Result<Answer, Failure> {
    let dir = customize.roots().state_dir.join("layers");
    let _ = std::fs::create_dir_all(&dir);
    let lock =
        std::fs::OpenOptions::new().create(true).append(true).open(dir.join(WAIT_LOCK)).map_err(
            |error| super::pr::failure(format!("could not open the wait lock: {error}")),
        )?;
    if lock.try_lock().is_err() {
        return Ok(Answer::Library {
            json: json!({ "waiting": false, "why": "another wait is running" }),
            human: "another wait for a rebuild is running\n".to_owned(),
        });
    }
    let http = Http::with_timeout(Duration::from_secs(30))?;
    let started = now();
    let mut refreshes: u32 = 0;
    for round in 0u32.. {
        let rebuilds = Rebuilds::load(customize);
        let ask_runs = round % RUN_EVERY == 0;
        let seen: Vec<Seen> = rebuilds
            .open()
            .map(|rebuild| Seen {
                asked_ms: rebuild.asked_ms,
                found: !rebuild.pointer.is_empty()
                    && matches!(http.get_json(&rebuild.pointer), Ok(Some(_))),
                run: rebuild.run.filter(|_| ask_runs).map(ask_run),
            })
            .collect();
        match look(&seen, now()) {
            Look::Done => break,
            Look::Refresh => {
                super::pr::refresh_with(customize, origin, now(), false)?;
                refreshes = refreshes.saturating_add(1);
                // A refresh that left the same rebuilds open (a pointer not
                // readable yet, say) is not run again at once.
                if Rebuilds::load(customize).by_name == rebuilds.by_name {
                    std::thread::sleep(POLL);
                }
            }
            Look::Sleep => std::thread::sleep(POLL),
        }
        if now().saturating_sub(started) > WAIT_MS.saturating_add(POLL_MS) {
            break;
        }
    }
    Ok(Answer::Library {
        json: json!({ "waited_ms": now().saturating_sub(started), "refreshes": refreshes }),
        human: "no rebuild left to wait for\n".to_owned(),
    })
}

#[cfg(test)]
#[path = "rebuild_tests.rs"]
mod tests;
