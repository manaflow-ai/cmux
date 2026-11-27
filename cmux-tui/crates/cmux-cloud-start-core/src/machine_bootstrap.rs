//! `cloud new-machine --bootstrap-script FILE` (and `--repo`): what the app sends a new machine and
//! how it reads the run's end (moved from the app's `CloudMachineBootstrap`). The script goes to the
//! machine over the Cloud file API (the signed-in person's authenticated link; no ssh, no exec
//! payload), next to a small runner, and one short exec starts the runner detached under systemd,
//! so a long bootstrap (the lane bootstrap installs tools for minutes) never meets the exec API's
//! 25 s limit. The runner runs the script as the machine's user, logs to [`log_path`] and writes
//! [`status_path`] (`{"state":"running|done|failed","exit_code":N,"script_sha256":"…",
//! "start_sha256":"…","at":unix}`), and ends when the script does. One runner at a time: a start
//! while one runs says `running`, and a start whose script and repo step finished last runs
//! nothing. With a repo the runner clones it first (the repo step; `status.json`'s `repo`), and a
//! machine with only `--repo` runs [`NO_SCRIPT`].
//!
//! Pure: the app makes the file writes and execs a [`Plan`] lists, in order, and asks
//! [`step_outcome`] after each exec; [`wait_next`] reads each [`wait_command`] answer.

use serde::{Deserialize, Serialize};

/// The bootstrap folder on the machine.
pub const DIRECTORY: &str = "/home/cmux/.cmux/bootstrap";
/// The transient unit the runner runs in (`systemctl status cmux-machine-bootstrap`).
pub const UNIT: &str = "cmux-machine-bootstrap";
/// The longest script the app uploads (the lane bootstrap is about 47 KB).
pub const MAX_BYTES: usize = 1 << 20;
/// The script of a machine that only clones a repository.
pub const NO_SCRIPT: &str = "#!/bin/sh\nexit 0\n";
/// The image's work user (uid 1000), whose home holds [`DIRECTORY`]. The exec API may run a
/// command as root or as this user (the provider's default differs by path), so every command
/// names it: as root it acts directly, as the user through passwordless sudo.
pub const USER: &str = "cmux";
/// The repo step's exit code when the repository needs GitHub access the machine does not have.
pub const NEEDS_GITHUB_EXIT: i64 = 3;
/// How long one read waits on the runner's lock, in seconds: under the exec API's limit (the app
/// gives each exec 20 s), so a long run is several reads.
pub const COMPLETION_LOCK_WAIT: u32 = 15;
/// Failed reads in a row that end a wait as [`Run::Unreachable`].
pub const MAX_FAILED_READS: u32 = 3;

/// `root CMD`: CMD as root, from either account.
pub const ROOT_HELPER: &str =
    r#"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#;
/// `fill_failed`: the last start's repo step left the rest of its checkout to a background fill
/// (`repo-status.json` says `"fill":"background"`), and that fill failed: the checkout's barrier
/// reads failed (`cmux repo wait DIR 0` exits 1). A start identical to it then runs again, so the
/// repo step repairs the checkout (cmux#38364). A fill still running, or a machine whose cmux has
/// no `repo wait`, is no failure. Needs `as_u`; the runner, which runs as the work user, defines it
/// as a plain call.
pub const FILL_FAILED: &str = r#"fill_failed() { r=$(cat "$d/repo-status.json" 2>/dev/null) || return 1; case "$r" in *'"fill":"background"'*) ;; *) return 1 ;; esac; f=$(printf '%s\n' "$r" | sed -n 's/.*"dir":"\([^"]*\)".*/\1/p'); [ -n "$f" ] || return 1; x=$(command -v cmux-tui || command -v cmux) || return 1; c=0; as_u "$x" repo wait "$f" 0 >/dev/null 2>&1 || c=$?; [ "$c" = 1 ]; }"#;
/// `as_u CMD`: CMD as the work user `$u`, from either account.
pub const USER_HELPER: &str =
    r#"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#;
/// No folder on the way may be a symlink: root's chown and chmod would follow it out of the home
/// folder.
pub const NO_SYMLINKS: &str =
    r#"for p in "$h/.cmux" "$d"; do [ -L "$p" ] && { echo "$p is a symlink" >&2; exit 1; }; done"#;
