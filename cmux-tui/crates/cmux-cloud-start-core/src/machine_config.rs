//! `.cmux/machine.toml`: one declared source per machine for its env, its secret names and its
//! setup (moved from the app's `CloudMachineConfig`). `cmux cloud new-machine --machine-config
//! FILE` and `cmux cloud apply-machine-config --target machine:<id> [--machine-config FILE]` upload
//! the file (names and plain values only, never a secret value) with the applier, and one short
//! exec starts the applier detached, as the bootstrap does. Without a file, the applier takes the
//! `--repo` checkout's `.cmux/machine.toml`, else the file uploaded last time.
//!
//! ```toml
//! version = 1
//! [env]                              # to ~/.config/cmux/machine.env (0600), sourced by shells
//! NODE_ENV = "development"
//! [secrets]
//! names = ["DATABASE_URL"]           # names only; reported missing until delivered
//! [setup]
//! run = ["bun install"]              # in order, bash -l, in the checkout; reruns only on change
//! timeout_minutes = 30               # per command
//! check = ["bun run typecheck"]      # reported, never a gate
//! ```
//!
//! The file is parsed on the machine, by the applier ([`applier`], Python's `tomllib`), never on
//! the Mac: the applier also takes the checkout's own file, which the Mac never reads. Secret
//! values (delivered over the daemon link) reach shells and agents but never `[setup]` or `check`
//! (run with `CMUX_MACHINE_SETUP=1`, in an environment of their own), whose output goes to
//! [`log_path`] with every delivered value masked, and never into [`status_path`], which the app
//! reads through the Cloud file API. Masking catches a value printed by accident; setup is the
//! person's own code, run as the machine's user, which can read the values anyway.
//!
//! The applier waits for a running bootstrap (the `--repo` clone) first, takes its own lock (a
//! second start says `running`), writes [`status_path`] (`waiting|running|done|failed`, the
//! source, `config_sha`, env names, `secrets.missing`, `setup` with `failing_index`, `checks`) and
//! ends when the last command does.

use serde::{Deserialize, Serialize};

use crate::machine_bootstrap::{HOME_OF_USER, Plan, ROOT_HELPER, Step, USER, USER_HELPER};

pub const DIRECTORY: &str = "/home/cmux/.cmux/machine-config";
/// The transient unit the applier runs in (`systemctl status cmux-machine-config`).
pub const UNIT: &str = "cmux-machine-config";
/// The largest file the applier takes.
pub const MAX_BYTES: usize = 64 * 1024;

const APPLIER: &str = include_str!("machine_config/applier.py");

/// The applier (`~/.cmux/machine-config/apply`, run with `python3 -I`).
pub fn applier() -> &'static str {
    APPLIER.strip_suffix('\n').unwrap_or(APPLIER)
}

pub fn status_path() -> String {
    format!("{DIRECTORY}/status.json")
}

pub fn log_path() -> String {
    format!("{DIRECTORY}/setup.log")
}

/// A request's name: unix ms, zero-padded so names sort by time, and the first 8 characters of a
/// random `nonce` (the app's UUID), lowercased.
pub fn request_id(now_ms: i64, nonce: &str) -> String {
    let random: String = nonce.chars().take(8).collect::<String>().to_lowercase();
    format!("{now_ms:013}-{random}")
}

const NO_SYMLINKS: &str = r#"for p in "$h/.cmux" "$d" "$d/requests"; do [ -L "$p" ] && { echo "$p is a symlink" >&2; exit 1; }; done"#;

/// As the bootstrap's prepare command, from root or the work user: the folders are the work
/// user's and 0700, and none on the way may be a symlink (uploads and the applier's cleanup would
/// follow it).
pub fn prepare_command() -> String {
    [
        "set -eu".to_owned(),
        ROOT_HELPER.to_owned(),
        format!("d={DIRECTORY}"),
        format!("u={USER}"),
        HOME_OF_USER.to_owned(),
        NO_SYMLINKS.to_owned(),
        r#"root mkdir -p "$d/requests" && root chown "$u:$u" "$h/.cmux" "$d" "$d/requests" && root chmod 700 "$d" "$d/requests""#.to_owned(),
    ]
    .join("; ")
}

