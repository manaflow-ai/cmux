//! The one-command ways to get the join line onto a new Mac (Leo,
//! 2026-11-02: "yeah i feel like there's too many commands and clicks to deal
//! with all that tbh", and "that usb key for setting stuff up, the scripts and
//! whatnot"):
//!
//! - `machine add --usb PATH` writes `PATH/cmux-setup.command` (0700: the same
//!   pasted line, then the file removes itself once the join worked) and a
//!   README.txt. The token is in the .command file and nowhere else: not on
//!   stdout, not in `--json`, not in the README. The line lives as long as the
//!   platform allows a line (10 minutes today). Existing files or symlinks at
//!   either name are refused before a token is made; nothing is overwritten.
//! - `machine add USER@HOST --vault|--bootstrap` runs the line on the host over
//!   ssh. The token reaches the remote shell on ssh's stdin (`read`), never in
//!   an argument list on either side, and the remote `sh` gets it in its
//!   environment exactly as the pasted line gives it. ssh's own prompts
//!   (a password, a new host key) go to the terminal, as ssh always does.
//!   Afterwards, on a terminal, it offers the agents' own sign-in on that Mac
//!   (`ssh -t`, the join script's sign-in step): the person signs in through
//!   Claude's and Codex's own flows; no login is read or copied from here.

use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{
    Add, AddArgs, Failure, Hooks, Platform, RunOptions, USB_TTL_SECS, WaitEnd, expiry_words,
    join_line, mint_for, now_ms,
};
use crate::cli::OutputMode;

/// The stick's script: Finder runs a `.command` in Terminal on a double-click.
pub(super) const USB_SCRIPT: &str = "cmux-setup.command";
pub(super) const USB_README: &str = "README.txt";
/// How long `machine add USER@HOST` reads the machine list for the joined machine.
const SSH_SEEN_WITHIN: Duration = Duration::from_secs(30);
/// ssh's own exit code for "could not connect or authenticate".
const SSH_FAILED: i32 = 255;

/// A host ssh can take as one word: `USER@HOST`, `HOST` or an ssh alias. Never an option
/// (`-oProxyCommand=…`), never a space or a control character.
pub(super) fn valid_host(host: &str) -> bool {
    (1..=255).contains(&host.len())
        && !host.starts_with('-')
        && host.bytes().all(|b| b.is_ascii_graphic() && !matches!(b, b'\'' | b'"' | b'\\' | b'`'))
}

/// An origin that is safe unquoted in a remote shell command.
fn shell_safe_origin(origin: &str) -> bool {
    !origin.is_empty()
        && origin
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'/' | b'.' | b'-' | b'_'))
}

/// What to run for ssh: its argv (never a token) and what goes to its stdin.
pub(in crate::cli) struct SshPlan {
    pub argv: Vec<String>,
    /// The token line for the remote `read`; `None`: ssh keeps this terminal's stdin (`-t`).
    pub stdin: Option<Zeroizing<String>>,
}

impl std::fmt::Debug for SshPlan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let stdin = self.stdin.as_ref().map(|_| "***");
        f.debug_struct("SshPlan").field("argv", &self.argv).field("stdin", &stdin).finish()
    }
}

/// The join over ssh: the remote shell reads the token from stdin into an unexported
/// variable, downloads the join script to a temp file (a failed download exits 1, never runs an
/// empty script), and hands the token to its `sh` in its environment, as the pasted line does.
/// Its exit code is the join's.
pub(super) fn join_plan(origin: &str, host: &str, token: &str) -> SshPlan {
    let remote = format!(
        "sh -c 'IFS= read -r t; f=$(mktemp \"${{TMPDIR:-/tmp}}/cmux-join.XXXXXX\") || exit 1; trap \"rm -f \\\"\\$f\\\"\" EXIT; curl -fsSL {origin}/v1/machines/join.sh -o \"$f\" || {{ echo \"cmux: could not download the join script from {origin}\" >&2; exit 1; }}; CMUX_JOIN=\"$t\" sh \"$f\"'"
    );
    SshPlan {
        argv: ["ssh", "-o", "ConnectTimeout=15", "--", host, remote.as_str()]
            .map(str::to_owned)
            .to_vec(),
        stdin: Some(Zeroizing::new(format!("{token}\n"))),
    }
}