/// The work user's home, from either account.
pub(crate) const HOME_OF_USER: &str = r#"h=$(getent passwd "$u" | cut -d: -f6)"#;

const RUNNER: &str = include_str!("machine_bootstrap/runner.sh");

/// The runner (`run` in [`DIRECTORY`]).
pub fn runner() -> &'static str {
    RUNNER.strip_suffix('\n').unwrap_or(RUNNER)
}

pub fn log_path() -> String {
    format!("{DIRECTORY}/bootstrap.log")
}

pub fn status_path() -> String {
    format!("{DIRECTORY}/status.json")
}

/// Which bootstrap a machine runs: the lane bootstrap also reads its lane host name.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    #[default]
    Plain,
    Lane,
}

/// `text` as one single-quoted shell word.
pub fn shell_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// `export` lines the runner sources: the machine's name, and for the lane bootstrap the lane host
/// name it reads (`LANE_VM_NAME`; leo-workspace tools/lane-vm-bootstrap).
pub fn environment(kind: Kind, name: Option<&str>) -> String {
    let Some(name) = name else { return String::new() };
    let mut lines = vec![format!("export CMUX_MACHINE_NAME={}", shell_quoted(name))];
    if kind == Kind::Lane {
        lines.push(format!("export LANE_VM_NAME={}", shell_quoted(name)));
    }
    lines.join("\n") + "\n"
}

/// A start's own upload folder (`in-<id>`, the id a UUID: no quoting needed).
pub fn staging_directory(start_id: &str) -> String {
    let id: String = start_id.chars().filter(|c| c.is_ascii_hexdigit() || *c == '-').collect();
    format!("{DIRECTORY}/in-{id}")
}

