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
    /// `-c VALUE`, `--enable VALUE`, `--disable VALUE` and `--profile VALUE`,
    /// in order.
    pub args: Vec<OsString>,
    /// `-C DIR` / `--cd DIR`, as given (relative to the launch folder).
    pub cd: Option<PathBuf>,
    /// A config argument this could not read (not UTF-8 where an option name
    /// is expected, or a `-C` folder that is not): Codex is not asked, the
    /// answer is unknown.
    pub unreadable: bool,
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

/// The options that change which config Codex loads: (short letter, long
/// name, the flag `codex mcp get` takes it as; `None` is `-C`/`--cd`).
const CONFIG_OPTIONS: [(Option<char>, &str, Option<&str>); 5] = [
    (Some('c'), "config", Some("-c")),
    (None, "enable", Some("--enable")),
    (None, "disable", Some("--disable")),
    (Some('p'), "profile", Some("--profile")),
    (Some('C'), "cd", None),
];

/// The config-affecting arguments in Codex's argument list `args` (until
/// `--`): `-c`/`--config`, `--enable`, `--disable`, `-p`/`--profile` and
/// `-C`/`--cd`, in every form clap accepts. A value is passed on as given; an
/// option of these written with bytes that are not UTF-8, or a `-C` folder
/// that is not, makes the arguments [`ConfigArgs::unreadable`].
pub(crate) fn config_args(args: &[OsString]) -> ConfigArgs {
    let mut found = ConfigArgs::default();
    let mut args = args.iter();
    while let Some(raw) = args.next() {
        let Some(arg) = raw.to_str() else {
            let bytes = raw.as_encoded_bytes();
            let ours = [
                &b"-c"[..],
                b"-p",
                b"-C",
                b"--config",
                b"--profile",
                b"--cd",
                b"--enable",
                b"--disable",
            ];
            if ours.iter().any(|prefix| bytes.starts_with(prefix)) {
                found.unreadable = true;
            }
            continue;
        };
        if arg == "--" {
            break;
        }
        for (short, long, as_flag) in CONFIG_OPTIONS {
            let Some(value) = option_value(arg, short, long) else { continue };
            let value = match value {
                Some(value) => Some(OsString::from(value)),
                None => args.next().cloned(),
            };
            let Some(value) = value else { break };
            match as_flag {
                Some(flag) => {
                    found.args.push(OsString::from(flag));
                    found.args.push(value);
                }
                None if value.to_str().is_none() => found.unreadable = true,
                None => found.cd = Some(PathBuf::from(value)),
            }
            break;
        }
    }
    found
}

/// Codex's options that take a value (0.160's top level, `exec`, `resume`
/// and `fork`, and 0.169's `--cyber-access-program`), so the scan below never
/// reads a value as a subcommand or a skip flag. A Codex that adds one can
/// make the scan misread a launch; that is harmless, because the off switch
/// carries its own transport and never leaves Codex an entry it cannot
/// start (agent_computer_use.rs `turn_off_cmux`).
const VALUE_OPTIONS: [&str; 26] = [
    "--cyber-access-program",
    "-c",
    "--config",
    "--enable",
    "--disable",
    "--remote",
    "--remote-auth-token-env",
    "-i",
    "--image",
    "-m",
    "--model",
    "--local-provider",
    "-p",
    "--profile",
    "-s",
    "--sandbox",
    "-C",
    "--cd",
    "--add-dir",
    "-a",
    "--ask-for-approval",
    "--thread-source",
    "--output-schema",
    "--color",
    "-o",
    "--output-last-message",
];

/// Options after which the session's folder or config is not the one `mcp
/// get` sees from the launch folder: a new worktree (`--worktree`, untrusted,
/// no project layer), a remote app server, or no user config.
const DIFFERENT_LAUNCH: [&str; 4] =
    ["--worktree", "--remote", "--remote-auth-token-env", "--ignore-user-config"];