/// The agents' own sign-in on the host, on this terminal (`ssh -t`): the join script's
/// sign-in step, which runs `claude` and `codex login` there for the person.
pub(super) fn signin_plan(origin: &str, host: &str) -> SshPlan {
    let remote =
        format!("sh -c 'curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN_STEP=signin sh'");
    SshPlan {
        argv: ["ssh", "-t", "-o", "ConnectTimeout=15", "--", host, remote.as_str()]
            .map(str::to_owned)
            .to_vec(),
        stdin: None,
    }
}

/// The one command a person runs later to sign in the host's agents through their own flows.
pub(super) fn signin_hint(origin: &str, host: &str) -> String {
    format!("ssh -t {host} 'curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN_STEP=signin sh'")
}

/// Runs `plan`: the token (if any) is written to ssh's stdin and the pipe closed; the remote
/// join's own lines go to stderr, so stdout stays this command's answer. ssh's exit code.
pub(super) fn run_ssh(plan: &SshPlan) -> std::io::Result<i32> {
    use std::os::fd::AsFd as _;
    let (program, args) = plan.argv.split_first().ok_or_else(|| std::io::Error::other("no ssh"))?;
    let mut command = cmux_process::Command::new(program);
    command.args(args);
    match &plan.stdin {
        Some(_) => {
            let progress = std::io::stderr().as_fd().try_clone_to_owned()?;
            command.stdin(cmux_process::Stdio::piped()).stdout(progress);
        }
        None => {
            command.stdin(cmux_process::Stdio::inherit());
        }
    }
    let mut child = command.spawn()?;
    if let (Some(input), Some(mut pipe)) = (&plan.stdin, child.stdin.take()) {
        // An ssh that ended early (refused, no route) closes the pipe: its exit code says why.
        let _ = pipe.write_all(input.as_bytes());
        drop(pipe);
    }
    let status = child.wait()?;
    Ok(status.code().unwrap_or(SSH_FAILED))
}

/// The stick's `.command`: downloads the join script to a temp file (a failed download keeps
/// the file and exits nonzero), runs it with the token in its environment, and removes itself
/// only once the join worked; otherwise it exits with the join's code.
pub(super) fn usb_script(origin: &str, token: &str, expires: &str) -> String {
    format!(
        "#!/bin/sh
# cmux: makes this Mac one of your cmux machines. Double-click it in Finder.
# It works once and expires {expires}. Whoever holds this file can join
# your team's machines until then. Once the join works it deletes itself.
here=\"$0\"
f=\"$(mktemp \"${{TMPDIR:-/tmp}}/cmux-join.XXXXXX\")\" || exit 1
trap 'rm -f \"$f\"' EXIT
if ! curl -fsSL {origin}/v1/machines/join.sh -o \"$f\"; then
  printf '%s\\n' \"cmux: could not download the join script from {origin}; check this Mac's internet, then double-click again\"
  exit 1
fi
if CMUX_JOIN={token} sh \"$f\"; then
  rm -f -- \"$here\" && printf '%s\\n' \"cmux: done; removed $here\"
else
  rc=$?
  printf '%s\\n' \"cmux: the join did not finish (exit $rc); the lines above say why\"
  exit \"$rc\"
fi
"
    )
}

/// The stick's README: no token.
pub(super) fn usb_readme(expires: &str, vault: bool) -> String {
    let vault = if vault {
        "It also gives that Mac the env vars in your cmux vault (cmux machine vault ls).\n"
    } else {
        ""
    };
    format!(
        "cmux machine setup

On the new Mac: plug in this stick, open it in Finder and double-click
cmux-setup.command. It installs cmux's machine daemon, joins the Mac to your
cmux machines, installs Claude Code and Codex if they are missing, and then
asks you to sign in to them on that Mac with their own sign-in.
{vault}
The file works once and expires {expires}. Until it is used or expires,
anyone who holds this stick can join a machine to your team: keep the stick
with you, or delete cmux-setup.command to cancel. It deletes itself once a
join works.
"
    )
}

/// "on 2026-11-03 at 14:32 UTC", or "soon" when the time is unreadable.
pub(super) fn expiry_date_words(expires_at_ms: Option<u64>) -> String {
    let Some(ms) = expires_at_ms else { return "soon".into() };
    let secs = ms / 1000;
    let (days, of_day) = (secs / 86_400, secs % 86_400);
    let (y, m, d) = civil_from_days(i64::try_from(days).unwrap_or(0));
    format!("on {y:04}-{m:02}-{d:02} at {:02}:{:02} UTC", of_day / 3600, (of_day / 60) % 60)
}

