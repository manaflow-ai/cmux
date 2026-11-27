//! A Cloud machine's cmux-tui update, as the app's Swift once decided it around the
//! `cmux link machine update` CLI (`CloudMachineUpdateTarget`, `CloudMachineUpdate`) and the
//! legacy update through the Cloud API's exec (`CloudLegacyMachineUpdate`). Pure: the app runs
//! the CLI and the execs and hands each answer here; this says what it means and what to run next.
//!
//! - [`outcome`]: the shared daemon update policy's outcome of one `link machine update` answer,
//!   then [`checked`]: an update that reports another build than the one asked for failed.
//! - [`stop`]: the person's "Update Machine" button's stop for a refused answer.
//! - [`start_command`], [`wait_command`], [`install_command`]: the legacy update's shell, and
//!   [`begin`] / [`advance`]: its run (one start exec, then waits until a result line).

use serde::{Deserialize, Serialize};

use super::cli::{Answer, BAD_ANSWER, ExecRun};
use super::pin::{self, Pin};

/// The Rust target the shared policy names when the app carries no machine build (images/cmux-vm).
pub const CLOUD_TARGET: &str = "x86_64-unknown-linux-gnu";

/// `link machine update`'s code for a start's own update that ran past its bound.
pub const MACHINE_UPDATE_ABANDONED: &str = "machine_update_abandoned";

/// Where the app's per-commit Linux builds are published (`RemoteInstallPlan.base`).
pub const RELEASE_BASE: &str = "https://files.cmux.com/cmux-tui";

/// The fleet upgrade's directory: its runs share one lock, so the app's run and an operator's
/// never overlap on one machine.
pub const DIRECTORY: &str = "/var/lib/cmux-tui-upgrade";

/// One wait's bound on the machine, under the provider's 5-minute exec.
pub const WAIT_SECONDS: u64 = 270;

/// Waits before the app stops asking (about 27 minutes).
pub const WAITS: u32 = 6;

/// The start exec's timeout.
pub const START_TIMEOUT_MS: u64 = 60_000;

/// The shared update policy's outcome (`DaemonUpdateOutcome`). `unsupported`'s reason is the
/// app's own localized text, so it carries none here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Outcome {
    HandledElsewhere,
    Updated {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        build: Option<String>,
    },
    Current,
    Busy,
    Held {
        reason: String,
    },
    NeedsBinary {
        target: String,
    },
    Unsupported,
    RolledBack {
        reason: String,
    },
    Failed {
        reason: String,
    },
}

/// The policy's outcome of one `link machine update` answer (cmux-tui `link/machine_update.rs`).
pub fn outcome(answer: &Answer) -> Outcome {
    // A newer build than this app's (or the same tree): not this app's to replace.
    if answer.ok && answer.not_older {
        return Outcome::HandledElsewhere;
    }
    if answer.ok {
        return if answer.updated {
            Outcome::Updated { build: answer.build.clone() }
        } else {
            Outcome::Current
        };
    }
    let detail = answer
        .error
        .clone()
        .or_else(|| answer.error_code.clone())
        .unwrap_or_else(|| BAD_ANSWER.to_owned());
    match answer.error_code.as_deref() {
        // Another update runs, the daemon did not answer, the CLI lost the machine before it read
        // the end, or the old daemon outlived its stop: not now, not recorded, asked again.
        Some(
            "machine_update_busy"
            | "machine_unreachable"
            | "machine_update_unresolved"
            | "machine_update_pending",
        ) => Outcome::Busy,
        // Someone's own build from another path, or a start's own update past its bound: no toast.
        Some("machine_update_foreign_daemon" | MACHINE_UPDATE_ABANDONED) => {
            Outcome::Held { reason: detail }
        }
        Some("machine_update_unavailable" | "machine_update_download_failed") => {
            Outcome::NeedsBinary { target: CLOUD_TARGET.to_owned() }
        }
        Some("machine_update_unsupported") => Outcome::Unsupported,
        Some("machine_update_rolled_back") => Outcome::RolledBack { reason: detail },
        _ => Outcome::Failed { reason: detail },
    }
}

/// `other` names commit `hash` (`DaemonBuildCommit.sameCommit`): at least 7 lowercase hex
/// characters, one a prefix of the other.
pub fn same_commit(hash: &str, other: &str) -> bool {
    let other = other.to_lowercase();
    other.len() >= 7
        && other.bytes().all(|byte| byte.is_ascii_hexdigit())
        && (hash.starts_with(&other) || other.starts_with(hash))
}