/// Whether this launch's session runs where, and with the config, that
/// `codex mcp get` in the launch folder sees: only an allowlist of new
/// session forms (`codex`, `codex PROMPT`, `review`, `exec`/`e`, `exec
/// review`, `exec PROMPT`), without [`DIFFERENT_LAUNCH`] options. Anything
/// else is not probed: a resumed or forked session (`resume`, `fork`, `exec
/// resume`) keeps the folder and config it was recorded with, and any other
/// word that could name a subcommand (a single lowercase word, such as
/// `execpolicy`, `cloud-tasks` or one a later Codex adds) may be no session at
/// all. A one-word prompt (`codex hi`) reads as such a word too and is not
/// probed either: that only costs the turn-off, never a launch.
pub(crate) fn probe_matches_launch(args: &[OsString]) -> bool {
    let mut args = args.iter();
    let mut positionals = Vec::new();
    // Every argument up to `--`: a skip flag counts after the prompt too
    // (`codex exec hi --worktree`), and option values are never read as one.
    while let Some(arg) = args.next() {
        let Some(arg) = arg.to_str() else { return false };
        if arg == "--" {
            break;
        }
        if !arg.starts_with('-') || arg == "-" {
            positionals.push(arg);
            continue;
        }
        let flag = arg.split('=').next().unwrap_or_default();
        if DIFFERENT_LAUNCH.contains(&flag) {
            return false;
        }
        // `-pwork`, `-C/w`: a short option with its value attached.
        let short_attached = !arg.starts_with("--")
            && arg.chars().nth(2).is_some()
            && arg.get(..2).is_some_and(|short| VALUE_OPTIONS.contains(&short));
        if VALUE_OPTIONS.contains(&flag) && !arg.contains('=') && !short_attached {
            args.next();
        }
    }
    match positionals.as_slice() {
        [] | ["review", ..] => true,
        ["exec" | "e"] | ["exec" | "e", "review", ..] => true,
        ["exec" | "e", next, ..] => !could_be_subcommand(next),
        [first, ..] => !could_be_subcommand(first),
    }
}