/// The bootstrap folder and this start's upload folder, the work user's, before the uploads.
pub fn prepare_command(staged: &str) -> String {
    [
        "set -eu".to_owned(),
        ROOT_HELPER.to_owned(),
        format!("d={DIRECTORY}"),
        format!("s={staged}"),
        format!("u={USER}"),
        HOME_OF_USER.to_owned(),
        NO_SYMLINKS.to_owned(),
        format!(r#"root mkdir -p "$d" && root chown -h {USER}:{USER} "$d" && root chmod 700 "$d""#),
        format!(
            r#"[ -L "$s" ] && {{ echo "$s is a symlink" >&2; exit 1; }}; root mkdir -p "$s" && root chown -h {USER}:{USER} "$s" && root chmod 700 "$s""#
        ),
    ]
    .join("; ")
}

/// The file API may write as root, so the files go to the work user first, and a start that cannot
/// hand them over fails here instead of in the runner. Uploads land in this start's own folder, so
/// no upload ever changes the files a running runner runs: the start moves them into the bootstrap
/// folder only while it holds the runner's lock, and a start while a runner runs, or while an
/// earlier start's runner has not taken over yet (its `starting`, for up to a minute, the applier's
/// wait too), says `running` and drops its files. The runner always runs as the work user with its
/// home, in a transient systemd unit (it outlives the exec); without systemd, or when
/// `systemd-run` fails, under `setsid`.
pub fn start_command(staged: &str) -> String {
    [
        "set -eu".to_owned(),
        ROOT_HELPER.to_owned(),
        USER_HELPER.to_owned(),
        format!("d={DIRECTORY}"),
        format!("s={staged}"),
        format!("u={USER}"),
        HOME_OF_USER.to_owned(),
        NO_SYMLINKS.to_owned(),
        // Exclusive against a machine-config apply (it holds this shared for its whole run): from
        // here until `starting` is out, so an apply either sees this start or this start waits for
        // it (15 s, then a clear refusal). Opened read-only and only once it exists and is no link:
        // root never creates or writes through a link the work user planted.
        r#"[ -e "$d/start.lock" ] || as_u touch "$d/start.lock"; { [ -f "$d/start.lock" ] && [ ! -L "$d/start.lock" ]; } || { echo "$d/start.lock is not a regular file" >&2; exit 1; }; exec 7<"$d/start.lock""#.to_owned(),
        r#"flock -w 15 7 || { echo "a machine config apply is running on this machine: start the bootstrap again when it ends" >&2; exit 1; }"#.to_owned(),
        r#"root chown -hR "$u:$u" "$d" 2>/dev/null || true"#.to_owned(),
        r#"[ -d "$s" ] && [ ! -L "$s" ] || { echo "$s is not a folder" >&2; exit 1; }"#.to_owned(),
        r#"for f in script env run repo repo.json; do { [ -f "$s/$f" ] && [ ! -L "$s/$f" ] && [ "$(stat -c %U "$s/$f")" = "$u" ]; } || { echo "$s/$f is not $u's: the start needs root or passwordless sudo" >&2; exit 1; }; done"#.to_owned(),
        // The runner's own lock, held from the `running` check until `starting` is out (opened
        // read-only, a regular file of the work user's, like start.lock): a runner an earlier start
        // launched that only now gets to run finds it taken and exits, so it never runs the files
        // between this start's move and its `starting`. Let go before the launch, so this start's
        // runner can take it.
        r#"[ -e "$d/lock" ] || as_u touch "$d/lock"; { [ -f "$d/lock" ] && [ ! -L "$d/lock" ]; } || { echo "$d/lock is not a regular file" >&2; exit 1; }; exec 6<"$d/lock""#.to_owned(),
        r#"flock -n 6 || { as_u rm -rf "$s" || true; echo running; exit 0; }"#.to_owned(),
        // An earlier start launched a runner that has not taken over yet: its files are not
        // replaced under it. After a minute without it (the applier's wait for a `starting` too)
        // that start counts as dead.
        r#"at=$(sed -n 's/^{"state":"starting".*"at":\([0-9]*\)}$/\1/p' "$d/status.json" 2>/dev/null || true)"#.to_owned(),
        r#"if [ -n "$at" ] && [ $(( $(date +%s) - at )) -lt 60 ]; then as_u rm -rf "$s" || true; echo running; exit 0; fi"#.to_owned(),
        // No runner runs: this start's files become the bootstrap folder's (a rename each, as the
        // work user), where the runner and a machine-config apply read them (`script`,
        // `repo.json`).
        r#"for f in script env run repo repo.json; do as_u mv -f "$s/$f" "$d/$f"; done; as_u rm -rf "$s""#.to_owned(),
        // `script_sha256` is the script's; `start_sha256` is the script's and the repo step's,
        // which say together what a start runs: the same pair done already runs nothing.
        r#"sum=$(sha256sum "$d/script" | cut -d' ' -f1); key=$(cat "$d/script" "$d/repo" | sha256sum | cut -d' ' -f1)"#.to_owned(),
        // Not when its background fill failed since: the same start repairs it.
        FILL_FAILED.to_owned(),
        r#"if grep -q "\"state\":\"done\".*\"start_sha256\":\"$key\"" "$d/status.json" 2>/dev/null && ! fill_failed; then echo skipped; exit 0; fi"#.to_owned(),
        r#"as_u rm -f "$d/repo-status.json""#.to_owned(),
        // Only when a runner is launched: a machine-config applier waits on `starting` (a retry of
        // a failed script too). The runner takes `alive` once it runs, which the applier waits on
        // too.
        r#"printf '{"state":"starting","exit_code":null,"script_sha256":"%s","start_sha256":"%s","at":%s}\n' "$sum" "$key" "$(date +%s)" | as_u tee "$d/status.json" >/dev/null"#.to_owned(),
        "exec 6<&-".to_owned(),
        format!(
            r#"if command -v systemd-run >/dev/null 2>&1 && {{ root systemctl reset-failed {UNIT} 2>/dev/null || true; root systemd-run --quiet --collect --unit={UNIT} --uid="$u" --gid="$u" --setenv=HOME="$h" --working-directory="$h" "$d/run"; }}; then :; else as_u env HOME="$h" setsid nohup "$d/run" >/dev/null 2>&1 </dev/null 7<&- & fi"#
        ),
        "echo started".to_owned(),
    ]
    .join("; ")
}

/// One read: waits (`flock -s -w`) while a runner holds `alive`, which it holds for its whole life
/// and the kernel drops however it ends, and reads [`status_path`] while it holds the lock shared,
/// so a runner can't take over between the two (a runner writes its status only while it holds
/// `alive`). It prints whether the lock was `free`, `held` (the wait ran out: read again) or `none`
/// (no runner made it yet), the machine's clock, and the status. The lock is let go at once, like
/// the applier's probe: a runner about to take it waits a moment at most. Only a start whose runner
/// has not taken over yet (`starting`, normally a few milliseconds) has no lock to wait on: that
/// read waits one second first, so a runner that never comes costs one read a second until its
/// minute is up.
pub fn wait_command() -> String {
    [
        "set -u".to_owned(),
        format!("d={DIRECTORY}"),
        format!("u={USER}"),
        HOME_OF_USER.to_owned(),
        NO_SYMLINKS.to_owned(),
        r#"if grep -q '"state":"starting"' "$d/status.json" 2>/dev/null; then sleep 1; fi"#.to_owned(),
        // The clock is read just before the status, under the same lock: a `starting` never looks
        // older than it is.
        "w=none; s=''; n=$(date +%s)".to_owned(),
        format!(
            r#"if [ -f "$d/alive" ] && [ ! -L "$d/alive" ] && exec 8<"$d/alive"; then if flock -s -w {COMPLETION_LOCK_WAIT} 8; then w=free; n=$(date +%s); s=$(cat "$d/status.json" 2>/dev/null || true); else w=held; fi; exec 8<&-; else n=$(date +%s); s=$(cat "$d/status.json" 2>/dev/null || true); fi"#
        ),
        r#"printf 'cmux-wait %s %s\n%s\n' "$w" "$n" "$s""#.to_owned(),
    ]
    .join("; ")
}

// MARK: The start's plan

pub use crate::machine_repo::Repo;

/// One step of a plan: a file write over the Cloud file API, or one exec.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Step {
    /// Writes `text`, or the caller's own bytes (`payload`: the script or the machine config).
    Write {
        path: String,
        mode: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        payload: Option<Payload>,
    },
    /// Runs `command`; its answer goes to [`step_outcome`] with `said`.
    Exec { command: String, said: Vec<String> },
}