/// What the CLI's run of the update came to: its answer, or why it threw.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Ran {
    /// The answer used (the legacy exec update's, when that ran instead).
    pub answer: Option<Answer>,
    /// The CLI ran past its deadline: how the update ended is unknown.
    pub timed_out: bool,
    /// Any other thrown error, as text.
    pub error: Option<String>,
    /// The build the update was asked for (`DaemonBuildCommit.hash`).
    pub build: String,
    /// The legacy update's pinned build, when it ran: a DEV build's tree pin is its tree's
    /// publishing commit, which the machine then reports.
    pub pinned: Option<String>,
}

/// The policy's outcome of one update run, and whether the machine's daemon may have restarted
/// (no answer: it may have).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Checked {
    pub outcome: Outcome,
    pub restarted: bool,
}

/// [`outcome`] of a run, held to the build it asked for.
pub fn checked(ran: &Ran) -> Checked {
    let outcome = match (&ran.answer, ran.timed_out) {
        (_, true) => Outcome::Busy,
        (Some(answer), false) => outcome(answer),
        (None, false) => Outcome::Failed { reason: ran.error.clone().unwrap_or_default() },
    };
    let outcome = match outcome {
        Outcome::Updated { build: Some(reported) }
            if !same_commit(&ran.build, &reported)
                && ran.pinned.as_deref() != Some(reported.as_str()) =>
        {
            Outcome::Failed {
                reason: format!(
                    "the machine reports build {reported} after the update, not {}",
                    ran.build
                ),
            }
        }
        other => other,
    };
    let restarted = if ran.timed_out {
        true
    } else {
        ran.answer.as_ref().is_none_or(Answer::may_have_restarted_daemon)
    };
    Checked { outcome, restarted }
}

/// The build the CLI judged older when it answered `machine_update_unsupported`: the legacy exec
/// update runs only then, held to it. None: not that way.
pub fn legacy_judged(answer: &Answer) -> Option<&str> {
    if answer.error_code.as_deref() != Some("machine_update_unsupported") {
        return None;
    }
    answer.build.as_deref().filter(|build| !build.is_empty())
}

/// The "Update Machine" button's stop for an answer (`CloudMachineUpdate.run`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "stop", rename_all = "camelCase")]
pub enum Stop {
    /// Updated or current: the move goes on.
    None,
    /// Too old to update in place: no Retry.
    Unsupported,
    /// This app carries no machine build: no Retry.
    Unavailable,
    /// Anything else, with what it said: Retry may help.
    Failed { detail: String },
}

pub fn stop(answer: &Answer) -> Stop {
    if answer.ok {
        return Stop::None;
    }
    match answer.error_code.as_deref() {
        Some("machine_update_unsupported") => Stop::Unsupported,
        Some("machine_update_unavailable") => Stop::Unavailable,
        _ => Stop::Failed {
            detail: answer.error.clone().or_else(|| answer.error_code.clone()).unwrap_or_default(),
        },
    }
}

/// The immutable per-commit release `cmux link machine update` downloads too.
pub fn url(pin: &Pin) -> String {
    format!("{RELEASE_BASE}/{}/cmux-tui-{}", pin.commit, pin::TARGET)
}

/// The transient unit of run `nonce`.
pub fn unit(nonce: &str) -> String {
    format!("cmux-app-tui-update-{nonce}")
}

/// The daemon's user `u` and home `h` (`cmuxTuiLayoutSelector` in
/// web/services/vms/drivers/cmuxTuiDaemon.ts).
const LAYOUT: &str = "if id -u cmux >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && setpriv --reuid=cmux --regid=cmux --init-groups test -w /home/cmux 2>/dev/null && setpriv --reuid=cmux --regid=cmux --init-groups sudo -n true >/dev/null 2>&1; then u=cmux; h=/home/cmux; else u=root; h=/root; fi";

/// `root CMD`: CMD as root, from the machine's user (passwordless sudo) or root.
const ROOT_HELPER: &str = r#"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#;

/// `echo BASE64 | base64 -d | root tee FILE`: the exec body carries no quoting of its own.
fn write_file(contents: &str, file: &str) -> String {
    format!("echo {} | base64 -d | root tee \"{file}\" >/dev/null", base64(contents.as_bytes()))
}