/// As the bootstrap's start command: the files go to the work user (checked by owner name), a
/// request becomes complete only then, a running applier (its lock) answers `running`, and the
/// applier runs as the work user with its home in a transient systemd unit (python3 by its
/// absolute path: an older systemd-run does not search PATH), else under `setsid`. The unit's
/// control group goes with it: a setup command that escaped its process group (`setsid`, a
/// daemon) is stopped when the apply ends; the no-systemd fallback cannot do that. It needs python3
/// with `tomllib` (3.11+; Ubuntu 24.04 has 3.12). Finalizes only `request`'s own files (an applier
/// may be taking others, and another writer may still be staging its own), then starts the
/// applier.
pub fn start_command(request: &str) -> String {
    [
        "set -eu".to_owned(),
        ROOT_HELPER.to_owned(),
        USER_HELPER.to_owned(),
        format!("d={DIRECTORY}"),
        format!("u={USER}"),
        format!("r={request}"),
        HOME_OF_USER.to_owned(),
        NO_SYMLINKS.to_owned(),
        // After the symlink check: only the known staged files, never a link (-h), never a whole
        // tree.
        r#"root chown -h "$u:$u" "$d" "$d/requests" "$d/requests/$r.apply" "$d/requests/$r.pending" $([ -e "$d/requests/$r.toml" ] && echo "$d/requests/$r.toml") 2>/dev/null || true"#.to_owned(),
        r#"for f in requests requests/$r.apply requests/$r.pending $([ -e "$d/requests/$r.toml" ] && echo requests/$r.toml); do [ "$(stat -c %U "$d/$f")" = "$u" ] || { echo "$d/$f is not $u's: the start needs root or passwordless sudo" >&2; exit 1; }; done"#.to_owned(),
        // Owned now: the applier replaces the shared one in one rename (a running one keeps its
        // open file).
        r#"as_u mv -f "$d/requests/$r.apply" "$d/apply""#.to_owned(),
        r#"py=$(command -v python3) && "$py" -I -c 'import tomllib' 2>/dev/null || { echo "the machine has no python3 with tomllib (3.11 or later)" >&2; exit 1; }"#.to_owned(),
        // Owned now: this request becomes complete (and visible to a running applier) only here.
        r#"as_u mv -f "$d/requests/$r.pending" "$d/requests/$r.json""#.to_owned(),
        r#"if ! as_u flock -w 5 "$d/lock" true; then echo running; exit 0; fi"#.to_owned(),
        format!(
            r#"if command -v systemd-run >/dev/null 2>&1 && {{ root systemctl reset-failed {UNIT} 2>/dev/null || true; root systemd-run --quiet --collect --unit={UNIT} --property=KillMode=control-group --uid="$u" --gid="$u" --setenv=HOME="$h" --working-directory="$h" "$py" -I "$d/apply"; }}; then :; else command -v setsid >/dev/null 2>&1 || {{ echo "the machine has neither a working systemd-run nor setsid to start the applier" >&2; exit 1; }}; as_u env HOME="$h" setsid nohup "$py" -I "$d/apply" >/dev/null 2>&1 </dev/null & fi"#
        ),
        "echo started".to_owned(),
    ]
    .join("; ")
}

/// An apply's facts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyRequest {
    /// Whether the app uploads a file (the caller's `config` payload); none applies what the
    /// machine has.
    pub uploaded: bool,
    pub now_ms: i64,
    /// A UUID of the app's, for the request's name.
    pub nonce: String,
}

/// Uploads the applier and stages this request (`requests/<ms>-<id>.toml` and `.pending`); the
/// start command hands them to the machine's user and only then renames `.pending` to `.json`,
/// which marks the request complete, and starts the applier. A running applier takes the newest
/// staged request after its current one, so two applies never overwrite each other's input.
pub fn apply_plan(request: &ApplyRequest) -> Plan {
    let id = request_id(request.now_ms, &request.nonce);
    let staged = |suffix: &str| format!("{DIRECTORY}/requests/{id}.{suffix}");
    let mut steps = vec![
        Step::Exec { command: prepare_command(), said: Vec::new() },
        // This request's own copy: the start command moves it over `apply` once it is the work
        // user's, so a concurrent apply never replaces the file another one is about to run.
        Step::Write {
            path: staged("apply"),
            mode: 0o700,
            text: Some(applier().to_owned()),
            payload: None,
        },
    ];
    if request.uploaded {
        steps.push(Step::Write {
            path: staged("toml"),
            mode: 0o600,
            text: None,
            payload: Some(crate::machine_bootstrap::Payload::Config),
        });
    }
    let source = if request.uploaded { "uploaded" } else { "auto" };
    steps.push(Step::Write {
        path: staged("pending"),
        mode: 0o600,
        text: Some(format!("{{\"source\":\"{source}\"}}\n")),
        payload: None,
    });
    steps.push(Step::Exec {
        command: start_command(&id),
        said: ["started", "running"].map(String::from).to_vec(),
    });
    Plan { steps }
}

#[cfg(test)]
mod tests;