/// The caller's bytes a write step sends.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Payload {
    Script,
    Config,
}

/// The steps of one start or apply, in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    pub steps: Vec<Step>,
}

/// A bootstrap start's facts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartRequest {
    #[serde(default)]
    pub kind: Kind,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub repo: Option<Repo>,
    /// A UUID of the app's, naming this start's upload folder.
    pub start_id: String,
}

/// Uploads the script with its environment, the runner and the repo step into a folder of this
/// start's own, then starts: no upload ever changes the files a running runner runs.
pub fn start_plan(request: &StartRequest) -> Plan {
    let staged = staging_directory(&request.start_id);
    let write = |name: &str, mode: u32, text: String| Step::Write {
        path: format!("{staged}/{name}"),
        mode,
        text: Some(text),
        payload: None,
    };
    let repo = request.repo.as_ref();
    Plan {
        steps: vec![
            // The directory belongs to the machine's user, so its runner can write the log and
            // status.
            Step::Exec { command: prepare_command(&staged), said: Vec::new() },
            Step::Write {
                path: format!("{staged}/script"),
                mode: 0o700,
                text: None,
                payload: Some(Payload::Script),
            },
            write("env", 0o600, environment(request.kind, request.name.as_deref())),
            write("run", 0o700, runner().to_owned()),
            // Always both, so no step or record of an earlier start is left: no repo is `null` and
            // a no-op.
            write("repo.json", 0o644, repo.map_or_else(|| "null\n".to_owned(), Repo::record)),
            write("repo", 0o700, repo.map_or_else(|| NO_SCRIPT.to_owned(), Repo::step)),
            Step::Exec {
                command: start_command(&staged),
                said: ["started", "running", "skipped"].map(String::from).to_vec(),
            },
        ],
    }
}

/// One exec's answer, as the app got it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecAnswer {
    pub exit_code: i64,
    #[serde(default)]
    pub stdout: String,
    #[serde(default)]
    pub stderr: String,
}

/// How a start went: `started`, `running` (another start's run is under way; this one's files are
/// dropped), `skipped` (this script and repo step already finished here) or `failed` with its
/// `reason`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Outcome {
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl Outcome {
    pub fn failed(reason: String) -> Self {
        Self { status: "failed".into(), reason: Some(reason) }
    }
}