/// Standard base64 with padding (Foundation's `base64EncodedString()`).
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let byte = |at: usize| u32::from(chunk.get(at).copied().unwrap_or(0));
        let n = (byte(0) << 16) | (byte(1) << 8) | byte(2);
        for i in 0..4 {
            if i <= chunk.len() {
                let sextet = (n >> (18 - 6 * i)) & 63;
                out.push(ALPHABET.get(sextet as usize).map_or('=', |&c| char::from(c)));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The pinned install the guest script runs as root (`install.cmd`): the daemon's own layout,
/// the pinned binary downloaded and checked beside it, then renamed over it, owned by the
/// daemon's user. A binary that already matches the pin stays.
pub fn install_command(pin: &Pin) -> String {
    let check = |file: &str| {
        format!("printf '%s  %s\\n' {} \"{file}\" | sha256sum -c >/dev/null 2>&1", pin.sha256)
    };
    let lines = [
        "set -eu".to_owned(),
        LAYOUT.to_owned(),
        r#"bin="$h/.cmux/bin/cmux-tui"; tmp="$bin.app-update""#.to_owned(),
        format!("if [ -x \"$bin\" ] && {}; then :; else", check("$bin")),
        format!(
            "  curl -fsSL --retry 3 -o \"$tmp\" '{}' && {} || {{ rm -f \"$tmp\"; echo 'the pinned build did not download or match its pin' >&2; exit 1; }}",
            url(pin),
            check("$tmp")
        ),
        r#"  chmod 755 "$tmp"; [ "$u" = root ] || chown "$u:$u" "$tmp"; mv -f "$tmp" "$bin""#
            .to_owned(),
        "fi".to_owned(),
        r#"ln -sfn "$bin" /usr/local/bin/cmux-tui"#.to_owned(),
        r#""$bin" --version"#.to_owned(),
    ];
    lines.join("\n") + "\n"
}

/// The start exec: the run's files go to a fresh directory (runs older than a week go), and the
/// guest script starts as root in a transient systemd unit (without systemd, under `setsid`),
/// detached from the exec. Says `started`, or `NOROOT` from an account that cannot become root.
/// `expected` (a 40-hex commit; anything else is left out) goes to `<run-dir>/expect-build`.
pub fn start_command(
    pin: &Pin,
    script: &str,
    nonce: &str,
    directory: &str,
    expected: Option<&str>,
) -> String {
    let args = format!("{} {} \"$r\"", pin.sha256, pin.commit);
    let unit = unit(nonce);
    let mut lines = vec![
        "set -eu".to_owned(),
        ROOT_HELPER.to_owned(),
        "root true 2>/dev/null || { echo NOROOT; exit 0; }".to_owned(),
        format!("d={directory}; r=\"$d/app-{nonce}\""),
        r#"root mkdir -p "$r""#.to_owned(),
        r#"root find "$d" -maxdepth 1 -name 'app-*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true"#
            .to_owned(),
        write_file(&install_command(pin), "$r/install.cmd"),
        write_file(script, "$r/upgrade.sh"),
    ];
    // It reaches a shell: only a 40-hex commit.
    if let Some(expected) = expected.map(str::to_lowercase).filter(|text| pin::is_hex(text, 40)) {
        lines.push(write_file(&format!("{expected}\n"), "$r/expect-build"));
    }
    lines.extend([
        format!("if command -v systemd-run >/dev/null 2>&1 && root systemd-run --quiet --collect --unit={unit} /bin/sh \"$r/upgrade.sh\" {args} >/dev/null 2>&1; then"),
        format!("  echo {unit} | root tee \"$r/unit\" >/dev/null"),
        "else".to_owned(),
        // sudo's command is the shell, which ends at once: the run is its child's, not sudo's.
        format!("  pid=$(root sh -c 'setsid nohup /bin/sh \"$1\" \"$2\" \"$3\" \"$4\" </dev/null >/dev/null 2>&1 & echo $!' sh \"$r/upgrade.sh\" {args})"),
        r#"  printf '%s\n' "$pid" | root tee "$r/pid" >/dev/null"#.to_owned(),
        "fi".to_owned(),
        "echo started".to_owned(),
    ]);
    lines.join("\n")
}

/// A wait exec: until the run's process ends, at most `seconds`, then its result line on stdout
/// and the log's tail on stderr. A run that ended takes its files and, unless its rollback
/// failed, the backup of the old binary with it.
pub fn wait_command(nonce: &str, directory: &str, seconds: u64) -> String {
    [
        "set -eu".to_owned(),
        ROOT_HELPER.to_owned(),
        format!("r={directory}/app-{nonce}"),
        r#"if [ -s "$r/unit" ]; then pid=$(root systemctl show -p MainPID --value "$(root cat "$r/unit")" 2>/dev/null || echo 0); else pid=$(root cat "$r/pid" 2>/dev/null || echo 0); fi"#.to_owned(),
        format!("if [ \"${{pid:-0}}\" -gt 0 ] 2>/dev/null && root kill -0 \"$pid\" 2>/dev/null; then root timeout {seconds} tail --pid=\"$pid\" -f /dev/null >/dev/null 2>&1 || true; fi"),
        r#"line=$(root cat "$r/result" 2>/dev/null || true); root tail -n 15 "$r/log" >&2 2>/dev/null || true"#.to_owned(),
        r#"case "$line" in ""|running|PENDING*) ;; "FAIL rollback"*) root rm -f "$r/install.cmd" "$r/upgrade.sh" ;; *) root rm -f "$r/install.cmd" "$r/upgrade.sh" "$r/cmux-tui.prev" ;; esac"#.to_owned(),
        r#"printf '%s\n' "$line""#.to_owned(),
    ]
    .join("\n")
}

/// A legacy update run's inputs. The app makes `nonce` (16 hex characters) and reads `script`
/// from its resources.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub pin: Pin,
    #[serde(default)]
    pub script: String,
    pub nonce: String,
    #[serde(default)]
    pub directory: Option<String>,
    #[serde(default)]
    pub wait_seconds: Option<u64>,
    #[serde(default)]
    pub waits: Option<u32>,
    /// The 40-hex commit `--if-older` judged older; the guest leaves a changed binary alone.
    #[serde(default)]
    pub expected: Option<String>,
}

/// Where a run is, carried by the app between execs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub commit: String,
    pub nonce: String,
    pub directory: String,
    pub wait_seconds: u64,
    pub waits: u32,
    /// The start exec ran; false before its answer.
    #[serde(default)]
    pub started: bool,
    /// Waits still to run.
    #[serde(default)]
    pub left: u32,
    /// The start ended on its own without `started`: what it said.
    #[serde(default)]
    pub refused: Option<String>,
}