/// Whether `word` could name a Codex subcommand: one lowercase word of
/// letters, digits and dashes (`resume`, `cloud-tasks`, `stdio-to-uds`). A
/// prompt is usually more (`"fix the bug"`).
fn could_be_subcommand(word: &str) -> bool {
    word.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && word.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
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
    use std::os::unix::process::CommandExt as _;
    if config.unreadable {
        return CodexEntry::Unknown;
    }
    let folder = config.cd.as_ref().map_or_else(|| cwd.to_path_buf(), |cd| cwd.join(cd));
    // Its own process group, so a timeout ends Codex and anything it started.
    let child = Command::new(codex)
        .process_group(0)
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
        if let Ok(group) = i32::try_from(child.id()) {
            // SAFETY: `kill` takes no pointers; `-group` names the process
            // group this child leads (`process_group(0)` above).
            unsafe { libc::kill(-group, libc::SIGKILL) };
        }
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
            "--disable=g",
            "-C",
            "../x",
            "exec",
            "hi",
        ]));
        assert_eq!(
            strings(&found.args),
            ["-c", "a=1", "-c", "b=2", "-c", "c=3", "--enable", "f", "--disable", "g"]
        );
        assert_eq!(found.cd, Some(PathBuf::from("../x")));
        assert_eq!(config_args(&os(&["--cd=/w"])).cd, Some(PathBuf::from("/w")));
        assert_eq!(config_args(&os(&["-C/w"])).cd, Some(PathBuf::from("/w")));
        let after = config_args(&os(&["--", "-p", "x", "-C", "y"]));
        assert_eq!(after, ConfigArgs::default());
        // A folder or an option that is not UTF-8: unreadable, never guessed.
        use std::os::unix::ffi::OsStringExt as _;
        let odd = OsString::from_vec(b"/w\xff".to_vec());
        assert!(config_args(&[OsString::from("-C"), odd.clone()]).unreadable);
        assert!(config_args(&[OsString::from_vec(b"-C/w\xff".to_vec())]).unreadable);
        let value = config_args(&[OsString::from("-c"), odd.clone()]);
        assert!(!value.unreadable, "a -c value is passed on as given");
        assert_eq!(value.args, [OsString::from("-c"), odd]);
        // Other options and prompts are not config.
        assert_eq!(config_args(&os(&["--model", "o3", "fix -p bug"])), ConfigArgs::default());
    }

    /// Only a new session in the launch folder is probed; a new worktree, a
    /// resumed or forked session, a remote app server, no user config or a
    /// subcommand that is no session is not.
    #[test]
    fn only_a_launch_mcp_get_sees_is_probed() {
        for args in [
            &[][..],
            &["fix the bug"],
            &["Fix it"],
            &["exec", "fix the bug"],
            &["-p", "work", "-C", "sub", "say hi"],
            &["-pwork", "--model", "o3", "resume this"],
            &["e", "--json", "say hi"],
            &["review"],
            &["exec", "review", "--base", "main"],
            &["--", "resume"],
            &["say hi", "--", "--worktree"],
            &["-c", "--worktree", "say hi"],
            &["--cyber-access-program", "--worktree", "say hi"],
        ] {
            assert!(probe_matches_launch(&os(args)), "{args:?}");
        }
        for args in [
            &["--worktree"][..],
            &["exec", "--worktree", "hi"],
            &["resume", "--last"],
            &["fork", "--last"],
            &["exec", "resume", "--last"],
            &["e", "fork", "abc"],
            &["-m", "o3", "resume"],
            &["--remote", "ws://h:1"],
            &["--remote=ws://h:1", "hi"],
            &["exec", "--ignore-user-config", "hi"],
            // A skip flag after the prompt.
            &["exec", "hi", "--worktree"],
            &["exec", "hi", "--ignore-user-config"],
            &["hi", "--remote", "ws://h:1"],
            &["fix the bug", "--worktree"],
            &["cloud"],
            &["app-server"],
            // Subcommands 0.169 adds, and any a later Codex adds.
            &["execpolicy", "check"],
            &["tcp-tunnel"],
            &["responses-api-proxy"],
            &["stdio-to-uds", "/x"],
            &["cloud-tasks"],
            &["exec", "some-new-verb"],
            // A one-word prompt: not probed (only the turn-off is lost).
            &["hi"],
            &["exec", "hi"],
        ] {
            assert!(!probe_matches_launch(&os(args)), "{args:?}");
        }
    }

    /// A fake `codex` at `dir/codex` running `body`; it records its arguments
    /// and folder in `dir/seen`.
    fn fake_codex(dir: &Path, body: &str) -> PathBuf {
        let path = dir.join("codex");
        let seen = dir.join("seen");
        let script =
            format!("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > '{}'\n{body}\n", seen.display());
        // Written by a child process, never through a descriptor of this one:
        // another test's fork could inherit an open write descriptor, and
        // running the script while it is open fails with "Text file busy".
        // A new name each time (rename over the old one), so a script that
        // still runs from an earlier call is never written to.
        let fresh = dir.join(format!("codex.{}", std::process::id()));
        let mut child = Command::new("/bin/sh")
            .args(["-c", "cat > \"$1\" && chmod 755 \"$1\" && mv -f \"$1\" \"$2\"", "sh"])
            .arg(&fresh)
            .arg(&path)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        {
            use std::io::Write as _;
            child.stdin.take().unwrap().write_all(script.as_bytes()).unwrap();
        }
        assert!(child.wait().unwrap().success());
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
        // A timeout ends Codex's whole process group, children included.
        let pid_file = root.join("grandchild");
        let codex =
            fake_codex(&root, &format!("sleep 30 & echo $! > '{}'; wait", pid_file.display()));
        assert_eq!(ask(&codex, Duration::from_millis(500)), CodexEntry::Unknown);
        let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
        // SAFETY: signal 0 only asks whether the process exists. The killed
        // grandchild is reaped by init, so give it a moment to be gone.
        let alive = || unsafe { libc::kill(pid, 0) } == 0;
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while alive() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!alive(), "the grandchild outlived the timeout");
        // An unreadable `-C` is never guessed: Codex is not asked.
        use std::os::unix::ffi::OsStringExt as _;
        let unreadable = config_args(&[OsString::from("-C"), OsString::from_vec(b"\xff".to_vec())]);
        let codex = fake_codex(&root, &format!("echo '{entry}'"));
        std::fs::remove_file(root.join("seen")).unwrap();
        assert_eq!(resolve(&codex, &path, &work, &unreadable, TIMEOUT), CodexEntry::Unknown);
        assert!(!root.join("seen").exists(), "Codex was asked");
    }
}