/// Days since 1970-01-01 as a proleptic Gregorian date (H. Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, u32::try_from(m).unwrap_or(1), u32::try_from(d).unwrap_or(1))
}

/// The stick's file names that are already taken (a file, a folder or a symlink, followed or
/// not): nothing is ever overwritten or written through a link.
pub(super) fn usb_taken(dir: &Path) -> Vec<PathBuf> {
    [USB_SCRIPT, USB_README]
        .iter()
        .map(|name| dir.join(name))
        .filter(|path| std::fs::symlink_metadata(path).is_ok())
        .collect()
}

/// Writes the stick's two files, each new (`O_CREAT|O_EXCL`, which never follows a symlink):
/// the `.command` owner-only (0700), the README 0644.
pub(super) fn write_usb(
    dir: &Path,
    script: &str,
    readme: &str,
) -> std::io::Result<(PathBuf, PathBuf)> {
    use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
    let script_path = dir.join(USB_SCRIPT);
    let readme_path = dir.join(USB_README);
    let create = |path: &Path, mode: u32, text: &str| -> std::io::Result<()> {
        let mut file =
            std::fs::OpenOptions::new().write(true).create_new(true).mode(mode).open(path)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        // The umask may have taken bits off.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
    };
    create(&readme_path, 0o644, readme)?;
    if let Err(e) = create(&script_path, 0o700, script) {
        let _ = std::fs::remove_file(&readme_path);
        return Err(e);
    }
    Ok((script_path, readme_path))
}