/// A character Swift's `Character.isNewline` takes for a line break.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// A failed exec's words: the last 500 characters of its stderr, else of its stdout.
fn tail(ran: &ExecAnswer) -> String {
    let text = if ran.stderr.is_empty() { &ran.stdout } else { &ran.stderr };
    let count = text.chars().count();
    text.chars().skip(count.saturating_sub(500)).collect()
}

/// After one exec of a plan: `None` goes on to the next step; otherwise the plan ends with this
/// outcome. An exec with no `said` only has to succeed; the last one says how the start went in
/// its last line, which must be one of `said`.
pub fn step_outcome(ran: &ExecAnswer, said: &[String]) -> Option<Outcome> {
    if said.is_empty() {
        return (ran.exit_code != 0).then(|| Outcome::failed(tail(ran)));
    }
    let last = ran.stdout.split(is_newline).rfind(|line| !line.is_empty()).unwrap_or("");
    if ran.exit_code == 0 && said.iter().any(|word| word == last) {
        Some(Outcome { status: last.to_owned(), reason: None })
    } else {
        Some(Outcome::failed(tail(ran)))
    }
}

// MARK: The run's end

/// The run's end as [`status_path`] says it, before it becomes words.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "run")]
pub enum Run {
    /// The script, and the clone when one was asked, finished. `repo_path` is the clone's absolute
    /// path on the machine (`/home/cmux/work/NAME`); none without a repo.
    #[serde(rename_all = "camelCase")]
    Finished { repo_path: Option<String> },
    /// The repo step found no GitHub access to `repo` (`OWNER/NAME`) on the machine.
    NeedsGitHub { repo: String },
    /// The clone or update of `repo` failed (another repository in its folder, a missing ref…).
    RepoFailed { repo: String },
    #[serde(rename_all = "camelCase")]
    ScriptFailed { exit_code: i64 },
    /// The start's runner never took over (it came a minute late, or not at all).
    RunnerNeverCame,
    /// The runner ended without writing its end (killed, or the machine restarted).
    Stopped,
    /// The wait's bound passed (or the wait was cancelled) while the runner still ran.
    StillRunning,
    /// The machine did not answer three reads in a row; the last error's text.
    Unreachable { error: String },
}

/// One [`wait_command`] answer: the run's end, or read again (`wait`), or an answer that says
/// nothing (`unreadable`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Read {
    Ended(Run),
    Wait,
    Unreadable,
}

/// An integer JSON value as Swift's `as? Int` reads it: a whole number in range.
fn integer(value: Option<&serde_json::Value>) -> Option<i64> {
    let value = value?;
    value.as_i64().or_else(|| {
        value.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18).map(|f| f as i64)
    })
}

