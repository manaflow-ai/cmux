//! The person's own `cmux` MCP entry as Codex itself resolves it, for the
//! `codex` shim's placement of this build's server (agent_computer_use.rs).
//!
//! Codex merges many config layers (system, user, `--profile` files, trusted
//! projects from the git root, worktrees, per-folder trust, `-C`, `-c`), and
//! a copy of those rules drifted from Codex's own. So the shim asks Codex:
//! before the launch it runs `codex [config args] mcp get cmux --json` in the
//! launch's folder (or `-C`'s), with the same config-affecting arguments the
//! person passed (`-c`/`--config`, `--enable`, `-p`/`--profile` in any form),
//! and reads the merged entry Codex prints. That takes about 25 ms (Codex
//! 0.160.1 on a fleet Mac), so nothing is cached. When Codex does not answer
//! within [`TIMEOUT`], fails, or prints something unreadable, the answer is
//! [`CodexEntry::Unknown`] and the shim takes the safe placement.

use std::ffi::{OsStr, OsString};
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use crate::agent_computer_use::{CodexEntry, SERVER};

/// The longest the shim waits for Codex's answer before it launches.
pub(crate) const TIMEOUT: Duration = Duration::from_secs(2);

/// What Codex prints for a name it has no server under (Codex 0.160.1).
const NO_SERVER: &str = "No MCP server named";

/// The person's Codex arguments that change which config Codex loads, as
/// `codex mcp get` takes them, and the folder `-C`/`--cd` names.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ConfigArgs {
    /// `-c VALUE`, `--enable VALUE` and `--profile VALUE`, in order.
    pub args: Vec<OsString>,
    /// `-C DIR` / `--cd DIR`, as given (relative to the launch folder).
    pub cd: Option<PathBuf>,
}

/// The value of option `long` (or its `short` letter) when `arg` is one: the
/// next argument for `-x`/`--long`, or the attached one in `-xVALUE`,
/// `-x=VALUE` and `--long=VALUE`. `Some(None)` means it takes the next one.
fn option_value<'a>(arg: &'a str, short: Option<char>, long: &str) -> Option<Option<&'a str>> {
    if let Some(rest) = arg.strip_prefix("--").and_then(|rest| rest.strip_prefix(long)) {
        return match rest.strip_prefix('=') {
            Some(value) => Some(Some(value)),
            None if rest.is_empty() => Some(None),
            None => None,
        };
    }
    let short = short?;
    let rest = arg.strip_prefix('-')?.strip_prefix(short)?;
    if arg.starts_with("--") {
        return None;
    }
    if rest.is_empty() {
        return Some(None);
    }
    Some(Some(rest.strip_prefix('=').unwrap_or(rest)))
}

/// The config-affecting arguments in Codex's argument list `args` (until
/// `--`): `-c`/`--config`, `--enable`, `-p`/`--profile` and `-C`/`--cd`, in
/// every form clap accepts.
pub(crate) fn config_args(args: &[OsString]) -> ConfigArgs {
    let mut found = ConfigArgs::default();
    let mut args = args.iter().map(|arg| arg.to_str());
    while let Some(arg) = args.next() {
        let Some(arg) = arg else { continue };
        if arg == "--" {
            break;
        }
        for (short, long, as_flag) in [
            (Some('c'), "config", Some("-c")),
            (None, "enable", Some("--enable")),
            (Some('p'), "profile", Some("--profile")),
            (Some('C'), "cd", None),
        ] {
            let Some(value) = option_value(arg, short, long) else { continue };
            let value = match value {
                Some(value) => Some(value.to_owned()),
                None => args.next().flatten().map(str::to_owned),
            };
            if let Some(value) = value {
                match as_flag {
                    Some(flag) => {
                        found.args.push(OsString::from(flag));
                        found.args.push(OsString::from(value));
                    }
                    None => found.cd = Some(PathBuf::from(value)),
                }
            }
            break;
        }
    }
    found
}