pub(super) fn add_usb(
    platform: &Platform,
    args: &AddArgs,
    dir: &Path,
    output: OutputMode,
    out: &mut dyn Write,
    options: RunOptions,
) -> Result<i32, Failure> {
    // Checked before a token exists, so a wrong path or a used stick spends nothing.
    if !std::fs::metadata(dir).is_ok_and(|m| m.is_dir()) {
        return Err(Failure::usage(format!(
            "{} is not a folder: name the stick's folder (for example /Volumes/STICK)",
            dir.display()
        )));
    }
    if let Some(taken) = usb_taken(dir).first() {
        return Err(Failure::usage(format!(
            "{} already exists: remove it (and the stick's other cmux file) first; nothing is overwritten",
            taken.display()
        )));
    }
    let add = Add {
        name: args.name.as_deref(),
        ttl: Some(args.ttl.unwrap_or(USB_TTL_SECS)),
        wait: false,
        every: options.every,
        vault: args.vault,
    };
    let minted = mint_for(platform, &add)?;
    let expires = expiry_date_words(minted.expires_at_ms);
    let script = Zeroizing::new(usb_script(&platform.origin, &minted.token, &expires));
    let (script_path, readme_path) = write_usb(dir, &script, &usb_readme(&expires, args.vault))
        .map_err(|e| {
            Failure::new(
                "machine_join.usb",
                format!(
                    "cannot write to {} ({:?}); the line was not saved and expires on its own",
                    dir.display(),
                    e.kind()
                ),
            )
        })?;
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    let summary = json!({
        "usb": { "script": script_path, "readme": readme_path },
        "joinTokenId": minted.join_token_id,
        "expiresAt": minted.expires_at,
        "teamId": minted.team_id,
        "name": minted.label.or_else(|| args.name.clone()),
        "vault": args.vault,
    });
    match output {
        OutputMode::Human => writeln!(
            out,
            "Wrote {} and {}.\nOn the new Mac: plug in the stick, open it in Finder and double-click {USB_SCRIPT}. It works once and expires {expires}.\nWhoever holds this stick can join your team's machines until the line is used or expires; delete {USB_SCRIPT} to cancel sooner.",
            script_path.display(),
            readme_path.display(),
        )
        .map_err(io)?,
        OutputMode::Json => writeln!(out, "{summary}").map_err(io)?,
        OutputMode::JsonLines => {
            let mut event = summary;
            if let Some(object) = event.as_object_mut() {
                object.insert("event".into(), json!("written"));
            }
            writeln!(out, "{event}").map_err(io)?;
        }
        OutputMode::Quiet => {}
    }
    Ok(0)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn add_over_ssh(
    platform: &Platform,
    args: &AddArgs,
    host: &str,
    output: OutputMode,
    out: &mut dyn Write,
    options: RunOptions,
    hooks: &mut Hooks<'_>,
    interrupt: impl Future<Output = ()>,
) -> Result<i32, Failure> {
    if !shell_safe_origin(&platform.origin) {
        return Err(Failure::usage(
            "this platform origin cannot go in a remote command: use the pasted line (cmux machine add)",
        ));
    }
    let add = Add {
        name: args.name.as_deref(),
        ttl: args.ttl,
        wait: false,
        every: options.every,
        vault: args.vault,
    };
    let minted = mint_for(platform, &add)?;
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    if output == OutputMode::Human {
        writeln!(
            out,
            "Joining {host} over ssh (ssh may ask for its password or to trust its host key)…"
        )
        .map_err(io)?;
        out.flush().map_err(io)?;
    }
    let code = (hooks.ssh)(&join_plan(&platform.origin, host, &minted.token)).map_err(|e| {
        Failure::new("machine_join.ssh", format!("cannot run ssh ({:?})", e.kind()))
    })?;
    if code == SSH_FAILED {
        let line = join_line(&platform.origin, &minted.token);
        let expiry = expiry_words(minted.expires_at_ms, now_ms());
        match output {
            OutputMode::Human => writeln!(
                out,
                "ssh could not reach {host}. If Remote Login is off on that Mac, turn it on there: System Settings > General > Sharing > Remote Login, then run this again.\nOr paste this line on it instead (it works once and {expiry}):\n\n{line}\n"
            )
            .map_err(io)?,
            OutputMode::Json | OutputMode::JsonLines => {
                let value = json!({
                    "event": "ssh_unreachable",
                    "host": host,
                    "line": line,
                    "token": minted.token,
                    "joinTokenId": minted.join_token_id,
                    "expiresAt": minted.expires_at,
                });
                writeln!(out, "{value}").map_err(io)?;
            }
            OutputMode::Quiet => {}
        }
        return Ok(4);
    }
    if code != 0 {
        return Err(Failure::new(
            "machine_join.remote_failed",
            format!("the join on {host} did not finish (exit {code}); its own lines above say why"),
        ));
    }
    // The join already finished on the host; `--no-wait` skips only the look in the list.
    let end = if args.wait == Some(false) {
        WaitEnd::Expired
    } else {
        let deadline = minted
            .expires_at_ms
            .unwrap_or(u64::MAX)
            .min(now_ms() + SSH_SEEN_WITHIN.as_millis() as u64);
        platform
            .wait_for_join(&minted.join_token_id, deadline, options.every, interrupt)
            .unwrap_or(WaitEnd::Expired)
    };
    let joined = match &end {
        WaitEnd::Joined(machine) => {
            json!({ "machineId": machine.machine_id, "name": machine.name })
        }
        WaitEnd::Expired | WaitEnd::Interrupted => Value::Null,
    };
    match output {
        OutputMode::Human => {
            let text = match &end {
                WaitEnd::Joined(machine) => {
                    format!("{} joined (machine {}).", machine.name, machine.machine_id)
                }
                _ => format!(
                    "{host} ran the join; it shows in `cmux machine list` once it reports in."
                ),
            };
            writeln!(out, "{text}").map_err(io)?;
        }
        OutputMode::Json | OutputMode::JsonLines => {
            let value = json!({
                "event": "joined",
                "host": host,
                "joinTokenId": minted.join_token_id,
                "vault": args.vault,
                "joined": joined,
            });
            writeln!(out, "{value}").map_err(io)?;
        }
        OutputMode::Quiet => {}
    }
    if output == OutputMode::Human {
        let question = format!(
            "Sign in to Claude Code and Codex on {host} now, with their own sign-in on that Mac?"
        );
        if options.interactive && (hooks.confirm)(&question) {
            let _ = (hooks.ssh)(&signin_plan(&platform.origin, host));
        } else {
            // The sign-in step finds the agents where they are installed on that Mac (the
            // managed Codex is not on PATH), so the hint runs it rather than naming a binary.
            writeln!(out, "To sign in its agents there: {}", signin_hint(&platform.origin, host))
                .map_err(io)?;
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests;