/// One [`wait_command`] answer. `repo` is what this bootstrap asked to clone (none: no repo).
pub fn read(ran: &ExecAnswer, repo: Option<&Repo>) -> Read {
    use serde_json::Value;
    let mut lines = ran.stdout.split('\n');
    if ran.exit_code != 0 {
        return Read::Unreadable;
    }
    let Some(head) = lines.by_ref().find(|line| line.starts_with("cmux-wait ")) else {
        return Read::Unreadable;
    };
    let head: Vec<&str> = head.split(' ').filter(|part| !part.is_empty()).collect();
    let [_, lock, now] = head.as_slice() else { return Read::Unreadable };
    let Ok(now) = now.parse::<i64>() else { return Read::Unreadable };
    let lock = *lock;
    if lock == "held" {
        return Read::Wait;
    }
    let text = lines.collect::<Vec<_>>().join("\n");
    let text = text.trim_matches(|c: char| c.is_whitespace());
    // No status at all: no start ever got as far as `starting` here.
    if text.is_empty() {
        return Read::Ended(Run::RunnerNeverCame);
    }
    let Ok(Value::Object(status)) = serde_json::from_str::<Value>(text) else {
        return Read::Unreadable;
    };
    let Some(state) = status.get("state").and_then(Value::as_str) else { return Read::Unreadable };
    let code = integer(status.get("exit_code"));
    let cloned = status.get("repo").and_then(Value::as_object);
    let repo_status = cloned.and_then(|c| c.get("status")).and_then(Value::as_str);
    let name = repo.map(Repo::display).unwrap_or_else(|| {
        cloned.and_then(|c| c.get("url")).and_then(Value::as_str).unwrap_or("").to_owned()
    });
    let repo_end = |repo_status: Option<&str>| {
        if repo_status == Some("needs_github") {
            Run::NeedsGitHub { repo: name.clone() }
        } else {
            Run::RepoFailed { repo: name.clone() }
        }
    };
    match state {
        "done" => {
            let Some(repo) = repo else { return Read::Ended(Run::Finished { repo_path: None }) };
            if !repo_status.is_none_or(|s| ["cloned", "updated", "kept"].contains(&s)) {
                return Read::Ended(repo_end(repo_status));
            }
            let dir = cloned
                .and_then(|c| c.get("dir"))
                .and_then(Value::as_str)
                .filter(|dir| dir.starts_with('/'))
                .map(str::to_owned);
            Read::Ended(Run::Finished {
                repo_path: Some(
                    dir.unwrap_or_else(|| format!("/home/{USER}/{}", repo.directory())),
                ),
            })
        }
        "failed" => {
            // The runner's own refusal when it came a minute after its start (`"late":true`),
            // before any step.
            if status.get("late").and_then(Value::as_bool) == Some(true) {
                return Read::Ended(Run::RunnerNeverCame);
            }
            // `step` says which step failed; a runner from before it (no `step`) is read from the
            // repo status.
            let repo_step = match status.get("step").and_then(Value::as_str) {
                Some(step) => step == "repo",
                None => {
                    repo_status == Some("failed")
                        || (repo_status == Some("needs_github") && code == Some(NEEDS_GITHUB_EXIT))
                }
            };
            if !repo_step {
                return Read::Ended(Run::ScriptFailed { exit_code: code.unwrap_or(-1) });
            }
            Read::Ended(repo_end(repo_status))
        }
        // Read under a free `alive`: the runner that wrote `running` is gone. Without an `alive`
        // the read raced the runner making it (the next read sees it); counted as a failed read,
        // so it never spins.
        "running" if lock == "free" => Read::Ended(Run::Stopped),
        "running" => Read::Unreadable,
        "starting" => {
            let at = integer(status.get("at")).unwrap_or(now);
            if now.saturating_sub(at) >= 60 {
                Read::Ended(Run::RunnerNeverCame)
            } else {
                Read::Wait
            }
        }
        _ => Read::Unreadable,
    }
}

/// One read of a wait, as the app made it: the machine's answer, or the error the exec threw.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitRead {
    #[serde(default)]
    pub answer: Option<ExecAnswer>,
    /// The thrown error's text (an exec cut off at its timeout, a machine that does not answer).
    #[serde(default)]
    pub error: Option<String>,
    /// Failed reads in a row before this one.
    #[serde(default)]
    pub failures: u32,
    #[serde(default)]
    pub repo: Option<Repo>,
}

/// What the wait does after one read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitNext {
    /// The run ended: the wait returns it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended: Option<Run>,
    /// Failed reads in a row, this one counted.
    pub failures: u32,
    /// Set once [`MAX_FAILED_READS`] reads in a row failed: the wait ends as
    /// [`Run::Unreachable`] (unless it was cancelled meanwhile, which ends it still running).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unreachable: Option<Run>,
}

/// After one read of a wait: an ended run returns at once; a read that says read again resets the
/// failures; an unreadable answer or a thrown exec counts one more failure (an exec cut off at its
/// timeout is read again; a machine that never answers is not).
pub fn wait_next(read_: &WaitRead) -> WaitNext {
    let (failures, last) = match (&read_.answer, &read_.error) {
        (Some(answer), _) => match read(answer, read_.repo.as_ref()) {
            Read::Ended(run) => {
                return WaitNext { ended: Some(run), failures: read_.failures, unreachable: None };
            }
            Read::Wait => (0, String::new()),
            Read::Unreadable => (read_.failures.saturating_add(1), "unreadable answer".to_owned()),
        },
        (None, error) => (read_.failures.saturating_add(1), error.clone().unwrap_or_default()),
    };
    WaitNext {
        ended: None,
        failures,
        unreachable: (failures >= MAX_FAILED_READS).then_some(Run::Unreachable { error: last }),
    }
}

#[cfg(test)]
mod tests;