/// Asks the Codex at `codex` for its `cmux` entry: `codex <config args> mcp
/// get cmux --json` in `cwd` (joined with `-C`'s folder), with `PATH` set to
/// `path`, bounded by `timeout`.
pub(crate) fn resolve(
    codex: &Path,
    path: &OsStr,
    cwd: &Path,
    config: &ConfigArgs,
    timeout: Duration,
) -> CodexEntry {
    let folder = config.cd.as_ref().map_or_else(|| cwd.to_path_buf(), |cd| cwd.join(cd));
    let child = Command::new(codex)
        .args(&config.args)
        .args(["mcp", "get", SERVER, "--json"])
        .current_dir(&folder)
        .env("PATH", path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let Ok(mut child) = child else { return CodexEntry::Unknown };
    let (Some(mut stdout), Some(mut stderr)) = (child.stdout.take(), child.stderr.take()) else {
        let _ = child.kill();
        let _ = child.wait();
        return CodexEntry::Unknown;
    };
    let (sender, receiver) = mpsc::channel();
    // Reads both pipes to their end, so a chatty Codex never blocks on a full
    // pipe; the answer comes back on the channel.
    std::thread::spawn(move || {
        let err = std::thread::spawn(move || {
            let mut text = Vec::new();
            let _ = stderr.read_to_end(&mut text);
            text
        });
        let mut out = Vec::new();
        let _ = stdout.read_to_end(&mut out);
        let err = err.join().unwrap_or_default();
        let _ = sender.send((out, err));
    });
    let Ok((out, err)) = receiver.recv_timeout(timeout) else {
        let _ = child.kill();
        let _ = child.wait();
        return CodexEntry::Unknown;
    };
    let Ok(status) = child.wait() else { return CodexEntry::Unknown };
    if status.success() {
        return match serde_json::from_slice::<serde_json::Value>(&out) {
            Ok(entry) if entry.is_object() => CodexEntry::Found(entry),
            _ => CodexEntry::Unknown,
        };
    }
    if String::from_utf8_lossy(&err).contains(NO_SERVER) {
        CodexEntry::Absent
    } else {
        CodexEntry::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    fn strings(args: &[OsString]) -> Vec<String> {
        args.iter().map(|a| a.to_string_lossy().into_owned()).collect()
    }

    /// Every form clap gives `-p`, `-c`, `--enable` and `-C`; nothing after `--`.
    #[test]
    fn config_args_are_read_in_every_form() {
        for (given, profile) in [
            (&["-p", "work"][..], "work"),
            (&["-pwork"], "work"),
            (&["-p=work"], "work"),
            (&["--profile", "work"], "work"),
            (&["--profile=work"], "work"),
        ] {
            assert_eq!(strings(&config_args(&os(given)).args), ["--profile", profile], "{given:?}");
        }
        let found = config_args(&os(&[
            "-c",
            "a=1",
            "--config=b=2",
            "-cc=3",
            "--enable",
            "f",
            "-C",
            "../x",
            "exec",
            "hi",
        ]));
        assert_eq!(strings(&found.args), ["-c", "a=1", "-c", "b=2", "-c", "c=3", "--enable", "f"]);
        assert_eq!(found.cd, Some(PathBuf::from("../x")));
        assert_eq!(config_args(&os(&["--cd=/w"])).cd, Some(PathBuf::from("/w")));
        assert_eq!(config_args(&os(&["-C/w"])).cd, Some(PathBuf::from("/w")));
        let after = config_args(&os(&["--", "-p", "x", "-C", "y"]));
        assert_eq!(after, ConfigArgs::default());
        // Other options and prompts are not config.
        assert_eq!(config_args(&os(&["--model", "o3", "fix -p bug"])), ConfigArgs::default());
    }

    /// A fake `codex` at `dir/codex` running `body`; it records its arguments
    /// and folder in `dir/seen`.
    fn fake_codex(dir: &Path, body: &str) -> PathBuf {
        let path = dir.join("codex");
        let seen = dir.join("seen");
        std::fs::write(
            &path,
            format!("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > '{}'\n{body}\n", seen.display()),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// What the shim gets from Codex: the entry it prints, no entry, or an
    /// unknown answer when Codex fails, prints nonsense or takes too long; it
    /// asks with the person's config arguments, in `-C`'s folder.
    #[test]
    fn resolve_asks_codex_and_reads_its_answer() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let work = root.join("work");
        std::fs::create_dir_all(work.join("sub")).unwrap();
        let path = OsString::from("/usr/bin:/bin");
        let config = config_args(&os(&["-p", "w", "-c", "x=1", "-C", "sub"]));
        let ask = |codex: &Path, timeout| resolve(codex, &path, &work, &config, timeout);

        let entry = r#"{"name":"cmux","enabled":true,"transport":{"type":"stdio","command":"/opt/cmux","args":["mcp","serve"]}}"#;
        let codex = fake_codex(&root, &format!("echo '{entry}'"));
        let CodexEntry::Found(found) = ask(&codex, TIMEOUT) else { panic!("no entry") };
        assert_eq!(found["transport"]["command"], "/opt/cmux");
        let seen = std::fs::read_to_string(root.join("seen")).unwrap();
        let seen: Vec<&str> = seen.lines().collect();
        assert_eq!(seen[0], work.join("sub").to_str().unwrap(), "asked in -C's folder");
        assert_eq!(seen[1..], ["--profile", "w", "-c", "x=1", "mcp", "get", "cmux", "--json"]);

        let codex =
            fake_codex(&root, "echo \"Error: No MCP server named 'cmux' found.\" >&2; exit 1");
        assert_eq!(ask(&codex, TIMEOUT), CodexEntry::Absent);
        let codex = fake_codex(&root, "echo 'Error: failed to load configuration' >&2; exit 1");
        assert_eq!(ask(&codex, TIMEOUT), CodexEntry::Unknown);
        let codex = fake_codex(&root, "echo 'not json'");
        assert_eq!(ask(&codex, TIMEOUT), CodexEntry::Unknown);
        let codex = fake_codex(&root, "exec sleep 30");
        let started = std::time::Instant::now();
        assert_eq!(ask(&codex, Duration::from_millis(300)), CodexEntry::Unknown);
        assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
        assert_eq!(ask(&root.join("missing"), TIMEOUT), CodexEntry::Unknown);
    }
}