/// The run's next step: one exec to run (its answer goes to [`advance`]), or its answer.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "step", rename_all = "camelCase")]
pub enum Step {
    #[serde(rename_all = "camelCase")]
    Exec {
        command: String,
        timeout_ms: u64,
        state: State,
    },
    Done {
        answer: Box<Answer>,
    },
}

/// The run's first exec: the start.
pub fn begin(plan: &Plan) -> Step {
    let directory = plan.directory.clone().unwrap_or_else(|| DIRECTORY.to_owned());
    let command =
        start_command(&plan.pin, &plan.script, &plan.nonce, &directory, plan.expected.as_deref());
    Step::Exec {
        command,
        timeout_ms: START_TIMEOUT_MS,
        state: State {
            commit: plan.pin.commit.clone(),
            nonce: plan.nonce.clone(),
            directory,
            wait_seconds: plan.wait_seconds.unwrap_or(WAIT_SECONDS),
            waits: plan.waits.unwrap_or(WAITS),
            started: false,
            left: 0,
            refused: None,
        },
    }
}

/// The run after one exec's answer (`ran` none: it threw or did not answer). A start that did not
/// answer, or that the provider ended (exit 124), may have started the run: the waits read what it
/// left. Only a start that ended on its own and said otherwise started nothing, so one wait reads
/// the run that never began. A wait without an outcome is followed by the next; with none left the
/// answer is `machine_update_unresolved`, so the policy asks again.
pub fn advance(mut state: State, ran: Option<&ExecRun>) -> Step {
    if !state.started {
        state.started = true;
        if let Some(started) = ran {
            if started.last_line() == "NOROOT" {
                return Step::Done {
                    answer: Box::new(started.legacy_update_answer(&state.commit)),
                };
            }
            if started.last_line() != "started" && started.exit_code != 124 {
                state.refused = Some(started.failure_detail());
            }
        }
        state.left = if state.refused.is_some() { 1 } else { state.waits };
    } else if let Some(waited) = ran {
        let reply = waited.legacy_update_answer(&state.commit);
        if reply.error_code.as_deref() != Some("machine_update_unresolved") {
            return Step::Done { answer: Box::new(reply) };
        }
    }
    if state.left > 0 {
        state.left -= 1;
        return Step::Exec {
            command: wait_command(&state.nonce, &state.directory, state.wait_seconds),
            timeout_ms: (state.wait_seconds + 20) * 1000,
            state,
        };
    }
    if let Some(detail) = state.refused {
        return Step::Done { answer: Box::new(Answer::failed("machine_update_failed", detail)) };
    }
    let minutes = u64::from(state.waits) * state.wait_seconds / 60;
    Step::Done {
        answer: Box::new(Answer::failed(
            "machine_update_unresolved",
            format!("the machine's update did not end within {minutes} minutes"),
        )),
    }
}

#[cfg(test)]
#[path = "machine_update_tests.rs"]
mod tests;
